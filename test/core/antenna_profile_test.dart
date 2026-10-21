// Antenna profiles per radio (spec m1-app-0.4.0 §4; AC-14, AC-15; ranges from CMAT validate.ts:77–79).
//
// API under test (lib/core/antenna_profile.dart, lib/core/api.dart; JSON mount names chosen by Q = the enum names):
//   enum AntennaMount { handheld, insideCar, roofMagMount, fixedMast }
//   AntennaProfile({required AntennaMount mount, double? gainDbi /* null = Don't know */, required double heightM,
//       required DateTime updatedAt}); toJson() -> {mount, gain_dbi, height_m, updated_at}; Antenna toAntenna() (v1 wire)
//   static AntennaProfile? AntennaProfile.tryParse(Object? json) -> null for an unknown mount / out-of-range number
//   Settings.antennaProfiles: Map<String, AntennaProfile> keyed by lower-case companion public key;
//       JSON `antenna_profiles`; copyWith(antennaProfiles: …)
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/settings_store.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

final t0 = DateTime.utc(2026, 10, 17, 12);

AntennaProfile prof(AntennaMount m, {double? gain, double height = 1.8}) =>
    AntennaProfile(mount: m, gainDbi: gain, heightM: height, updatedAt: t0);

void main() {
  group('AC-14 wire mapping (Drive Format v1 session, v1.1 ping fields)', () {
    test('handheld and inside car → internal; roof mag-mount and fixed mast → external', () {
      expect(prof(AntennaMount.handheld).toAntenna().type, 'internal');
      expect(prof(AntennaMount.insideCar).toAntenna().type, 'internal');
      expect(prof(AntennaMount.roofMagMount).toAntenna().type, 'external');
      expect(prof(AntennaMount.fixedMast).toAntenna().type, 'external');
    });

    test('gain passed through, "Don\'t know" → null; height passed through; mount itself not on the wire', () {
      expect(prof(AntennaMount.roofMagMount, gain: 5.8, height: 1.8).toAntenna().toJson(),
          {'type': 'external', 'gain_dbi': 5.8, 'height_m': 1.8});
      expect(prof(AntennaMount.handheld, height: 1.2).toAntenna().toJson(),
          {'type': 'internal', 'gain_dbi': null, 'height_m': 1.2});
    });

    test('golden: an upload body with a profile-mapped antenna has exactly the v1 keys and passes the v1 shape rules', () {
      final base = makeSession();
      final session = DriveSession(
        id: base.id,
        startedAt: base.startedAt,
        label: base.label,
        channel: base.channel,
        radio: base.radio,
        antenna: prof(AntennaMount.fixedMast, gain: null, height: 6).toAntenna(),
        companion: base.companion,
      );
      // build is new in 0.4.0 for reports; it must not leak into the v1 upload's `app`.
      const app = AppInfo(name: 'MeshSonar', version: '0.4.0', build: '5', platform: 'iOS');
      final body = jsonDecode(jsonEncode(DriveBatch(app: app, session: session, pings: [makePing(0), makePing(1)]).toJson()))
          as Map<String, dynamic>;
      expect(shapeProblems(body), isEmpty);
      expect(body.keys.toSet(), {'format', 'app', 'session', 'pings'});
      expect(body['format'], 'meshsonar.drive.v1');
      expect((body['app'] as Map).keys.toSet(), {'name', 'version', 'platform'});
      final s = body['session'] as Map;
      expect(s.keys.toSet(), {'id', 'started_at', 'ended_at', 'label', 'channel', 'radio', 'antenna', 'companion'});
      expect(s['antenna'], {'type': 'external', 'gain_dbi': null, 'height_m': 6});
      expect((s['radio'] as Map).keys.toSet(), {'freq_mhz', 'bw_khz', 'sf', 'cr', 'tx_dbm'});
      expect((s['companion'] as Map).keys.toSet(), {'public_key', 'name', 'firmware'});
      for (final ping in (body['pings'] as List).cast<Map>()) {
        expect(ping.keys.toSet(),
            {'id', 'ts', 'lat', 'lon', 'gps_accuracy_m', 'speed_mps', 'kind', 'noise_floor_dbm', 'echoes', 'neighbor',
              // 0.6.0: the Drive Format v1.1 ping fields (optional; the v1 server ignores them)
              'pkt_hash', 'tx_epoch_s', 'tx_dbm', 'wire_tag'});
      }
      expect(jsonEncode(body), isNot(contains('mount')));
      expect(jsonEncode(body), isNot(contains('fixedMast')));
    });
  });

  group('ranges as the server validator: gain −10…20 dBi, height 0…300 m; height required', () {
    Map<String, Object?> j({Object? mount = 'roofMagMount', Object? gain = 5.8, Object? height = 1.8}) =>
        {'mount': mount, 'gain_dbi': gain, 'height_m': height, 'updated_at': '2026-10-17T12:00:00.000Z'};

    test('edges are accepted', () {
      for (final (g, h) in [(-10, 0), (20, 300), (null, 0.5), (0, 300.0)]) {
        final x = AntennaProfile.tryParse(j(gain: g, height: h));
        expect(x, isNotNull, reason: 'gain $g height $h');
        expect(x!.gainDbi, g?.toDouble());
        expect(x.heightM, h.toDouble());
      }
    });

    test('out of range, wrong type, missing height or unknown mount → that profile is dropped (null)', () {
      for (final bad in [
        j(gain: -10.5),
        j(gain: 20.1),
        j(height: -0.1),
        j(height: 300.5),
        j(height: null),
        j(height: 'tall'),
        j(gain: 'high'),
        j(gain: double.nan),
        j(mount: 'mag-mount'),
        j(mount: null),
        'not a map',
        null,
      ]) {
        expect(AntennaProfile.tryParse(bad), isNull, reason: '$bad');
      }
    });

    test('every mount round-trips through JSON', () {
      for (final m in AntennaMount.values) {
        final x = prof(m, gain: 2.5, height: 4);
        final back = AntennaProfile.tryParse(jsonDecode(jsonEncode(x.toJson())));
        expect(back!.mount, m);
        expect(back.gainDbi, 2.5);
        expect(back.heightM, 4);
        expect(back.updatedAt, t0);
      }
      expect(prof(AntennaMount.handheld).toJson().keys.toSet(), {'mount', 'gain_dbi', 'height_m', 'updated_at'});
    });
  });

  group('settings', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('meshsonar_antenna_'));
    tearDown(() async => tmp.delete(recursive: true));

    test('profiles are stored per radio (lower-case key) and survive save/load', () async {
      final store = FileSettingsStore(File(p.join(tmp.path, 'settings.json')));
      final s = const Settings().copyWith(antennaProfiles: {
        'abcdef0123': prof(AntennaMount.roofMagMount, gain: 5.8),
        'ffee000111': prof(AntennaMount.handheld, height: 1.2),
      });
      await store.save(s);
      final raw = jsonDecode(File(p.join(tmp.path, 'settings.json')).readAsStringSync()) as Map;
      expect((raw['antenna_profiles'] as Map).keys.toSet(), {'abcdef0123', 'ffee000111'});
      final back = await store.load();
      expect(back.antennaProfiles.keys.toSet(), {'abcdef0123', 'ffee000111'});
      expect(back.antennaProfiles['abcdef0123']!.mount, AntennaMount.roofMagMount);
      expect(back.antennaProfiles['abcdef0123']!.gainDbi, 5.8);
      expect(back.antennaProfiles['ffee000111']!.gainDbi, isNull);
    });

    test('upper-case keys in the file are lower-cased', () {
      final s = Settings.fromJson({
        'antenna_profiles': {
          'ABCDEF0123': {'mount': 'fixedMast', 'gain_dbi': 3, 'height_m': 8, 'updated_at': '2026-10-17T12:00:00.000Z'},
        },
      });
      expect(s.antennaProfiles.keys, ['abcdef0123']);
    });

    test('one bad profile drops only that profile, never the rest of the settings', () {
      final s = Settings.fromJson({
        'server_url': 'https://example.org',
        'driver_key': 'ms_k',
        'key_status': 'approved',
        'interval_sec': 45,
        'antenna_profiles': {
          'aa11': {'mount': 'roofMagMount', 'gain_dbi': 5.8, 'height_m': 1.8, 'updated_at': '2026-10-17T12:00:00.000Z'},
          'bb22': {'mount': 'spaceship', 'gain_dbi': 5.8, 'height_m': 1.8, 'updated_at': '2026-10-17T12:00:00.000Z'},
          'cc33': {'mount': 'handheld', 'gain_dbi': 99, 'height_m': 1.8, 'updated_at': '2026-10-17T12:00:00.000Z'},
          'dd44': 'garbage',
        },
      });
      expect(s.antennaProfiles.keys.toSet(), {'aa11'});
      expect(s.serverUrl, 'https://example.org');
      expect(s.driverKey, 'ms_k');
      expect(s.intervalSec, 45);
      expect(Settings.fromJson({'antenna_profiles': 'nope'}).antennaProfiles, isEmpty);
      expect(const Settings().antennaProfiles, isEmpty);
    });

    test('AC-15: 0.3.x settings load with no profiles, the old antenna kept read-only, nothing else changed', () async {
      final f = File(p.join(tmp.path, 'settings.json'));
      final old = {
        'server_url': 'https://cmh-meshcore.lovable.app',
        'driver_key': 'ms_old_key_0123456789abcdef',
        'key_status': 'approved',
        'display': 'KE4BFI',
        'channel': '#wardriving',
        'interval_sec': 30,
        'min_distance_m': 100,
        'antenna': {'type': 'external', 'gain_dbi': 5.8, 'height_m': 1.8},
        'auto_sync': true,
        'sync_during_drive': true,
        'sync_every_min': 5,
        'heard_hold_pings': 3,
      };
      f.writeAsStringSync(jsonEncode(old));
      final store = FileSettingsStore(f);
      final s = await store.load();
      expect(s.antennaProfiles, isEmpty);
      expect(s.antenna.toJson(), {'type': 'external', 'gain_dbi': 5.8, 'height_m': 1.8});
      await store.save(s);
      final saved = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      for (final k in old.keys) {
        expect(saved[k], old[k], reason: '$k must be unchanged by the 0.4.0 upgrade');
      }
      // 0.11.0 adds discoveryMode alongside the 0.4.0 antennaProfiles upgrade.
      expect(saved.keys.toSet().difference(old.keys.toSet()), {'antenna_profiles', 'discovery_mode'});
    });
  });
}
