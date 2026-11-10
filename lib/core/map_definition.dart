// The Map Definition cache (plan unified-map-system §2.2 / §8b row M2; contract meshsonar-infra
// docs/planning/map-definition-contract.md). Pure Dart.
//
// `GET /api/map/definition?scope=` describes every map: basemaps, layers in drawing order, palettes, symbols, label rules,
// filters, limits, coverage meta. Both clients will render ONLY from it (that is the M2 phase proper; this file is the
// cache under it):
//   - a bundled copy ships in the app (assets/map/map-definition.json = the M1 fixture), so a first launch with no network
//     still has a definition;
//   - the last good copy per scope is kept on disk with its ETag and when it was confirmed;
//   - it is refreshed when older than [MapDefinitionStore.maxAge] (If-None-Match: a 304 costs no body);
//   - a body that fails to parse (or a higher schema `v` than this app reads) NEVER replaces a good copy: the app keeps
//     the copy it has, and a 404 (endpoint not deployed yet) or a network failure changes nothing.
// No identifier is sent; the scope (region / group slug, or none for the hub) is the only parameter.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// The schema version this app reads. A definition with a higher `v` is refused (contract rule).
const supportedMapDefinitionV = 1;

/// The bundled copy (pubspec assets).
const mapDefinitionAsset = 'assets/map/map-definition.json';

class MapDefinition {
  final Map<String, dynamic> json;
  MapDefinition._(this.json);

  int get v => json['v'] as int;

  /// FNV-1a hash of the body (cache key, ETag).
  String get version => json['version'] as String;
  Map<String, dynamic> get scope => json['scope'] as Map<String, dynamic>;
  String get scopeSlug => scope['slug'] as String? ?? 'hub';
  List<Map<String, dynamic>> get basemaps => (json['basemaps'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get layers => (json['layers'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get palettes => (json['palettes'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic> get coverage => json['coverage'] as Map<String, dynamic>;
  Map<String, dynamic>? basemap(String id) => basemaps.where((b) => b['id'] == id).firstOrNull;
  Map<String, dynamic>? layer(String id) => layers.where((l) => l['id'] == id).firstOrNull;

  /// Throws [FormatException] for anything the contract calls unusable: not JSON, `v` missing or higher than
  /// [supportedMapDefinitionV], no `version`, empty `layers` / `palettes` / `basemaps`, no `coverage` object, or a layer /
  /// palette / basemap without an id.
  factory MapDefinition.parse(String body) {
    final Object? j;
    try {
      j = jsonDecode(body);
    } catch (_) {
      throw const FormatException('map definition: not JSON');
    }
    if (j is! Map<String, dynamic>) throw const FormatException('map definition: not an object');
    final v = j['v'];
    if (v is! int || v < 1) throw const FormatException('map definition: no schema version');
    if (v > supportedMapDefinitionV) throw FormatException('map definition: schema v$v is newer than this app ($supportedMapDefinitionV)');
    if (j['version'] is! String || (j['version'] as String).isEmpty) throw const FormatException('map definition: no version');
    if (j['scope'] is! Map) throw const FormatException('map definition: no scope');
    for (final k in ['layers', 'palettes', 'basemaps']) {
      final list = j[k];
      if (list is! List || list.isEmpty) throw FormatException('map definition: no $k');
      for (final e in list) {
        if (e is! Map || e['id'] is! String) throw FormatException('map definition: a $k entry without an id');
      }
    }
    if (j['coverage'] is! Map) throw const FormatException('map definition: no coverage');
    return MapDefinition._(j);
  }
}

/// Where a definition came from.
enum MapDefinitionOrigin { bundled, saved, server }

class MapDefinitionCopy {
  final MapDefinition definition;
  final MapDefinitionOrigin origin;

  /// When the server last confirmed it (200 or 304); null for the bundled copy.
  final DateTime? confirmedAt;
  final String? etag;
  const MapDefinitionCopy(this.definition, this.origin, {this.confirmedAt, this.etag});
}

/// The bundled copy + last good copy per scope + refresh-when-stale.
class MapDefinitionStore {
  final Directory root;
  final Uri origin;
  final http.Client _client;

  /// Reads the bundled copy (rootBundle in the app, a file in tests).
  final Future<String> Function() loadBundled;
  final Duration maxAge;
  DateTime Function() clock;
  MapDefinitionStore({
    required this.root,
    required this.origin,
    http.Client? client,
    required this.loadBundled,
    this.maxAge = const Duration(hours: 1),
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       clock = clock ?? DateTime.now;

  /// The app's store (set at launch by app/map_definition_wiring.dart); null in tests and before launch finishes.
  static MapDefinitionStore? instance;

  final Map<String, MapDefinitionCopy> _mem = {};
  MapDefinitionCopy? _bundled;
  final Map<String, Future<MapDefinitionCopy>> _inflight = {};
  final _changes = StreamController<String>.broadcast();

  /// The scope key ('' = the server's own scope, the hub on meshsonar.com) whose copy changed.
  Stream<String> get changes => _changes.stream;

  static String _key(String? scope) => (scope ?? '').trim().toLowerCase();
  File _file(String key) => File(p.join(root.path, 'map_definition_${key.isEmpty ? '_host' : key}.json'));

  Uri urlFor(String? scope) {
    var base = origin.path;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final k = _key(scope);
    return origin.replace(path: '$base/api/map/definition', queryParameters: k.isEmpty ? null : {'scope': k}, fragment: null);
  }

  Future<MapDefinitionCopy> _bundledCopy() async =>
      _bundled ??= MapDefinitionCopy(MapDefinition.parse(await loadBundled()), MapDefinitionOrigin.bundled);

  /// The best copy for [scope] without the network: the last good saved one, else the bundled one. Never throws for a
  /// damaged saved file (it is ignored); throws only if the bundled copy itself is broken (a build error a test catches).
  Future<MapDefinitionCopy> current([String? scope]) async {
    final k = _key(scope);
    final m = _mem[k];
    if (m != null) return m;
    try {
      final j = jsonDecode(await _file(k).readAsString()) as Map<String, dynamic>;
      final copy = MapDefinitionCopy(
        MapDefinition.parse(j['body'] as String),
        MapDefinitionOrigin.saved,
        confirmedAt: DateTime.tryParse(j['confirmed_at'] as String? ?? ''),
        etag: j['etag'] as String?,
      );
      return _mem[k] = copy;
    } catch (_) {
      return _bundledCopy();
    }
  }

  /// True when [scope]'s copy is the bundled one or was confirmed longer than [maxAge] ago.
  Future<bool> isStale([String? scope]) async {
    final c = await current(scope);
    final at = c.confirmedAt;
    return at == null || clock().difference(at) >= maxAge || clock().isBefore(at);
  }

  /// Refreshes [scope] when stale (or [force]); returns the copy in use afterwards. Never throws: a 404 (not deployed), a
  /// server error, no network, or a body that does not parse all keep the copy the app has.
  Future<MapDefinitionCopy> refreshIfStale([String? scope, bool force = false]) {
    final k = _key(scope);
    return _inflight[k] ??= _refresh(k, force).whenComplete(() {
      _inflight.remove(k); // a block: returning the removed Future would make whenComplete wait for itself
    });
  }

  Future<MapDefinitionCopy> _refresh(String k, bool force) async {
    final have = await current(k);
    if (!force && !await isStale(k)) return have;
    try {
      final etag = have.origin == MapDefinitionOrigin.bundled ? null : have.etag;
      final r = await _client
          .get(urlFor(k), headers: {'accept': 'application/json', 'if-none-match': ?etag})
          .timeout(const Duration(seconds: 15));
      final now = clock().toUtc();
      if (r.statusCode == 304 && etag != null) {
        final copy = MapDefinitionCopy(have.definition, MapDefinitionOrigin.saved, confirmedAt: now, etag: etag);
        await _save(k, jsonEncode(have.definition.json), etag, now);
        return _mem[k] = copy;
      }
      if (r.statusCode != 200) return have;
      final body = utf8.decode(r.bodyBytes);
      final MapDefinition d;
      try {
        d = MapDefinition.parse(body);
      } on FormatException {
        return have; // never replace a good copy with one that failed to parse
      }
      final newEtag = r.headers['etag'];
      await _save(k, body, newEtag, now);
      final copy = MapDefinitionCopy(d, MapDefinitionOrigin.server, confirmedAt: now, etag: newEtag);
      _mem[k] = copy;
      if (have.definition.version != d.version && !_changes.isClosed) _changes.add(k);
      return copy;
    } catch (_) {
      return have;
    }
  }

  Future<void> _save(String k, String body, String? etag, DateTime at) async {
    try {
      await root.create(recursive: true);
      final f = _file(k);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({'body': body, 'etag': etag, 'confirmed_at': at.toIso8601String()}), flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      // a copy we cannot save only costs a download next launch
    }
  }

  void dispose() => _changes.close();
}
