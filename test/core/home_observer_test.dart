// Home observer client (phone observer O3, contract section 4): PUT / heartbeat / DELETE / GET me, the heartbeat only while
// home mode is on and the radio is connected, the public position rule, the settings shape and the HTTP paths.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/home_observer.dart';

class _Tx implements HomeObserverTransport {
  final calls = <String>[];
  HomeObserverHttpResult next = const HomeObserverHttpResult(200);
  Object? throwIt;
  Map<String, dynamic> meBody = const {};
  Future<HomeObserverHttpResult> _r(String c) async {
    calls.add(c);
    if (throwIt != null) throw throwIt!;
    return next;
  }

  @override
  Future<HomeObserverHttpResult> putHome(String driverKey, Map<String, dynamic> body) => _r('PUT $driverKey ${jsonEncode(body)}');
  @override
  Future<HomeObserverHttpResult> heartbeat(String driverKey, Map<String, dynamic> body) => _r('HB ${body['id']} ${jsonEncode(body)}');
  @override
  Future<HomeObserverHttpResult> deleteHome(String driverKey, String observerId) => _r('DEL $observerId');
  @override
  Future<HomeObserverHttpResult> me(String driverKey) async {
    calls.add('ME');
    return HomeObserverHttpResult(200, body: meBody);
  }
}

const _id = 'aaaabbbbccccddddeeeeffff00001111';

/// [_Tx] whose answers come from [next] in order.
class _Seq implements HomeObserverTransport {
  final _Tx inner;
  final HomeObserverHttpResult Function() next;
  _Seq(this.inner, this.next);
  Future<HomeObserverHttpResult> _r(Future<HomeObserverHttpResult> f) async {
    await f;
    return next();
  }

  @override
  Future<HomeObserverHttpResult> putHome(String k, Map<String, dynamic> b) => _r(inner.putHome(k, b));
  @override
  Future<HomeObserverHttpResult> heartbeat(String k, Map<String, dynamic> b) => _r(inner.heartbeat(k, b));
  @override
  Future<HomeObserverHttpResult> deleteHome(String k, String id) => _r(inner.deleteHome(k, id));
  @override
  Future<HomeObserverHttpResult> me(String k) => inner.me(k);
}

void main() {
  late _Tx tx;
  late bool active, connected;
  String? key;
  HomeObserverService svc() => HomeObserverService(
        transport: () => tx,
        driverKey: () => key,
        observerId: () async => _id,
        active: () => active,
        connected: () => connected,
        autoTimer: false,
      );

  setUp(() {
    tx = _Tx();
    active = true;
    connected = true;
    key = 'driver-key';
  });

  test('PUT sends id, exact lat/lon and the public choice', () async {
    final s = svc();
    final o = await s.register(const HomeObserverConfig(on: true, lat: 39.961234567, lon: -82.998765432, locationPublic: HomeLocationPublic.rounded1km));
    expect(o, HomeCallOutcome.ok);
    final body = jsonDecode(tx.calls.single.substring('PUT driver-key '.length)) as Map;
    expect(body, {'id': _id, 'lat': 39.961235, 'lon': -82.998765, 'location_public': 'rounded_1km'});
  });

  test('heartbeat only while home mode is on AND the radio is connected', () async {
    final s = svc();
    expect(await s.heartbeatNow(), HomeCallOutcome.ok);
    connected = false;
    expect(await s.heartbeatNow(), isNull);
    connected = true;
    active = false;
    expect(await s.heartbeatNow(), isNull);
    expect(tx.calls.single.startsWith('HB $_id '), isTrue);
    expect(s.heartbeatsSent, 1);
  });

  test('the heartbeat timer runs every 5 minutes by default and stops on unregister', () async {
    final s = HomeObserverService(
      transport: () => tx,
      driverKey: () => key,
      observerId: () async => _id,
      active: () => active,
      connected: () => connected,
    );
    expect(s.heartbeatEvery, const Duration(minutes: 5));
    s.startHeartbeat();
    expect(s.heartbeatRunning, isTrue);
    await s.unregister();
    expect(s.heartbeatRunning, isFalse);
    expect(tx.calls.last, 'DEL $_id');
  });

  test('the timer beats again every period, in every mode, with mode and radio in the body (section 8.3)', () async {
    final s = HomeObserverService(
      transport: () => tx,
      driverKey: () => key,
      observerId: () async => _id,
      active: () => active,
      connected: () => connected,
      mode: () => 'drive',
      radio: () => {'model': 'Heltec V3', 'sf': 7},
      heartbeatEvery: const Duration(milliseconds: 20),
    );
    s.startHeartbeat();
    await Future<void>.delayed(const Duration(milliseconds: 75));
    s.stopHeartbeat();
    final hb = tx.calls.where((c) => c.startsWith('HB ')).toList();
    expect(hb.length, greaterThanOrEqualTo(3), reason: 'once at start, then every period');
    expect(jsonDecode(hb.first.split(' ').sublist(2).join(' ')), {'id': _id, 'mode': 'drive', 'radio': {'model': 'Heltec V3', 'sf': 7}});
  });

  test('outcomes are said in words: no key, not on the server, refused key, offline', () async {
    key = null;
    expect(await svc().register(const HomeObserverConfig(on: true, lat: 1, lon: 1)), HomeCallOutcome.noKey);
    key = 'k';
    tx.next = const HomeObserverHttpResult(404);
    expect(await svc().register(const HomeObserverConfig(on: true, lat: 1, lon: 1)), HomeCallOutcome.notOnServer);
    tx.next = const HomeObserverHttpResult(403);
    expect(await svc().unregister(), HomeCallOutcome.keyRefused);
    tx.throwIt = Exception('down');
    expect(await svc().heartbeatNow(), HomeCallOutcome.offline);
    for (final o in HomeCallOutcome.values) {
      expect(homeCallText(o), isNotEmpty);
    }
  });

  test('GET me: picks this phone by id, else by its key, else the only one', () async {
    tx.meBody = {
      'observers': [
        {'id': 'other', 'key': 'AA', 'kind': 'mobile', 'packets_24h': 3},
        {'id': _id, 'key': 'BB', 'kind': 'fixed', 'last_packet_at': '2026-11-08T12:00:00Z', 'packets_24h': 812,
          'home': {'lat': 39.96, 'lon': -83.0, 'location_public': 'exact'}},
      ]
    };
    final s = svc();
    expect(await s.refreshStatus(), HomeCallOutcome.ok);
    expect(s.status!.fixed, isTrue);
    expect(s.status!.packets24h, 812);
    expect(s.status!.lastPacketAt, DateTime.utc(2026, 11, 8, 12));
    expect(s.status!.homePublic, HomeLocationPublic.exact);
    final all = parsePhoneObservers(tx.meBody);
    expect(thisPhoneObserver(all, key: 'aa')!.id, 'other');
    expect(thisPhoneObserver([all.first]), same(thisPhoneObserver([all.first])));
    expect(thisPhoneObserver(all), isNull);
  });

  test('public position: exact, or the server\'s centre of the 0.01 degree cell, 3 decimals (contract section 7)', () {
    expect(publicHomePosition(39.96789, -82.99123, HomeLocationPublic.exact), (lat: 39.96789, lon: -82.99123));
    // The two values the server pinned (ms_round_1km): NOT round(x*100)/100 (that would give 39.99 / -83.01).
    expect(round1kmCentre(39.98765), 39.985);
    expect(round1kmCentre(-83.01234), -83.015);
    expect(publicHomePosition(39.98765, -83.01234, HomeLocationPublic.rounded1km), (lat: 39.985, lon: -83.015));
    expect(round1kmCentre(40.0), 40.005);
  });

  test('contract section 7 shapes: PUT/DELETE/heartbeat give {observer: {key, kind}}; GET me full row', () async {
    tx.next = const HomeObserverHttpResult(200, body: {'observer': {'key': 'ABCDEF', 'kind': 'fixed'}});
    final s = svc();
    await s.register(const HomeObserverConfig(on: true, lat: 39.9, lon: -83));
    expect(s.lastKey, 'abcdef');
    tx.meBody = {
      'observers': [
        {
          'id': _id, 'key': 'ABCDEF', 'kind': 'fixed', 'region': 'CMH', 'created_at': '2026-11-08T10:00:00Z',
          'last_packet_at': '2026-11-08T12:00:00Z', 'last_heartbeat_at': '2026-11-08T12:03:00Z', 'packets_24h': 40,
          'raw_packets_24h': 31, 'radio': {'model': 'Heltec V3'},
          'home': {'lat': 39.9, 'lon': -83.0, 'location_public': 'rounded_1km'},
        }
      ]
    };
    await s.refreshStatus();
    final st = s.status!;
    expect(st.fixed, isTrue);
    expect(st.packets24h, 40);
    expect(st.rawPackets24h, 31);
    expect(st.lastHeartbeatAt, DateTime.utc(2026, 11, 8, 12, 3));
    expect(st.homePublic, HomeLocationPublic.rounded1km);
    expect(st.homeLat, 39.9);
  });

  test('heartbeat 404 (server does not know the id): the saved home is PUT again, then the beat is resent', () async {
    var n = 0;
    final s = HomeObserverService(
      transport: () => _Seq(tx, () => n++ == 0 ? const HomeObserverHttpResult(404) : const HomeObserverHttpResult(200)),
      driverKey: () => key,
      observerId: () async => _id,
      active: () => true,
      connected: () => true,
      config: () => const HomeObserverConfig(on: true, lat: 39.9, lon: -83),
      autoTimer: false,
    );
    expect(await s.heartbeatNow(), HomeCallOutcome.ok);
    expect(tx.calls.map((c) => c.split(' ').first).toList(), ['HB', 'PUT', 'HB']);
  });

  test('DELETE home 404 = nothing to delete: done', () async {
    tx.next = const HomeObserverHttpResult(404);
    expect(await svc().unregister(), HomeCallOutcome.ok);
  });

  test('settings keep the home observer and the location choice; defaults write nothing', () {
    expect(const Settings().toJson().containsKey('home_observer'), isFalse);
    expect(const Settings().toJson().containsKey('telemetry_location'), isFalse);
    expect(const Settings().telemetryRegionOnly, isFalse, reason: 'Approximate is the default');
    final s = const Settings().copyWith(
        telemetryRegionOnly: true, homeObserver: const HomeObserverConfig(on: true, lat: 39.9, lon: -83, locationPublic: HomeLocationPublic.exact));
    final back = Settings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(back.telemetryRegionOnly, isTrue);
    expect(back.homeObserver, s.homeObserver);
    expect(back.copyWith(clearHomeObserver: true).homeObserver, isNull);
    expect(HomeObserverConfig.fromJson({'on': true, 'lat': 0, 'lon': 0}), isNull, reason: 'null island is not a home');
    expect(HomeObserverConfig.fromJson({'on': true, 'lat': 91, 'lon': 0}), isNull);
  });

  test('HTTP: paths, methods, x-driver-key and bodies', () async {
    final seen = <http.Request>[];
    final c = HttpCmatClient(Uri.parse('https://meshsonar.com'), client: MockClient((r) async {
      seen.add(r);
      if (r.url.path.endsWith('/observer/me')) return http.Response('[{"id":"$_id","kind":"fixed"}]', 200);
      return http.Response('{"ok":true}', 200);
    }));
    await c.putHome('k1', {'id': _id, 'lat': 1.5, 'lon': 2.5, 'location_public': 'exact'});
    await c.heartbeat('k1', {'id': _id, 'mode': 'drive', 'radio': {'sf': 7}});
    await c.deleteHome('k1', _id);
    final me = await c.me('k1');
    expect([for (final r in seen) '${r.method} ${r.url}'], [
      'PUT https://meshsonar.com/api/cmh/observer/home',
      'POST https://meshsonar.com/api/cmh/observer/heartbeat',
      'DELETE https://meshsonar.com/api/cmh/observer/home?id=$_id',
      'GET https://meshsonar.com/api/cmh/observer/me',
    ]);
    expect(seen.every((r) => r.headers['x-driver-key'] == 'k1'), isTrue);
    expect(jsonDecode(seen[0].body), {'id': _id, 'lat': 1.5, 'lon': 2.5, 'location_public': 'exact'});
    expect(jsonDecode(seen[1].body), {'id': _id, 'mode': 'drive', 'radio': {'sf': 7}});
    expect(seen[2].bodyBytes, isEmpty);
    expect(parsePhoneObservers(me.body).single.fixed, isTrue);
  });
}
