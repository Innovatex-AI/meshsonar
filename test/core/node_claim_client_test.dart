// The claim endpoints: wire contract (paths, methods, header, bodies, status codes), tolerant parsing, error mapping.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/node_claim.dart';

const _key = 'da5dc89c937225aadced4a1cb8a689c0d34ccab96576a0d0f69f3186c879c854';

Map<String, Object?> claimJson({String key = _key, Object? positionPublic = false}) => {
      'pubkey': key,
      'nodeType': 'repeater',
      'method': 'advert',
      'verifiedAt': '2026-10-31T12:00:00.000Z',
      'displayName': 'Hilltop',
      'positionPublic': positionPublic,
      'notes': null,
      'nodeName': 'OH.HILL',
    };

({HttpCmatClient client, List<http.Request> seen}) make(http.Response Function(http.Request r) answer) {
  final seen = <http.Request>[];
  final mock = MockClient((r) async {
    seen.add(r);
    return answer(r);
  });
  return (client: HttpCmatClient(Uri.parse('https://cmh.meshsonar.com'), client: mock), seen: seen);
}

http.Response json(int status, Object body) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  group('capability', () {
    test('nodeClaims is read from site-config capabilities', () {
      const on = SiteConfig(region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'), capabilities: {'nodeClaims'});
      const off = SiteConfig(region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'));
      expect(on.nodeClaims, isTrue);
      expect(off.nodeClaims, isFalse);
    });
  });

  group('parse', () {
    test('NodeClaim: all fields, unknown node type / method are tolerated, nulls stay null', () {
      final c = NodeClaim.parse(claimJson());
      expect(c.pubkey, _key);
      expect(c.nodeType, ClaimNodeType.repeater);
      expect(c.method, ClaimMethod.advert);
      expect(c.verifiedAt, DateTime.utc(2026, 10, 31, 12));
      expect(c.positionPublic, isFalse);
      expect(c.notes, isNull);
      expect(c.label, 'Hilltop');
      final odd = NodeClaim.parse({'pubkey': _key.toUpperCase(), 'nodeType': 'gizmo', 'method': 'login_attested', 'positionPublic': 'yes'});
      expect(odd.pubkey, _key);
      expect(odd.nodeType, ClaimNodeType.unknown);
      expect(odd.method, ClaimMethod.other);
      expect(odd.positionPublic, isNull);
      expect(odd.label, 'Radio da5dc89c');
      expect(() => NodeClaim.parse({'pubkey': 'short'}), throwsFormatException);
      expect(() => NodeClaim.parse('x'), throwsFormatException);
    });

    test('normalizePublicKey accepts spaces, 0x and upper case; rejects the rest', () {
      expect(normalizePublicKey('  0x${_key.toUpperCase()} '), _key);
      expect(normalizePublicKey('${_key.substring(0, 32)} ${_key.substring(32)}'), _key);
      expect(normalizePublicKey(_key.substring(2)), isNull);
      expect(normalizePublicKey('zz${_key.substring(2)}'), isNull);
    });

    test('ClaimChallenge sign: message is hex of the UTF-8 bytes; advert: code MS + 4 characters', () {
      final msg = utf8.encode('meshsonar-claim:v1:abc');
      final hex = msg.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final s = ClaimChallenge.parse({'challengeId': 'c1', 'kind': 'sign', 'message': hex, 'expiresAt': '2026-10-31T12:02:00Z'}, asked: ClaimKind.sign);
      expect(s.message, msg);
      final a = ClaimChallenge.parse({'challengeId': 'c2', 'kind': 'advert', 'code': 'MS7K2Q', 'expiresAt': '2026-10-31T12:15:00Z', 'instructions': 'x'}, asked: ClaimKind.advert);
      expect(a.code, 'MS7K2Q');
      expect(() => ClaimChallenge.parse({'challengeId': 'c', 'kind': 'advert', 'code': 'XX7K2Q', 'expiresAt': '2026-10-31T12:15:00Z'}, asked: ClaimKind.advert), throwsFormatException);
      expect(() => ClaimChallenge.parse({'challengeId': 'c', 'kind': 'advert', 'code': 'MS7K2Q', 'expiresAt': '2026-10-31T12:15:00Z'}, asked: ClaimKind.sign), throwsFormatException);
      expect(() => ClaimChallenge.parse({'challengeId': 'c', 'kind': 'sign', 'message': 'abc', 'expiresAt': '2026-10-31T12:02:00Z'}, asked: ClaimKind.sign), throwsFormatException);
    });

    test('ClaimStatus: pending / verified with claim / expired; unknown state is an error', () {
      expect(ClaimStatus.parse({'state': 'pending'}).state, ClaimState.pending);
      final v = ClaimStatus.parse({'state': 'verified', 'claim': claimJson(), 'seenAdvertAt': '2026-10-31T12:01:00Z'});
      expect(v.claim!.pubkey, _key);
      expect(v.seenAdvertAt, DateTime.utc(2026, 10, 31, 12, 1));
      expect(ClaimStatus.parse({'state': 'expired'}).state, ClaimState.expired);
      expect(() => ClaimStatus.parse({'state': 'who knows'}), throwsFormatException);
    });
  });

  group('HTTP contract', () {
    test('claim-start sign: POST, x-driver-key, lower-case key, 201', () async {
      final t = make((r) => json(201, {'challengeId': 'c1', 'kind': 'sign', 'message': '6162', 'expiresAt': '2026-10-31T12:02:00Z'}));
      final ch = await t.client.claimStart('KEY-1', _key.toUpperCase(), ClaimKind.sign);
      expect(ch.message, [0x61, 0x62]);
      final r = t.seen.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/api/cmh/claim-start');
      expect(r.headers['x-driver-key'], 'KEY-1');
      expect(jsonDecode(r.body), {'pubkey': _key, 'kind': 'sign'});
    });

    test('claim-start advert: returns the code', () async {
      final t = make((r) => json(201, {'challengeId': 'c2', 'kind': 'advert', 'code': 'MS7K2Q', 'expiresAt': '2026-10-31T12:15:00Z', 'instructions': 'i'}));
      final ch = await t.client.claimStart('k', _key, ClaimKind.advert);
      expect(ch.code, 'MS7K2Q');
      expect(jsonDecode(t.seen.single.body)['kind'], 'advert');
    });

    test('claim-start errors keep the status: 409 {error, owner}, 400, 401, 403, 429 with Retry-After', () async {
      for (final s in [400, 401, 403, 409, 429]) {
        final t = make((r) => http.Response(jsonEncode({'error': 'nope $s', 'owner': 'someone'}), s, headers: {'retry-after': '120', 'content-type': 'application/json'}));
        await expectLater(t.client.claimStart('k', _key, ClaimKind.advert),
            throwsA(isA<CmatException>().having((e) => e.status, 'status', s).having((e) => e.message, 'message', 'nope $s')));
      }
      final t = make((r) => http.Response('{"error":"slow"}', 429, headers: {'retry-after': '120'}));
      try {
        await t.client.claimStart('k', _key, ClaimKind.advert);
      } on CmatException catch (e) {
        expect(e.retryAfterSec, 120);
      }
    });

    test('a wrong-kind or unreadable answer is "unreadable", not a crash', () async {
      final t = make((r) => json(201, {'challengeId': 'c', 'kind': 'sign', 'message': '61', 'expiresAt': '2026-10-31T12:02:00Z'}));
      await expectLater(t.client.claimStart('k', _key, ClaimKind.advert), throwsA(isA<CmatException>()));
    });

    test('claim-complete: POST {challengeId, signature}, returns the claim; 410 / 422 / 400 surface', () async {
      final sig = 'ab' * 64;
      final t = make((r) => json(200, {'claim': claimJson()}));
      final c = await t.client.claimComplete('k', 'c1', sig.toUpperCase());
      expect(c.label, 'Hilltop');
      expect(t.seen.single.url.path, '/api/cmh/claim-complete');
      expect(jsonDecode(t.seen.single.body), {'challengeId': 'c1', 'signature': sig});
      for (final s in [400, 410, 422]) {
        final e = make((r) => json(s, {'error': 'x'}));
        await expectLater(e.client.claimComplete('k', 'c1', sig), throwsA(isA<CmatException>().having((x) => x.status, 'status', s)));
      }
      final bad = make((r) => json(200, {'claim': {'oops': true}}));
      await expectLater(bad.client.claimComplete('k', 'c1', sig), throwsA(isA<CmatException>()));
    });

    test('claim-status: GET with challengeId query', () async {
      final t = make((r) => json(200, {'state': 'pending'}));
      final s = await t.client.claimStatus('k', 'c1');
      expect(s.state, ClaimState.pending);
      expect(t.seen.single.method, 'GET');
      expect(t.seen.single.url.queryParameters, {'challengeId': 'c1'});
      expect(t.seen.single.headers['x-driver-key'], 'k');
    });

    test('my-radios: GET, a bad row is skipped', () async {
      final t = make((r) => json(200, {'claims': [claimJson(), {'pubkey': 'bad'}, claimJson(key: 'ab' * 32)]}));
      final l = await t.client.myRadios('k');
      expect(l.map((c) => c.pubkey), [_key, 'ab' * 32]);
      expect(t.seen.single.url.path, '/api/cmh/my-radios');
    });

    test('release: DELETE /claim?pubkey=', () async {
      final t = make((r) => json(200, {'released': true}));
      await t.client.releaseClaim('k', _key.toUpperCase());
      expect(t.seen.single.method, 'DELETE');
      expect(t.seen.single.url.path, '/api/cmh/claim');
      expect(t.seen.single.url.queryParameters, {'pubkey': _key});
    });

    test('update: PATCH sends only what changes; null clears', () async {
      final t = make((r) => json(200, {'claim': claimJson(positionPublic: true)}));
      final c = await t.client.updateClaim('k', _key, {'positionPublic': true, 'notes': null});
      expect(c.positionPublic, isTrue);
      final r = t.seen.single;
      expect(r.method, 'PATCH');
      expect(jsonDecode(r.body), {'pubkey': _key, 'positionPublic': true, 'notes': null});
    });

    test('network failure is a CmatException without a status', () async {
      final c = HttpCmatClient(Uri.parse('https://x.invalid'), client: MockClient((r) async => throw http.ClientException('down')));
      await expectLater(c.myRadios('k'), throwsA(isA<CmatException>().having((e) => e.status, 'status', isNull)));
    });
  });
}
