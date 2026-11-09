// Coverage v2 (Nov 8 2026 redesign): one fixed cell size (H3 res 11), the MEAN SNR of every ping result in the cell, five
// SNR bands by margin over the LoRa floor plus "No reply" (0) and "Heard, no direct signal" (6), and a Predicted layer.
// Plan: meshsonar-infra docs/planning/coverage-redesign-plan-2026-11-08.md (D1-D13). Server contract (frozen):
// docs/planning/coverage-v2-api-contract.md and meshcore-insights docs/PLATFORM_CONTRACT.md "Coverage v2 API".
//
// This file is pure Dart: the meta answer (legend source), the cell inspector answer, the band rule (the same as SQL
// ms_coverage_band and the website's v2-constants.ts bandOf), MVT tile decoding into flat arrays, and the HTTP reads.
// The app switches to all of this when site-config says `capabilities.coverageV2`; without it the old public-coverage path
// stays (D12).
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:vector_tile/vector_tile.dart' as vt;

/// The capability flag in `site-config.capabilities`.
const String kCoverageV2Capability = 'coverageV2';

/// The one cell resolution (D1).
const int kCoverageV2Res = 11;

/// The preset every map shows today (D13); the meta's `defaultPreset` wins when it says otherwise.
const String kDefaultCoveragePreset = 'sf7bw62.5';

/// Band numbers.
abstract final class CoverageBand {
  static const int noReply = 0;
  static const int edge = 1;
  static const int weak = 2;
  static const int fair = 3;
  static const int good = 4;
  static const int excellent = 5;
  static const int heardNoSnr = 6;

  /// Every band, legend order (strongest first, then the two non-strength states).
  static const List<int> legendOrder = [excellent, good, fair, weak, edge, heardNoSnr, noReply];
}

/// LoRa demodulation floor in dB for a spreading factor (SF7 -7.5, 2.5 dB lower per step), clamped to SF7..SF12.
double snrFloorDb(int sf) => -7.5 - 2.5 * (sf.clamp(7, 12) - 7);

/// The band of a cell (SQL ms_coverage_band, website bandOf): no successful result = 0; successes but no SNR = 6; otherwise by
/// margin over the floor: < 0 Edge, < 5 Weak, < 10 Fair, < 15 Good, else Excellent.
int coverageBandOf({required double? snrMean, required int nOk, required int nSnr, int sf = 7}) {
  if (nOk <= 0) return CoverageBand.noReply;
  if (nSnr <= 0 || snrMean == null || !snrMean.isFinite) return CoverageBand.heardNoSnr;
  final m = snrMean - snrFloorDb(sf);
  return m < 0 ? 1 : (m < 5 ? 2 : (m < 10 ? 3 : (m < 15 ? 4 : 5)));
}

/// The spreading factor in a preset id like `sf7bw62.5` (7 when it cannot be read).
int presetSf(String preset) {
  final m = RegExp(r'^sf(\d{1,2})').firstMatch(preset);
  return m == null ? 7 : (int.tryParse(m.group(1)!) ?? 7).clamp(7, 12);
}

/// One band of the legend.
class CoverageBandInfo {
  final int band;
  final String key;
  final String label;
  const CoverageBandInfo(this.band, this.key, this.label);
}

/// The bands as the server defines them today (used before the first meta answer, and as the fallback offline).
const List<CoverageBandInfo> kDefaultCoverageBands = [
  CoverageBandInfo(0, 'noReply', 'No reply'),
  CoverageBandInfo(1, 'edge', 'Edge'),
  CoverageBandInfo(2, 'weak', 'Weak'),
  CoverageBandInfo(3, 'fair', 'Fair'),
  CoverageBandInfo(4, 'good', 'Good'),
  CoverageBandInfo(5, 'excellent', 'Excellent'),
  CoverageBandInfo(6, 'heardNoSnr', 'Heard, no direct signal'),
];

/// `GET /api/coverage/meta`: what the legend and the tile layers need. The raw answer is kept so the app can cache it as is.
class CoverageMeta {
  final Map<String, dynamic> raw;
  final List<CoverageBandInfo> bands;
  final int faintBelow;
  final int res;
  final int windowDays;
  final int hexFromZoom;
  final int predictedFromZoom;
  final int maxZoom;
  final int version;
  final String defaultPreset;

  /// Band edges in dB per SF key (`sf7` -> [edge|weak, weak|fair, fair|good, good|excellent]).
  final Map<String, List<double>> edgesDb;
  final String? measuredAt, predictedAt;
  const CoverageMeta({
    this.raw = const {},
    this.bands = kDefaultCoverageBands,
    this.faintBelow = 3,
    this.res = kCoverageV2Res,
    this.windowDays = 365,
    this.hexFromZoom = 13,
    this.predictedFromZoom = 8,
    this.maxZoom = 22,
    this.version = 0,
    this.defaultPreset = kDefaultCoveragePreset,
    this.edgesDb = const {
      'sf7': [-7.5, -2.5, 2.5, 7.5],
    },
    this.measuredAt,
    this.predictedAt,
  });

  /// What the app uses before it has ever read the meta (same numbers as the server today).
  static const CoverageMeta fallback = CoverageMeta();

  /// Throws [FormatException] when [j] is not a meta answer.
  factory CoverageMeta.fromJson(Map<String, dynamic> j) {
    final rawBands = j['bands'];
    if (rawBands is! List || rawBands.isEmpty) throw const FormatException('coverage meta without bands');
    final bands = <CoverageBandInfo>[
      for (final b in rawBands)
        if (b is Map && b['band'] is num)
          CoverageBandInfo((b['band'] as num).toInt(), '${b['key'] ?? ''}', '${b['label'] ?? ''}'),
    ];
    if (bands.isEmpty) throw const FormatException('coverage meta bands unreadable');
    final edges = <String, List<double>>{};
    final e = j['edgesDb'];
    if (e is Map) {
      for (final en in e.entries) {
        final v = en.value;
        if (v is List && v.length == 4 && v.every((x) => x is num)) edges['${en.key}'] = [for (final x in v) (x as num).toDouble()];
      }
    }
    int i(Object? v, int d) => v is num ? v.toInt() : d;
    final tiles = j['tiles'] is Map ? j['tiles'] as Map : const {};
    return CoverageMeta(
      raw: j,
      bands: bands,
      faintBelow: i(j['faintBelow'], 3),
      res: i(j['res'], kCoverageV2Res),
      windowDays: i(j['windowDays'], 365),
      hexFromZoom: i(tiles['hexFromZoom'], 13),
      predictedFromZoom: i(tiles['predictedFromZoom'], 8),
      maxZoom: i(tiles['maxZoom'], 22),
      version: i(j['version'], 0),
      defaultPreset: j['defaultPreset'] is String && (j['defaultPreset'] as String).isNotEmpty ? j['defaultPreset'] as String : kDefaultCoveragePreset,
      edgesDb: edges.isEmpty ? const {'sf7': [-7.5, -2.5, 2.5, 7.5]} : edges,
      measuredAt: j['measuredAt'] as String?,
      predictedAt: j['predictedAt'] as String?,
    );
  }

  String toJsonString() => jsonEncode(raw);
  static CoverageMeta? fromJsonString(String s) {
    try {
      final j = jsonDecode(s);
      return j is Map<String, dynamic> ? CoverageMeta.fromJson(j) : null;
    } catch (_) {
      return null;
    }
  }

  /// The label of [band] (the server's words; the default list for an unknown band).
  String labelOf(int band) {
    for (final b in bands) {
      if (b.band == band) return b.label;
    }
    for (final b in kDefaultCoverageBands) {
      if (b.band == band) return b.label;
    }
    return 'Band $band';
  }

  /// The dB edges for [sf] (from the meta; computed from the floor when the meta has no row for it).
  List<double> edgesFor(int sf) {
    final e = edgesDb['sf$sf'];
    if (e != null) return e;
    final f = snrFloorDb(sf);
    return [f, f + 5, f + 10, f + 15];
  }

  /// "above +7.5 dB", "+2.5 to +7.5 dB", ..., "below -7.5 dB" for bands 1-5; null for 0 and 6.
  String? rangeText(int band, {int sf = 7}) {
    final e = edgesFor(sf);
    String db(double v) => '${v > 0 ? '+' : (v < 0 ? '−' : '')}${_trim(v.abs())}';
    return switch (band) {
      5 => 'above ${db(e[3])} dB',
      4 => '${db(e[2])} to ${db(e[3])} dB',
      3 => '${db(e[1])} to ${db(e[2])} dB',
      2 => '${db(e[0])} to ${db(e[1])} dB',
      1 => 'below ${db(e[0])} dB',
      _ => null,
    };
  }
}

String _trim(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// One repeater that served a measured cell (`measured.repeaters[]`). [key] is a prefix of the repeater's public key.
class CoverageCellRepeater {
  final String key;
  final int n;
  final double? snrMean, snrMax;
  const CoverageCellRepeater({required this.key, required this.n, this.snrMean, this.snrMax});
}

class MeasuredCellInfo {
  final int nOk, nFail, nSnr, band;
  final double? snrMean, snrMin, snrMax, snrSd, replyRate, noiseFloor;
  final String? firstAt, lastAt;
  final Map<String, int> sources;
  final List<CoverageCellRepeater> repeaters;
  const MeasuredCellInfo({
    required this.nOk,
    required this.nFail,
    required this.nSnr,
    required this.band,
    this.snrMean,
    this.snrMin,
    this.snrMax,
    this.snrSd,
    this.replyRate,
    this.noiseFloor,
    this.firstAt,
    this.lastAt,
    this.sources = const {},
    this.repeaters = const [],
  });
  int get attempts => nOk + nFail;
}

class PredictedCellInfo {
  final int band;
  final double? snrEst, dNearestM, opacity;
  final int contributors;
  final String? builtAt;
  const PredictedCellInfo({required this.band, this.snrEst, this.dNearestM, this.opacity, this.contributors = 0, this.builtAt});
}

/// `GET /api/coverage/cell/{h3}`: the inspector. At most one of [measured] / [predicted] is set (a measured cell is never
/// predicted); both null = nothing known there.
class CoverageCellInfo {
  final String h3;
  final String preset;
  final MeasuredCellInfo? measured;
  final PredictedCellInfo? predicted;
  final int version;
  const CoverageCellInfo({required this.h3, required this.preset, this.measured, this.predicted, this.version = 0});

  bool get isEmpty => measured == null && predicted == null;

  /// Throws [FormatException] when [j] is not an inspector answer.
  factory CoverageCellInfo.fromJson(Map<String, dynamic> j) {
    final h3 = j['h3'];
    if (h3 is! String) throw const FormatException('coverage cell answer without h3');
    double? d(Object? v) => v is num ? v.toDouble() : null;
    int i(Object? v) => v is num ? v.toInt() : 0;
    MeasuredCellInfo? m;
    final mj = j['measured'];
    if (mj is Map) {
      final src = <String, int>{};
      final s = mj['sources'];
      if (s is Map) {
        for (final e in s.entries) {
          if (e.value is num) src['${e.key}'] = (e.value as num).toInt();
        }
      }
      m = MeasuredCellInfo(
        nOk: i(mj['nOk']),
        nFail: i(mj['nFail']),
        nSnr: i(mj['nSnr']),
        band: i(mj['band']),
        snrMean: d(mj['snrMean']),
        snrMin: d(mj['snrMin']),
        snrMax: d(mj['snrMax']),
        snrSd: d(mj['snrSd']),
        replyRate: d(mj['replyRate']),
        noiseFloor: d(mj['noiseFloor']),
        firstAt: mj['firstAt'] as String?,
        lastAt: mj['lastAt'] as String?,
        sources: src,
        repeaters: [
          if (mj['repeaters'] is List)
            for (final r in mj['repeaters'] as List)
              if (r is Map && r['key'] is String)
                CoverageCellRepeater(key: (r['key'] as String).toLowerCase(), n: i(r['n']), snrMean: d(r['snrMean']), snrMax: d(r['snrMax'])),
        ],
      );
    }
    PredictedCellInfo? p;
    final pj = j['predicted'];
    if (pj is Map) {
      p = PredictedCellInfo(
        band: i(pj['band']),
        snrEst: d(pj['snrEst']),
        dNearestM: d(pj['dNearestM']),
        opacity: d(pj['opacity']),
        contributors: i(pj['contributors']),
        builtAt: pj['builtAt'] as String?,
      );
    }
    return CoverageCellInfo(h3: h3.toLowerCase(), preset: '${j['preset'] ?? kDefaultCoveragePreset}', measured: m, predicted: p, version: i(j['version']));
  }
}

// ---------------------------------------------------------------------------------------------------------- tiles

/// The tile layers (`source-layer` = the layer name). `heard` = passive Heard evidence (phone observer contract section
/// 8.5; shape in meshsonar-infra coverage-v2-api-contract.md "Heard layer"), behind `capabilities.coverageHeard`.
enum CoverageTileLayer { measured, predicted, heard }

/// A decoded coverage tile, flat (cheap to send between isolates): feature f has vertices [starts[f], starts[f+1]) in
/// [latLon] (lat, lon pairs). One vertex = a point (zoom <= 12, D11), more = a hexagon's outer ring (not closed).
class CoverageTileData {
  final Float64List latLon;
  final Int32List starts;
  final Uint8List band;
  final Int32List n;

  /// Predicted only (opacity 0.15-0.6); 0 for measured.
  final Float32List o;

  /// H3 ids (hexagons only, zoom >= 13); empty strings otherwise.
  final List<String> h;
  const CoverageTileData(this.latLon, this.starts, this.band, this.n, this.o, this.h);

  static final CoverageTileData empty = CoverageTileData(Float64List(0), Int32List(1), Uint8List(0), Int32List(0), Float32List(0), const []);

  int get length => band.length;
  int vertexCount(int f) => starts[f + 1] - starts[f];
  bool isPoint(int f) => vertexCount(f) == 1;
}

double tileLon(double x, int z) => x / (1 << z) * 360 - 180;
double tileLat(double y, int z) {
  final n = math.pi * (1 - 2 * y / (1 << z));
  return 180 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
}

/// The tile column/row containing a lon/lat at zoom [z].
(int x, int y) tileOf(double lat, double lon, int z) {
  final n = 1 << z;
  final x = ((lon + 180) / 360 * n).floor().clamp(0, n - 1);
  final s = math.sin(lat.clamp(-85.05112878, 85.05112878) * math.pi / 180);
  final y = ((0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * n).floor().clamp(0, n - 1);
  return (x, y);
}

/// Decodes one MVT tile of [layer] at z/x/y. Unknown layers, broken features and non-polygon/point geometry are skipped.
CoverageTileData decodeCoverageTile(Uint8List bytes, CoverageTileLayer layer, int z, int x, int y) {
  if (bytes.isEmpty) return CoverageTileData.empty;
  final tile = vt.VectorTile.fromBytes(bytes: bytes);
  vt.VectorTileLayer? lyr;
  for (final l in tile.layers) {
    if (l.name == layer.name) lyr = l;
  }
  if (lyr == null) return CoverageTileData.empty;
  final ext = lyr.extent.toDouble();
  final ll = <double>[];
  final starts = <int>[0];
  final band = <int>[], nn = <int>[], oo = <double>[];
  final hh = <String>[];
  for (final f in lyr.features) {
    final props = f.decodeProperties();
    double pd(String k) => _num(props[k]?.value);
    int pi(String k) => pd(k).round();

    void vertex(int px, int py) {
      ll
        ..add(tileLat(y + py / ext, z))
        ..add(tileLon(x + px / ext, z));
    }

    final type = f.type;
    if (type == vt.VectorTileGeomType.POINT) {
      final pts = f.decodePoint();
      if (pts.isEmpty || pts.first.length < 2) continue;
      vertex(pts.first[0], pts.first[1]);
    } else if (type == vt.VectorTileGeomType.POLYGON) {
      final polys = f.decodePolygon();
      if (polys.isEmpty || polys.first.isEmpty) continue;
      final ring = polys.first.first;
      // A closed ring repeats its first vertex at the end: drop it (same convention as HexCell boundaries).
      var count = ring.length;
      if (count > 1 && ring.first[0] == ring.last[0] && ring.first[1] == ring.last[1]) count--;
      if (count < 3) continue;
      for (var k = 0; k < count; k++) {
        vertex(ring[k][0], ring[k][1]);
      }
    } else {
      continue;
    }
    starts.add(ll.length ~/ 2);
    band.add(pi('band').clamp(0, 6));
    nn.add(pi('n'));
    oo.add(pd('o'));
    final hv = props['h']?.value;
    hh.add(hv is String ? hv.toLowerCase() : '');
  }
  return CoverageTileData(
    Float64List.fromList(ll),
    Int32List.fromList(starts),
    Uint8List.fromList(band),
    Int32List.fromList(nn),
    Float32List.fromList(oo),
    List.unmodifiable(hh),
  );
}

/// A property value as a number: protobuf Int64 (int/uint/sint), float, double, or 0.
double _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v == null || v is String || v is bool) return 0;
  return double.tryParse(v.toString()) ?? 0; // fixnum Int64
}

/// The tile ids covering a lon/lat box at [z].
List<(int x, int y)> tilesCovering(double south, double west, double north, double east, int z) {
  final (x0, y0) = tileOf(north, west, z);
  final (x1, y1) = tileOf(south, east, z);
  return [
    for (var tx = x0; tx <= x1; tx++)
      for (var ty = y0; ty <= y1; ty++) (tx, ty),
  ];
}

/// The tile zoom to read for a camera zoom: integer floor, at most 16 (a z16 hexagon is exact at every deeper zoom, so
/// zooming further in reuses those tiles instead of fetching ever smaller ones).
int coverageTileZoom(double zoom) => zoom.isNaN ? 13 : zoom.floor().clamp(0, 16);

// ---------------------------------------------------------------------------------------------------------- reads

class CoverageV2Exception implements Exception {
  final String message;

  /// True when it was the network (no answer at all), not the server refusing.
  final bool network;
  const CoverageV2Exception(this.message, {this.network = false});
  @override
  String toString() => message;
}

/// The coverage v2 reads. Global: every MeshSonar host answers the same, so [origin] is the configured server.
class CoverageV2Client {
  final Uri origin;
  final http.Client _http;
  final Duration timeout;
  CoverageV2Client(this.origin, {http.Client? client, this.timeout = const Duration(seconds: 20)}) : _http = client ?? http.Client();

  Uri _u(String path, [Map<String, String>? q]) {
    var base = origin.path;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return origin.replace(path: '$base/api/coverage/$path', queryParameters: q == null || q.isEmpty ? null : q, fragment: null);
  }

  Future<http.Response> _get(Uri u, {String accept = 'application/json'}) async {
    try {
      return await _http.get(u, headers: {'accept': accept}).timeout(timeout);
    } on TimeoutException {
      throw CoverageV2Exception('timed out talking to ${u.host}', network: true);
    } on http.ClientException catch (e) {
      throw CoverageV2Exception('network error: ${e.message}', network: true);
    } catch (e) {
      // SocketException / HandshakeException (dart:io types are not imported here so this file stays web-safe).
      throw CoverageV2Exception('network error: $e', network: true);
    }
  }

  Map<String, dynamic> _json(http.Response r) {
    if (r.statusCode != 200) throw CoverageV2Exception('server answered ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map<String, dynamic>) throw const CoverageV2Exception('server sent something that is not an object');
    return j;
  }

  Future<CoverageMeta> meta() async => CoverageMeta.fromJson(_json(await _get(_u('meta'))));

  /// The raw meta body (the app caches it as is).
  Future<String> metaBody() async {
    final r = await _get(_u('meta'));
    final j = _json(r);
    CoverageMeta.fromJson(j); // validates
    return jsonEncode(j);
  }

  Future<CoverageCellInfo> cell(String h3, {String? preset}) async =>
      CoverageCellInfo.fromJson(_json(await _get(_u('cell/${h3.trim().toLowerCase()}', {'preset': ?preset}))));

  /// One tile's bytes; null when the server has nothing there (204).
  Future<Uint8List?> tile(CoverageTileLayer layer, int z, int x, int y, {required String preset, int? version}) async {
    final r = await _get(
      _u('tiles/${layer.name}/$z/$x/$y.mvt', {'preset': preset, if (version != null && version > 0) 'v': '$version'}),
      accept: 'application/vnd.mapbox-vector-tile',
    );
    if (r.statusCode == 204) return null;
    if (r.statusCode != 200) throw CoverageV2Exception('server answered ${r.statusCode}');
    return r.bodyBytes;
  }

  void close() => _http.close();
}

/// Decodes on another isolate for big tiles (a z13 predicted tile is ~55 KB gzip and thousands of hexagons).
Future<CoverageTileData> decodeCoverageTileAsync(Uint8List bytes, CoverageTileLayer layer, int z, int x, int y) {
  if (bytes.length < 8 * 1024) return Future.value(decodeCoverageTile(bytes, layer, z, x, y));
  return Isolate.run(() => decodeCoverageTile(bytes, layer, z, x, y));
}

/// Key of one tile in a cache.
String coverageTileKey(CoverageTileLayer layer, String preset, int version, int z, int x, int y) => '${layer.name}|$preset|$version|$z/$x/$y';

/// Fetches and keeps decoded tiles in memory (LRU), one request per tile at a time, at most [maxConcurrent] in flight.
/// [onChange] is called whenever a tile lands. Failures are remembered so the map can say the layer is offline and fall
/// back to the saved JSON cells.
class CoverageTileStore {
  final CoverageV2Client client;
  final int capacity;
  final int maxConcurrent;
  final Future<CoverageTileData> Function(Uint8List bytes, CoverageTileLayer layer, int z, int x, int y) decode;
  CoverageTileStore(this.client, {this.capacity = 400, this.maxConcurrent = 6, this.decode = decodeCoverageTileAsync});

  final Map<String, CoverageTileData> _tiles = {};
  final Map<String, Future<void>> _inflight = {};
  final List<void Function()> _queue = [];
  int _running = 0;
  final Set<void Function()> _listeners = {};

  /// Consecutive network failures (reset by any success).
  int networkFailures = 0;

  /// Tiles fetched and decoded so far (tests, health).
  int fetched = 0;

  /// True when the last few tile reads all failed for want of a network.
  bool get offline => networkFailures >= 3;

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _notify() {
    for (final l in [..._listeners]) {
      l();
    }
  }

  /// The decoded tile when it is in memory (touches it in the LRU); null when not (yet).
  CoverageTileData? peek(String key) {
    final t = _tiles.remove(key);
    if (t != null) _tiles[key] = t;
    return t;
  }

  bool has(String key) => _tiles.containsKey(key);

  /// Puts a decoded tile in memory as if it had been fetched (tests).
  void debugPut(String key, CoverageTileData d) => _put(key, d);

  /// Starts loading the tile unless it is in memory or on its way.
  void want(CoverageTileLayer layer, String preset, int version, int z, int x, int y) {
    final key = coverageTileKey(layer, preset, version, z, x, y);
    if (_tiles.containsKey(key) || _inflight.containsKey(key)) return;
    final c = Completer<void>();
    _inflight[key] = c.future;
    _queue.add(() async {
      try {
        final bytes = await client.tile(layer, z, x, y, preset: preset, version: version);
        final data = bytes == null ? CoverageTileData.empty : await decode(bytes, layer, z, x, y);
        _put(key, data);
        networkFailures = 0;
        fetched++;
      } on CoverageV2Exception catch (e) {
        if (e.network) networkFailures++;
      } catch (_) {
        // a broken tile: draw nothing there rather than fail the layer
        _put(key, CoverageTileData.empty);
      } finally {
        _inflight.remove(key);
        c.complete();
        _running--;
        _pump();
        _notify();
      }
    });
    _pump();
  }

  void _put(String key, CoverageTileData d) {
    _tiles[key] = d;
    while (_tiles.length > capacity) {
      _tiles.remove(_tiles.keys.first);
    }
  }

  void _pump() {
    while (_running < maxConcurrent && _queue.isNotEmpty) {
      _running++;
      final job = _queue.removeLast(); // newest first: the view the person is looking at now
      job();
    }
  }

  /// Forgets every tile (a new data version or preset).
  void clear() => _tiles.clear();

  /// Test seam: completes when nothing is in flight.
  Future<void> idle() async {
    while (_inflight.isNotEmpty) {
      await Future.wait([..._inflight.values]);
    }
  }
}
