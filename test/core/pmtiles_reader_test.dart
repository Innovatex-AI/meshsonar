import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/pmtiles_reader.dart';

List<int> varint(int v) {
  final o = <int>[];
  while (v >= 0x80) {
    o.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  o.add(v);
  return o;
}

/// entries: (tileId, offset, length, runLength). Offsets always explicit (+1).
Uint8List dir(List<(int, int, int, int)> es) {
  final o = <int>[...varint(es.length)];
  var last = 0;
  for (final e in es) {
    o.addAll(varint(e.$1 - last));
    last = e.$1;
  }
  for (final e in es) {
    o.addAll(varint(e.$4));
  }
  for (final e in es) {
    o.addAll(varint(e.$3));
  }
  for (final e in es) {
    o.addAll(varint(e.$2 + 1));
  }
  return Uint8List.fromList(gzip.encode(o));
}

/// A tiny gzip-everything PMTiles v3 file: tile 0/0/0 in the root dir, tile 1/1/1 behind a leaf directory.
Uint8List buildPack({int version = 3}) {
  final t0 = Uint8List.fromList(gzip.encode([1, 2, 3]));
  final t1 = Uint8List.fromList(gzip.encode([9, 9]));
  final leaf = dir([(pmtilesTileId(1, 1, 1), t0.length, t1.length, 1)]);
  final root = dir([(0, 0, t0.length, 1), (pmtilesTileId(1, 0, 0), 0, leaf.length, 0)]);
  const hdr = 127;
  final rootOff = hdr, leafOff = rootOff + root.length, dataOff = leafOff + leaf.length;
  final h = ByteData(hdr);
  for (var i = 0; i < 7; i++) {
    h.setUint8(i, 'PMTiles'.codeUnitAt(i));
  }
  h.setUint8(7, version);
  void u64(int o, int v) => h.setUint64(o, v, Endian.little);
  u64(8, rootOff);
  u64(16, root.length);
  u64(40, leafOff);
  u64(48, leaf.length);
  u64(56, dataOff);
  u64(64, t0.length + t1.length);
  h.setUint8(97, 2);
  h.setUint8(98, 2);
  h.setUint8(99, 1);
  h.setUint8(100, 0);
  h.setUint8(101, 1);
  h.setInt32(102, -836534334, Endian.little);
  h.setInt32(106, 393612879, Endian.little);
  h.setInt32(110, -820241925, Endian.little);
  h.setInt32(114, 407127035, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...root, ...leaf, ...t0, ...t1]);
}

void main() {
  test('Hilbert tile ids match the spec', () {
    expect(pmtilesTileId(0, 0, 0), 0);
    expect(pmtilesTileId(1, 0, 0), 1);
    expect(pmtilesTileId(1, 0, 1), 2);
    expect(pmtilesTileId(1, 1, 1), 3);
    expect(pmtilesTileId(1, 1, 0), 4);
    expect(pmtilesTileId(2, 0, 0), 5);
    expect(() => pmtilesTileId(1, 2, 0), throwsA(isA<PmtilesException>()));
  });

  group('reader', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('pmt'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('reads root-directory and leaf-directory tiles, null for absent ones', () async {
      final f = File('${tmp.path}/a.pmtiles')..writeAsBytesSync(buildPack());
      final r = await PmtilesReader.open(f);
      expect(r.header.maxZoom, 1);
      expect(r.header.covers(39.96, -83.0), isTrue);
      expect(r.header.covers(0, 0), isFalse);
      expect(await r.tile(0, 0, 0), [1, 2, 3]);
      expect(await r.tile(1, 1, 1), [9, 9]);
      expect(await r.tile(1, 1, 0), isNull);
      expect(await r.tile(5, 0, 0), isNull); // outside the pack's zoom range
      await r.close();
    });

    test('rejects non-PMTiles and wrong versions', () async {
      final bad = File('${tmp.path}/b.pmtiles')..writeAsBytesSync(Uint8List(200));
      expect(PmtilesReader.open(bad), throwsA(isA<PmtilesException>()));
      final v2 = File('${tmp.path}/c.pmtiles')..writeAsBytesSync(buildPack(version: 2));
      expect(PmtilesReader.open(v2), throwsA(isA<PmtilesException>()));
    });
  });
}
