// WP13: DAY and CVG offline packs. Pack-open test on the small fixture pattern (pmtiles_reader_test.dart) with the
// real region bboxes, plus the manifest shape the app must accept with three packs.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/offline_packs.dart';
import 'package:meshsonar/core/pmtiles_reader.dart';

List<int> _varint(int v) {
  final o = <int>[];
  while (v >= 0x80) {
    o.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  o.add(v);
  return o;
}

Uint8List _dir(List<(int, int, int, int)> es) {
  final o = <int>[..._varint(es.length)];
  var last = 0;
  for (final e in es) {
    o.addAll(_varint(e.$1 - last));
    last = e.$1;
  }
  for (final e in es) {
    o.addAll(_varint(e.$4));
  }
  for (final e in es) {
    o.addAll(_varint(e.$3));
  }
  for (final e in es) {
    o.addAll(_varint(e.$2 + 1));
  }
  return Uint8List.fromList(gzip.encode(o));
}

/// 3-tile PMTiles v3 fixture (0/0/0, 1/0/0, 1/1/1 behind a leaf directory) with the given bbox (minLon, minLat, maxLon, maxLat).
Uint8List _pack(List<double> bbox) {
  final t0 = Uint8List.fromList(gzip.encode([1, 2, 3]));
  final t1 = Uint8List.fromList(gzip.encode([4, 4]));
  final t2 = Uint8List.fromList(gzip.encode([9, 9, 9, 9]));
  final leaf = _dir([
    (pmtilesTileId(1, 1, 1), t0.length + t1.length, t2.length, 1),
  ]);
  final root = _dir([
    (0, 0, t0.length, 1),
    (pmtilesTileId(1, 0, 0), t0.length, t1.length, 1),
    (pmtilesTileId(1, 1, 1), 0, leaf.length, 0),
  ]);
  const hdr = 127;
  final rootOff = hdr,
      leafOff = rootOff + root.length,
      dataOff = leafOff + leaf.length;
  final h = ByteData(hdr);
  for (var i = 0; i < 7; i++) {
    h.setUint8(i, 'PMTiles'.codeUnitAt(i));
  }
  h.setUint8(7, 3);
  void u64(int o, int v) => h.setUint64(o, v, Endian.little);
  u64(8, rootOff);
  u64(16, root.length);
  u64(40, leafOff);
  u64(48, leaf.length);
  u64(56, dataOff);
  u64(64, t0.length + t1.length + t2.length);
  h.setUint8(97, 2);
  h.setUint8(98, 2);
  h.setUint8(99, 1);
  h.setUint8(100, 0);
  h.setUint8(101, 14);
  for (var i = 0; i < 4; i++) {
    h.setInt32(102 + 4 * i, (bbox[i] * 1e7).round(), Endian.little);
  }
  return Uint8List.fromList([
    ...h.buffer.asUint8List(),
    ...root,
    ...leaf,
    ...t0,
    ...t1,
    ...t2,
  ]);
}

const _regions = <String, List<double>>{
  'DAY': [-85.3016, 39.3774, -83.2524, 40.5722],
  'CVG': [-85.7998, 38.3387, -83.2676, 39.5910],
  'CMH': [-83.6534, 39.3613, -82.0242, 40.7127],
};

Map<String, dynamic> _entry(String code) => {
  'code': code,
  'name': code,
  'version': 261101,
  'bytes': 1234567,
  'sha256': 'a' * 64,
  'url': 'https://tiles.meshsonar.com/$code-v261101.pmtiles',
  'bbox': _regions[code],
  'min_zoom': 0,
  'max_zoom': 14,
};

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('wp13'));
  tearDown(() => tmp.deleteSync(recursive: true));

  for (final code in ['DAY', 'CVG']) {
    test(
      '$code fixture pack opens, header bbox equals the manifest bbox, tiles read through root and leaf',
      () async {
        final f = File('${tmp.path}/$code.pmtiles')
          ..writeAsBytesSync(_pack(_regions[code]!));
        final r = await PmtilesReader.open(f);
        final b = _regions[code]!;
        expect(
          [r.header.minLon, r.header.minLat, r.header.maxLon, r.header.maxLat],
          [for (final v in b) closeTo(v, 1e-6)],
        );
        expect(r.header.maxZoom, 14);
        expect(await r.tile(0, 0, 0), [1, 2, 3]);
        expect(await r.tile(1, 0, 0), [4, 4]);
        expect(await r.tile(1, 1, 1), [9, 9, 9, 9]);
        expect(await r.tile(1, 0, 1), isNull);
        await r.close();
      },
    );
  }

  test('manifest with CMH, DAY and CVG parses; each pack covers its own city and not the others\' centres', () {
    final m = PackManifest.parse(
      jsonEncode({
        'attribution': '(c) OpenStreetMap contributors',
        'packs': [_entry('CMH'), _entry('DAY'), _entry('CVG')],
        'style_version': 4,
      }),
      Uri.parse('https://tiles.meshsonar.com/manifest.json'),
    );
    final by = {for (final p in m.packs) p.code: p};
    expect(by.keys.toSet(), {'CMH', 'DAY', 'CVG'});
    expect(by['DAY']!.covers(39.7589, -84.1916), isTrue); // Dayton
    expect(by['CVG']!.covers(39.1031, -84.5120), isTrue); // Cincinnati
    expect(by['CMH']!.covers(39.9612, -82.9988), isTrue); // Columbus
    expect(by['DAY']!.covers(39.1031, -84.5120), isFalse);
    expect(by['CVG']!.covers(39.7589, -84.1916), isFalse);
    expect(by['CMH']!.covers(39.7589, -84.1916), isFalse);
  });
}
