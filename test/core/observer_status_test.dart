// Observer status client (contract section 8.3 and 4.1): the heartbeat only while sharing is on and the radio is
// connected, GET me, the HTTP paths, and that the Home observer (removed in 0.38) leaves nothing behind in settings.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/observer_status.dart';

class _Tx implements ObserverStatusTransport {
  final calls = <String>[];
  ObserverHttpResult next = const ObserverHttpResult(200);
  Object? throwIt;
  Map<String, dynamic> meBody = const {};

  @override
  Future<ObserverHttpResult> heartbeat(String driverKey, Map<String, dynamic> body) async {
    calls.add('HB ${body['id']} ${jsonEncode(body)}');
    if (throwIt != null) throw throwIt!;
    return next;
  }

  @override
  Future<ObserverHttpResult> me(String driverKey) async {
    calls.add('ME');
    return ObserverHttpResult(200, body: meBody);
  }
}

const _id = 'aaaabbbbccccddddeeeeffff00001111';

void main() {
  late _Tx tx;
  late bool active, connected;
  String? key;
  ObserverStatusService svc() => ObserverStatusService(
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

  test('heartbeat only while sharing is on AND the radio is connected', () async {
    final s = svc();
    expect(await s.heartbeatNow(), ObserverCallOutcome.ok);
    connected = false;
    expect(await s.heartbeatNow(), isNull);
    connected = true;
    active = false;
    expect(await s.heartbeatNow(), isNull);
    expect(tx.calls.single.startsWith('HB $_id '), isTrue);
    expect(s.heartbeatsSent, 1);
  });

  test('the heartbeat timer runs every 5 minutes by default and stops on stopHeartbeat', () async {
    final s = ObserverStatusService(
      transport: () => tx,
      driverKey: () => key,
      observerId: () async => _id,
      active: () => active,
      connected: () => connected,
    );
    expect(s.heartbeatEvery, const Duration(minutes: 5));
    s.startHeartbeat();
    expect(s.heartbeatRunning, isTrue);
    s.stopHeartbeat();
    expect(s.heartbeatRunning, isFalse);
  });

  test('the timer beats again every period, with mode and radio in the body (section 8.3)', () async {
    final s = ObserverStatusService(
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
    await Future<void>.delayed(const Duration(milliseconds: 90)); // re-armed every 1.2 periods (battery plan A6)
    s.stopHeartbeat();
    final hb = tx.calls.where((c) => c.startsWith('HB ')).toList();
    expect(hb.length, greaterThanOrEqualTo(3), reason: 'once at start, then by the timer');
    expect(jsonDecode(hb.first.split(' ').sublist(2).join(' ')), {'id': _id, 'mode': 'drive', 'radio': {'model': 'Heltec V3', 'sf': 7}});
  });

  test('outcomes are said in words: no key, not on the server, refused key, offline', () async {
    key = null;
    expect(await svc().heartbeatNow(), ObserverCallOutcome.noKey);
    key = 'k';
    tx.next = const ObserverHttpResult(404);
    expect(await svc().heartbeatNow(), ObserverCallOutcome.notOnServer);
    tx.next = const ObserverHttpResult(403);
    expect(await svc().heartbeatNow(), ObserverCallOutcome.keyRefused);
    tx.next = const ObserverHttpResult(429);
    expect(await svc().heartbeatNow(), ObserverCallOutcome.rateLimited);
    tx.throwIt = Exception('down');
    expect(await svc().heartbeatNow(), ObserverCallOutcome.offline);
    for (final o in ObserverCallOutcome.values) {
      expect(observerCallText(o), isNotEmpty);
      expect(observerCallText(o).toLowerCase(), isNot(contains('home')));
    }
  });

  test('a heartbeat answer with {observer: {key}} gives this phone\'s server key', () async {
    tx.next = const ObserverHttpResult(200, body: {'observer': {'key': 'ABCDEF', 'kind': 'mobile'}});
    final s = svc();
    await s.heartbeatNow();
    expect(s.lastKey, 'abcdef');
  });

  test('GET me: picks this phone by id, else by its key, else the only one; full row parsed', () async {
    tx.meBody = {
      'observers': [
        {'id': 'other', 'key': 'AA', 'kind': 'mobile', 'packets_24h': 3},
        {
          'id': _id, 'key': 'BB', 'kind': 'mobile', 'region': 'CMH', 'last_packet_at': '2026-11-08T12:00:00Z',
          'last_heartbeat_at': '2026-11-08T12:03:00Z', 'packets_24h': 812, 'raw_packets_24h': 31,
        },
      ]
    };
    final s = svc();
    expect(await s.refreshStatus(), ObserverCallOutcome.ok);
    expect(s.status!.id, _id);
    expect(s.status!.kind, 'mobile');
    expect(s.status!.packets24h, 812);
    expect(s.status!.rawPackets24h, 31);
    expect(s.status!.lastPacketAt, DateTime.utc(2026, 11, 8, 12));
    expect(s.status!.lastHeartbeatAt, DateTime.utc(2026, 11, 8, 12, 3));
    final all = parsePhoneObservers(tx.meBody);
    expect(thisPhoneObserver(all, key: 'aa')!.id, 'other');
    expect(thisPhoneObserver([all.first]), same(all.first));
    expect(thisPhoneObserver(all), isNull);
    expect(parsePhoneObservers([{'id': 'x'}]).single.kind, 'mobile', reason: 'a bare list works, kind defaults to mobile');
  });

  test('settings: an old Home observer choice is ignored on read and never written again', () {
    final s = Settings.fromJson({
      'home_observer': {'on': true, 'lat': 39.9, 'lon': -83.0, 'location_public': 'exact'},
      'home_antenna': 'fixedMast',
      'telemetry_location': 'region',
    });
    expect(s.telemetryRegionOnly, isTrue);
    expect(s.toJson().containsKey('home_observer'), isFalse);
    expect(s.toJson().containsKey('home_antenna'), isFalse);
    expect(const Settings().toJson().containsKey('telemetry_location'), isFalse);
    expect(const Settings().telemetryRegionOnly, isFalse, reason: 'Approximate is the default');
    expect(const Settings().telemetryEnabled, isTrue, reason: 'Share with MeshSonar is on by default');
  });

  test('HTTP: heartbeat and me paths, methods, x-driver-key and bodies', () async {
    final seen = <http.Request>[];
    final c = HttpCmatClient(Uri.parse('https://meshsonar.com'), client: MockClient((r) async {
      seen.add(r);
      if (r.url.path.endsWith('/observer/me')) return http.Response('[{"id":"$_id","kind":"mobile"}]', 200);
      return http.Response('{"ok":true}', 200);
    }));
    await c.heartbeat('k1', {'id': _id, 'mode': 'drive', 'radio': {'sf': 7}});
    final me = await c.me('k1');
    expect([for (final r in seen) '${r.method} ${r.url}'], [
      'POST https://meshsonar.com/api/cmh/observer/heartbeat',
      'GET https://meshsonar.com/api/cmh/observer/me',
    ]);
    expect(seen.every((r) => r.headers['x-driver-key'] == 'k1'), isTrue);
    expect(jsonDecode(seen[0].body), {'id': _id, 'mode': 'drive', 'radio': {'sf': 7}});
    expect(parsePhoneObservers(me.body).single.id, _id);
  });
}
