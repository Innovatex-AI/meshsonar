import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/settings_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('meshsonar_settings_'));
  tearDown(() async => tmp.delete(recursive: true));

  test('missing file gives defaults', () async {
    final s = await FileSettingsStore(File(p.join(tmp.path, 'nope', 'settings.json'))).load();
    expect(s.toJson(), const Settings().toJson());
  });

  test('corrupt file gives defaults', () async {
    final f = File(p.join(tmp.path, 'settings.json'))..writeAsStringSync('{"server_url": "x", trunc');
    expect((await FileSettingsStore(f).load()).toJson(), const Settings().toJson());
    f.writeAsStringSync('[1,2,3]');
    expect((await FileSettingsStore(f).load()).toJson(), const Settings().toJson());
    f.writeAsStringSync('{"interval_sec": "thirty"}');
    expect((await FileSettingsStore(f).load()).toJson(), const Settings().toJson());
  });

  test('save then load round-trips, creating the folder, no temp file left', () async {
    final f = File(p.join(tmp.path, 'a', 'b', 'settings.json'));
    final store = FileSettingsStore(f);
    const s = Settings(
      serverUrl: 'https://example.org',
      driverKey: 'ms_abcdefghijklmnopqrstuvwxyz',
      keyStatus: DriverKeyStatus.approved,
      display: 'KE4BFI',
      channel: '#test',
      intervalSec: 15,
      minDistanceM: 50,
      antenna: Antenna(type: 'external', gainDbi: 3, heightM: 1.5),
      autoSync: false,
    );
    await store.save(s);
    expect((await FileSettingsStore(f).load()).toJson(), s.toJson());
    expect(File('${f.path}.tmp').existsSync(), isFalse);
  });

  test('rapid saves are serialized; last one wins', () async {
    final f = File(p.join(tmp.path, 'settings.json'));
    final store = FileSettingsStore(f);
    await Future.wait([for (var i = 1; i <= 20; i++) store.save(Settings(intervalSec: 10 + i))]);
    expect((await store.load()).intervalSec, 30);
  });

  test('old/odd values are brought into range; antenna defaults to internal', () {
    final s = Settings.fromJson({'interval_sec': 0, 'min_distance_m': 5000, 'sync_every_min': 0, 'antenna': {'type': 'mag-mount', 'gain_dbi': 3}});
    expect(s.intervalSec, Settings.minIntervalSec);
    expect(s.minDistanceM, Settings.maxDistance);
    expect(s.syncEveryMin, Settings.minSyncEveryMin);
    expect(s.antenna.type, 'internal');
    expect(s.antenna.gainDbi, 3);
    expect(const Settings().antenna.type, 'internal');
    expect(const Settings().syncDuringDrive, isTrue);
  });


  test('numbers written as 30.0 load (num-tolerant), and one odd field never resets the rest', () async {
    final f = File(p.join(tmp.path, 'settings.json'))
      ..writeAsStringSync('{"server_url": "https://example.org", "driver_key": "ms_k", "key_status": "approved", '
          '"interval_sec": 45.0, "min_distance_m": 150.0, "sync_every_min": 7.0, "heard_hold_pings": 4.0, '
          '"antenna": {"type": "external", "gain_dbi": 3, "height_m": 2}, "auto_sync": false}');
    final s = await FileSettingsStore(f).load();
    expect(s.serverUrl, 'https://example.org');
    expect(s.driverKey, 'ms_k');
    expect(s.keyStatus, DriverKeyStatus.approved);
    expect(s.intervalSec, 45);
    expect(s.minDistanceM, 150);
    expect(s.syncEveryMin, 7);
    expect(s.heardHoldPings, 4);
    expect(s.antenna.type, 'external');
    expect(s.autoSync, isFalse);

    // Wrong types fall back field by field instead of throwing away the whole file.
    final odd = Settings.fromJson({
      'server_url': 'https://example.org',
      'driver_key': 'ms_k',
      'interval_sec': '45',
      'min_distance_m': double.nan,
      'auto_sync': 'yes',
      'channel': 7,
      'antenna': 'mag-mount',
      'heard_hold_pings': 2.6,
    });
    expect(odd.serverUrl, 'https://example.org');
    expect(odd.driverKey, 'ms_k');
    expect(odd.intervalSec, 30);
    expect(odd.minDistanceM, 100);
    expect(odd.autoSync, isTrue);
    expect(odd.channel, '#wardriving');
    expect(odd.antenna.type, 'internal');
    expect(odd.heardHoldPings, 3);
  });

  // AC-13 (spec m1-app-0.4.0 §5): MeshSonar has no "also send to MeshMapper" setting. A stray key from anywhere
  // (an old build, a hand-edited file) loads normally and is gone after the next save.
  test('AC-13: unknown also_send_meshmapper key loads normally and is dropped on the next save', () async {
    final f = File(p.join(tmp.path, 'settings.json'))
      ..writeAsStringSync('{"server_url": "https://example.org", "driver_key": "ms_k", "key_status": "approved", '
          '"channel": "#wardriving", "interval_sec": 45, "also_send_meshmapper": true, '
          '"meshmapper_url": "https://meshmapper.example/api"}');
    final store = FileSettingsStore(f);
    final s = await store.load();
    expect(s.serverUrl, 'https://example.org');
    expect(s.driverKey, 'ms_k');
    expect(s.keyStatus, DriverKeyStatus.approved);
    expect(s.intervalSec, 45);
    expect(s.toJson().keys, isNot(contains('also_send_meshmapper')));
    await store.save(s);
    final raw = f.readAsStringSync();
    expect(raw, isNot(contains('also_send_meshmapper')));
    expect(raw, isNot(contains('meshmapper')));
    expect(raw, contains('https://example.org'));
  });

  test('model numbers written as floats load too (hops, delay, sf, cr)', () {
    final e = Echo.fromJson({'repeater': 'ab', 'hops': 1.0, 'delay_ms': 840.0});
    expect(e.hops, 1);
    expect(e.delayMs, 840);
    final r = Radio.fromJson({'sf': 7.0, 'cr': 5.0});
    expect(r.sf, 7);
    expect(r.cr, 5);
  });
}
