// Coverage v2 core: the band rule (same as SQL ms_coverage_band / website bandOf), the meta and inspector answers, and MVT
// decoding of the live fixtures captured from meshsonar.com on Nov 8 2026 (meshsonar-infra docs/planning/coverage-v2-fixtures).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/coverage_v2.dart';

Map<String, dynamic> _json(String name) => jsonDecode(File('test/fixtures/coverage_v2/$name').readAsStringSync()) as Map<String, dynamic>;
Uint8List _bytes(String name) => File('test/fixtures/coverage_v2/$name').readAsBytesSync();

void main() {
  group('band rule', () {
    test('margins over the SF7 floor: edges belong to the band above', () {
      int b(double s) => coverageBandOf(snrMean: s, nOk: 1, nSnr: 1);
      expect(b(-10), 1);
      expect(b(-7.51), 1);
      expect(b(-7.5), 2);
      expect(b(-2.5), 3);
      expect(b(2.5), 4);
      expect(b(7.49), 4);
      expect(b(7.5), 5);
      expect(b(13), 5);
    });
    test('no reply is 0, heard without a direct SNR is 6', () {
      expect(coverageBandOf(snrMean: null, nOk: 0, nSnr: 0), 0);
      expect(coverageBandOf(snrMean: 5, nOk: 0, nSnr: 0), 0);
      expect(coverageBandOf(snrMean: null, nOk: 2, nSnr: 0), 6);
    });
    test('other SFs shift by their floor', () {
      expect(snrFloorDb(7), -7.5);
      expect(snrFloorDb(12), -20);
      expect(coverageBandOf(snrMean: -12, nOk: 1, nSnr: 1, sf: 12), 3); // margin 8 dB over -20
      expect(presetSf('sf7bw62.5'), 7);
      expect(presetSf('sf11bw250'), 11);
      expect(presetSf('junk'), 7);
    });
  });

  group('meta', () {
    final m = CoverageMeta.fromJson(_json('meta.json'));
    test('reads the live answer', () {
      expect(m.bands.length, 7);
      expect(m.labelOf(5), 'Excellent');
      expect(m.labelOf(6), 'Heard, no direct signal');
      expect(m.faintBelow, 3);
      expect(m.hexFromZoom, 13);
      expect(m.predictedFromZoom, 8);
      expect(m.version, 101);
      expect(m.defaultPreset, 'sf7bw62.5');
      expect(m.edgesFor(7), [-7.5, -2.5, 2.5, 7.5]);
      expect(m.edgesFor(12), [-20, -15, -10, -5]);
    });
    test('legend ranges in dB', () {
      expect(m.rangeText(5), 'above +7.5 dB');
      expect(m.rangeText(4), '+2.5 to +7.5 dB');
      expect(m.rangeText(3), '−2.5 to +2.5 dB');
      expect(m.rangeText(1), 'below −7.5 dB');
      expect(m.rangeText(0), isNull);
      expect(m.rangeText(6), isNull);
    });
    test('round-trips through the offline cache text', () {
      final again = CoverageMeta.fromJsonString(m.toJsonString())!;
      expect(again.version, m.version);
      expect(again.bands.length, 7);
      expect(CoverageMeta.fromJsonString('nope'), isNull);
      expect(() => CoverageMeta.fromJson({'v': 1}), throwsFormatException);
    });
  });

  group('cell inspector', () {
    test('measured cell', () {
      final c = CoverageCellInfo.fromJson(_json('cell-measured.json'));
      expect(c.h3, '8b2a95620b46fff');
      expect(c.predicted, isNull);
      final m = c.measured!;
      expect(m.nOk, 5);
      expect(m.nFail, 0);
      expect(m.band, 4);
      expect(m.snrMean, 6.35);
      expect(m.replyRate, 1);
      expect(m.sources, {'meshsonar': 1, 'meshmapper': 4});
      expect([for (final r in m.repeaters) r.key], ['297d', 'da5d']);
      expect(m.repeaters.first.snrMean, 6.83);
    });
    test('predicted cell', () {
      final c = CoverageCellInfo.fromJson(_json('cell-predicted.json'));
      expect(c.measured, isNull);
      final p = c.predicted!;
      expect(p.band, 4);
      expect(p.snrEst, 6.55);
      expect(p.dNearestM, 976);
      expect(p.contributors, 2);
    });
  });

  group('MVT tiles', () {
    test('z13 measured: hexagons inside the tile, with band, n and h', () {
      final d = decodeCoverageTile(_bytes('measured-13-2207-3102.mvt'), CoverageTileLayer.measured, 13, 2207, 3102);
      expect(d.length, greaterThan(0));
      final s = tileLat(3103, 13), n = tileLat(3102, 13), w = tileLon(2207, 13), e = tileLon(2208, 13);
      for (var f = 0; f < d.length; f++) {
        expect(d.vertexCount(f), 6, reason: 'a res-11 hexagon (ring not closed)');
        expect(d.band[f], inInclusiveRange(0, 6));
        expect(d.n[f], greaterThan(0));
        expect(d.h[f], startsWith('8b'));
        // Hexagons are clipped to the tile buffer, so a vertex may sit a little outside: allow one cell (~0.0005 deg).
        for (var v = d.starts[f]; v < d.starts[f + 1]; v++) {
          expect(d.latLon[2 * v], inInclusiveRange(s - 0.001, n + 0.001));
          expect(d.latLon[2 * v + 1], inInclusiveRange(w - 0.001, e + 0.001));
        }
      }
    });
    test('z9 measured: centroid points over Columbus', () {
      final d = decodeCoverageTile(_bytes('measured-9-137-193.mvt'), CoverageTileLayer.measured, 9, 137, 193);
      expect(d.length, greaterThan(100));
      for (var f = 0; f < d.length; f++) {
        expect(d.isPoint(f), isTrue);
        expect(d.latLon[2 * d.starts[f]], inInclusiveRange(39, 41));
        expect(d.latLon[2 * d.starts[f] + 1], inInclusiveRange(-84, -82));
      }
    });
    test('z16 predicted: opacity in 0.15-0.6, band 0-5', () {
      final d = decodeCoverageTile(_bytes('predicted-16-17658-24819.mvt'), CoverageTileLayer.predicted, 16, 17658, 24819);
      expect(d.length, greaterThan(0));
      for (var f = 0; f < d.length; f++) {
        expect(d.band[f], inInclusiveRange(0, 5));
        expect(d.o[f], inInclusiveRange(0.149, 0.601));
      }
    });
    test('the wrong layer name and empty bytes decode to nothing', () {
      expect(decodeCoverageTile(_bytes('measured-9-137-193.mvt'), CoverageTileLayer.predicted, 9, 137, 193).length, 0);
      expect(decodeCoverageTile(Uint8List(0), CoverageTileLayer.measured, 9, 137, 193).length, 0);
    });
    test('tile maths', () {
      final (x, y) = tileOf(39.96, -83.0, 13);
      expect((x, y), (2207, 3102));
      expect(coverageTileZoom(12.7), 12);
      expect(coverageTileZoom(19), 16);
      expect(tilesCovering(39.95, -83.01, 39.97, -82.99, 13), contains((2207, 3102)));
    });
  });

  group('client and tile store', () {
    test('paths, 204 = empty tile, 400 = error', () async {
      final seen = <String>[];
      final c = CoverageV2Client(Uri.parse('https://meshsonar.com'), client: MockClient((r) async {
        seen.add(r.url.toString());
        if (r.url.path.endsWith('/meta')) return http.Response(jsonEncode(_json('meta.json')), 200);
        if (r.url.path.contains('/cell/')) return http.Response(jsonEncode(_json('cell-measured.json')), 200);
        if (r.url.path.contains('/9/')) return http.Response('', 204);
        return http.Response('bad', 400);
      }));
      expect((await c.meta()).version, 101);
      expect((await c.cell('8B2A95620B46FFF', preset: 'sf7bw62.5')).measured!.nOk, 5);
      expect(await c.tile(CoverageTileLayer.measured, 9, 1, 2, preset: 'sf7bw62.5'), isNull);
      expect(() => c.tile(CoverageTileLayer.measured, 10, 1, 2, preset: 'sf7bw62.5'), throwsA(isA<CoverageV2Exception>()));
      expect(seen[0], 'https://meshsonar.com/api/coverage/meta');
      expect(seen[1], 'https://meshsonar.com/api/coverage/cell/8b2a95620b46fff?preset=sf7bw62.5');
      expect(seen[2], 'https://meshsonar.com/api/coverage/tiles/measured/9/1/2.mvt?preset=sf7bw62.5');
    });

    test('the store fetches once, keeps tiles, and counts network failures', () async {
      var calls = 0;
      var fail = false;
      final store = CoverageTileStore(
        CoverageV2Client(Uri.parse('https://x.test'), client: MockClient((r) async {
          calls++;
          if (fail) throw http.ClientException('offline');
          return http.Response.bytes(_bytes('measured-13-2207-3102.mvt'), 200);
        })),
        decode: (b, l, z, x, y) async => decodeCoverageTile(b, l, z, x, y),
      );
      var changes = 0;
      store.addListener(() => changes++);
      store.want(CoverageTileLayer.measured, 'p', 1, 13, 2207, 3102);
      store.want(CoverageTileLayer.measured, 'p', 1, 13, 2207, 3102);
      await store.idle();
      expect(calls, 1);
      expect(changes, 1);
      expect(store.peek(coverageTileKey(CoverageTileLayer.measured, 'p', 1, 13, 2207, 3102))!.length, greaterThan(0));
      fail = true;
      for (var i = 0; i < 3; i++) {
        store.want(CoverageTileLayer.measured, 'p', 1, 13, 1, i);
      }
      await store.idle();
      expect(store.offline, isTrue);
    });
  });
}
