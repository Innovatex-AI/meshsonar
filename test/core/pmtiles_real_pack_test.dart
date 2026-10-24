// The PMTiles reader against the REAL hosted CMH pack (tiles.meshsonar.com, CMH-v261024, planetiler 0.10.2,
// OpenMapTiles schema). Skips cleanly when the 53 MB pack is not on this machine (see test/support/real_pack.dart).
//
// Expected tile hashes, directory statistics and layer lists below were produced by an INDEPENDENT implementation
// (the protomaps `pmtiles` Python package + `mapbox-vector-tile`), via tool/pmtiles_reference.py. They are not
// derived from our Dart reader.

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/pmtiles_reader.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' show VectorTileReader;

import '../support/real_pack.dart';

/// (name, z, x, y, sha256 of the gunzipped tile, MVT layer names) from tool/pmtiles_reference.py.
const _reference = <(String, int, int, int, String, List<String>)>[
  ('z0', 0, 0, 0, '63547489bc5eb4376492a92ac7fe3cb7f118b865c9ac79a7ea574ccec2741e8e', ['water']),
  ('z6 Columbus', 6, 17, 24, '70c678741b947de55ad0ba6cc3443e6cf492bbb2fcea31078de3287c064a13c0', [
    'boundary', 'landuse', 'park', 'place', 'transportation', 'transportation_name', 'water', 'waterway', //
  ]),
  ('z10 Columbus', 10, 275, 387, '6361cc61abb4f28b1d25c7be74511868bee9c7c9422ce566f91a619152c8b12b', [
    'aerodrome_label', 'aeroway', 'boundary', 'landcover', 'landuse', 'mountain_peak', 'park', 'place', //
    'transportation', 'transportation_name', 'water', 'water_name', 'waterway',
  ]),
  ('z14 Columbus', 14, 4414, 6205, '58ccdcf17a12f903fe9a4161ed1077dd5da58be3c855981ad5602484349d63f3', [
    'aeroway', 'building', 'housenumber', 'landcover', 'landuse', 'park', 'place', 'poi', 'transportation', //
    'transportation_name', 'water', 'water_name', 'waterway',
  ]),
  ('z14 SW corner', 14, 4384, 6240, 'dc83aafa8f2b33097f122b1a05cf599081e02bf159104e14da6f007798cef1f6', [
    'landcover', 'poi', 'transportation', 'transportation_name', //
  ]),
  ('z14 NE corner', 14, 4458, 6160, '2a65d871909288df8316857997f5fd9eb9bd0df4910b78a183f81e9787a54efb', [
    'place', 'transportation', 'transportation_name', 'water_name', //
  ]),
];

void main() {
  final skip = realPackSkip;
  late PmtilesReader r;

  setUpAll(() async {
    if (skip != false) return;
    r = await PmtilesReader.open(realPackFile()!);
  });
  tearDownAll(() async {
    if (skip != false) return;
    await r.close();
  });

  test('header matches the manifest: bbox, zooms, gzip, MVT', () {
    final h = r.header;
    expect(h.tileType, PmtilesHeader.typeMvt);
    expect(h.tileCompression, PmtilesHeader.gzip);
    expect(h.internalCompression, PmtilesHeader.gzip);
    expect(h.minZoom, 0);
    expect(h.maxZoom, 14);
    expect(h.minLon, closeTo(realPackBbox[0], 1e-6));
    expect(h.minLat, closeTo(realPackBbox[1], 1e-6));
    expect(h.maxLon, closeTo(realPackBbox[2], 1e-6));
    expect(h.maxLat, closeTo(realPackBbox[3], 1e-6));
    expect(h.clustered, isTrue);
    // Independent values (pmtiles Python): the leaf section sits AFTER the metadata, root is 39 bytes.
    expect([h.rootOffset, h.rootLength, h.leafOffset, h.leafLength], [127, 39, 52938925, 16770]);
    expect([h.dataOffset, h.dataLength, h.metadataOffset, h.metadataLength], [16384, 52921302, 52937686, 1239]);
    expect([h.addressedTiles, h.tileEntries, h.tileContents], [8196, 8196, 8196]);
    expect(realPackFile()!.lengthSync(), realPackBytes);
  }, skip: skip);

  test('metadata names the OpenMapTiles vector layers', () async {
    final m = await r.metadata();
    final layers = {for (final l in (m['vector_layers'] as List)) (l as Map)['id'] as String};
    expect(
      layers,
      containsAll(['water', 'transportation', 'building', 'place', 'transportation_name', 'boundary', 'landuse', 'landcover', 'park', 'water_name']),
    );
  }, skip: skip);

  test('tiles at z0/z6/z10/z14 and both bbox corners equal the independent reader, byte for byte, and parse as MVT', () async {
    for (final (name, z, x, y, sha, layers) in _reference) {
      final b = await r.tile(z, x, y);
      expect(b, isNotNull, reason: name);
      expect(sha256.convert(b!).toString(), sha, reason: '$name gunzipped bytes');
      final mvt = VectorTileReader().read(b);
      expect(mvt.layers.map((l) => l.name).toSet(), layers.toSet(), reason: '$name layers');
      expect(mvt.layers.every((l) => l.extent == 4096 && l.features.isNotEmpty), isTrue, reason: '$name features');
    }
  }, skip: skip);

  test('Columbus tile coordinates come from lat/lon as the map computes them', () {
    expect(tileXY(39.96, -83.00, 10), (275, 387));
    expect(tileXY(39.96, -83.00, 14), (4414, 6205));
  });

  test('tiles just outside the bbox, below/above the zoom range, and in an empty ocean are null', () async {
    expect(await r.tile(14, 4381, 6240), isNull); // 3 tiles west of the SW corner
    expect(await r.tile(14, 4458, 6157), isNull); // 3 tiles north of the NE corner
    expect(await r.tile(15, 8828, 12410), isNull); // z15 > max zoom
    expect(await r.tile(10, 0, 0), isNull); // far away, same zoom
  }, skip: skip);

  test('every tile entry is reachable through the leaf directories (brute-force walk vs lookups)', () async {
    final all = await r.allTileEntries();
    // Independent statistics: 3 leaf directories, 8196 tile entries, all with run length 1 (planetiler wrote no runs
    // for this inland pack; runs are covered by the synthetic test in pmtiles_reader_test.dart).
    expect(all.length, 8196);
    expect(all.every((e) => e.runLength == 1), isTrue);
    for (var i = 1; i < all.length; i++) {
      expect(all[i].tileId, greaterThan(all[i - 1].tileId));
    }
    // Every zoom 0..14 is present; decode each entry's tile id back to z/x/y and look it up through the public API.
    final byZoom = <int, int>{};
    var checked = 0;
    for (var i = 0; i < all.length; i += 37) {
      final (z, x, y) = _zxy(all[i].tileId);
      byZoom[z] = (byZoom[z] ?? 0) + 1;
      expect(pmtilesTileId(z, x, y), all[i].tileId);
      final t = await r.tile(z, x, y);
      expect(t, isNotNull, reason: '$z/$x/$y');
      checked++;
    }
    expect(checked, greaterThan(200));
    final zooms = {for (final e in all) _zxy(e.tileId).$1};
    expect(zooms, {for (var z = 0; z <= 14; z++) z});
    // Tile ids that fall between entries resolve to null, not to the preceding tile.
    var gaps = 0;
    for (var i = 1; i < all.length && gaps < 50; i++) {
      if (all[i].tileId - all[i - 1].tileId > 1) {
        final (z, x, y) = _zxy(all[i - 1].tileId + 1);
        expect(await r.tile(z, x, y), isNull, reason: 'gap $z/$x/$y');
        gaps++;
      }
    }
    expect(gaps, 50);
  }, skip: skip);

  test('many concurrent tile requests (as the map makes them) all succeed', () async {
    final futures = <Future<List<int>?>>[];
    for (var dx = -4; dx <= 4; dx++) {
      for (var dy = -4; dy <= 4; dy++) {
        futures.add(r.tile(14, 4414 + dx, 6205 + dy));
        futures.add(r.tile(12, 1103 + dx ~/ 4, 1551 + dy ~/ 4));
      }
    }
    final got = await Future.wait(futures);
    expect(got.every((t) => t != null && t.isNotEmpty), isTrue);
  }, skip: skip);

  test('a closed reader refuses reads instead of crashing', () async {
    final r2 = await PmtilesReader.open(realPackFile()!);
    // In flight at close: either finishes or fails with PmtilesException; never a FileSystemException or a hang.
    final pending = r2.tile(14, 4414, 6205).then((t) => t != null, onError: (Object e) => e is PmtilesException);
    await r2.close();
    expect(await pending, isTrue);
    expect(r2.tile(14, 4414, 6205), throwsA(isA<PmtilesException>()));
  }, skip: skip);
}

/// Inverse of [pmtilesTileId] (test-side brute force: find the zoom, then search the Hilbert position).
(int, int, int) _zxy(int id) {
  var acc = 0, z = 0;
  while (acc + (1 << z) * (1 << z) <= id) {
    acc += (1 << z) * (1 << z);
    z++;
  }
  final n = 1 << z;
  var d = id - acc;
  var x = 0, y = 0;
  for (var s = 1; s < n; s *= 2) {
    final rx = 1 & (d ~/ 2);
    final ry = 1 & (d ^ rx);
    if (ry == 0) {
      if (rx == 1) {
        x = s - 1 - x;
        y = s - 1 - y;
      }
      final t = x;
      x = y;
      y = t;
    }
    x += s * rx;
    y += s * ry;
    d ~/= 4;
  }
  return (z, x, y);
}
