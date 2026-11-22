// ID step 5 on the wire: paths / methods / bodies of the three calls, parsing of the three shapes, tolerance, error codes.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/core/person_observers.dart';

final _a = 'ab' * 32, _b = 'cd' * 32, _c = 'ef' * 32;
const _dk = 'test-driver-key';

({HttpCmatClient client, List<http.Request> seen}) make(http.Response Function(http.Request r) answer) {
  final seen = <http.Request>[];
  final mock = MockClient((r) async {
    seen.add(r);
    return answer(r);
  });
  return (client: HttpCmatClient(Uri.parse('https://cmh.meshsonar.com'), client: mock), seen: seen);
}

http.Response js(int status, Object body, {Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...headers});

Map<String, Object?> fixed([Map<String, Object?> over = const {}]) => {
      'key': _a.toUpperCase(),
      'kind': 'fixed',
      'name': 'Hilltop',
      'publicName': 'Hilltop North',
      'nodeName': 'HT1',
      'method': 'signature',
      'claimedAt': '2026-11-20T10:00:00Z',
      'named': false,
      'iata': 'CMH',
      'model': 'Heltec V3',
      'firmware': 'v1.9.0',
      'lastHeardAt': '2026-11-22T09:00:00Z',
      'lastPacketAt': '2026-11-22T08:59:00Z',
      'lastStatusAt': '2026-11-22T08:58:00Z',
      'positionPublic': true,
      'position': 'rounded_1km',
      'blocked': false,
      'health': {'state': 'deaf', 'flatMinutes': 95, 'battery': {'mv': 3630, 'low': true, 'trend': 'falling'}},
      ...over,
    };

Map<String, Object?> phone([Map<String, Object?> over = const {}]) => {
      'key': _b,
      'kind': 'phone',
      'name': 'MeshSonar phone 212DE2',
      'device': {'id': 'd1', 'name': 'iPhone'},
      'installs': 2,
      'lastHeardAt': '2026-11-22T09:05:00Z',
      'mode': 'drive',
      'radioKey': _c,
      'radioName': 'Truck Radio',
      'feeds': ['phone', 'broker'],
      'showRadioName': true,
      'countedOnce': true,
      'blocked': false,
      ...over,
    };

Map<String, Object?> offer([Map<String, Object?> over = const {}]) => {
      'key': _c,
      'name': 'Barn Observer',
      'iata': 'CMH',
      'offeredBy': {'key': _a, 'name': 'Hilltop'},
      'firstSeenAt': '2026-11-10T10:00:00Z',
      'lastSeenAt': '2026-11-22T10:00:00Z',
      ...over,
    };

void main() {
  group('parsing', () {
    test('a fixed observer', () {
      final r = PersonObservers.parse({'observers': [fixed()], 'offers': []});
      final o = r.observers.single as FixedObserver;
      expect(o.key, _a, reason: 'keys are lower-cased');
      expect(o.name, 'Hilltop');
      expect(o.publicName, 'Hilltop North');
      expect(o.nodeName, 'HT1');
      expect(o.method, ClaimMethod.signature);
      expect(o.claimedAt, DateTime.utc(2026, 11, 20, 10));
      expect(o.iata, 'CMH');
      expect(o.model, 'Heltec V3');
      expect(o.firmware, 'v1.9.0');
      expect(o.lastHeardAt, DateTime.utc(2026, 11, 22, 9));
      expect(o.lastPacketAt, isNotNull);
      expect(o.lastStatusAt, isNotNull);
      expect(o.positionPublic, isTrue);
      expect(o.position, ObserverPosition.rounded1km);
      expect(o.blocked, isFalse);
      expect(o.health?.state, 'deaf');
      expect(o.health?.batteryMv, 3630);
      expect(o.health?.batteryLow, isTrue);
      expect(o.editableName, 'Hilltop North');
      expect(o.positionShown, isTrue);
    });

    test('a phone observer', () {
      final o = PersonObservers.parse({'observers': [phone()]}).observers.single as PhoneObserver;
      expect(o.name, 'MeshSonar phone 212DE2');
      expect(o.deviceId, 'd1');
      expect(o.deviceName, 'iPhone');
      expect(o.installs, 2);
      expect(o.mode, 'drive');
      expect(o.radioKey, _c);
      expect(o.radioName, 'Truck Radio');
      expect(o.feeds, ['phone', 'broker']);
      expect(o.showRadioName, isTrue);
      expect(o.countedOnce, isTrue);
      expect(o.canShowRadioName, isTrue);
    });

    test('an offer', () {
      final o = PersonObservers.parse({'offers': [offer()]}).offers.single;
      expect(o.key, _c);
      expect(o.name, 'Barn Observer');
      expect(o.iata, 'CMH');
      expect(o.offeredByKey, _a);
      expect(o.offeredByName, 'Hilltop');
      expect(o.firstSeenAt, DateTime.utc(2026, 11, 10, 10));
      expect(o.label, 'Barn Observer');
      expect(o.radioLabel, 'Hilltop');
    });

    test('an offer without names is shown by short key', () {
      final o = ObserverOffer.tryParse(offer({'name': null, 'offeredBy': {'key': _a, 'name': null}}))!;
      expect(o.label, '${_c.substring(0, 8)}…${_c.substring(60)}');
      expect(o.radioLabel, '${_a.substring(0, 8)}…${_a.substring(60)}');
    });

    test('tolerant: unknown fields ignored, missing optional fields null', () {
      final f = PersonObserver.tryParse({'key': _a, 'kind': 'fixed', 'name': 'X', 'surprise': 1}) as FixedObserver;
      expect(f.publicName, isNull);
      expect(f.nodeName, isNull);
      expect(f.iata, isNull);
      expect(f.lastHeardAt, isNull);
      expect(f.positionPublic, isNull);
      expect(f.positionShown, isTrue, reason: 'unset = shown, as on the site');
      expect(f.position, ObserverPosition.hidden);
      expect(f.health, isNull);
      expect(f.method, ClaimMethod.other);
      final p = PersonObserver.tryParse({'key': _b, 'kind': 'phone', 'extra': {}}) as PhoneObserver;
      expect(p.mode, isNull);
      expect(p.radioKey, isNull);
      expect(p.canShowRadioName, isFalse);
      expect(p.feeds, ['phone']);
      expect(p.showRadioName, isFalse);
      expect(p.countedOnce, isFalse);
      expect(p.deviceName, 'Device');
    });

    test('tolerant: an unknown kind, a bad key or a non-object row is skipped; the rest is kept', () {
      final r = PersonObservers.parse({
        'observers': [
          {'key': _a, 'kind': 'satellite', 'name': 'x'},
          {'key': 'short', 'kind': 'fixed'},
          'junk',
          null,
          phone(),
          fixed({'mode': 'weird'}),
        ],
        'offers': [offer({'key': 'nope'}), 5, offer()],
      });
      expect(r.observers.map((o) => o.runtimeType), [PhoneObserver, FixedObserver]);
      expect(r.offers, hasLength(1));
    });

    test('tolerant: odd field values never throw', () {
      final p = PersonObserver.tryParse(phone({'mode': 'swimming', 'feeds': ['mqtt', 5], 'installs': 'two', 'device': 'x', 'lastHeardAt': 'yesterday'})) as PhoneObserver;
      expect(p.mode, isNull);
      expect(p.feeds, ['phone']);
      expect(p.installs, 1);
      expect(p.lastHeardAt, isNull);
      final f = PersonObserver.tryParse(fixed({'health': {'state': 'purple'}, 'position': 'moon', 'positionPublic': 'yes'})) as FixedObserver;
      expect(f.health, isNull);
      expect(f.position, ObserverPosition.hidden);
      expect(f.positionPublic, isNull);
      expect(PersonObservers.parse({'observers': 'x', 'offers': {}}).observers, isEmpty);
    });
  });

  group('calls', () {
    test('person-observers: GET, x-driver-key, no body', () async {
      final m = make((r) => js(200, {'observers': [fixed(), phone()], 'offers': [offer()]}));
      final r = await m.client.personObservers(_dk);
      expect(r.observers, hasLength(2));
      expect(r.offers, hasLength(1));
      final q = m.seen.single;
      expect(q.method, 'GET');
      expect(q.url.path, '/api/cmh/person-observers');
      expect(q.headers['x-driver-key'], _dk);
    });

    test('person-observer-offer: POST {key, action}', () async {
      final m = make((r) {
        final b = jsonDecode(r.body) as Map;
        return js(200, {'ok': true, b['action'] == 'accept' ? 'accepted' : 'declined': true});
      });
      expect(await m.client.answerObserverOffer(_dk, _c.toUpperCase(), accept: true), OfferOutcome.accepted);
      expect(await m.client.answerObserverOffer(_dk, _c, accept: false), OfferOutcome.declined);
      expect(jsonDecode(m.seen[0].body), {'key': _c, 'action': 'accept'});
      expect(jsonDecode(m.seen[1].body), {'key': _c, 'action': 'decline'});
      expect(m.seen.every((q) => q.method == 'POST' && q.url.path == '/api/cmh/person-observer-offer' && q.headers['x-driver-key'] == _dk), isTrue);
    });

    test('person-observer-offer: already answered', () async {
      final m = make((r) => js(200, {'ok': true, 'already': true}));
      expect(await m.client.answerObserverOffer(_dk, _c, accept: true), OfferOutcome.already);
    });

    test('person-observer-pref: POST {key, showRadioName}', () async {
      final m = make((r) => js(200, {'ok': true}));
      await m.client.setShowRadioName(_dk, _b, true);
      final q = m.seen.single;
      expect(q.method, 'POST');
      expect(q.url.path, '/api/cmh/person-observer-pref');
      expect(jsonDecode(q.body), {'key': _b, 'showRadioName': true});
    });

    test('the existing claim calls carry a fixed observer\'s name, position and release', () async {
      final m = make((r) => r.method == 'DELETE' ? js(200, {'ok': true}) : js(200, {'claim': {'pubkey': _a, 'nodeType': 'repeater', 'method': 'signature'}}));
      await m.client.updateClaim(_dk, _a, {'displayName': 'New', 'positionPublic': false});
      await m.client.releaseClaim(_dk, _a);
      expect(m.seen[0].method, 'PATCH');
      expect(jsonDecode(m.seen[0].body), {'pubkey': _a, 'displayName': 'New', 'positionPublic': false});
      expect(m.seen[1].method, 'DELETE');
      expect(m.seen[1].url.path, '/api/cmh/claim');
      expect(m.seen[1].url.queryParameters['pubkey'], _a);
    });
  });

  group('errors', () {
    test('flag off: every call is 404 {"error":"not found"}', () async {
      final m = make((r) => js(404, {'error': 'not found'}));
      for (final f in <Future<Object?> Function()>[
        () => m.client.personObservers(_dk),
        () => m.client.answerObserverOffer(_dk, _c, accept: true),
        () => m.client.setShowRadioName(_dk, _b, true),
      ]) {
        await expectLater(f(), throwsA(isA<CmatException>().having((e) => e.status, 'status', 404).having((e) => e.message, 'message', 'not found')));
      }
    });

    test('409 owned', () async {
      final m = make((r) => js(409, {'error': 'Another owner already holds this observer.', 'code': 'owned'}));
      await expectLater(
        m.client.answerObserverOffer(_dk, _c, accept: true),
        throwsA(isA<CmatException>().having((e) => e.status, 's', 409).having((e) => e.code, 'code', 'owned')),
      );
    });

    test('404 not_found on an offer and on a pref', () async {
      final m = make((r) => js(404, {'error': 'There is no such offer for you', 'code': 'not_found'}));
      await expectLater(m.client.answerObserverOffer(_dk, _c, accept: false), throwsA(isA<CmatException>().having((e) => e.code, 'code', 'not_found')));
      await expectLater(m.client.setShowRadioName(_dk, _b, false), throwsA(isA<CmatException>().having((e) => e.status, 's', 404)));
    });

    test('400 bad input keeps the plain-words error', () async {
      final m = make((r) => js(400, {'error': 'key must be 64 hex characters'}));
      await expectLater(
        m.client.setShowRadioName(_dk, 'xyz', true),
        throwsA(isA<CmatException>().having((e) => e.status, 's', 400).having((e) => e.message, 'm', 'key must be 64 hex characters')),
      );
    });

    test('429 carries Retry-After', () async {
      final m = make((r) => js(429, {'error': 'slow down'}, headers: {'retry-after': '17'}));
      await expectLater(m.client.personObservers(_dk), throwsA(isA<CmatException>().having((e) => e.retryAfterSec, 'retry', 17)));
    });

    test('an unreadable answer to the list is an error, not an empty list', () async {
      final m = make((r) => http.Response('<html>', 200));
      await expectLater(m.client.personObservers(_dk), throwsA(isA<CmatException>()));
    });
  });
}
