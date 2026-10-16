// Public MeshCore node directory (map.meshcore.io) as a second source of repeater names and positions, used after
// CMAT's own list. Pure Dart (no Flutter).
//
// Endpoint (verified 2026-10-16): GET https://map.meshcore.io/api/v1/nodes — no query parameters are honoured (no
// bbox, type or limit filter), so the whole registry comes back: a JSON array of ~66k nodes, ~17 MB gzipped /
// ~52 MB decoded. Each node: {public_key (64 hex), type (1 chat, 2 repeater, 3 room server, 4 sensor), adv_name,
// adv_lat, adv_lon, last_advert (ISO, "1970-01-01…" when never heard), params{freq,bw,sf,cr}, link, source, …}.
// Same fields CMAT reads (meshcore-insights src/lib/link-evidence.ts filterMeshcoreMap; repeaters are type 2).
//
// Because of that size this class is careful:
//  - the body is streamed and split into one small JSON object at a time (never a 52 MB decode), and only repeaters
//    with a position within [radiusKm] of a centre are kept (≈350 around Columbus);
//  - the result is cached to a small JSON file and refetched at most once per [ttl] (24 h), or when the centre moves
//    more than half the radius, or on a forced (manual) refresh;
//  - a failed attempt backs off for [retryAfter] so an offline phone doesn't retry on every ping;
//  - every error is caught: offline, timeouts, bad JSON or a huge body only mean "no extra names".
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'heard.dart' show haversineM;
import 'model.dart';

/// What the directory cache holds: the repeaters near [centerLat]/[centerLon] at [fetchedAt].
class DirectorySnapshot {
  final DateTime fetchedAt; // UTC
  final double centerLat;
  final double centerLon;
  final double radiusKm;

  /// Nodes in the whole registry when fetched (for "350 of 66,674").
  final int totalNodes;
  final List<RepeaterRef> repeaters;
  final String source;
  const DirectorySnapshot({
    required this.fetchedAt,
    required this.centerLat,
    required this.centerLon,
    required this.radiusKm,
    required this.totalNodes,
    required this.repeaters,
    required this.source,
  });

  Map<String, dynamic> toJson() => {
        'v': 1,
        'source': source,
        'fetched_at': fetchedAt.toUtc().toIso8601String(),
        'center': {'lat': centerLat, 'lon': centerLon},
        'radius_km': radiusKm,
        'total_nodes': totalNodes,
        'repeaters': repeaters.map((r) => r.toJson()).toList(),
      };

  factory DirectorySnapshot.fromJson(Map<String, dynamic> j) {
    final c = (j['center'] as Map).cast<String, dynamic>();
    return DirectorySnapshot(
      fetchedAt: DateTime.parse(j['fetched_at'] as String).toUtc(),
      centerLat: (c['lat'] as num).toDouble(),
      centerLon: (c['lon'] as num).toDouble(),
      radiusKm: (j['radius_km'] as num?)?.toDouble() ?? 150,
      totalNodes: (j['total_nodes'] as num?)?.toInt() ?? 0,
      source: j['source'] as String? ?? '',
      repeaters: ((j['repeaters'] as List?) ?? const [])
          .map((e) => RepeaterRef.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }
}

class RepeaterDirectory {
  static final Uri defaultUrl = Uri.parse('https://map.meshcore.io/api/v1/nodes');

  /// map.meshcore.io node type for a repeater.
  static const int repeaterType = 2;

  final File cacheFile;
  final Uri url;
  final http.Client? client;
  final DateTime Function() clock;
  final double radiusKm;
  final Duration ttl;

  /// No response headers, or no bytes for this long = give up.
  final Duration timeout;

  /// Hard cap on one whole download (slow links).
  final Duration totalTimeout;

  /// Decoded body larger than this = give up (the registry is ~52 MB today).
  final int maxBytes;

  /// Keep at most this many repeaters (nearest first).
  final int maxRepeaters;

  /// Skip repeaters whose last advert is older than this (registry entries linger for years). Never-heard dates are kept.
  final Duration maxAdvertAge;

  /// After a failed fetch, wait this long before trying again (unless forced).
  final Duration retryAfter;

  RepeaterDirectory({
    required this.cacheFile,
    Uri? url,
    this.client,
    DateTime Function()? clock,
    this.radiusKm = 150,
    this.ttl = const Duration(hours: 24),
    this.timeout = const Duration(seconds: 20),
    this.totalTimeout = const Duration(seconds: 120),
    this.maxBytes = 120 * 1024 * 1024,
    this.maxRepeaters = 3000,
    this.maxAdvertAge = const Duration(days: 180),
    this.retryAfter = const Duration(minutes: 30),
  })  : url = url ?? defaultUrl,
        clock = clock ?? DateTime.now;

  DirectorySnapshot? _snapshot;
  DirectorySnapshot? get snapshot => _snapshot;

  /// Plain-language reason the last refresh failed (null after a success).
  String? lastError;
  DateTime? _lastFailure;
  Future<DirectorySnapshot?>? _inFlight;

  /// Reads the cache file. Never throws; null when there is no usable cache.
  Future<DirectorySnapshot?> load() async {
    try {
      if (!await cacheFile.exists()) return _snapshot;
      final raw = jsonDecode(await cacheFile.readAsString());
      if (raw is! Map) return _snapshot;
      _snapshot = DirectorySnapshot.fromJson(raw.cast<String, dynamic>());
    } catch (_) {
      // A damaged cache only costs names.
    }
    return _snapshot;
  }

  /// True when [s] is missing, older than [ttl], or centred more than half the radius away from [lat]/[lon].
  bool isStale(DirectorySnapshot? s, {double? lat, double? lon}) {
    if (s == null) return true;
    if (clock().toUtc().difference(s.fetchedAt) >= ttl) return true;
    if (lat != null && lon != null && haversineM(lat, lon, s.centerLat, s.centerLon) > radiusKm * 1000 / 2) return true;
    return false;
  }

  /// Fetches the directory around [lat]/[lon] when the cache is stale (or [force]), saves it, and returns the newest
  /// snapshot available (the old cache on failure). Never throws. Concurrent calls share one download.
  Future<DirectorySnapshot?> refresh({required double lat, required double lon, bool force = false}) {
    final cur = _snapshot;
    if (!force && !isStale(cur, lat: lat, lon: lon)) return Future.value(cur);
    final lf = _lastFailure;
    if (!force && lf != null && clock().difference(lf) < retryAfter) return Future.value(cur);
    return _inFlight ??= _fetch(lat, lon).whenComplete(() => _inFlight = null);
  }

  Future<DirectorySnapshot?> _fetch(double lat, double lon) async {
    final c = client ?? http.Client();
    try {
      final snap = await _download(c, lat, lon).timeout(totalTimeout);
      _snapshot = snap;
      lastError = null;
      _lastFailure = null;
      await _save(snap);
      return snap;
    } catch (e) {
      lastError = _describe(e);
      _lastFailure = clock();
      return _snapshot;
    } finally {
      if (client == null) c.close();
    }
  }

  Future<DirectorySnapshot> _download(http.Client client, double lat, double lon) async {
    final req = http.Request('GET', url)
      ..headers['Accept'] = 'application/json'
      ..headers['User-Agent'] = 'MeshSonar (open-source MeshCore wardriving app)';
    final res = await client.send(req).timeout(timeout);
    if (res.statusCode != 200) {
      unawaited(res.stream.drain<void>().catchError((_) {}));
      throw HttpException('HTTP ${res.statusCode}');
    }
    if ((res.contentLength ?? 0) > maxBytes) throw const FormatException('directory too large');
    final now = clock().toUtc();
    final keep = <String, (RepeaterRef, double)>{};
    var total = 0;
    var bytes = 0;
    final splitter = JsonArraySplitter((obj) {
      total++;
      final hit = nodeToRepeater(obj, lat: lat, lon: lon, radiusKm: radiusKm, now: now, maxAdvertAge: maxAdvertAge);
      if (hit != null) keep[hit.$1.key] = hit;
    });
    await for (final chunk in res.stream.timeout(timeout)) {
      bytes += chunk.length;
      if (bytes > maxBytes) throw const FormatException('directory too large');
      splitter.add(chunk);
    }
    if (!splitter.sawArray) throw const FormatException('expected a JSON array of nodes');
    final list = keep.values.toList()..sort((a, b) => a.$2.compareTo(b.$2));
    return DirectorySnapshot(
      fetchedAt: now,
      centerLat: lat,
      centerLon: lon,
      radiusKm: radiusKm,
      totalNodes: total,
      repeaters: [for (final r in list.take(maxRepeaters)) r.$1],
      source: url.toString(),
    );
  }

  Future<void> _save(DirectorySnapshot s) async {
    try {
      await cacheFile.parent.create(recursive: true);
      final tmp = File('${cacheFile.path}.tmp');
      await tmp.writeAsString(jsonEncode(s.toJson()), flush: true);
      await tmp.rename(cacheFile.path);
    } catch (_) {
      // Keep the in-memory copy; the next launch just refetches.
    }
  }

  static String _describe(Object e) {
    if (e is TimeoutException) return 'The node map didn\'t answer in time.';
    if (e is SocketException || e is http.ClientException) return 'No connection to the node map.';
    if (e is HttpException) return 'The node map answered ${e.message}.';
    if (e is FormatException) return 'The node map sent something unexpected (${e.message}).';
    return 'Couldn\'t read the node map.';
  }

  /// One registry node → a repeater within [radiusKm] of [lat]/[lon] (with its distance in m), else null.
  static (RepeaterRef, double)? nodeToRepeater(
    Map<String, dynamic> n, {
    required double lat,
    required double lon,
    required double radiusKm,
    DateTime? now,
    Duration? maxAdvertAge,
  }) {
    if (n['type'] != repeaterType) return null;
    final key = n['public_key'];
    final la = n['adv_lat'], lo = n['adv_lon'];
    if (key is! String || la is! num || lo is! num) return null;
    final k = key.toLowerCase();
    if (k.length < 8 || !_hex.hasMatch(k)) return null;
    final rlat = la.toDouble(), rlon = lo.toDouble();
    if (rlat == 0 && rlon == 0) return null; // "no position" placeholder
    if (rlat.abs() > 90 || rlon.abs() > 180) return null;
    if (now != null && maxAdvertAge != null) {
      final la = DateTime.tryParse(n['last_advert'] as String? ?? '');
      if (la != null && la.year > 1970 && now.difference(la) > maxAdvertAge) return null;
    }
    final d = haversineM(lat, lon, rlat, rlon);
    if (d > radiusKm * 1000) return null;
    var name = (n['adv_name'] is String ? n['adv_name'] as String : '').trim();
    if (name.length > 64) name = name.substring(0, 64);
    return (RepeaterRef(key: k, name: name, lat: rlat, lon: rlon), d);
  }

  static final RegExp _hex = RegExp(r'^[0-9a-f]+$');

  /// Filters an already-decoded node list (tests and small payloads). Nearest first.
  static List<RepeaterRef> parseNodes(
    Object? decoded, {
    required double lat,
    required double lon,
    double radiusKm = 150,
    DateTime? now,
    Duration? maxAdvertAge,
  }) {
    final rows = decoded is List ? decoded : (decoded is Map && decoded['nodes'] is List ? decoded['nodes'] as List : null);
    if (rows == null) throw const FormatException('expected a JSON array of nodes');
    final keep = <String, (RepeaterRef, double)>{};
    for (final r in rows) {
      if (r is! Map) continue;
      final hit = nodeToRepeater(r.cast<String, dynamic>(),
          lat: lat, lon: lon, radiusKm: radiusKm, now: now, maxAdvertAge: maxAdvertAge);
      if (hit != null) keep[hit.$1.key] = hit;
    }
    final list = keep.values.toList()..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final r in list) r.$1];
  }
}

/// Splits a streamed JSON array of objects (`[{…},{…}]`, or `{"nodes":[…]}`) into one decoded object at a time, so a
/// huge body never has to be held or decoded whole. Works on raw UTF-8 bytes (JSON structural characters are ASCII).
class JsonArraySplitter {
  final void Function(Map<String, dynamic> obj) onObject;
  JsonArraySplitter(this.onObject);

  final List<int> _stack = []; // '[' or '{' per open container
  bool _inString = false;
  bool _escape = false;
  bool sawArray = false;
  BytesBuilder? _buf; // bytes of the element object being collected
  int _objDepth = -1; // stack depth at which the collected object opened

  void add(List<int> chunk) {
    var start = -1; // where the collected object starts within this chunk
    if (_buf != null) start = 0;
    for (var i = 0; i < chunk.length; i++) {
      final c = chunk[i];
      if (_inString) {
        if (_escape) {
          _escape = false;
        } else if (c == 0x5C) {
          _escape = true;
        } else if (c == 0x22) {
          _inString = false;
        }
        continue;
      }
      switch (c) {
        case 0x22: // "
          _inString = true;
        case 0x5B: // [
          _stack.add(c);
          if (_stack.length <= 2) sawArray = true;
        case 0x7B: // {
          // An element of the top-level array (or of a top-level object's array): start collecting.
          if (_buf == null && _stack.isNotEmpty && _stack.last == 0x5B && _stack.length <= 2) {
            _buf = BytesBuilder(); // copies, so chunk buffers are never retained
            _objDepth = _stack.length;
            start = i;
          }
          _stack.add(c);
        case 0x5D: // ]
        case 0x7D: // }
          if (_stack.isNotEmpty) _stack.removeLast();
          if (c == 0x7D && _buf != null && _stack.length == _objDepth) {
            _buf!.add(_slice(chunk, start, i + 1));
            _emit(_buf!.takeBytes());
            _buf = null;
            _objDepth = -1;
            start = -1;
          }
      }
    }
    if (_buf != null && start >= 0) {
      _buf!.add(_slice(chunk, start, chunk.length));
    }
  }

  static List<int> _slice(List<int> chunk, int from, int to) =>
      chunk is Uint8List ? Uint8List.sublistView(chunk, from, to) : chunk.sublist(from, to);

  void _emit(Uint8List bytes) {
    try {
      final v = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (v is Map) onObject(v.cast<String, dynamic>());
    } catch (_) {
      // One bad node is skipped, not the whole directory.
    }
  }
}
