// ID steps 2 and 3 on the wire: capability, paths / methods / bodies of every call, tolerant parsing, the link guard.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/person_identity.dart';

const _key = 'da5dc89c937225aadced4a1cb8a689c0d34ccab96576a0d0f69f3186c879c854';

({HttpCmatClient client, List<http.Request> seen}) make(http.Response Function(http.Request r) answer) {
  final seen = <http.Request>[];
  final mock = MockClient((r) async {
    seen.add(r);
    return answer(r);
  });
  return (client: HttpCmatClient(Uri.parse('https://cmh.meshsonar.com'), client: mock), seen: seen);
}

http.Response js(int status, Object body) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
Map<String, Object?> claim() => {'pubkey': _key, 'nodeType': 'companion', 'method': 'signature', 'verifiedAt': '2026-11-22T10:00:00Z'};

void main() {
  test('radioProof is read from site-config capabilities; absent = false (production at build 73)', () {
    const region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
    expect(const SiteConfig(region: region, capabilities: {'radioProof'}).radioProof, isTrue);
    expect(const SiteConfig(region: region, capabilities: {'nodeClaims', 'driverAccount'}).radioProof, isFalse);
    expect(const SiteConfig(region: region).radioProof, isFalse);
    expect(parseCapabilities({'radioProof': true, 'x': false}), {'radioProof'});
  });

  group('calls', () {
    test('radio-proof-start / -complete / -decide: POST, x-driver-key, bodies', () async {
      final text = utf8.encode('meshsonar-login:v1:meshsonar.com:connect:$_key:${'ab' * 16}:1800000000');
      final hex = text.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final m = make((r) {
        final n = r.url.pathSegments.last;
        if (n == 'radio-proof-start') return js(201, {'proofId': 'p1', 'purpose': 'connect', 'message': hex, 'expiresAt': '2026-11-22T10:02:00Z'});
        if (n == 'radio-proof-complete') {
          return js(200, {'outcome': 'owned_by_other', 'proofId': 'p1', 'decideUntil': '2026-11-22T10:10:00Z', 'owner': {'name': 'KE4BFI', 'nodeType': 'companion'}, 'askFirst': true, 'canJoin': false});
        }
        return js(200, {'outcome': 'join_pending', 'requestId': 'r1'});
      });
      final s = await m.client.radioProofStart('KEY', _key.toUpperCase());
      expect(s.proofId, 'p1');
      expect(utf8.decode(s.message), startsWith('meshsonar-login:v1:'));
      final c = await m.client.radioProofComplete('KEY', 'p1', 'AB' * 64);
      expect(c.kind, ProofKind.ownedByOther);
      expect((c.ownerName, c.askFirst, c.canJoin), ('KE4BFI', true, false));
      final d = await m.client.radioProofDecide('KEY', 'p1', join: true);
      expect((d.kind, d.requestId), (DecideKind.joinPending, 'r1'));
      expect([for (final r in m.seen) '${r.method} ${r.url.path}'], ['POST /api/cmh/radio-proof-start', 'POST /api/cmh/radio-proof-complete', 'POST /api/cmh/radio-proof-decide']);
      expect(m.seen.every((r) => r.headers['x-driver-key'] == 'KEY'), isTrue);
      expect(jsonDecode(m.seen[0].body), {'pubkey': _key});
      expect(jsonDecode(m.seen[1].body), {'proofId': 'p1', 'signature': 'ab' * 64});
      expect(jsonDecode(m.seen[2].body), {'proofId': 'p1', 'decision': 'join'});
    });

    test('a 404 (flag off) and a 422 bad_signature surface as CmatException with status and code', () async {
      final m = make((r) => r.url.pathSegments.last == 'radio-proof-start' ? js(404, {'error': 'not found'}) : js(422, {'error': 'x', 'code': 'bad_signature'}));
      await expectLater(m.client.radioProofStart('KEY', _key), throwsA(isA<CmatException>().having((e) => e.status, 'status', 404)));
      await expectLater(m.client.radioProofComplete('KEY', 'p1', 'ab' * 64), throwsA(isA<CmatException>().having((e) => e.code, 'code', 'bad_signature')));
    });

    test('person devices, rename, remove, notices, prefs, link-start', () async {
      final m = make((r) {
        switch (r.url.pathSegments.last) {
          case 'person-devices':
            return js(200, {
              'devices': [
                {'id': 'd1', 'name': 'iPhone', 'nameSet': false, 'kind': 'app', 'status': 'approved', 'createdAt': '2026-11-01T00:00:00Z', 'lastSeenAt': '2026-11-22T09:00:00Z', 'model': 'iPhone17,1', 'appBuild': '73', 'os': 'iOS 27.2', 'current': true},
                {'id': 'd2', 'name': 'MeshMapper import', 'kind': 'meshmapper', 'status': 'approved', 'lastSeenAt': null},
                'junk',
                {'name': 'no id'},
              ]
            });
          case 'person-notices':
            return js(200, {
              'notices': [
                {'id': 'n1', 'kind': 'join_request', 'createdAt': '2026-11-22T09:00:00Z', 'read': false, 'resolution': null, 'pubkey': _key, 'nodeName': 'My radio', 'device': {'id': 'd3', 'name': 'iPad', 'removed': false}},
                {'id': 'n2', 'kind': 'radio_taken', 'read': true, 'resolution': null, 'pubkey': _key, 'nodeName': null, 'device': null},
              ],
              'askFirst': true
            });
          case 'person-prefs':
            return js(200, {'askFirst': jsonDecode(r.body)['askFirst']});
          case 'link-start':
            return js(201, {'code': 'ABCDEFGHJKMN', 'url': 'https://meshsonar.com/link?code=ABCDEFGHJKMN', 'expiresAt': '2026-11-22T10:10:00Z'});
          default:
            return js(200, {'ok': true});
        }
      });
      final devs = await m.client.personDevices('KEY');
      expect(devs.map((d) => d.id), ['d1', 'd2']);
      expect(devs.first.current, isTrue);
      expect(devs.first.detail, 'iPhone17,1 · build 73 · iOS 27.2');
      expect(devs.last.isImport, isTrue);
      expect(devs.last.detail, 'MeshMapper import');
      await m.client.renameDevice('KEY', 'd2', null);
      await m.client.removeDevice('KEY', 'd2');
      final n = await m.client.personNotices('KEY');
      expect(n.askFirst, isTrue);
      expect(n.notices.first.isOpenRequest, isTrue);
      expect(n.notices.first.words, 'iPad wants to join your account because it connected My radio.');
      expect(n.notices.last.words, contains('moved to their account'));
      expect(n.unread, 1);
      await m.client.personNoticeAct('KEY', 'n1', 'approve');
      expect(await m.client.setAskFirst('KEY', true), isTrue);
      final l = await m.client.linkStart('KEY');
      expect(l.url.toString(), 'https://meshsonar.com/link?code=ABCDEFGHJKMN');
      expect([for (final r in m.seen) '${r.method} ${r.url.path}'], [
        'GET /api/cmh/person-devices',
        'POST /api/cmh/person-device-rename',
        'POST /api/cmh/person-device-remove',
        'GET /api/cmh/person-notices',
        'POST /api/cmh/person-notice',
        'POST /api/cmh/person-prefs',
        'POST /api/cmh/link-start',
      ]);
      expect(jsonDecode(m.seen[1].body), {'id': 'd2', 'name': null});
      expect(jsonDecode(m.seen[4].body), {'id': 'n1', 'action': 'approve'});
    });
  });

  group('parse', () {
    test('LinkStart only ever opens a MeshSonar https link', () {
      Map<String, dynamic> j(String u) => {'code': 'ABC', 'url': u, 'expiresAt': '2026-11-22T10:10:00Z'};
      expect(LinkStart.parse(j('https://meshsonar.com/link?code=ABC')).code, 'ABC');
      expect(LinkStart.parse(j('https://cmh.meshsonar.com/link?code=ABC')).code, 'ABC');
      for (final bad in ['http://meshsonar.com/link', 'https://evil.example/link?code=ABC', 'https://meshsonar.com.evil.example/x', 'javascript:alert(1)', '']) {
        expect(() => LinkStart.parse(j(bad)), throwsFormatException, reason: bad);
      }
    });
    test('outcomes: unknown outcome and bad bodies throw FormatException; a missing canJoin means can join', () {
      expect(() => ProofResult.parse({'outcome': 'weird'}), throwsFormatException);
      expect(() => ProofStart.parse({'proofId': 'p', 'message': 'zz', 'expiresAt': '2026-11-22T10:00:00Z'}), throwsFormatException);
      expect(ProofResult.parse({'outcome': 'owned_by_other', 'proofId': 'p', 'owner': {'name': null}}).canJoin, isTrue);
      expect(ProofResult.parse({'outcome': 'owned_by_other', 'proofId': 'p', 'owner': {'name': null}}).ownerName, isNull);
      expect(DecideResult.parse({'outcome': 'refused', 'reason': 'device_has_account'}).reason, 'device_has_account');
      expect(() => DecideResult.parse({'outcome': 'x'}), throwsFormatException);
    });
  });
}

