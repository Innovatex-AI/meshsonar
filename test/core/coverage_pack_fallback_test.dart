// Offline coverage from a pack's snapshot (M2): when the network fails the coverage layers read the installed pack's
// snapshot tile (Measured + Predicted in ONE tile, as build-packs.py writes them), and once the network is back the live
// tile replaces it (at most one re-ask a minute).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/coverage_v2.dart';

void main() {
  final measured = File('test/fixtures/basemap/cov-measured-13-2207-3102.mvt').readAsBytesSync();
  final predicted = File('test/fixtures/basemap/cov-predicted-13-2207-3102.mvt').readAsBytesSync();
  final both = Uint8List.fromList([...measured, ...predicted]); // two MVT messages = one MVT with both layers

  test('a concatenated snapshot tile decodes to each layer exactly like the separate tiles', () {
    for (final (layer, alone) in [(CoverageTileLayer.measured, measured), (CoverageTileLayer.predicted, predicted)]) {
      final a = decodeCoverageTile(alone, layer, 13, 2207, 3102);
      final b = decodeCoverageTile(both, layer, 13, 2207, 3102);
      expect(b.band, a.band, reason: layer.name);
      expect(b.latLon, a.latLon);
      expect(a.band, isNotEmpty, reason: 'the fixture has ${layer.name} cells');
    }
  });

  test('network down: the pack snapshot fills the layer; network back: the live tile replaces it after a minute', () async {
    var online = false;
    var liveAsks = 0;
    final client = CoverageV2Client(
      Uri.parse('https://meshsonar.com'),
      client: MockClient((req) async {
        if (!online) throw http.ClientException('offline');
        liveAsks++;
        return http.Response.bytes(measured, 200);
      }),
    );
    var now = DateTime.utc(2026, 11, 9, 12);
    final packAsks = <String>[];
    final store = CoverageTileStore(
      client,
      decode: (b, l, z, x, y) async => decodeCoverageTile(b, l, z, x, y),
      offlineTiles: (preset, z, x, y) async {
        packAsks.add('$preset $z/$x/$y');
        return z == 13 && x == 2207 && y == 3102 ? both : null;
      },
    )..clock = () => now;
    final mk = coverageTileKey(CoverageTileLayer.measured, 'sf7bw62.5', 227, 13, 2207, 3102);
    final pk = coverageTileKey(CoverageTileLayer.predicted, 'sf7bw62.5', 227, 13, 2207, 3102);
    store.want(CoverageTileLayer.measured, 'sf7bw62.5', 227, 13, 2207, 3102);
    store.want(CoverageTileLayer.predicted, 'sf7bw62.5', 227, 13, 2207, 3102);
    await store.idle();
    expect(store.peek(mk)!.band, isNotEmpty);
    expect(store.peek(pk)!.band, isNotEmpty);
    expect(store.fromPack(mk), isTrue);
    expect(packAsks, hasLength(2));
    // a tile the pack does not have stays missing (the layer's ancestor stand-in covers it)
    store.want(CoverageTileLayer.measured, 'sf7bw62.5', 227, 14, 4414, 6204);
    await store.idle();
    expect(store.has(coverageTileKey(CoverageTileLayer.measured, 'sf7bw62.5', 227, 14, 4414, 6204)), isFalse);

    online = true;
    store.networkFailures = 0;
    store.want(CoverageTileLayer.measured, 'sf7bw62.5', 227, 13, 2207, 3102);
    await store.idle();
    expect(liveAsks, 0, reason: 'within a minute of the pack serve: no re-ask');
    now = now.add(const Duration(minutes: 2));
    store.want(CoverageTileLayer.measured, 'sf7bw62.5', 227, 13, 2207, 3102);
    await store.idle();
    expect(liveAsks, 1);
    expect(store.fromPack(mk), isFalse, reason: 'the live tile replaced the snapshot');
  });

  test('while the layer is offline the pack is read first, with no network wait', () async {
    var netAsks = 0;
    final store = CoverageTileStore(
      CoverageV2Client(Uri.parse('https://meshsonar.com'), client: MockClient((_) async {
        netAsks++;
        throw http.ClientException('offline');
      })),
      decode: (b, l, z, x, y) async => decodeCoverageTile(b, l, z, x, y),
      offlineTiles: (p, z, x, y) async => both,
    )..networkFailures = 3;
    store.want(CoverageTileLayer.measured, 'sf7bw62.5', 1, 13, 2207, 3102);
    await store.idle();
    expect(netAsks, 0);
    expect(store.peek(coverageTileKey(CoverageTileLayer.measured, 'sf7bw62.5', 1, 13, 2207, 3102))!.band, isNotEmpty);
  });
}
