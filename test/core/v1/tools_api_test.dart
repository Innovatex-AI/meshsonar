// The Tools reads (tools_api.dart): path-inspect and the prefix report against bodies captured from the live API
// (cmh, Nov 21 2026), the trace against a body built from the server code (no live TRACE existed), tolerant parsing,
// not-found, offline, and the hop / prefix input rules.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/v1/packet_models.dart' show HopConfidence;
import 'package:meshsonar/core/v1/tools_api.dart';
import 'package:meshsonar/core/v1/v1_client.dart' show resetV1NotLive;

String fixture(String name) => File('test/fixtures/analyzer/$name.json').readAsStringSync();
http.Response json(String body, [int status = 200]) => http.Response(body, status, headers: {'content-type': 'application/json; charset=utf-8'});
const base = 'https://cmh.meshsonar.com';

void main() {
  setUp(resetV1NotLive);

  test('path-inspect posts hops and hashSize and reads the candidates', () async {
    late http.Request sent;
    final api = ToolsApi(base, client: MockClient((r) async {
      sent = r;
      return json(fixture('tools-path-inspect'));
    }));
    final res = await api.pathInspect(['a1', '3f'], hashSize: 1);
    expect(sent.method, 'POST');
    expect(sent.url.toString(), '$base/v1/tools/path-inspect');
    expect(jsonDecode(sent.body), {'hops': ['a1', '3f'], 'hashSize': 1});
    expect(res.candidates.length, 3);
    final c = res.candidates.first;
    expect(c.rank, 1);
    expect(c.speculative, isTrue);
    expect(c.score, closeTo(0.41, 0.001));
    expect(c.hops.map((h) => h.prefix), ['a1', '3f']);
    expect(c.hops.first.node!.key.length, 64);
    expect(c.hops.first.hopScore, isNotNull);
    expect(c.totalKm, isNotNull);
    expect(res.speculativeBelow, 0.7);
    expect(res.unknownHops, isEmpty);
  });

  test('path-inspect: odd fields do not throw, a server error is a V1Error', () async {
    final meta = (jsonDecode(fixture('tools-path-inspect')) as Map)['meta'];
    final odd = jsonEncode({
      'data': {
        'candidates': [
          {'rank': '1', 'hops': [{'prefix': 'a1', 'node': null}, 'junk', {'node': {}}]},
          'junk',
        ],
        'unknownHops': 2,
      },
      'meta': meta,
    });
    final res = await ToolsApi(base, client: MockClient((_) async => json(odd))).pathInspect(['a1'], hashSize: 1);
    expect(res.candidates.single.hops.single.node, isNull);
    expect(res.candidates.single.score, 0);
    expect(res.unknownHops.length, 2);

    final bad = ToolsApi(base, client: MockClient((_) async => json('{"error":{"code":"bad_param","message":"hashSize must be 1, 2 or 3","param":"body","requestId":"r"}}', 400)));
    await expectLater(bad.pathInspect(['a1'], hashSize: 9), throwsA(isA<V1Error>().having((e) => e.code, 'code', 'bad_param')));
  });

  test('trace reads hops, SNRs, observations and the copies', () async {
    late Uri asked;
    final api = ToolsApi(base, client: MockClient((r) async {
      asked = r.url;
      return json(fixture('tools-trace'));
    }));
    final t = await api.trace(' 50B835A910DA5AAC ');
    expect(asked.path, '/v1/traces/50b835a910da5aac');
    expect(t.targets, ['a1', '3f', 'c4']);
    expect(t.completed, 2);
    expect(t.complete, isFalse);
    expect(t.hops[0].confidence, HopConfidence.unique);
    expect(t.hops[0].node!.name, 'Nagglepuss2');
    expect(t.hops[0].snrDb, 9.25);
    expect(t.hops[1].confidence, HopConfidence.ambiguous);
    expect(t.hops[2].snrDb, isNull);
    expect(t.observations.length, 2);
    expect(t.observations[1].observerKind, 'outside');
    expect(t.observations[1].observerName, isNull);
    expect(t.spread, const Duration(milliseconds: 1200));
    expect(t.copies, ['50b835a910da5aac', '7c1e02aa44b1d3f0']);
  });

  test('trace: a bare body still parses; not found and offline are told apart', () async {
    final meta = (jsonDecode(fixture('tools-trace')) as Map)['meta'];
    final bare = jsonEncode({'data': {'hash': 'AAAAAAAAAAAAAAAA', 'tag': 12345, 'hops': 'x', 'observations': [{'observer': 'x'}, {}]}, 'meta': meta});
    final t = await ToolsApi(base, client: MockClient((_) async => json(bare))).trace('aaaaaaaaaaaaaaaa');
    expect(t.hash, 'aaaaaaaaaaaaaaaa');
    expect(t.tag, '12345');
    expect(t.hops, isEmpty);
    expect(t.observations, isEmpty);
    expect(t.complete, isFalse);

    final missing = ToolsApi(base, client: MockClient((_) async => json('{"error":{"code":"not_found","message":"No packet with hash x in the last 90 days.","param":"hash","requestId":"r"}}', 404)));
    await expectLater(missing.trace('50b835a910da5aac'), throwsA(isA<V1Error>().having((e) => e.notFound, 'notFound', isTrue)));
    final down = ToolsApi(base, client: MockClient((_) async => throw const SocketException('down')));
    await expectLater(down.trace('50b835a910da5aac'), throwsA(isA<V1Error>().having((e) => e.offline, 'offline', isTrue)));
  });

  test('recent traces ask for TRACE packets of the last 7 days', () async {
    late Uri asked;
    final meta = (jsonDecode(fixture('tools-trace')) as Map)['meta'];
    final api = ToolsApi(base, client: MockClient((r) async {
      asked = r.url;
      return json(jsonEncode({'data': [], 'page': {'limit': 30, 'next': null, 'prev': null}, 'meta': meta}));
    }));
    expect(await api.recentTraces(), isEmpty);
    expect(asked.path, '/v1/packets');
    expect(asked.queryParameters['type'], 'TRACE');
    expect(asked.queryParameters['window'], '7d');
    expect(asked.queryParameters['limit'], '30');
  });

  test('prefix report: checks, conflicts, suggestions, overview', () async {
    late Uri asked;
    final api = ToolsApi(base, client: MockClient((r) async {
      asked = r.url;
      return json(fixture('tools-prefix'));
    }));
    final p = await api.prefix(prefix: ' A1 ');
    expect(asked.path, '/v1/insights/hashes/prefix');
    expect(asked.queryParameters, {'prefix': 'a1'});
    expect(p.query, 'a1');
    expect(p.checks.map((c) => c.bytes), [1, 2, 3]);
    expect(p.checks.first.free, isFalse);
    expect(p.checks.first.conflicts, isNotEmpty);
    expect(p.checks.first.conflicts.first.key.startsWith('a1'), isTrue);
    expect(p.checks[1].prefix, isNull);
    expect(p.suggestions, isNotEmpty);
    expect(p.repeaters, greaterThan(0));
    expect(p.recommendation, anyOf('1', '2'));
    expect(p.radiusKm, 200);
    expect(p.note, isNotNull);
    await api.prefix();
    expect(asked.queryParameters, isEmpty);
  });

  test('hop input: spaces, commas, arrows, an unbroken string, and errors', () {
    expect(parseHopInput('a1, b2 c3').hops, ['a1', 'b2', 'c3']);
    expect(parseHopInput('A1 > b2 → c3 -> d4').hops, ['a1', 'b2', 'c3', 'd4']);
    expect(parseHopInput('a1-b2;c3').hops, ['a1', 'b2', 'c3']);
    expect(parseHopInput('a1b2c3').hops, ['a1', 'b2', 'c3']);
    expect(parseHopInput('a1b2c3d4', hashSize: 2).hops, ['a1b2', 'c3d4']);
    final two = parseHopInput('a1b2 c3d4');
    expect(two.hops, ['a1b2', 'c3d4']);
    expect(two.hashSize, 2, reason: 'hops typed apart set the size themselves');
    expect(parseHopInput('a1b2c3', hashSize: 3).hashSize, 3);
    expect(parseHopInput('').error, 'Type at least one hop prefix.');
    expect(parseHopInput('a1 zz').error, contains('"zz" is not hex'));
    expect(parseHopInput('a1 b2c').error, contains('"b2c" is not a 1-byte prefix'));
    expect(parseHopInput('a1b2c', hashSize: 2).error, contains('cannot be cut'));
    expect(parseHopInput(List.filled(65, 'a1').join(' ')).error, 'At most 64 hops.');
  });

  test('prefix input rule', () {
    expect(prefixInputError(''), isNull);
    expect(prefixInputError('a1'), isNull);
    expect(prefixInputError('A1B2C3'), isNull);
    expect(prefixInputError('a' * 64), isNull);
    expect(prefixInputError('a1b'), isNotNull);
    expect(prefixInputError('xyz1'), isNotNull);
  });
}
