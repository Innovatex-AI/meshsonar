// Callsign, display name, anonymous and leaderboard (driver-settings, build 66 A6): on disk first, the phone's pending edit
// wins, the server's value replaces the phone's with nothing pending, a key with no account cannot opt in to the
// leaderboard, and an older server (no capability) is never called. Also the zone purge flow of the zones controller.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/driver_settings_controller.dart';
import 'package:meshsonar/app/privacy_zones_controller.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/driver_settings.dart';
import 'package:meshsonar/core/privacy_zone_store.dart';
import 'package:meshsonar/core/privacy_zones.dart';

import '../ui/fakes.dart' show FakeCmatClient;

class _Client extends FakeCmatClient {
  _Client() : super(Uri.parse('https://cmh.meshsonar.com'));
  Map<String, Object?> row = {'scope': 'account', 'callsign': 'KE4BFI', 'display': null, 'anonymous': false, 'leaderboardOptIn': false, 'trimM': 500, 'privacyZones': <Object>[], 'updatedAt': <String, Object?>{}};
  final List<Map<String, Object?>> posts = [];
  int gets = 0;
  Object? error;
  final List<(List<PrivacyZone>, bool)> purges = [];
  ZonePurgeResult purgeAnswer = const ZonePurgeResult(pings: 12, positions: 3, heard: 1, sessions: 2);

  DriverSettings get _s => DriverSettings.tryParse({'settings': row})!;

  @override
  Future<DriverSettings> driverSettings(String driverKey) async {
    gets++;
    if (error != null) throw error!;
    return _s;
  }

  @override
  Future<DriverSettings> setDriverSettings(String driverKey, Map<String, Object?> fields) async {
    if (error != null) throw error!;
    posts.add(fields);
    row = {...row, ...fields};
    return _s;
  }

  @override
  Future<ZonePurgeResult> purgeZones(String driverKey, List<PrivacyZone> zones, {bool dryRun = false}) async {
    if (error != null) throw error!;
    purges.add((zones, dryRun));
    return ZonePurgeResult(dryRun: dryRun, pings: purgeAnswer.pings, positions: purgeAnswer.positions, heard: purgeAnswer.heard, sessions: purgeAnswer.sessions);
  }
}

void main() {
  late _Client client;
  late MemoryDriverSettingsStore store;
  String? key;
  var support = ZoneSupport.yes;
  late DriverSettingsController c;

  setUp(() {
    client = _Client();
    store = MemoryDriverSettingsStore();
    key = 'driver-key-0123456789abcdef';
    support = ZoneSupport.yes;
    c = DriverSettingsController(store: store, driverKey: () => key, client: () => client, support: () => support);
  });

  test('with nothing pending the server value replaces the phone value', () async {
    await c.load();
    await c.sync();
    expect(c.callsign, 'KE4BFI');
    expect(c.anonymous, isFalse);
    client.row = {...client.row, 'anonymous': true, 'display': 'Andy'};
    await c.sync();
    expect(c.anonymous, isTrue);
    expect(c.display, 'Andy');
  });

  test('an edit is on disk first, goes out as ONLY that field, and is acknowledged', () async {
    await c.load();
    await c.sync();
    await c.set(SettingField.anonymous, true);
    expect(store.json!['pending'], {'anonymous': true}, reason: 'saved before it is sent');
    await c.sync();
    expect(client.posts.single, {'anonymous': true});
    expect(c.hasPending, isFalse);
    expect((store.json!['pending'] as Map), isEmpty);
    expect(c.anonymous, isTrue);
  });

  test('the phone pending edit wins over a different value on the server, and over a stale GET', () async {
    key = null;
    await c.load();
    await c.set(SettingField.leaderboardOptIn, true);
    expect(c.leaderboardOptIn, isTrue);
    expect(c.status, SettingsSyncStatus.waitingForKey);
    client.row = {...client.row, 'leaderboardOptIn': false};
    key = 'driver-key-0123456789abcdef';
    await c.sync();
    expect(client.posts.single, {'leaderboardOptIn': true});
    expect(client.row['leaderboardOptIn'], isTrue);
  });

  test('values are cleaned like the server does: callsign upper-cased, display name trimmed and capped', () async {
    await c.load();
    await c.set(SettingField.callsign, '  ke4bfi/1 ');
    await c.set(SettingField.display, '  ${'x' * 60}  ');
    await c.sync();
    expect(client.posts.last['callsign'] ?? client.posts.first['callsign'], 'KE4BFI/1');
    expect((c.display ?? '').length, kDisplayNameMax);
    expect(callsignProblem('ab'), isNotNull);
    expect(callsignProblem('ke4bfi'), isNull);
    expect(callsignProblem(''), isNull);
  });

  test('a key with no account cannot opt in: 409 needs_account drops that edit and the toggle says so', () async {
    await c.load();
    await c.set(SettingField.leaderboardOptIn, true);
    client.error = const CmatException('the leaderboard needs an account', status: 409, code: 'needs_account');
    await c.sync();
    expect(c.needsAccount, isTrue);
    expect(c.leaderboardAvailable, isFalse);
    expect(c.hasPending, isFalse);
  });

  test('an older server (no driverSettings) is never called', () async {
    support = ZoneSupport.no;
    await c.load();
    await c.sync();
    await c.set(SettingField.anonymous, true);
    await c.sync();
    expect(client.gets, 0);
    expect(client.posts, isEmpty);
    expect(c.status, SettingsSyncStatus.unsupported);
  });

  test('a server 400 drops the refused edit (it would be refused forever) and says why', () async {
    await c.load();
    await c.set(SettingField.display, 'ok');
    client.error = const CmatException('display: too long', status: 400);
    await c.sync();
    expect(c.hasPending, isFalse);
    expect(c.status, SettingsSyncStatus.rejected);
    expect(c.error, 'display: too long');
  });

  test('pending edits survive an app restart', () async {
    key = null;
    await c.load();
    await c.set(SettingField.anonymous, true);
    final c2 = DriverSettingsController(store: store, driverKey: () => 'driver-key-0123456789abcdef', client: () => client, support: () => support);
    await c2.load();
    expect(c2.anonymous, isTrue);
    await c2.sync();
    expect(client.posts.single, {'anonymous': true});
  });

  group('zone purge', () {
    const home = PrivacyZone(lat: 39.9612, lon: -82.9988, radiusM: 300, label: 'Home');
    late MemoryPrivacyZoneStore zstore;
    var purgeOk = true;
    late PrivacyZonesController z;
    setUp(() {
      zstore = MemoryPrivacyZoneStore();
      purgeOk = true;
      z = PrivacyZonesController(
          store: zstore, driverKey: () => key, client: () => client, support: () => ZoneSupport.yes, purgeSupported: () => purgeOk);
    });

    test('a new zone is queued; dry run counts, then purge removes and clears the queue; the zone label is not sent', () async {
      await z.load();
      await z.setZones([home]);
      expect(zstore.state.purge, [home], reason: 'the offer survives a restart');
      expect(z.purgeQueue, [home]);
      final preview = await z.previewPurge();
      expect(preview!.pings, 12);
      expect(client.purges.single.$2, isTrue, reason: 'a dry run first: nothing deleted');
      final r = await z.runPurge();
      expect(r!.pings, 12);
      expect(client.purges.last.$2, isFalse);
      expect(z.purgeQueue, isEmpty);
      expect(zstore.state.purge, isEmpty);
    });

    test('keeping them clears the offer without calling the purge; a smaller zone queues nothing; a bigger one queues again', () async {
      await z.load();
      await z.setZones([home]);
      await z.dismissPurge();
      expect(z.purgeQueue, isEmpty);
      expect(client.purges.where((p) => !p.$2), isEmpty);
      await z.setZones([home.copyWith(radiusM: 100)]);
      expect(z.purgeQueue, isEmpty);
      await z.setZones([home.copyWith(radiusM: 600)]);
      expect(z.purgeQueue, hasLength(1));
    });

    test('an older server (no zonePurge) is never offered or called; a failed purge stays queued', () async {
      purgeOk = false;
      await z.load();
      await z.setZones([home]);
      expect(z.purgeQueue, isEmpty);
      expect(await z.previewPurge(), isNull);
      expect(client.purges, isEmpty);
      purgeOk = true;
      client.error = const CmatException('down');
      expect(await z.runPurge(), isNull);
      expect(zstore.state.purge, [home]);
    });
  });
}
