// Repeater list sync (Stream 3): the viewed/current region's roster (`GET <region host>/api/cmh/region-repeaters`) and
// the global network layer (`GET <server>/api/cmh/network-repeaters`, lib/core/network_repeaters.dart), kept in a
// small versioned on-disk store that is read at launch before any network call, so names and map pins work offline.
// Pure Dart.
//
// Limits (the server shares a 120 req/min/IP budget, and carrier NAT puts many phones behind one IP):
//  - no background fetch: only app open (launch), resume, a region switch and pull-to-refresh trigger a request;
//  - roster: launch always revalidates (If-None-Match, a cheap 304); resume / region switch at most once per region per
//    [rosterMinGap] (10 min); failures back off (30 s doubling, capped at 30 min); a forced refresh waits [forceFloor];
//  - network list: at most once per [networkMinGap] (6 h, persisted across launches) unless forced; a 404 means the
//    server does not offer it yet ("capability absent"), checked again after the same 6 h; never retried in a loop;
//  - one request per list in flight at a time (concurrent callers share it);
//  - delta refresh (site-config capability `networkRepeatersDelta`): a stored list with a cursor is refreshed with
//    `?updated_since=<cursor>` (changed rows + removed keys, ~0.3 MB instead of ~6.5 MB decoded, ~190 KB instead of
//    ~3.6 MB on the wire, Oct 2026); the full list (with ETag) is the fallback, asked for at most once per sync, on 410,
//    any other refusal, a body that is not a consistent delta, a cursor older than [RepeaterSync.maxCursorAge] (13
//    days; the server's floor is 14), a last full download older than [RepeaterSync.fullRefreshAge] (30 days), no
//    stored list, or the capability off/unknown.
// Requests carry no identifier, no driver key and no position: the region is only in the host name. The one query
// parameter is the delta cursor (whole seconds, the same for everyone who last synced in that minute).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data' show Uint8List;

import 'package:http/http.dart' as http;

import 'etag_client.dart' show newRegionWireClient;
import 'network_repeaters.dart';
import 'region_cache.dart' show asOfLabel;
import 'region_repeaters_api.dart';

/// What started a sync (decides whether the rate limits let it through).
enum SyncTrigger {
  /// The app was opened (first sync of this run).
  launch,

  /// The app came back to the foreground.
  resume,

  /// The viewed or current region changed.
  view,

  /// The person pulled to refresh.
  force,
}

/// Whether the server offers the global network list.
enum NetworkCapability {
  /// Not asked yet (and nothing stored).
  unknown,

  /// The server answered with the list (now or on an earlier run).
  available,

  /// The server answered 404/410: it does not offer the list yet. The app uses its other sources.
  absent,
}

/// One region's stored roster.
class RosterRecord {
  final String slug;
  final String baseUrl;
  final RegionRepeaters data;

  /// The decoded server body, kept as-is so the store can write it back.
  final Object? raw;
  final String? etag;

  /// Last 200 (new content).
  final DateTime fetchedAt;

  /// Last 200 or 304 (confirmed current).
  final DateTime checkedAt;
  const RosterRecord({
    required this.slug,
    required this.baseUrl,
    required this.data,
    required this.raw,
    required this.etag,
    required this.fetchedAt,
    required this.checkedAt,
  });

  RosterRecord checked(DateTime at) =>
      RosterRecord(slug: slug, baseUrl: baseUrl, data: data, raw: raw, etag: etag, fetchedAt: fetchedAt, checkedAt: at);
}

/// The stored network list.
class NetworkRecord {
  final NetworkRepeaters data;

  /// The ETag of the last FULL download; null once a delta changed the list (it no longer matches that body).
  final String? etag;

  /// Last change of the stored rows (full download or delta).
  final DateTime fetchedAt;

  /// Last 200 or 304 (confirmed current).
  final DateTime checkedAt;

  /// The `updated_since` cursor: whole seconds since 1970. After a full download `floor(asOf)`, after a delta its
  /// `asOfS`. Null when the list has no `asOf` (then no delta is asked for).
  final int? cursorS;

  /// When the stored rows last came from a full download (a delta-maintained list is re-downloaded after
  /// [RepeaterSync.fullRefreshAge] as a guard against drift).
  final DateTime fullAt;
  NetworkRecord({
    required this.data,
    required this.etag,
    required this.fetchedAt,
    required this.checkedAt,
    this.cursorS,
    DateTime? fullAt,
  }) : fullAt = fullAt ?? fetchedAt;
  NetworkRecord checked(DateTime at) =>
      NetworkRecord(data: data, etag: etag, fetchedAt: fetchedAt, checkedAt: at, cursorS: cursorS, fullAt: fullAt);
}

/// The on-disk store: one file per roster (`roster_<slug>.json`), one for the network list (`network.json`) and a small
/// meta file (`meta.json`, the network capability and attempt time). Every file carries `"v": 1`; a file with another
/// version, or damaged, is ignored (costs one download). Writes are atomic (temp file + rename).
class RepeaterSyncStore {
  static const int version = 1;
  final Directory dir;

  /// Rosters kept (least recently confirmed dropped first).
  final int maxRosters;

  /// A file larger than this is not written (memory only for this run).
  final int maxFileBytes;
  /// Decode the stored network list (MB-sized: 6.2 MB for the 55.6k-row list of Oct 2026) in a background isolate, so
  /// the launch read never stalls the UI isolate. Tests may turn it off; both paths use [decodeStoredNetwork].
  final bool parseInIsolate;
  RepeaterSyncStore(this.dir, {this.maxRosters = 8, this.maxFileBytes = 24 * 1024 * 1024, this.parseInIsolate = true});

  File _f(String name) => File('${dir.path}${Platform.pathSeparator}$name');
  static String _safe(String slug) => slug.replaceAll(RegExp(r'[^a-z0-9-]'), '_');

  Future<Map<String, dynamic>?> _read(File f) async {
    try {
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['v'] != version) return null;
      return j.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _write(File f, Map<String, dynamic> j) async {
    try {
      final text = jsonEncode({'v': version, ...j});
      if (text.length > maxFileBytes) return false;
      await dir.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(f.path);
      return true;
    } catch (_) {
      return false; // a full or read-only disk only costs the offline copy
    }
  }

  static DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;

  Future<Map<String, RosterRecord>> loadRosters() async {
    final out = <String, RosterRecord>{};
    try {
      if (!await dir.exists()) return out;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!name.startsWith('roster_') || !name.endsWith('.json')) continue;
        final j = await _read(e);
        if (j == null) continue;
        final slug = j['slug'], url = j['baseUrl'], fetched = _time(j['fetchedAt']), checked = _time(j['checkedAt']);
        if (slug is! String || url is! String || fetched == null || checked == null) continue;
        try {
          final data = RegionRepeaters.fromJson(j['body'], regionSlug: slug);
          out[slug] = RosterRecord(
            slug: slug,
            baseUrl: url,
            data: data,
            raw: j['body'],
            etag: j['etag'] as String?,
            fetchedAt: fetched,
            checkedAt: checked,
          );
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  Future<void> saveRoster(RosterRecord r) async {
    await _write(_f('roster_${_safe(r.slug)}.json'), {
      'slug': r.slug,
      'baseUrl': r.baseUrl,
      'etag': r.etag,
      'fetchedAt': r.fetchedAt.toUtc().toIso8601String(),
      'checkedAt': r.checkedAt.toUtc().toIso8601String(),
      'body': r.raw,
    });
    await _evictRosters();
  }

  Future<void> _evictRosters() async {
    try {
      final all = await loadRosters();
      if (all.length <= maxRosters) return;
      final byAge = all.values.toList()..sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
      for (final r in byAge.take(all.length - maxRosters)) {
        final f = _f('roster_${_safe(r.slug)}.json');
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }

  Future<NetworkRecord?> loadNetwork() async {
    try {
      final f = _f('network.json');
      if (!await f.exists()) return null;
      final text = await f.readAsString();
      return parseInIsolate ? await decodeStoredNetworkInIsolate(text) : decodeStoredNetwork(text);
    } catch (_) {
      return null;
    }
  }

  Future<bool> saveNetwork(NetworkRecord r) => _write(_f('network.json'), {
    'etag': r.etag,
    'fetchedAt': r.fetchedAt.toUtc().toIso8601String(),
    'checkedAt': r.checkedAt.toUtc().toIso8601String(),
    'asOf': r.data.asOf?.toUtc().toIso8601String(),
    'cursorS': r.cursorS,
    'fullAt': r.fullAt.toUtc().toIso8601String(),
    'hidden': r.data.hidden,
    'rows': [for (final x in r.data.rows) x.toRow()],
  });

  Future<({NetworkCapability capability, DateTime? lastAttemptAt})> loadMeta() async {
    final j = await _read(_f('meta.json'));
    final cap = switch (j?['network']) {
      'available' => NetworkCapability.available,
      'absent' => NetworkCapability.absent,
      _ => NetworkCapability.unknown,
    };
    return (capability: cap, lastAttemptAt: _time(j?['networkAttemptAt']));
  }

  Future<void> saveMeta(NetworkCapability c, DateTime? attemptAt) =>
      _write(_f('meta.json'), {'network': c.name, 'networkAttemptAt': attemptAt?.toUtc().toIso8601String()});
}

/// Load state of one list, for the map layer and the panels.
enum SyncState {
  /// Nothing stored and nothing asked yet.
  idle,

  /// A request is out and nothing is stored yet.
  loading,

  /// Stored and confirmed by the server on this run (or within the rate-limit window).
  ready,

  /// Stored, but the newest attempt failed (offline/server error): rows are the last good copy.
  stale,

  /// Nothing stored and the newest attempt failed.
  failed,

  /// The server does not offer this list (network-repeaters answered 404/410).
  unsupported,
}

/// One list as the map layer consumes it (stream-1-maps.md 4.3). [rows] gets a new identity on every change.
class RepeaterSet {
  final List<NetworkRepeater> rows;

  /// The server's own "as of" (network list: the newest upstream pull; roster: its status.computedAt).
  final DateTime? asOf;

  /// When this phone last got a 200 or 304 for it.
  final DateTime? fetchedAt;
  final SyncState state;

  /// Credit line to show with the rows (global list only).
  final String? attribution;
  const RepeaterSet({required this.rows, required this.state, this.asOf, this.fetchedAt, this.attribution});
  static const empty = RepeaterSet(rows: [], state: SyncState.idle);
}

/// The roster's positioned rows in the same compact shape as the network list (type 3 for room servers; last advert =
/// the roster's last heard time).
List<NetworkRepeater> rosterAsRows(RegionRepeaters r) => [
  for (final x in r.rows)
    if (x.hasPosition && !(x.lat == 0 && x.lon == 0))
      NetworkRepeater(
        key: x.key,
        name: x.name,
        lat: x.lat!,
        lon: x.lon!,
        type: x.role == 'room' ? 3 : 2,
        lastAdvert: x.lastHeardAt,
      ),
];

bool _never() => false;

class RepeaterSync {
  /// Null = memory only (tests).
  final RepeaterSyncStore? store;

  // Disk writes run one after another, so two answers for the same list never race on one temp file and the roster
  // eviction always sees the previous write.
  Future<void> _writes = Future<void>.value();
  Future<T> _serial<T>(Future<T> Function() write) {
    final r = _writes.then((_) => write());
    _writes = r.then((_) {}, onError: (Object _) {});
    return r;
  }

  /// Completes when every disk write queued so far has finished.
  Future<void> get writesDone => _writes;
  final http.Client Function() rosterClient;
  final http.Client Function() networkClient;
  final DateTime Function() clock;
  final Duration rosterMinGap;
  final Duration networkMinGap;

  /// A pull-to-refresh within this long of the previous request for the same list does nothing (no loops).
  final Duration forceFloor;
  final Duration timeout;
  final Duration networkTimeout;

  /// Decode the (MB-sized) network list on a background isolate so the UI never stalls. Widget tests turn it off.
  final bool parseInIsolate;

  /// Whether the server advertises `GET network-repeaters?updated_since=` (site-config `networkRepeatersDelta`).
  /// AppState points this at its site config; unknown site config = false = the full list with ETag, as before.
  bool Function() deltaCapable;

  /// A stored list whose cursor is older than this is not refreshed by delta (the server answers 410 beyond 14 days:
  /// removals are kept 15 days). 13 days leaves a day of slack.
  final Duration maxCursorAge;

  /// A delta-maintained list is downloaded in full again after this long since its last full download (drift guard).
  final Duration fullRefreshAge;

  /// Decoded bytes of every network-list answer this run and how many requests carried them (delta saving is
  /// visible in the log line and tests).
  int networkBytesIn = 0;
  int networkRequests = 0;

  RepeaterSync({
    this.store,
    http.Client Function()? rosterClient,
    http.Client Function()? networkClient,
    DateTime Function()? clock,
    this.rosterMinGap = const Duration(minutes: 10),
    this.networkMinGap = const Duration(hours: 6),
    this.forceFloor = const Duration(seconds: 10),
    this.timeout = const Duration(seconds: 20),
    this.networkTimeout = const Duration(seconds: 90),
    this.parseInIsolate = true,
    bool Function()? deltaCapable,
    this.maxCursorAge = const Duration(days: 13),
    this.fullRefreshAge = const Duration(days: 30),
  }) : deltaCapable = deltaCapable ?? _never,
       rosterClient = rosterClient ?? newRegionWireClient,
       networkClient = networkClient ?? http.Client.new,
       clock = clock ?? DateTime.now;

  final Map<String, RosterRecord> _rosters = {};
  NetworkRecord? _network;
  NetworkCapability _capability = NetworkCapability.unknown;
  DateTime? _networkAttemptAt;
  int _networkFailures = 0;
  String? _networkError;
  bool _networkLaunchDone = false;

  final Map<String, DateTime> _rosterAttemptAt = {};
  final Map<String, int> _rosterFailures = {};
  final Map<String, String> _rosterError = {};
  final Set<String> _rosterLaunchDone = {};
  final Map<String, Future<bool>> _rosterInFlight = {};
  Future<bool>? _networkInFlight;

  bool _loaded = false;
  Future<void>? _loading;
  bool get loaded => _loaded;

  final List<void Function()> _listeners = [];
  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _changed() {
    for (final l in List.of(_listeners)) {
      try {
        l();
      } catch (_) {}
    }
  }

  /// One line per noteworthy event, for the diagnostics log (never shown as an error to the person).
  void Function(String line)? log;

  /// Reads the stored lists (once). Never throws.
  Future<void> load() => _loading ??= () async {
    final s = store;
    if (s != null) {
      try {
        _rosters.addAll(await s.loadRosters());
        _network = await s.loadNetwork();
        final m = await s.loadMeta();
        _capability = m.capability;
        _networkAttemptAt = m.lastAttemptAt;
        if (_network != null && _capability == NetworkCapability.unknown) _capability = NetworkCapability.available;
      } catch (_) {}
    }
    _loaded = true;
    _changed();
  }();

  // ---------------------------------------------------------------------------------------------------- read side
  Map<String, RosterRecord> get rosters => Map.unmodifiable(_rosters);
  RosterRecord? roster(String slug) => _rosters[slug];
  NetworkRecord? get network => _network;
  NetworkCapability get networkCapability => _capability;

  /// True when the network list can stand in for the 17 MB map.meshcore.io download: the server offers it and a copy
  /// confirmed within [maxAge] is stored.
  bool networkUsable({Duration maxAge = const Duration(days: 14)}) {
    final n = _network;
    return _capability == NetworkCapability.available &&
        n != null &&
        n.data.rows.isNotEmpty &&
        clock().difference(n.checkedAt) <= maxAge;
  }

  /// The last failure for [slug]'s roster since its last success; null when the stored copy is current.
  String? rosterError(String slug) => _rosterError[slug];
  String? get networkError => _networkError;

  /// "Updated 5m ago" / "Offline - as of 2d ago" for [slug]'s stored roster; null when nothing is stored.
  String? rosterLabel(String slug) {
    final r = _rosters[slug];
    if (r == null) return null;
    return asOfLabel(r.checkedAt, clock(), offline: _rosterError.containsKey(slug));
  }

  /// Same for the network list; null when nothing is stored.
  String? get networkLabel {
    final n = _network;
    if (n == null) return null;
    return asOfLabel(n.checkedAt, clock(), offline: _networkError != null);
  }

  // ---------------------------------------------------------------------------------------------------- roster
  Duration _rosterBackoff(int failures) {
    if (failures <= 0) return Duration.zero;
    final s = 30 * (1 << (failures - 1).clamp(0, 10));
    return Duration(seconds: s > 1800 ? 1800 : s);
  }

  /// Whether a roster request for [slug] may go out now for [trigger].
  bool rosterDue(String slug, SyncTrigger trigger) {
    final now = clock();
    final last = _rosterAttemptAt[slug];
    final fails = _rosterFailures[slug] ?? 0;
    switch (trigger) {
      case SyncTrigger.force:
        return last == null || now.difference(last) >= forceFloor;
      case SyncTrigger.launch:
        if (!_rosterLaunchDone.contains(slug)) return true;
        continue gated;
      gated:
      case SyncTrigger.resume:
      case SyncTrigger.view:
        if (last != null) {
          if (now.difference(last) < rosterMinGap) return false;
          if (fails > 0 && now.difference(last) < _rosterBackoff(fails)) return false;
          return true;
        }
        final stored = _rosters[slug];
        return stored == null || now.difference(stored.checkedAt) >= rosterMinGap;
    }
  }

  /// Revalidates [slug]'s roster from [baseUrl] when the limits allow it. True when the stored roster changed or was
  /// confirmed; false when skipped or failed. Never throws.
  Future<bool> syncRoster({required String baseUrl, required String slug, required SyncTrigger trigger}) {
    final inflight = _rosterInFlight[slug];
    if (inflight != null) return inflight;
    if (!rosterDue(slug, trigger)) return Future.value(false);
    final f =
        _fetchRoster(
              baseUrl,
              slug,
            ) // Block body: returning the removed future from whenComplete would make it wait on itself.
            .whenComplete(() {
              _rosterInFlight.remove(slug);
            });
    _rosterInFlight[slug] = f;
    return f;
  }

  Future<bool> _fetchRoster(String baseUrl, String slug) async {
    await load();
    final now = clock();
    _rosterAttemptAt[slug] = now;
    _rosterLaunchDone.add(slug);
    final stored = _rosters[slug];
    final http.Client c;
    try {
      c = rosterClient();
    } catch (e) {
      return _rosterFailed(slug, 'no HTTP client: $e');
    }
    try {
      final uri = regionRepeatersUri(baseUrl, slug);
      final headers = <String, String>{'accept': 'application/json'};
      final sameHost = stored != null && stored.baseUrl == baseUrl;
      if (sameHost && stored.etag != null) headers['if-none-match'] = stored.etag!;
      final res = await c.get(uri, headers: headers).timeout(timeout);
      // The shared ETag client answers from its own disk copy when the network fails; that is not a confirmation.
      if (res.headers['x-meshsonar-cache'] == 'offline') return _rosterFailed(slug, 'offline (served from cache)');
      if (res.statusCode == 304 && sameHost) {
        final r = stored.checked(clock());
        _rosters[slug] = r;
        _rosterOk(slug);
        unawaited(_serial(() => store?.saveRoster(r) ?? Future<void>.value()));
        _changed();
        return true;
      }
      if (res.statusCode != 200) return _rosterFailed(slug, 'HTTP ${res.statusCode}');
      final Object? body;
      try {
        body = jsonDecode(utf8.decode(res.bodyBytes));
      } on FormatException {
        return _rosterFailed(slug, 'invalid JSON');
      }
      final RegionRepeaters data;
      try {
        data = RegionRepeaters.fromJson(body, regionSlug: slug);
      } on RegionRepeatersException catch (e) {
        return _rosterFailed(slug, e.message);
      }
      final at = clock();
      final r = RosterRecord(
        slug: slug,
        baseUrl: baseUrl,
        data: data,
        raw: body,
        etag: res.headers['etag'],
        fetchedAt: at,
        checkedAt: at,
      );
      _rosters[slug] = r;
      _rosterOk(slug);
      unawaited(_serial(() => store?.saveRoster(r) ?? Future<void>.value()));
      log?.call('Region repeaters ($slug): ${data.rows.length} from the server');
      _changed();
      return true;
    } on TimeoutException {
      return _rosterFailed(slug, 'timed out');
    } catch (e) {
      return _rosterFailed(slug, '$e');
    } finally {
      c.close();
    }
  }

  void _rosterOk(String slug) {
    _rosterFailures.remove(slug);
    _rosterError.remove(slug);
  }

  bool _rosterFailed(String slug, String why) {
    _rosterFailures[slug] = (_rosterFailures[slug] ?? 0) + 1;
    _rosterError[slug] = why;
    log?.call('Region repeaters ($slug) not updated: $why');
    _changed();
    return false;
  }

  // ---------------------------------------------------------------------------------------------------- network
  /// The network list's address on [server] (the configured MeshSonar server; never another host).
  static Uri networkUri(Uri server) {
    final base = server.path.endsWith('/') ? server.path.substring(0, server.path.length - 1) : server.path;
    return server.replace(path: '$base/api/cmh/network-repeaters', query: null, fragment: null);
  }

  Duration get _networkWait {
    // With nothing stored, a failure retries sooner (10 min doubling) but never more often than that; otherwise the
    // regular 6 h gate applies to failures too.
    if (_network == null && _networkFailures > 0 && _capability != NetworkCapability.absent) {
      final m = 10 * (1 << (_networkFailures - 1).clamp(0, 6));
      final d = Duration(minutes: m);
      return d < networkMinGap ? d : networkMinGap;
    }
    return networkMinGap;
  }

  bool networkDue(SyncTrigger trigger) {
    final now = clock();
    final last = _networkAttemptAt;
    if (trigger == SyncTrigger.force) return last == null || now.difference(last) >= forceFloor;
    if (last == null) return true;
    return now.difference(last) >= _networkWait;
  }

  /// Fetches the network list from [server] when the limits allow it. True when the stored list changed or was
  /// confirmed. A 404 marks the capability absent (quietly). Never throws.
  Future<bool> syncNetwork({required Uri server, required SyncTrigger trigger}) {
    final inflight = _networkInFlight;
    if (inflight != null) return inflight;
    final f =
        () async {
          await load();
          if (!networkDue(trigger)) return false;
          return _fetchNetwork(server);
        }().whenComplete(() {
          _networkInFlight = null;
        });
    _networkInFlight = f;
    return f;
  }

  /// asOf of the list we held when a delta was last refused and the full list did not move past it: no delta is asked
  /// for again until a different list is held (PLATFORM_CONTRACT client rule: no loop).
  DateTime? _deltaGaveUpAsOf;

  /// Why no delta may be asked for now, or null when one may. An empty string = silently (nothing to log).
  String? _deltaBlocker(NetworkRecord? stored) {
    if (stored == null || stored.cursorS == null || !deltaCapable()) return '';
    final now = clock();
    final cursorAge = now.difference(DateTime.fromMillisecondsSinceEpoch(stored.cursorS! * 1000, isUtc: true));
    if (cursorAge > maxCursorAge) return 'stored list is ${cursorAge.inDays} days behind';
    final fullAge = now.difference(stored.fullAt);
    if (fullAge > fullRefreshAge) return 'last full download was ${fullAge.inDays} days ago';
    final gaveUp = _deltaGaveUpAsOf;
    if (gaveUp != null && stored.data.asOf == gaveUp) return '';
    return null;
  }

  Future<bool> _fetchNetwork(Uri server) async {
    final now = clock();
    _networkAttemptAt = now;
    _networkLaunchDone = true;
    final stored = _network;
    final blocker = _deltaBlocker(stored);
    DateTime? goneAsOf;
    if (blocker == null) {
      final r = await _fetchNetworkDelta(server, stored!);
      if (r != null) return r;
      goneAsOf = stored.data.asOf;
    } else if (blocker.isNotEmpty) {
      log?.call('Network repeater list: full download ($blocker)');
    }
    return _fetchNetworkFull(server, now, goneAsOf: goneAsOf);
  }

  /// `?updated_since=<cursor>` against the stored list. True = applied; false = the attempt failed like any network
  /// failure (offline, 5xx, 429: already recorded, the stored list stays); null = fall back to the full list, once
  /// (410, any other refusal, a body that is not a consistent delta). Never throws.
  Future<bool?> _fetchNetworkDelta(Uri server, NetworkRecord stored) async {
    final http.Client c;
    try {
      c = networkClient();
    } catch (e) {
      return _networkFailed('no HTTP client: $e');
    }
    try {
      final uri = networkUri(server).replace(queryParameters: {'updated_since': '${stored.cursorS}'});
      final res = await c.get(uri, headers: const {'accept': 'application/json'}).timeout(networkTimeout);
      networkRequests++;
      networkBytesIn += res.bodyBytes.length;
      final code = res.statusCode;
      if (code == 429 || code >= 500) return _networkFailed('HTTP $code');
      if (code != 200) {
        log?.call('Network repeater list: delta refused (HTTP $code); downloading the full list');
        return null;
      }
      final NetworkDelta delta;
      final NetworkRepeaters merged;
      try {
        final bytes = res.bodyBytes;
        delta = (parseInIsolate && bytes.length > _deltaIsolateBytes)
            ? await parseNetworkDeltaInIsolate(bytes)
            : NetworkDelta.parse(jsonDecode(utf8.decode(bytes)));
        // The cursor may not move back in time and never into the future (the server would answer 400).
        final nowS = clock().millisecondsSinceEpoch ~/ 1000;
        if (delta.asOfS < stored.cursorS! - 60) throw const NetworkRepeatersFormatException('delta: cursor went backwards');
        if (delta.asOfS > nowS + 300) throw const NetworkRepeatersFormatException('delta: cursor is in the future');
        merged = delta.applyTo(stored.data);
      } on FormatException catch (e) {
        log?.call('Network repeater list: delta unusable (${e.message}); downloading the full list');
        return null;
      } on NetworkRepeatersFormatException catch (e) {
        log?.call('Network repeater list: delta unusable (${e.message}); downloading the full list');
        return null;
      }
      final at = clock();
      final r = NetworkRecord(
        data: merged,
        etag: delta.isEmpty ? stored.etag : null, // a changed list no longer matches the full body's ETag
        fetchedAt: delta.isEmpty ? stored.fetchedAt : at,
        checkedAt: at,
        cursorS: delta.asOfS,
        fullAt: stored.fullAt,
      );
      _network = r;
      _networkOk();
      final saved = await _serial(() => store?.saveNetwork(r) ?? Future<bool>.value(true));
      log?.call(
        'Network repeater list: delta +${delta.rows.length} changed, -${delta.removed.length} removed, '
        '${(res.bodyBytes.length / 1024).round()} KB, now ${merged.rows.length} repeaters'
        '${saved ? '' : ' (not saved: too large or disk full)'}',
      );
      _changed();
      return true;
    } on TimeoutException {
      return _networkFailed('timed out');
    } catch (e) {
      return _networkFailed('$e');
    } finally {
      c.close();
    }
  }

  /// Bodies above this are decoded in the background isolate (the full list always is).
  static const int _deltaIsolateBytes = 64 * 1024;

  Future<bool> _fetchNetworkFull(Uri server, DateTime now, {DateTime? goneAsOf}) async {
    final stored = _network;
    final http.Client c;
    try {
      c = networkClient();
    } catch (e) {
      return _networkFailed('no HTTP client: $e');
    }
    try {
      final headers = <String, String>{'accept': 'application/json'};
      if (stored?.etag != null) headers['if-none-match'] = stored!.etag!;
      final res = await c.get(networkUri(server), headers: headers).timeout(networkTimeout);
      networkRequests++;
      networkBytesIn += res.bodyBytes.length;
      if (res.statusCode == 404 || res.statusCode == 410) {
        final was = _capability;
        _capability = NetworkCapability.absent;
        _networkFailures = 0;
        _networkError = null;
        unawaited(_serial(() => store?.saveMeta(_capability, now) ?? Future<void>.value()));
        if (was != NetworkCapability.absent) {
          log?.call(
            'Network repeater list: not offered by this server (HTTP ${res.statusCode}); using the other sources',
          );
        }
        _changed();
        return false;
      }
      if (res.statusCode == 304 && stored != null) {
        final r = stored.checked(clock());
        _network = r;
        _networkOk();
        _noteGaveUp(goneAsOf, r.data.asOf);
        unawaited(_serial(() => store?.saveNetwork(r) ?? Future<bool>.value(true)));
        _changed();
        return true;
      }
      if (res.statusCode != 200) return _networkFailed('HTTP ${res.statusCode}');
      final NetworkRepeaters data;
      try {
        final bytes = res.bodyBytes;
        data = parseInIsolate
            ? await parseNetworkBodyInIsolate(bytes)
            : NetworkRepeaters.parse(jsonDecode(utf8.decode(bytes)));
      } on FormatException {
        return _networkFailed('invalid JSON');
      } on NetworkRepeatersFormatException catch (e) {
        return _networkFailed(e.message);
      }
      final at = clock();
      final r = NetworkRecord(
        data: data,
        etag: res.headers['etag'],
        fetchedAt: at,
        checkedAt: at,
        cursorS: deltaCursorOf(data),
        fullAt: at,
      );
      _network = r;
      _networkOk();
      _noteGaveUp(goneAsOf, data.asOf);
      final saved = await _serial(() => store?.saveNetwork(r) ?? Future<bool>.value(true));
      log?.call(
        'Network repeater list: ${data.rows.length} repeaters'
        '${data.dropped > 0 ? ', ${data.dropped} malformed rows dropped' : ''}${saved ? '' : ' (not saved: too large or disk full)'}',
      );
      _changed();
      return true;
    } on TimeoutException {
      return _networkFailed('timed out');
    } catch (e) {
      return _networkFailed('$e');
    } finally {
      c.close();
    }
  }

  /// A delta was refused and the full list is the very list we already held: the server's floor is newer than that
  /// list, so a delta from it keeps failing until the collector writes again. Do not ask again until the list moves.
  void _noteGaveUp(DateTime? goneAsOf, DateTime? newAsOf) {
    if (goneAsOf != null && newAsOf == goneAsOf) _deltaGaveUpAsOf = goneAsOf;
  }

  void _networkOk() {
    _capability = NetworkCapability.available;
    _networkFailures = 0;
    _networkError = null;
    unawaited(_serial(() => store?.saveMeta(_capability, _networkAttemptAt) ?? Future<void>.value()));
  }

  bool _networkFailed(String why) {
    _networkFailures++;
    _networkError = why;
    unawaited(_serial(() => store?.saveMeta(_capability, _networkAttemptAt) ?? Future<void>.value()));
    log?.call('Network repeater list not updated: $why');
    _changed();
    return false;
  }

  // ---------------------------------------------------------------------------------------------------- map view
  final Map<String, (RosterRecord, List<NetworkRepeater>)> _rosterRowsMemo = {};
  (NetworkRecord, RepeaterSet)? _globalMemo;

  /// [slug]'s roster as a [RepeaterSet] (positioned rows only).
  RepeaterSet regionSet(String? slug) {
    if (slug == null) return RepeaterSet.empty;
    final r = _rosters[slug];
    final failing = _rosterError.containsKey(slug);
    final busy = _rosterInFlight.containsKey(slug);
    if (r == null) {
      return RepeaterSet(
        rows: const [],
        state: busy ? SyncState.loading : (failing ? SyncState.failed : SyncState.idle),
      );
    }
    final memo = _rosterRowsMemo[slug];
    final rows = (memo != null && identical(memo.$1.data, r.data))
        ? memo.$2
        : List<NetworkRepeater>.unmodifiable(rosterAsRows(r.data));
    _rosterRowsMemo[slug] = (r, rows);
    return RepeaterSet(
      rows: rows,
      state: failing ? SyncState.stale : SyncState.ready,
      asOf: r.data.status.computedAt,
      fetchedAt: r.checkedAt,
    );
  }

  /// The global network list as a [RepeaterSet].
  RepeaterSet get globalSet {
    const credit = 'Data: MeshCore Map (map.meshcore.io)';
    final n = _network;
    if (n == null) {
      final SyncState st = _capability == NetworkCapability.absent
          ? SyncState.unsupported
          : (_networkInFlight != null
                ? SyncState.loading
                : (_networkError != null ? SyncState.failed : SyncState.idle));
      return RepeaterSet(rows: const [], state: st, attribution: credit);
    }
    final memo = _globalMemo;
    if (memo != null &&
        identical(memo.$1, n) &&
        memo.$2.state == (_networkError != null ? SyncState.stale : SyncState.ready)) {
      return memo.$2;
    }
    final set = RepeaterSet(
      rows: memo != null && identical(memo.$1.data, n.data) ? memo.$2.rows : n.data.rows,
      state: _capability == NetworkCapability.absent
          ? SyncState.unsupported
          : (_networkError != null ? SyncState.stale : SyncState.ready),
      asOf: n.data.asOf,
      fetchedAt: n.checkedAt,
      attribution: credit,
    );
    _globalMemo = (n, set);
    return set;
  }

  /// True once this run has asked the server for the network list (or decided it was not due).
  bool get networkLaunchDone => _networkLaunchDone;
}

/// Decodes and parses a network-repeaters body in a background isolate. Top level on purpose: a closure created inside
/// an async instance method captures that method's whole context (its pending Futures included), which Isolate.run
/// cannot send ("object is unsendable - _Future"): every real fetch failed that way. Here the closure holds [bytes] only.
Future<NetworkRepeaters> parseNetworkBodyInIsolate(Uint8List bytes) =>
    Isolate.run(() => NetworkRepeaters.parse(jsonDecode(utf8.decode(bytes))), debugName: 'network-repeaters-parse');

/// Parses a delta body in a background isolate (top level, like [parseNetworkBodyInIsolate]: the closure holds [bytes]
/// only, no service state).
Future<NetworkDelta> parseNetworkDeltaInIsolate(Uint8List bytes) =>
    Isolate.run(() => NetworkDelta.parse(jsonDecode(utf8.decode(bytes))), debugName: 'network-repeaters-delta');

/// The stored `network.json` text as a [NetworkRecord]; null when it is another version, damaged or incomplete.
NetworkRecord? decodeStoredNetwork(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! Map || j['v'] != RepeaterSyncStore.version) return null;
    DateTime? time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
    final fetched = time(j['fetchedAt']), checked = time(j['checkedAt']);
    if (fetched == null || checked == null) return null;
    final data = NetworkRepeaters.parse({'asOf': j['asOf'], 'hidden': j['hidden'], 'rows': j['rows']});
    final etag = j['etag'], cursor = j['cursorS'];
    // Files written before deltas have no cursor: the list's own asOf is the right one (PLATFORM_CONTRACT).
    return NetworkRecord(
      data: data,
      etag: etag is String ? etag : null,
      fetchedAt: fetched,
      checkedAt: checked,
      cursorS: cursor is int && cursor > 0 ? cursor : deltaCursorOf(data),
      fullAt: time(j['fullAt']) ?? fetched,
    );
  } catch (_) {
    return null;
  }
}

/// [decodeStoredNetwork] in a background isolate (top level for the same reason as [parseNetworkBodyInIsolate]).
Future<NetworkRecord?> decodeStoredNetworkInIsolate(String text) =>
    Isolate.run(() => decodeStoredNetwork(text), debugName: 'network-store-load');
