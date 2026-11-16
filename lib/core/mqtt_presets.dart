// The MQTT broker presets for Settings > Observer (observer-everywhere-mqtt-plan-2026-11-15.md sections 3.3, 6 and D10):
//   * a bundled copy ships with the app (assets/mqtt/mqtt-presets.json = meshcore-insights src/data/mqtt-presets.json), so
//     the picker works on a first launch with no network;
//   * the last good server copy (`GET /api/cmh/mqtt-presets`, ETag) is kept in one file and wins over the bundled one;
//   * [MqttPresetStore.refreshIfStale] asks the server again when the copy is older than [MqttPresetStore.maxAge] (or on
//     demand) and never throws: offline, a 404 (endpoint not deployed), a server error or an unreadable answer all keep
//     the copy the app has, and say so in [MqttPresetRefresh].
// Every preset ships OFF: a preset only says the broker exists. [MqttPresetCatalog.search] backs the picker's search.
// Pure Dart: no Flutter imports (the app hands in the asset reader and the cache file).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api.dart' show CmatException;
import 'mqtt_contract.dart';

/// Where the presets in use came from.
enum MqttPresetOrigin { bundled, saved, server }

/// What the last refresh came to.
enum MqttPresetRefresh {
  /// The server sent a new list (now in use and saved).
  fresh,

  /// The server said the copy the app holds is current.
  notModified,

  /// No connection to the server: the copy the app has stays.
  offline,

  /// The server does not serve presets (404/501) or answered with an error or an unreadable list: the copy stays.
  failed,
}

/// The picker's sections, from the preset file's `group` field.
enum MqttPresetGroup {
  main('main', 'Popular'),
  usRegional('us-regional', 'US regional'),
  more('more', 'Outside the US');

  final String wire;
  final String label;
  const MqttPresetGroup(this.wire, this.label);
  static MqttPresetGroup parse(Object? v) => values.firstWhere((g) => g.wire == v, orElse: () => MqttPresetGroup.more);
}

/// The presets in use with their groups, where they came from and when the server last confirmed them.
class MqttPresetCatalog {
  final MqttPresetList list;
  final Map<String, MqttPresetGroup> _groups;
  final MqttPresetOrigin origin;
  final String? etag;

  /// When the server last confirmed this copy (200 or 304); null for the bundled copy.
  final DateTime? confirmedAt;

  MqttPresetCatalog(this.list, Map<String, MqttPresetGroup> groups, this.origin, {this.etag, this.confirmedAt})
      : _groups = Map.unmodifiable(groups);

  List<MqttPreset> get presets => list.presets;

  MqttPreset? byId(String? id) {
    if (id == null) return null;
    for (final p in list.presets) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The picker section of [p]: the file's own group, else the bundled copy's for the same id, else [MqttPresetGroup.more].
  MqttPresetGroup groupOf(MqttPreset p) => _groups[p.id] ?? MqttPresetGroup.more;

  /// Presets whose name, host or region contain every word of [query] (any case), in file order; all of them for an
  /// empty query.
  List<MqttPreset> search(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return presets;
    return [
      for (final p in presets)
        if (words.every((w) => '${p.name} ${p.host} ${p.region ?? ''} ${groupOf(p).label}'.toLowerCase().contains(w)))
          p,
    ];
  }

  MqttPresetCatalog _with({MqttPresetOrigin? origin, String? etag, DateTime? confirmedAt}) =>
      MqttPresetCatalog(list, _groups, origin ?? this.origin, etag: etag ?? this.etag, confirmedAt: confirmedAt ?? this.confirmedAt);

  /// The preset file shape (`{v, asOf, presets: [...]}`), groups included, as saved in the cache file.
  Map<String, dynamic> toFileJson() => {
        'v': list.version,
        if (list.asOf != null) 'asOf': list.asOf!.toIso8601String().substring(0, 10),
        'presets': [for (final p in presets) presetToJson(p, groupOf(p))],
      };

  /// Parses a preset file (bundled or server). Throws [FormatException] when it is not one; single presets that do not
  /// parse are skipped (MqttPresetList.parse).
  static MqttPresetCatalog parseFile(String body, MqttPresetOrigin origin,
      {String? etag, DateTime? confirmedAt, Map<String, MqttPresetGroup> fallbackGroups = const {}}) {
    final j = jsonDecode(body);
    if (j is! Map<String, dynamic>) throw const FormatException('mqtt-presets: not an object');
    final list = MqttPresetList.parse(j);
    return MqttPresetCatalog(list, {...fallbackGroups, ...groupsOf(j)}, origin, etag: etag, confirmedAt: confirmedAt);
  }

  /// `id -> group` from a preset file's raw JSON (presets without a known group are left out).
  static Map<String, MqttPresetGroup> groupsOf(Map<String, dynamic> j) {
    final out = <String, MqttPresetGroup>{};
    final list = j['presets'];
    if (list is! List) return out;
    for (final p in list) {
      if (p is Map && p['id'] is String && p['group'] is String) out[p['id'] as String] = MqttPresetGroup.parse(p['group']);
    }
    return out;
  }
}

/// One preset in the preset file's own keys (the inverse of MqttPreset.tryParse).
Map<String, dynamic> presetToJson(MqttPreset p, MqttPresetGroup group) => {
      'id': p.id,
      'name': p.name,
      'host': p.host,
      'port': p.port,
      'path': p.wsPath,
      'auth': p.auth.wire,
      if (p.aud != null) 'aud': p.aud,
      'group': group.wire,
      if (p.region != null) 'region': p.region,
      if (p.needsRealIata) 'needsRealIata': true,
      'verified': p.verified,
      if (p.verifiedNote != null) 'verifiedNote': p.verifiedNote,
    };

/// The bundled copy + the last good server copy + refresh-when-stale.
class MqttPresetStore {
  /// Reads the bundled preset file (rootBundle in the app, a file or a string in tests).
  final Future<String> Function() loadBundled;

  /// Where the last good server copy is kept; null = memory only.
  final File? cacheFile;

  /// The conditional GET (`CmatClient.mqttPresets`), looked up on every refresh so a changed server URL is followed.
  final Future<MqttPresetFetch> Function({String? ifNoneMatch}) Function() fetcher;
  final Duration maxAge;
  final DateTime Function() clock;

  MqttPresetStore({
    required this.loadBundled,
    required this.fetcher,
    this.cacheFile,
    this.maxAge = const Duration(hours: 6),
    DateTime Function()? clock,
  }) : clock = clock ?? (() => DateTime.now().toUtc());

  MqttPresetCatalog? _current;
  MqttPresetCatalog? _bundled;
  Future<MqttPresetRefresh>? _inflight;

  /// The last refresh's result; null before the first one.
  MqttPresetRefresh? lastRefresh;

  Future<MqttPresetCatalog> _bundledCopy() async =>
      _bundled ??= MqttPresetCatalog.parseFile(await loadBundled(), MqttPresetOrigin.bundled);

  /// The best copy without the network: the one in memory, else the saved server copy, else the bundled one. A damaged
  /// saved file is ignored; throws only when the bundled copy itself is broken (a build error the asset test catches).
  Future<MqttPresetCatalog> current() async {
    final c = _current;
    if (c != null) return c;
    final bundled = await _bundledCopy();
    final f = cacheFile;
    if (f != null) {
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final body = j['body'];
        final saved = MqttPresetCatalog.parseFile(
          jsonEncode(body),
          MqttPresetOrigin.saved,
          etag: j['etag'] as String?,
          confirmedAt: DateTime.tryParse(j['confirmed_at'] as String? ?? '')?.toUtc(),
          fallbackGroups: _groupsOfBundled(bundled),
        );
        if (saved.presets.isNotEmpty) return _current = saved;
      } catch (_) {
        // No saved copy yet, or a damaged one: the bundled copy is used.
      }
    }
    return _current = bundled;
  }

  static Map<String, MqttPresetGroup> _groupsOfBundled(MqttPresetCatalog b) => {for (final p in b.presets) p.id: b.groupOf(p)};

  /// True when the copy in use is the bundled one or the server confirmed it longer than [maxAge] ago.
  Future<bool> isStale() async {
    final c = await current();
    final at = c.confirmedAt;
    final now = clock();
    return at == null || now.difference(at) >= maxAge || now.isBefore(at);
  }

  /// Asks the server when the copy is stale (or [force]); one request at a time. Never throws.
  Future<MqttPresetRefresh?> refreshIfStale({bool force = false}) async {
    if (!force && !await isStale()) return null;
    return _inflight ??= _refresh().whenComplete(() => _inflight = null);
  }

  Future<MqttPresetRefresh> _refresh() async {
    final have = await current();
    final MqttPresetFetch got;
    try {
      got = await fetcher()(ifNoneMatch: have.origin == MqttPresetOrigin.bundled ? null : have.etag);
    } on SocketException {
      return lastRefresh = MqttPresetRefresh.offline;
    } on TimeoutException {
      return lastRefresh = MqttPresetRefresh.offline;
    } on CmatException catch (e) {
      // cmat_client.dart: no HTTP status = the request never got an answer (no network, timeout, TLS failure).
      return lastRefresh = e.status == null ? MqttPresetRefresh.offline : MqttPresetRefresh.failed;
    } catch (_) {
      return lastRefresh = MqttPresetRefresh.failed;
    }
    final now = clock();
    if (got.notModified) {
      if (have.origin == MqttPresetOrigin.bundled) return lastRefresh = MqttPresetRefresh.failed;
      _current = have._with(origin: MqttPresetOrigin.server, etag: got.etag, confirmedAt: now);
      await _save(_current!);
      return lastRefresh = MqttPresetRefresh.notModified;
    }
    final list = got.list!;
    if (list.presets.isEmpty) return lastRefresh = MqttPresetRefresh.failed; // an empty list never replaces a good one
    final bundled = await _bundledCopy();
    // The parsed list carries no groups: keep the ones the copy in use (or the bundled copy) knows for the same ids.
    final groups = {..._groupsOfBundled(bundled), for (final p in have.presets) p.id: have.groupOf(p)};
    _current = MqttPresetCatalog(list, groups, MqttPresetOrigin.server, etag: got.etag, confirmedAt: now);
    await _save(_current!);
    return lastRefresh = MqttPresetRefresh.fresh;
  }

  Future<void> _save(MqttPresetCatalog c) async {
    final f = cacheFile;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'etag': c.etag,
        'confirmed_at': c.confirmedAt?.toIso8601String(),
        'body': c.toFileJson(),
      }));
      await tmp.rename(f.path);
    } catch (_) {
      // A full or read-only disk only costs the saved copy; the one in memory is still used.
    }
  }
}
