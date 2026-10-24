import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/pmtiles_reader.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' show VectorTileReader;

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

    test('run-length entries cover exactly their run; zero offsets mean "right after the previous tile"', () async {
      // Root (uncompressed internals) with: tile 0 (run 1), tiles 1..4 (one shared blob, run 4), tile 5 contiguous
      // (offset varint 0 -> previous offset + previous length), then tile 9 (run 1). 6, 7, 8 absent.
      final a = gzip.encode([1]), b = gzip.encode([2, 2]), c = gzip.encode([3, 3, 3]), d = gzip.encode([4]);
      final data = [...a, ...b, ...c, ...d];
      final o = <int>[...varint(4)];
      var last = 0;
      for (final id in [0, 1, 5, 9]) {
        o.addAll(varint(id - last));
        last = id;
      }
      for (final run in [1, 4, 1, 1]) {
        o.addAll(varint(run));
      }
      for (final len in [a.length, b.length, c.length, d.length]) {
        o.addAll(varint(len));
      }
      o.addAll(varint(0 + 1)); // explicit offset 0
      o.addAll(varint(0)); // contiguous
      o.addAll(varint(0)); // contiguous
      o.addAll(varint(a.length + b.length + c.length + 1)); // explicit
      final root = Uint8List.fromList(o);
      const hdr = 127;
      final h = ByteData(hdr);
      for (var i = 0; i < 7; i++) {
        h.setUint8(i, 'PMTiles'.codeUnitAt(i));
      }
      h.setUint8(7, 3);
      h.setUint64(8, hdr, Endian.little);
      h.setUint64(16, root.length, Endian.little);
      h.setUint64(40, hdr + root.length, Endian.little);
      h.setUint64(56, hdr + root.length, Endian.little);
      h.setUint64(64, data.length, Endian.little);
      h.setUint8(97, 1); // internal: none
      h.setUint8(98, 2);
      h.setUint8(99, 1);
      h.setUint8(101, 2);
      final f = File('${tmp.path}/runs.pmtiles')..writeAsBytesSync([...h.buffer.asUint8List(), ...root, ...data]);
      final r = await PmtilesReader.open(f);
      expect(await r.tile(0, 0, 0), [1]);
      for (final (x, y) in [(0, 0), (0, 1), (1, 1), (1, 0)]) {
        expect(await r.tile(1, x, y), [2, 2], reason: '1/$x/$y in the run');
      }
      expect(await r.tile(2, 0, 0), [3, 3, 3]); // id 5, contiguous offset
      for (final id in [6, 7, 8]) {
        final (x, y) = [(1, 0), (1, 1), (0, 1)][id - 6];
        expect(pmtilesTileId(2, x, y), id);
        expect(await r.tile(2, x, y), isNull, reason: 'id $id after the run');
      }
      expect(await r.tile(2, 0, 2), [4]); // id 9
      expect(await r.tile(2, 0, 3), isNull); // id 10: past the last entry's run
      final all = await r.allTileEntries();
      expect([for (final e in all) (e.tileId, e.runLength)], [(0, 1), (1, 4), (5, 1), (9, 1)]);
      expect(all[2].offset, a.length + b.length); // contiguous offset resolved
      await r.close();
    });

    test('concurrent lookups are queued on the one file handle (the old reader threw "async operation pending")', () async {
      final f = File('${tmp.path}/a.pmtiles')..writeAsBytesSync(buildPack());
      final r = await PmtilesReader.open(f);
      final got = await Future.wait([for (var i = 0; i < 40; i++) i.isEven ? r.tile(0, 0, 0) : r.tile(1, 1, 1)]);
      expect(got.where((t) => t != null).length, 40);
      await r.close();
    });

    test('rejects non-PMTiles and wrong versions', () async {
      final bad = File('${tmp.path}/b.pmtiles')..writeAsBytesSync(Uint8List(200));
      expect(PmtilesReader.open(bad), throwsA(isA<PmtilesException>()));
      final v2 = File('${tmp.path}/c.pmtiles')..writeAsBytesSync(buildPack(version: 2));
      expect(PmtilesReader.open(v2), throwsA(isA<PmtilesException>()));
    });
  });

  test('committed fixture (3 real CMH tiles, tool/make_pack_fixture.dart) reads, hashes like the independent reader, parses as MVT', () async {
    final r = await PmtilesReader.open(File('test/fixtures/cmh_mini.pmtiles'));
    expect(r.header.tileType, PmtilesHeader.typeMvt);
    expect(r.header.maxZoom, 10);
    for (final (z, x, y, sha, layer) in [
      (0, 0, 0, '63547489bc5eb4376492a92ac7fe3cb7f118b865c9ac79a7ea574ccec2741e8e', 'water'),
      (6, 17, 24, '70c678741b947de55ad0ba6cc3443e6cf492bbb2fcea31078de3287c064a13c0', 'place'),
      (10, 275, 387, '6361cc61abb4f28b1d25c7be74511868bee9c7c9422ce566f91a619152c8b12b', 'transportation_name'),
    ]) {
      final t = (await r.tile(z, x, y))!;
      expect(sha256.convert(t).toString(), sha, reason: '$z/$x/$y');
      expect(VectorTileReader().read(t).layers.map((l) => l.name), contains(layer));
    }
    expect(await r.tile(10, 275, 388), isNull);
    expect([for (final e in await r.allTileEntries()) e.runLength], [1, 1, 1]);
    await r.close();
  });
}
