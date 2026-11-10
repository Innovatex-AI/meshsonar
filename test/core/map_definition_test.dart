// The Map Definition cache (core/map_definition.dart, plan §8b row M2) against the M1 fixture: the bundled copy is the
// fixture and parses; the basemap it names is the one the app draws; the last good copy is kept per scope; refresh only
// when stale (ETag, 304); a body that fails to parse, a newer schema, a 404 (not deployed) or no network never replace a
// good copy.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/basemap.dart';
import 'package:meshsonar/core/map_definition.dart';

final bundled = File('assets/map/map-definition.json').readAsStringSync();

String withVersion(String v, {int schema = 1}) {
  final j = jsonDecode(bundled) as Map<String, dynamic>;
  j['version'] = v;
  j['v'] = schema;
  return jsonEncode(j);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('mapdef'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the bundled copy is the M1 fixture (meshsonar-infra docs/planning) and parses', () {
    final infra = File('../meshsonar-infra/docs/planning/map-definition-fixture.json');
    if (infra.existsSync()) expect(bundled, infra.readAsStringSync(), reason: 'copy the fixture again when M1 regenerates it');
    final d = MapDefinition.parse(bundled);
    expect(d.v, 1);
    expect(d.layers.map((l) => l['id']), containsAllInOrder(['borders', 'predicted', 'heard', 'measured', 'repeaters']));
    expect(d.palettes.map((p) => p['id']), containsAll(['standard', 'colour_blind']));
    expect((d.coverage['tiles'] as Map)['hexFromZoom'], 13);
  });

  test('contract parity: the road basemap in the definition is the one the app draws, with the same credit', () {
    final road = MapDefinition.parse(bundled).basemap('road')!;
    expect((road['vector'] as Map)['tiles'], OurBasemap.tileUrl);
    expect((road['vector'] as Map)['bounds'], OurBasemap.bounds);
    expect((road['vector'] as Map)['maxzoom'], OurBasemap.maxZoom);
    expect((road['attribution'] as List).join(' '), OurBasemap.attribution);
    expect(road['offline'], isTrue, reason: 'Road may go in an offline pack');
    expect((road['fallbackStyle'] as Map)['light'], contains('tiles.openfreemap.org'));
  });

  test('parse refuses what the contract calls unusable', () {
    final j = jsonDecode(bundled) as Map<String, dynamic>;
    String without(String k) => jsonEncode({...j}..remove(k));
    for (final bad in [
      'not json',
      '[]',
      without('v'),
      without('version'),
      without('layers'),
      without('palettes'),
      without('basemaps'),
      without('coverage'),
      jsonEncode({...j, 'layers': []}),
      jsonEncode({...j, 'layers': [{'name': 'no id'}]}),
      withVersion('x', schema: 2),
    ]) {
      expect(() => MapDefinition.parse(bad), throwsFormatException, reason: bad.length > 40 ? bad.substring(0, 40) : bad);
    }
  });

  MapDefinitionStore store(http.Client c, {DateTime Function()? clock}) => MapDefinitionStore(
    root: Directory('${tmp.path}/d'),
    origin: Uri.parse('https://meshsonar.com'),
    client: c,
    loadBundled: () async => bundled,
    clock: clock,
  );

  test('first launch with no network: the bundled copy', () async {
    final s = store(MockClient((_) async => throw http.ClientException('offline')));
    final c = await s.refreshIfStale('cmh');
    expect(c.origin, MapDefinitionOrigin.bundled);
    expect(c.definition.version, MapDefinition.parse(bundled).version);
  });

  test('not deployed yet (404) or a server error: the copy the app has', () async {
    for (final code in [404, 500, 503]) {
      final s = store(MockClient((_) async => http.Response('nope', code)));
      expect((await s.refreshIfStale()).origin, MapDefinitionOrigin.bundled);
    }
  });

  test('a good server copy is saved per scope, reused offline, refreshed only when stale, with If-None-Match', () async {
    var now = DateTime.utc(2026, 11, 9, 20);
    final asks = <http.Request>[];
    var answer = (http.Request r) async => http.Response.bytes(utf8.encode(withVersion('aaaa1111')), 200, headers: {'etag': '"md1-aaaa1111"'});
    final s = store(MockClient((r) async {
      asks.add(r);
      return answer(r);
    }), clock: () => now);
    final changed = <String>[];
    s.changes.listen(changed.add);
    final c = await s.refreshIfStale('CMH');
    expect(asks.single.url.toString(), 'https://meshsonar.com/api/map/definition?scope=cmh');
    expect(c.origin, MapDefinitionOrigin.server);
    expect(c.definition.version, 'aaaa1111');
    await Future<void>.delayed(Duration.zero);
    expect(changed, ['cmh']);
    await s.refreshIfStale('cmh');
    expect(asks, hasLength(1), reason: 'fresh for an hour');
    now = now.add(const Duration(hours: 2));
    answer = (r) async => http.Response('', 304);
    final c2 = await s.refreshIfStale('cmh');
    expect(asks.last.headers['if-none-match'], '"md1-aaaa1111"');
    expect(c2.definition.version, 'aaaa1111');
    expect(c2.confirmedAt, now.toUtc());
    // a new run of the app with no network: the saved copy, not the bundled one
    final offline = store(MockClient((_) async => throw http.ClientException('offline')), clock: () => now);
    final c3 = await offline.refreshIfStale('cmh', true);
    expect(c3.origin, MapDefinitionOrigin.saved);
    expect(c3.definition.version, 'aaaa1111');
    // other scopes are separate
    expect((await offline.current('day')).origin, MapDefinitionOrigin.bundled);
    // the hub: no scope parameter
    expect(s.urlFor(null).toString(), 'https://meshsonar.com/api/map/definition');
  });

  test('never replace a good copy with one that failed to parse (broken JSON, a newer schema, an empty layer list)', () async {
    var now = DateTime.utc(2026, 11, 9, 20);
    var body = withVersion('good0001');
    final s = store(MockClient((_) async => http.Response.bytes(utf8.encode(body), 200, headers: {'etag': '"e"'})), clock: () => now);
    expect((await s.refreshIfStale('cmh')).definition.version, 'good0001');
    final broken = jsonDecode(withVersion('bad00002')) as Map<String, dynamic>..['layers'] = [];
    for (final bad in ['{"v":1,', withVersion('bad00001', schema: 2), jsonEncode(broken)]) {
      now = now.add(const Duration(hours: 2));
      body = bad;
      final c = await s.refreshIfStale('cmh');
      expect(c.definition.version, 'good0001');
      final again = store(MockClient((_) async => throw http.ClientException('offline')), clock: () => now);
      expect((await again.current('cmh')).definition.version, 'good0001', reason: 'the saved file was not overwritten');
    }
  });

  test('a damaged saved file falls back to the bundled copy (never a crash)', () async {
    Directory('${tmp.path}/d').createSync(recursive: true);
    File('${tmp.path}/d/map_definition_cmh.json').writeAsStringSync('{garbage');
    final s = store(MockClient((_) async => throw http.ClientException('offline')));
    expect((await s.current('cmh')).origin, MapDefinitionOrigin.bundled);
  });
}
