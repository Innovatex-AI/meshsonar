// Minimal read-only PMTiles v3 reader (protomaps spec v3).
// Pure Dart (dart:io only). Own implementation because the pub `pmtiles` package pins latlong2 ^0.9 (we use ^0.10).
import 'dart:io';
import 'dart:typed_data';

class PmtilesException implements Exception {
  final String message;
  PmtilesException(this.message);
  @override
  String toString() => 'PmtilesException: $message';
}

/// Hilbert-curve tile id of z/x/y, the key PMTiles directories are sorted by.
int pmtilesTileId(int z, int x, int y) {
  if (z > 26) throw PmtilesException('zoom $z too high');
  var acc = 0;
  for (var i = 0; i < z; i++) {
    acc += (1 << i) * (1 << i);
  }
  final n = 1 << z;
  if (x < 0 || y < 0 || x >= n || y >= n) {
    throw PmtilesException('tile $z/$x/$y out of range');
  }
  var d = 0;
  var tx = x, ty = y;
  for (var s = n ~/ 2; s > 0; s ~/= 2) {
    final rx = (tx & s) > 0 ? 1 : 0;
    final ry = (ty & s) > 0 ? 1 : 0;
    d += s * s * ((3 * rx) ^ ry);
    if (ry == 0) {
      if (rx == 1) {
        tx = s - 1 - tx;
        ty = s - 1 - ty;
      }
      final t = tx;
      tx = ty;
      ty = t;
    }
  }
  return acc + d;
}

class PmtilesHeader {
  final int rootOffset, rootLength, leafOffset, leafLength, dataOffset, dataLength;
  final int internalCompression, tileCompression, tileType, minZoom, maxZoom;
  final double minLon, minLat, maxLon, maxLat;
  const PmtilesHeader({
    required this.rootOffset,
    required this.rootLength,
    required this.leafOffset,
    required this.leafLength,
    required this.dataOffset,
    required this.dataLength,
    required this.internalCompression,
    required this.tileCompression,
    required this.tileType,
    required this.minZoom,
    required this.maxZoom,
    required this.minLon,
    required this.minLat,
    required this.maxLon,
    required this.maxLat,
  });

  /// Compression codes: 1 none, 2 gzip. Anything else (brotli, zstd) is unsupported here.
  static const none = 1, gzip = 2;
  static const typeMvt = 1;

  factory PmtilesHeader.parse(Uint8List b) {
    if (b.length < 127) throw PmtilesException('header too short');
    final magic = String.fromCharCodes(b.sublist(0, 7));
    if (magic != 'PMTiles') throw PmtilesException('not a PMTiles file');
    if (b[7] != 3) {
      throw PmtilesException('unsupported PMTiles version ${b[7]}');
    }
    final d = ByteData.sublistView(b);
    int u64(int o) => d.getUint64(o, Endian.little);
    double e7(int o) => d.getInt32(o, Endian.little) / 1e7;
    return PmtilesHeader(
      rootOffset: u64(8),
      rootLength: u64(16),
      leafOffset: u64(40),
      leafLength: u64(48),
      dataOffset: u64(56),
      dataLength: u64(64),
      internalCompression: b[97],
      tileCompression: b[98],
      tileType: b[99],
      minZoom: b[100],
      maxZoom: b[101],
      minLon: e7(102),
      minLat: e7(106),
      maxLon: e7(110),
      maxLat: e7(114),
    );
  }

  bool covers(double lat, double lon) => lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon;
}

class _Entry {
  final int tileId, offset, length, runLength;
  _Entry(this.tileId, this.offset, this.length, this.runLength);
}

class PmtilesReader {
  final RandomAccessFile _file;
  final PmtilesHeader header;
  final Map<int, List<_Entry>> _dirCache = {};
  PmtilesReader._(this._file, this.header);

  static Future<PmtilesReader> open(File f) async {
    final raf = await f.open();
    try {
      final head = await raf.read(127);
      return PmtilesReader._(raf, PmtilesHeader.parse(head));
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  Future<void> close() => _file.close().then((_) {});

  Future<Uint8List> _read(int offset, int length) async {
    await _file.setPosition(offset);
    final b = await _file.read(length);
    if (b.length != length) {
      throw PmtilesException('truncated file (wanted $length at $offset, got ${b.length})');
    }
    return b;
  }

  Uint8List _decompress(Uint8List b, int compression) {
    if (compression == PmtilesHeader.none) return b;
    if (compression == PmtilesHeader.gzip) {
      return Uint8List.fromList(gzip.decode(b));
    }
    throw PmtilesException('unsupported compression $compression (build packs with gzip)');
  }

  static List<_Entry> _parseDir(Uint8List b) {
    var pos = 0;
    int varint() {
      var result = 0, shift = 0;
      while (true) {
        final byte = b[pos++];
        result |= (byte & 0x7f) << shift;
        if (byte < 0x80) return result;
        shift += 7;
      }
    }

    final n = varint();
    final ids = List<int>.filled(n, 0), runs = List<int>.filled(n, 0), lens = List<int>.filled(n, 0), offs = List<int>.filled(n, 0);
    var last = 0;
    for (var i = 0; i < n; i++) {
      last += varint();
      ids[i] = last;
    }
    for (var i = 0; i < n; i++) {
      runs[i] = varint();
    }
    for (var i = 0; i < n; i++) {
      lens[i] = varint();
    }
    for (var i = 0; i < n; i++) {
      final v = varint();
      offs[i] = (v == 0 && i > 0) ? offs[i - 1] + lens[i - 1] : v - 1;
    }
    return [for (var i = 0; i < n; i++) _Entry(ids[i], offs[i], lens[i], runs[i])];
  }

  Future<List<_Entry>> _dir(int offset, int length) async {
    final cached = _dirCache[offset];
    if (cached != null) return cached;
    final dir = _parseDir(_decompress(await _read(offset, length), header.internalCompression));
    if (_dirCache.length > 64) _dirCache.remove(_dirCache.keys.first);
    return _dirCache[offset] = dir;
  }

  /// The (decompressed) tile bytes, or null when the pack has no such tile.
  Future<Uint8List?> tile(int z, int x, int y) async {
    if (z < header.minZoom || z > header.maxZoom) return null;
    final id = pmtilesTileId(z, x, y);
    var off = header.rootOffset, len = header.rootLength;
    for (var depth = 0; depth < 4; depth++) {
      final dir = await _dir(off, len);
      var lo = 0, hi = dir.length - 1, found = -1;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        if (dir[mid].tileId <= id) {
          found = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      if (found < 0) return null;
      final e = dir[found];
      if (e.runLength > 0) {
        if (id >= e.tileId + e.runLength) return null;
        final raw = await _read(header.dataOffset + e.offset, e.length);
        return _decompress(raw, header.tileCompression);
      }
      off = header.leafOffset + e.offset;
      len = e.length;
    }
    throw PmtilesException('directory depth exceeded');
  }
}
