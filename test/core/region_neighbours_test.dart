// The regions next to the viewed one (lib/core/region_neighbours.dart): order, outlines, label point, hit testing (a tap in
// the viewed region never offers a switch), and agreement with the website's `regionsNear` when its checkout is present.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_neighbours.dart';
import 'package:path/path.dart' as p;

import '../support/regions_559.dart';
import 'cmat_env.dart';

RegionIndexEntry box(String code, double w, double s, double e, double n, {String? name, bool outline = true, String? type}) => RegionIndexEntry(
      code: code,
      slug: code.toLowerCase(),
      name: name ?? '$code, US',
      url: 'https://${code.toLowerCase()}.meshsonar.com',
      bbox: [w, s, e, n],
      boundary: outline
          ? {
              'type': 'Polygon',
              'coordinates': [
                [[w, s], [e, s], [e, n], [w, n], [w, s]],
              ],
            }
          : null,
    );

void main() {
  // A row of boxes with a one degree gap, plus one far away.
  final cmh = box('CMH', -83.5, 39.5, -82.5, 40.5);
  final day = box('DAY', -84.8, 39.5, -83.8, 40.5); // 0.3 deg west of CMH
  final cvg = box('CVG', -84.9, 38.6, -83.9, 39.3); // south-west
  final cle = box('CLE', -82.0, 41.0, -81.0, 41.8); // north-east
  final syd = box('SYD', 150, -34, 151, -33);
  final index = [syd, cle, cmh, cvg, day];

  test('nearest first by the gap between boxes, then centre; the viewed region and a region with no box are left out', () {
    final set = neighboursOf([...index, const RegionIndexEntry(code: 'NOX', slug: 'nox', name: 'No box', url: 'x')], cmh);
    expect(set.neighbours.map((n) => n.region.code), ['DAY', 'CVG', 'CLE', 'SYD']);
    expect(set.neighbours.first.gapM, closeTo(0.3 * 111195 * 0.77, 6000));
    expect(set.viewing.code, 'CMH');
  });

  test('limit', () {
    expect(neighboursOf(index, cmh, limit: 2).neighbours.length, 2);
  });

  test('a region with no box has no neighbours', () {
    expect(neighboursOf(index, const RegionIndexEntry(code: 'NOX', slug: 'nox', name: 'No box', url: 'x')).isEmpty, isTrue);
  });

  test('outlines: the outer ring of every part, holes dropped; label inside the biggest part', () {
    final multi = RegionIndexEntry(
      code: 'ISL',
      slug: 'isl',
      name: 'Islands, US',
      url: 'x',
      bbox: const [0, 0, 10, 10],
      boundary: {
        'type': 'MultiPolygon',
        'coordinates': [
          [
            [[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]],
          ],
          [
            [[2, 2], [10, 2], [10, 10], [2, 10], [2, 2]],
            [[5, 5], [6, 5], [6, 6], [5, 6], [5, 5]], // a hole
          ],
        ],
      },
    );
    final home = box('HOM', -5, 0, -1, 10);
    final n = neighboursOf([home, multi], home).neighbours.single;
    expect(n.rings.length, 2, reason: 'the hole is not a ring of its own');
    expect(n.rings.map((r) => r.length), [5, 5]);
    expect(n.label.lat, 6.0);
    expect(n.label.lon, 6.0);
    expect(n.contains(8, 8), isTrue);
    expect(n.contains(5.5, 5.5), isFalse, reason: 'the hole');
    expect(n.name, 'Islands', reason: 'country suffix cut');
  });

  test('hit: inside a neighbour is that neighbour; inside the viewed region never; in the overlap the viewed region wins', () {
    final set = neighboursOf(index, cmh);
    expect(set.hit(40.0, -84.3)?.region.code, 'DAY');
    expect(set.hit(40.0, -83.0), isNull, reason: 'inside CMH itself');
    expect(set.hit(35.0, -90.0), isNull, reason: 'nowhere');
    final overlap = neighboursOf([cmh, box('OVR', -83.2, 39.8, -82.0, 40.8)], cmh);
    expect(overlap.hit(40.0, -83.0), isNull);
    expect(overlap.hit(40.7, -82.2)?.region.code, 'OVR');
  });

  test('smallest wins where neighbours overlap', () {
    final big = box('BIG', -86, 39, -83.6, 41);
    final small = box('SML', -85, 39.5, -84.5, 40);
    final set = neighboursOf([cmh, big, small], cmh);
    expect(set.hit(39.7, -84.7)?.region.code, 'SML');
  });

  test('559 regions: fast, and the list is the same every time', () {
    final regions = parseRegionsIndexBody(jsonEncode({'regions': [for (var i = 0; i < 559; i++) syntheticRegion(i).toJson()], 'asOf': 'x'}));
    final sw = Stopwatch()..start();
    final a = neighboursOf(regions, regions[100]);
    sw.stop();
    expect(a.neighbours.length, kRegionNeighbourMax);
    expect(sw.elapsedMilliseconds, lessThan(500));
    expect(neighboursOf(regions, regions[100]).neighbours.map((n) => n.region.code), a.neighbours.map((n) => n.region.code));
  });

  group('agrees with the website (regionsNear)', () {
    final bun = findBun();
    final skip = contractSkipReason('src/lib/region/neighbours.ts');
    test('the same 15 neighbours in the same order on the 559-region stand-in', skip: skip, () async {
      final regions = [for (var i = 0; i < 559; i++) syntheticRegion(i)];
      final tmp = await Directory.systemTemp.createTemp('meshsonar_nb_');
      addTearDown(() => tmp.delete(recursive: true));
      final f = File(p.join(tmp.path, 'index.json'));
      await f.writeAsString(jsonEncode({'regions': [for (final r in regions) r.toJson()]}));
      final script = p.join(Directory.current.path, 'test', 'fixtures', 'neighbours.ts');
      for (final i in [0, 1, 100, 250, 400, 558, 27, 28]) {
        final r = await Process.run(bun!, ['run', script, cmatDir(), f.path, regions[i].slug, '16']);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final theirs = (jsonDecode(r.stdout as String) as List).cast<String>();
        final ours = [regions[i].slug, ...neighboursOf(regions, regions[i]).neighbours.map((n) => n.region.slug)];
        expect(ours, theirs, reason: 'viewing ${regions[i].slug}');
      }
    });
  });
}
