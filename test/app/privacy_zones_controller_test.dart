// The privacy-zone controller: saved on the phone first, sent when it can be (lazy key, offline, a server without the
// endpoint, a server that refuses), the phone's list winning while a change is pending.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/privacy_zones_controller.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/privacy_zone_store.dart';
import 'package:meshsonar/core/privacy_zones.dart';

import '../ui/fakes.dart' show FakeCmatClient;

class _Client extends FakeCmatClient {
  _Client() : super(Uri.parse('https://cmh.meshsonar.com'));
  List<PrivacyZone> server = [];
  int trim = 500;
  ZoneScope scope = ZoneScope.account;
  Object? error;
  final List<List<PrivacyZone>> posts = [];
  int gets = 0;
  Completer<void>? gate;

  @override
  Future<DriverPrivacy> driverPrivacy(String driverKey) async {
    gets++;
    if (error != null) throw error!;
    return DriverPrivacy(zones: server, trimM: trim, scope: scope);
  }

  @override
  Future<DriverPrivacy> setDriverPrivacy(String driverKey, {List<PrivacyZone>? zones, int? trimM}) async {
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    posts.add(zones ?? server);
    if (zones != null) server = zones;
    if (trimM != null) trim = trimM;
    return DriverPrivacy(zones: server, trimM: trim, scope: scope);
  }
}

void main() {
  late _Client client;
  late MemoryPrivacyZoneStore store;
  String? key;
  var support = ZoneSupport.yes;
  late PrivacyZonesController c;

  setUp(() {
    client = _Client();
    store = MemoryPrivacyZoneStore();
    key = 'driver-key-0123456789abcdef';
    support = ZoneSupport.yes;
    c = PrivacyZonesController(store: store, driverKey: () => key, client: () => client, support: () => support);
  });

  const home = PrivacyZone(lat: 39.9612, lon: -82.9988, radiusM: 300, label: 'Home');

  test('a change is on disk before anything is sent, then sent, then not pending', () async {
    await c.load();
    final f = c.setZones([home]);
    await f;
    expect(store.state.zones, [home]);
    await c.sync();
    expect(client.posts.single, [home]);
    expect(c.pending, isFalse);
    expect(store.state.pending, isFalse);
    expect(c.status, ZoneSyncStatus.synced);
    expect(c.state.scope, ZoneScope.account);
  });

  test('no driver key yet: the editor works, the change waits on disk, and goes out the moment a key exists (lazy key, D9)', () async {
    key = null;
    await c.load();
    await c.setZones([home]);
    await c.sync();
    expect(client.posts, isEmpty);
    expect(c.status, ZoneSyncStatus.waitingForKey);
    expect(store.state.pending, isTrue);
    // A new controller (app restart) still has them.
    final c2 = PrivacyZonesController(store: store, driverKey: () => key, client: () => client, support: () => support);
    await c2.load();
    expect(c2.zones, [home]);
    key = 'driver-key-0123456789abcdef';
    await c2.sync();
    expect(client.posts.single, [home]);
    expect(c2.status, ZoneSyncStatus.synced);
  });

  test('offline: the queue holds the change and the next sync sends it; the phone list wins over the server\'s meanwhile', () async {
    await c.load();
    client.error = const CmatException('network error: down');
    client.server = const [PrivacyZone(lat: 1, lon: 1, radiusM: 100)];
    await c.setZones([home]);
    await c.sync();
    expect(c.status, ZoneSyncStatus.offline);
    expect(c.zones, [home], reason: 'the server\'s older list does not replace an unsent change');
    expect(c.pending, isTrue);
    client.error = null;
    await c.sync();
    expect(client.server, [home]);
    expect(c.status, ZoneSyncStatus.synced);
    expect(c.pending, isFalse);
  });

  test('nothing pending: the server\'s list replaces the phone\'s (edited on the website)', () async {
    await c.load();
    client.server = const [PrivacyZone(lat: 1, lon: 2, radiusM: 100, label: 'Work')];
    client.trim = 800;
    await c.sync();
    expect(c.zones.single.label, 'Work');
    expect(c.trimM, 800);
    expect(client.posts, isEmpty);
  });

  test('a server without driverPrivacy: unsupported, nothing is sent, zones stay on the phone', () async {
    support = ZoneSupport.no;
    await c.load();
    await c.setZones([home]);
    await c.sync();
    expect(c.status, ZoneSyncStatus.unsupported);
    expect(client.posts, isEmpty);
    expect(client.gets, 0);
    expect(c.zones, [home]);
  });

  test('an old server answering 404 is treated as unsupported', () async {
    support = ZoneSupport.unknown;
    client.error = const CmatException('server answered 404', status: 404);
    await c.load();
    await c.setZones([home]);
    await c.sync();
    expect(c.status, ZoneSyncStatus.unsupported);
  });

  test('the server refusing the list (400) says why and keeps the zones', () async {
    client.error = const CmatException('zone 1: radius must be 50 to 5000 m (got 20)', status: 400);
    await c.load();
    await c.setZones([home]);
    await c.sync();
    expect(c.status, ZoneSyncStatus.rejected);
    expect(c.error, contains('radius must be'));
    expect(c.zones, [home]);
  });

  test('401 says the key is not recognised', () async {
    client.error = const CmatException('x-driver-key required', status: 401);
    await c.load();
    await c.setZones([home]);
    await c.sync();
    expect(c.status, ZoneSyncStatus.rejected);
    expect(c.error, contains('driver key'));
  });

  test('limits and normalisation apply on the way in: 10 zones, 4 decimals, wrapped longitude', () async {
    await c.load();
    await c.setZones([for (var i = 0; i < 14; i++) PrivacyZone(lat: 10.0 + i / 10, lon: 190.123456, radiusM: 200)]);
    expect(c.zones.length, kZoneMax);
    expect(c.zones.first.lon, -169.8765);
    await c.sync();
    expect(client.posts.last.length, kZoneMax);
    for (final z in client.posts.last) {
      expect(z.toJson()['lon'], -169.8765);
    }
  });

  test('an edit made while a send is in flight is sent by the next pass, never lost', () async {
    await c.load();
    client.gate = Completer<void>();
    await c.setZones([home]); // starts a background sync that waits on the gate
    await Future<void>.delayed(Duration.zero);
    const work = PrivacyZone(lat: 40, lon: -83, radiusM: 100, label: 'Work');
    await c.setZones([home, work]);
    client.gate!.complete();
    client.gate = null;
    await c.sync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(client.server, [home, work]);
    expect(c.pending, isFalse);
  });

  test('trim distance is clamped and sent with pending state', () async {
    await c.load();
    await c.setTrim(99999);
    expect(c.trimM, kTrimMaxM);
    await c.sync();
    expect(client.trim, kTrimMaxM);
  });
}
