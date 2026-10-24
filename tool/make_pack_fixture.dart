// Builds test/fixtures/cmh_mini.pmtiles: a tiny, valid PMTiles v3 file holding three REAL tiles copied byte-for-byte
// (after gunzip + gzip) from the hosted CMH pack, so tests without the 53 MB pack still exercise real planetiler MVT.
//
//   dart run tool/make_pack_fixture.dart /path/to/CMH-v261024.pmtiles test/fixtures/cmh_mini.pmtiles
//
// Tiles: 0/0/0, 6/17/24 and 10/275/387 (Columbus). Header bbox/zooms copied from the source. Root directory only,
// gzip internal and tile compression, clustered. The test checks the gunzipped tiles hash to the same values the
// independent Python reader produced for the full pack (tool/pmtiles_reference.py).
import 'dart:io';
import 'dart:typed_data';

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

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/make_pack_fixture.dart <source.pmtiles> <out.pmtiles>');
    exit(2);
  }
  final r = await PmtilesReader.open(File(args[0]));
  final want = [(0, 0, 0), (6, 17, 24), (10, 275, 387)];
  final entries = <(int, List<int>)>[];
  for (final (z, x, y) in want) {
    final t = await r.tile(z, x, y);
    if (t == null) throw StateError('source lacks $z/$x/$y');
    // GZipCodec with a fixed level and no timestamp-dependent header field keeps the output reproducible.
    entries.add((pmtilesTileId(z, x, y), GZipCodec(level: 9).encode(t)));
  }
  entries.sort((a, b) => a.$1.compareTo(b.$1));
  final dir = <int>[..._varint(entries.length)];
  var last = 0;
  for (final e in entries) {
    dir.addAll(_varint(e.$1 - last));
    last = e.$1;
  }
  for (var i = 0; i < entries.length; i++) {
    dir.addAll(_varint(1));
  }
  for (final e in entries) {
    dir.addAll(_varint(e.$2.length));
  }
  for (var i = 0; i < entries.length; i++) {
    dir.addAll(_varint(i == 0 ? 1 : 0)); // first offset explicit (0 + 1), the rest contiguous
  }
  final root = GZipCodec(level: 9).encode(dir);
  final data = [for (final e in entries) ...e.$2];
  final src = r.header;
  await r.close();
  const hdr = 127;
  final h = ByteData(hdr);
  for (var i = 0; i < 7; i++) {
    h.setUint8(i, 'PMTiles'.codeUnitAt(i));
  }
  h.setUint8(7, 3);
  void u64(int o, int v) => h.setUint64(o, v, Endian.little);
  u64(8, hdr);
  u64(16, root.length);
  u64(24, hdr + root.length); // metadata: none (length 0)
  u64(32, 0);
  u64(40, hdr + root.length); // leaf dirs: none
  u64(48, 0);
  u64(56, hdr + root.length);
  u64(64, data.length);
  u64(72, entries.length);
  u64(80, entries.length);
  u64(88, entries.length);
  h.setUint8(96, 1);
  h.setUint8(97, PmtilesHeader.gzip);
  h.setUint8(98, PmtilesHeader.gzip);
  h.setUint8(99, PmtilesHeader.typeMvt);
  h.setUint8(100, 0);
  h.setUint8(101, 10);
  h.setInt32(102, (src.minLon * 1e7).round(), Endian.little);
  h.setInt32(106, (src.minLat * 1e7).round(), Endian.little);
  h.setInt32(110, (src.maxLon * 1e7).round(), Endian.little);
  h.setInt32(114, (src.maxLat * 1e7).round(), Endian.little);
  final out = File(args[1]);
  await out.writeAsBytes([...h.buffer.asUint8List(), ...root, ...data]);
  stdout.writeln('${out.path}: ${await out.length()} bytes, ${entries.length} tiles');
}
