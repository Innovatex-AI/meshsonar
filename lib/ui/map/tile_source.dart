// Base-map tiles for the live map: network + disk cache + installed offline pack, as one source.
//
// Why a provider of our own (flutter_map's NetworkTileProvider does the happy path fine):
//   * It retried every failed tile three times with no cap on concurrent requests, so with no signal a pan queued dozens of
//     doomed requests, each throwing an error (error spam, "map offline" flicker, wasted work on the UI isolate).
//   * A cached tile that had gone stale was REPLACED by an error when the server could not be reached, so the map went blank
//     over an area the person had just looked at.
//
// Rules here:
//   1. Cache first. A fresh cached tile is shown with no request. A stale one is shown too when the network is down or the
//      refresh fails; it is only refreshed when the network is up.
//   2. Bounded network. At most [TileFetchGate.maxConcurrent] requests at once, newest request first (the tiles on screen now),
//      each cancelled when its tile leaves the screen, each with a timeout. A failed tile is tried again after 1 s, 3 s and
//      10 s ([MeshTileProvider.loadWithRetry]); an empty answer for a failed tile is never kept as the tile (build 72).
//   3. Circuit breaker, for a network that is really gone. [TileFetchGate.failuresToOpen] failures in a row WITH NO ANSWER
//      FROM ANY SERVER (a timeout, no route), and no success in the last few seconds, open the gate: tiles are then served
//      from the cache only, with no requests at all, until one probe gets through. The first probe goes out after
//      [TileFetchGate.firstOpenFor] (3 s), then 6 s, 12 s, [TileFetchGate.openFor] at most; one success closes the breaker.
//      A server that answers with an error (404, 500, 429) is a network that works: it never opens the breaker. A 429 or
//      503 with Retry-After pauses new requests for that long and halves the requests in flight.
//      Build 72: before, any three failures (HTTP errors included) opened it for 15 s, a probe that ended without a result
//      left it shut for good, and a few slow tiles after a pan turned the whole map blank ("slow, don't refresh").
//   4. Tiles an installed offline pack draws are not requested at all ([shouldSkip]).
//   5. Everything is counted in [MapTileStats] for the "Map and GPS health" recorder and the source pill on the map.
//
// Tile servers and licences: docs/MAP_TILES.md.
import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import '../../app/build_flags.dart' show isDevelopmentBuild;

/// What happened to one tile request (for the health recorder and the source indicator).
enum TileOutcome { cacheHit, networkOk, staleServed, notModified, failed, offlineEmpty, cancelled, packCovered }

/// Counters for tile loads. One shared instance feeds the health recorder; tests make their own.
class MapTileStats extends ChangeNotifier {
  static final MapTileStats instance = MapTileStats();

  final Map<TileOutcome, int> _counts = {for (final o in TileOutcome.values) o: 0};
  final Map<TileOutcome, int> _total = {for (final o in TileOutcome.values) o: 0};
  DateTime? _lastNetworkOk;
  DateTime? _lastCacheServe;
  DateTime? _lastFailure;
  int _packHits = 0, _packMisses = 0, _totalPackHits = 0, _totalPackMisses = 0;

  /// Injected clock (tests).
  DateTime Function() clock = DateTime.now;

  /// Why the last tile requests failed ("timeout", "HTTP 503", "ClientException ..."), newest last, 20 at most. For the
  /// health readout and the simulator harness: a failure is never just a count.
  final List<String> failureReasons = [];
  final Map<String, int> failureKinds = {};

  void recordFailureReason(String reason) {
    failureReasons.add(reason);
    if (failureReasons.length > 20) failureReasons.removeAt(0);
    failureKinds[reason] = (failureKinds[reason] ?? 0) + 1;
  }

  void record(TileOutcome o) {
    _counts[o] = _counts[o]! + 1;
    _total[o] = _total[o]! + 1;
    final now = clock();
    switch (o) {
      case TileOutcome.networkOk || TileOutcome.notModified:
        _lastNetworkOk = now;
      case TileOutcome.cacheHit || TileOutcome.staleServed:
        _lastCacheServe = now;
      case TileOutcome.failed || TileOutcome.offlineEmpty:
        _lastFailure = now;
      case TileOutcome.cancelled || TileOutcome.packCovered:
        break;
    }
    notifyListeners();
  }

  /// A vector tile the offline pack served / did not have.
  void recordPack({required bool hit}) {
    if (hit) {
      _packHits++;
      _totalPackHits++;
    } else {
      _packMisses++;
      _totalPackMisses++;
    }
  }

  DateTime? get lastNetworkOk => _lastNetworkOk;
  DateTime? get lastCacheServe => _lastCacheServe;
  DateTime? get lastFailure => _lastFailure;
  int total(TileOutcome o) => _total[o]!;
  int get totalPackHits => _totalPackHits;
  int get totalPackMisses => _totalPackMisses;

  /// The counts since the last call, then starts a new window.
  Map<String, int> takeWindow() {
    final out = <String, int>{
      'cache_hit': _counts[TileOutcome.cacheHit]!,
      'network_ok': _counts[TileOutcome.networkOk]! + _counts[TileOutcome.notModified]!,
      'stale_served': _counts[TileOutcome.staleServed]!,
      'failed': _counts[TileOutcome.failed]!,
      'offline_empty': _counts[TileOutcome.offlineEmpty]!,
      'cancelled': _counts[TileOutcome.cancelled]!,
      'pack_covered_skipped': _counts[TileOutcome.packCovered]!,
      'pack_hit': _packHits,
      'pack_miss': _packMisses,
    };
    for (final o in TileOutcome.values) {
      _counts[o] = 0;
    }
    _packHits = _packMisses = 0;
    return out;
  }

  void resetForTest() {
    for (final o in TileOutcome.values) {
      _counts[o] = 0;
      _total[o] = 0;
    }
    _packHits = _packMisses = _totalPackHits = _totalPackMisses = 0;
    _lastNetworkOk = _lastCacheServe = _lastFailure = null;
    failureReasons.clear();
    failureKinds.clear();
  }
}

/// Which base-map source the person is looking at right now.
enum MapSource { offlinePack, online, cachedOffline, none }

/// The source to show, from what the last seconds of tile traffic did. [packActive]: an offline pack covers the view.
MapSource currentMapSource(MapTileStats s, DateTime now, {required bool packActive, bool gateOpen = false, Duration window = const Duration(seconds: 12)}) {
  if (packActive) return MapSource.offlinePack;
  bool recent(DateTime? t) => t != null && now.difference(t) <= window;
  if (!gateOpen && recent(s.lastNetworkOk) && !(recent(s.lastFailure) && !recent(s.lastNetworkOk))) return MapSource.online;
  if (recent(s.lastCacheServe) || (gateOpen && s.total(TileOutcome.cacheHit) + s.total(TileOutcome.staleServed) > 0)) {
    return gateOpen || recent(s.lastFailure) ? MapSource.cachedOffline : MapSource.online;
  }
  if (gateOpen || recent(s.lastFailure)) return MapSource.none;
  return MapSource.online;
}

/// Concurrency cap + circuit breaker for tile requests.
class TileFetchGate {
  /// Requests in flight at once, and how many may wait behind them. Sized for a phone by default; a map on a bigger screen
  /// asks for more with [ensureRoom]. A request beyond [maxWaiting] is DROPPED (the oldest first) and its tile stays blank
  /// until it leaves and re-enters the view, so the queue must hold at least everything one screen asks for.
  int maxConcurrent;
  final int failuresToOpen;

  /// The longest wait between probes while the breaker is open, and the first one.
  final Duration openFor;
  final Duration firstOpenFor;

  /// Failures do not open the breaker while some server answered this recently (a few slow tiles are not "offline").
  final Duration graceAfterAnswer;
  int maxWaiting;

  /// Tile requests dropped because the queue was full (health readout, tests).
  int dropped = 0;

  /// Makes room for a screen that needs it; never shrinks. [concurrent] is capped at 12.
  void ensureRoom({required int waiting, int? concurrent}) {
    if (waiting > maxWaiting) maxWaiting = waiting;
    if (concurrent != null && concurrent.clamp(1, 12) > maxConcurrent) maxConcurrent = concurrent.clamp(1, 12);
  }
  DateTime Function() clock;
  TileFetchGate({
    this.maxConcurrent = 6,
    this.failuresToOpen = 3,
    this.openFor = const Duration(seconds: 15),
    this.firstOpenFor = const Duration(seconds: 3),
    this.graceAfterAnswer = const Duration(seconds: 5),
    this.maxWaiting = 48,
    DateTime Function()? clock,
  })
    : clock = clock ?? DateTime.now {
    _instances.add(this);
  }

  /// Development builds only (screenshot harness, Settings > Developer later): pretend the phone has no network. Every gate
  /// closes at once and the map falls back to the disk cache / offline pack, exactly as with real connectivity loss. Always false
  /// in a release build, whatever is set. `--dart-define=MS_FORCE_OFFLINE=1` starts it on.
  static final ValueNotifier<bool> debugForceOffline = ValueNotifier<bool>(isDevelopmentBuild && const bool.fromEnvironment('MS_FORCE_OFFLINE'));
  static bool get _forced => isDevelopmentBuild && debugForceOffline.value;

  static final List<TileFetchGate> _instances = [];

  /// True while any gate's breaker is open, and the requests every gate has dropped from a full queue (health readout, the
  /// simulator harness).
  static bool get anyBreakerOpen => _instances.any((g) => g.isOpen);
  static int get droppedTotal => _instances.fold(0, (n, g) => n + g.dropped);

  /// Tile loads in flight on any provider (disk cache read, queue, network), counted for [tilesSettled].
  static int _pendingLoads = 0;

  /// Completes when no tile request is running or queued on any gate (and stays quiet for [quiet]), or after [cap]. Returns how long
  /// it waited, for the log. The screenshot harness awaits this before every `SCREEN` marker (plan 22.2 g).
  static Future<Duration> tilesSettled({Duration cap = const Duration(seconds: 20), Duration quiet = const Duration(milliseconds: 700)}) async {
    final sw = Stopwatch()..start();
    var quietSince = sw.elapsed;
    while (sw.elapsed < cap) {
      final busy = _pendingLoads > 0 || _instances.any((g) => g._running > 0 || g._waiting.isNotEmpty);
      if (busy) {
        quietSince = sw.elapsed;
      } else if (sw.elapsed - quietSince >= quiet) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return sw.elapsed;
  }

  int _running = 0;
  final ListQueue<_Waiter> _waiting = ListQueue(); // newest at the end: served first
  int _failuresInARow = 0;
  DateTime? _openUntil;
  DateTime? _lastAnswer;
  DateTime? _pausedUntil;
  Duration? _nextOpenFor;
  bool _probing = false;
  bool _phoneOffline = false;

  /// Counts every time the network came back after failures (the breaker closed, or a success followed failures). The map
  /// listens and asks again for the tiles that failed.
  final ValueNotifier<int> recoveries = ValueNotifier<int>(0);

  int get running => _running;
  int get waiting => _waiting.length;

  /// True while the breaker is open (no requests are made): the network is gone, by the phone's word or by ours.
  bool get isOpen {
    if (_phoneOffline || _forced) return true;
    final u = _openUntil;
    return u != null && clock().isBefore(u);
  }

  /// True while a server asked us to slow down (429 / 503 with Retry-After). Not "offline".
  bool get paused {
    final p = _pausedUntil;
    return p != null && clock().isBefore(p);
  }

  /// The phone's own view of the network (connectivity). Offline closes the door at once; online opens it and clears the count.
  void setPhoneOnline(bool online) {
    final was = _phoneOffline;
    _phoneOffline = !online;
    if (online) {
      _openUntil = null;
      _nextOpenFor = null;
      _failuresInARow = 0;
      _probing = false;
      if (was) recoveries.value++;
    }
  }

  bool get phoneOffline => _phoneOffline || _forced;

  /// May a request go out now? Open breaker: no, except one probe once the wait has passed. Paused by a server: no.
  bool get mayRequest {
    if (_phoneOffline || _forced) return false;
    if (paused) return false;
    final u = _openUntil;
    if (u == null) return true;
    if (clock().isBefore(u)) return false;
    if (_probing) return false;
    return true;
  }

  /// Waits for a free slot. Null when [cancel] completed first, or the queue was too long and this request was dropped.
  Future<TilePermit?> acquire(Future<void> cancel) {
    if (!mayRequest) return Future.value(null);
    final probe = _openUntil != null;
    if (probe) _probing = true; // half-open: this request is the probe
    if (_running < maxConcurrent) {
      _running++;
      return Future.value(TilePermit._(this, probe: probe));
    }
    final w = _Waiter();
    _waiting.addLast(w);
    while (_waiting.length > maxWaiting) {
      _waiting.removeFirst().completer.complete(null); // the oldest is off screen by now (the queue holds several screens)
      dropped++;
    }
    unawaited(cancel.then((_) {
      if (!w.completer.isCompleted && _waiting.remove(w)) w.completer.complete(null);
    }));
    return w.completer.future;
  }

  void _release(TilePermit p) {
    _running--;
    // A probe that ended with no result (cancelled, its tile left the screen) must not keep the door shut: the next request
    // is the probe. Before build 72 this left the breaker closed to everything until the phone reported a network change.
    if (p.probe && _probing) _probing = false;
    while (_running < maxConcurrent && _waiting.isNotEmpty) {
      final w = _waiting.removeLast();
      if (w.completer.isCompleted) continue;
      if (!mayRequest) {
        w.completer.complete(null);
        continue;
      }
      _running++;
      w.completer.complete(TilePermit._(this));
    }
  }

  /// A server answered with a tile (or "nothing here"): the network works.
  void recordSuccess() {
    final recovered = _failuresInARow > 0 || _openUntil != null;
    _failuresInARow = 0;
    _openUntil = null;
    _nextOpenFor = null;
    _probing = false;
    _lastAnswer = clock();
    if (recovered) recoveries.value++;
  }

  /// A server answered, but not with a tile (404, 500, 429...). The network works, so the breaker never opens for this; a
  /// server that asks us to slow down ([retryAfter], or any 429 / 503) is given the time and fewer requests at once.
  void recordServerError(int status, {Duration? retryAfter}) {
    _failuresInARow = 0;
    _openUntil = null;
    _nextOpenFor = null;
    _probing = false;
    _lastAnswer = clock();
    if (status == 429 || (status == 503 && retryAfter != null)) {
      final wait = retryAfter ?? const Duration(seconds: 2);
      _pausedUntil = clock().add(wait > const Duration(seconds: 30) ? const Duration(seconds: 30) : wait);
      if (maxConcurrent > 4) maxConcurrent = (maxConcurrent ~/ 2) < 4 ? 4 : maxConcurrent ~/ 2;
      slowedDown++;
    }
  }

  /// Times a server told us to slow down (health readout, tests).
  int slowedDown = 0;

  /// No answer from any server (a timeout, no route). Enough of these in a row, with no answer in the last
  /// [graceAfterAnswer], and the network is taken to be gone.
  void recordFailure() {
    _failuresInARow++;
    final wasProbe = _probing;
    _probing = false;
    final last = _lastAnswer;
    final quiet = last == null || clock().difference(last) >= graceAfterAnswer;
    final alreadyShut = _openUntil != null && clock().isBefore(_openUntil!); // the rest of a batch that failed together
    if (!alreadyShut && (wasProbe || (_failuresInARow >= failuresToOpen && quiet))) {
      // First wait short, then longer while the probes keep failing; never longer than [openFor].
      final wait = _nextOpenFor ?? firstOpenFor;
      _openUntil = clock().add(wait);
      final next = wait * 2;
      _nextOpenFor = next > openFor ? openFor : next;
      // Everything waiting is for a network that is not there.
      while (_waiting.isNotEmpty) {
        _waiting.removeLast().completer.complete(null);
      }
    }
  }
}

/// When the map may ask again for the tiles that failed, after the network came back ([TileFetchGate.recoveries]): at once,
/// but not more often than every 5 s, and less and less often (10 s, 20 s, 60 s at most) while recoveries keep coming, so a
/// connection that drops in and out does not make the map reload over and over. A minute of quiet starts over.
class TileReask {
  static const Duration first = Duration(seconds: 5), longest = Duration(seconds: 60);
  DateTime? _last;
  Duration _gap = first;

  /// How long to wait before re-asking, given a recovery at [now] (zero = now). Call [done] when the re-ask ran.
  Duration waitAt(DateTime now) {
    final last = _last;
    if (last == null) return Duration.zero;
    final since = now.difference(last);
    if (since >= longest) {
      _gap = first;
      return Duration.zero;
    }
    return since >= _gap ? Duration.zero : _gap - since;
  }

  void done(DateTime now) {
    final last = _last;
    if (last != null && now.difference(last) < longest) {
      final next = _gap * 2;
      _gap = next > longest ? longest : next;
    }
    _last = now;
  }
}

class _Waiter {
  final Completer<TilePermit?> completer = Completer<TilePermit?>();
}

class TilePermit {
  final TileFetchGate _gate;

  /// This request is the half-open probe of an open breaker.
  final bool probe;
  bool _done = false;
  TilePermit._(this._gate, {this.probe = false});
  void release() {
    if (_done) return;
    _done = true;
    _gate._release(this);
  }
}

/// A read-through disk cache for tiles. flutter_map's built-in cache implements this.
typedef TileCacheLookup = Future<CachedMapTile?> Function(String url);
typedef TileCacheStore = Future<void> Function(String url, CachedMapTileMetadata meta, Uint8List? bytes);

class MeshTileProvider extends TileProvider {
  final http.Client _client;
  final bool _ownsClient;
  final TileFetchGate gate;
  final MapTileStats stats;
  final MapCachingProvider? cache;
  final Duration timeout;

  /// The waits a raster tile image retries with (tests shorten them).
  final List<Duration> imageRetryDelays;

  /// True when an offline pack draws this tile (no request, no cache read).
  final bool Function(int z, int x, int y)? shouldSkip;

  MeshTileProvider({
    super.headers,
    http.Client? client,
    bool? ownsClient,
    TileFetchGate? gate,
    MapTileStats? stats,
    MapCachingProvider? cache,
    this.timeout = const Duration(seconds: 8),
    this.shouldSkip,
    this.imageRetryDelays = retryDelays,
  }) : _client = client ?? http.Client(),
       _ownsClient = ownsClient ?? client == null, // a client handed in is the caller's, unless it says otherwise
       gate = gate ?? TileFetchGate(),
       stats = stats ?? MapTileStats.instance,
       cache = cache ?? BuiltInMapCachingProvider.getOrCreateInstance();

  @override
  bool get supportsCancelLoading => true;

  @override
  ImageProvider getImageWithCancelLoadingSupport(TileCoordinates coordinates, TileLayer options, Future<void> cancelLoading) {
    final skip = shouldSkip?.call(coordinates.z, coordinates.x, coordinates.y) ?? false;
    return MeshTileImage(
      url: getTileUrl(coordinates, options),
      skip: skip,
      provider: this,
      cancel: cancelLoading,
    );
  }

  /// flutter_map calls this whenever ANY TileLayer that draws with this provider goes away (tile_layer.dart, State.dispose).
  /// One provider is shared by every tile layer of a map (the two Satellite imagery layers, the vector basemap, the names), so
  /// a layer leaving must NOT shut it down. Until build 72 it closed the HTTP client here: picking another basemap after
  /// Satellite disposed the imagery layers, the client was closed, and every tile request after that failed with
  /// "Client is already closed" until the app was restarted (three of those opened the breaker and the map went blank).
  /// The owner ends the provider with [close].
  @override
  void dispose() {
    super.dispose();
  }

  bool _closed = false;

  /// Ends the provider for good: closes the HTTP client it made. Called by whoever created it (CoverageMap), once.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  // ---- the load, separate from the ImageProvider so tests call it directly ----

  /// Resolves one tile to image bytes (a transparent PNG when there is nothing to show).
  Future<Uint8List> load(String url, {required bool skip, required Future<void> cancel}) async => (await loadWithOutcome(url, skip: skip, cancel: cancel)).$1;

  /// [load], plus what happened (the vector basemap counts failures for its fallback to OpenFreeMap).
  Future<(Uint8List, TileOutcome)> loadWithOutcome(String url, {required bool skip, required Future<void> cancel}) async {
    TileFetchGate._pendingLoads++;
    var outcome = TileOutcome.failed;
    try {
      final b = await _load(url, skip: skip, cancel: cancel, seen: (o) => outcome = o);
      return (b, outcome);
    } finally {
      TileFetchGate._pendingLoads--;
    }
  }

  /// The waits before a failed tile is asked for again. After the last one the tile is left for the next pan, zoom or
  /// network recovery ([TileFetchGate.recoveries]).
  static const List<Duration> retryDelays = [Duration(seconds: 1), Duration(seconds: 3), Duration(seconds: 10)];

  /// [loadWithOutcome], asked again after each of [delays] while the tile has nothing to show (a failed request, or no
  /// request allowed and nothing cached). Stops at once when [cancel] completes (the tile left the screen).
  Future<(Uint8List, TileOutcome)> loadWithRetry(String url, {required bool skip, required Future<void> cancel, List<Duration> delays = retryDelays}) async {
    var cancelled = false;
    unawaited(cancel.then((_) => cancelled = true));
    var r = await loadWithOutcome(url, skip: skip, cancel: cancel);
    for (final d in delays) {
      if (cancelled || !(r.$2 == TileOutcome.failed || r.$2 == TileOutcome.offlineEmpty)) break;
      await Future.any([Future<void>.delayed(d), cancel]);
      if (cancelled) break;
      r = await loadWithOutcome(url, skip: skip, cancel: cancel);
    }
    return r;
  }

  Future<Uint8List> _load(String url, {required bool skip, required Future<void> cancel, required void Function(TileOutcome) seen}) async {
    void rec(TileOutcome o) {
      stats.record(o);
      seen(o);
    }
    if (skip) {
      rec(TileOutcome.packCovered);
      return TileProvider.transparentImage;
    }
    CachedMapTile? cached;
    final c = cache;
    if (c != null && c.isSupported) {
      try {
        cached = await c.getTile(url);
      } catch (_) {
        cached = null; // corrupt or unreadable: treat as a miss
      }
    }
    final fresh = cached != null && !cached.metadata.isStale;
    if (fresh) {
      rec(TileOutcome.cacheHit);
      return cached.bytes;
    }
    if (!gate.mayRequest) {
      if (cached != null) {
        rec(TileOutcome.staleServed);
        return cached.bytes;
      }
      rec(TileOutcome.offlineEmpty);
      return TileProvider.transparentImage;
    }
    var cancelled = false;
    unawaited(cancel.then((_) => cancelled = true));
    final permit = await gate.acquire(cancel);
    if (permit == null || cancelled) {
      permit?.release();
      if (cancelled) {
        rec(TileOutcome.cancelled);
      } else {
        // dropped from a long queue or the gate closed while waiting
        rec(cached != null ? TileOutcome.staleServed : TileOutcome.offlineEmpty);
      }
      return cached?.bytes ?? TileProvider.transparentImage;
    }
    try {
      final abort = Completer<void>();
      var timedOut = false;
      final timer = Timer(timeout, () {
        timedOut = true;
        if (!abort.isCompleted) abort.complete();
      });
      unawaited(cancel.then((_) {
        if (!abort.isCompleted) abort.complete();
      }));
      try {
        final req = http.AbortableRequest('GET', Uri.parse(url), abortTrigger: abort.future);
        req.headers.addAll(headers);
        final lm = cached?.metadata.lastModified;
        if (lm != null && cached!.metadata.etag == null) req.headers['If-Modified-Since'] = _httpDate(lm);
        final etag = cached?.metadata.etag;
        if (etag != null) req.headers['If-None-Match'] = etag;
        final res = await _client.send(req);
        final bytes = await res.stream.toBytes();
        timer.cancel();
        if (res.statusCode == 304 && cached != null) {
          gate.recordSuccess();
          rec(TileOutcome.notModified);
          _store(url, res.headers, null);
          return cached.bytes;
        }
        if (res.statusCode == 204) {
          // A vector tile server's "nothing here" (our basemap answers 204 for an empty tile): an empty tile, not a failure.
          gate.recordSuccess();
          rec(TileOutcome.networkOk);
          _store(url, res.headers, Uint8List(0));
          return Uint8List(0);
        }
        if (res.statusCode == 200 && bytes.isNotEmpty) {
          gate.recordSuccess();
          rec(TileOutcome.networkOk);
          _store(url, res.headers, bytes);
          return bytes;
        }
        if (res.statusCode == 404) {
          // The server has no tile there (outside the extract, beyond its zoom): a final answer, an empty tile, not a failure.
          gate.recordSuccess();
          rec(TileOutcome.networkOk);
          return TileProvider.transparentImage;
        }
        // Any other status: a server that answers is a network that works (never the breaker); the tile itself failed.
        final ra = int.tryParse(res.headers['retry-after'] ?? '');
        gate.recordServerError(res.statusCode, retryAfter: ra == null ? null : Duration(seconds: ra));
        stats.recordFailureReason('HTTP ${res.statusCode}');
        rec(cached != null ? TileOutcome.staleServed : TileOutcome.failed);
        return cached?.bytes ?? TileProvider.transparentImage;
      } on http.RequestAbortedException {
        timer.cancel();
        if (timedOut) {
          gate.recordFailure();
          stats.recordFailureReason('timeout ${timeout.inSeconds}s');
          rec(cached != null ? TileOutcome.staleServed : TileOutcome.failed);
        } else {
          rec(TileOutcome.cancelled);
        }
        return cached?.bytes ?? TileProvider.transparentImage;
      } catch (e) {
        timer.cancel();
        if (cancelled) {
          rec(TileOutcome.cancelled);
        } else {
          gate.recordFailure();
          final text = e.toString();
          stats.recordFailureReason(text.length > 70 ? '${text.substring(0, 70)}…' : text);
          rec(cached != null ? TileOutcome.staleServed : TileOutcome.failed);
        }
        return cached?.bytes ?? TileProvider.transparentImage;
      }
    } finally {
      permit.release();
    }
  }

  void _store(String url, Map<String, String> headers, Uint8List? bytes) {
    final c = cache;
    if (c == null || !c.isSupported) return;
    try {
      final meta = CachedMapTileMetadata.fromHttpHeaders(headers, warnOnFallbackUsage: null);
      unawaited(c.putTile(url: url, metadata: meta, bytes: bytes).catchError((Object _) {}));
    } catch (_) {
      // a server whose headers cannot be cached: show the tile, skip the cache
    }
  }

  static String _httpDate(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final u = d.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${days[u.weekday - 1]}, ${two(u.day)} ${months[u.month - 1]} ${u.year} ${two(u.hour)}:${two(u.minute)}:${two(u.second)} GMT';
  }
}

/// The ImageProvider flutter_map asks for. Equal by url, so the framework's image cache dedupes repeated asks.
@immutable
class MeshTileImage extends ImageProvider<MeshTileImage> {
  final String url;
  final bool skip;
  final MeshTileProvider provider;
  final Future<void> cancel;
  const MeshTileImage({required this.url, required this.skip, required this.provider, required this.cancel});

  @override
  Future<MeshTileImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(MeshTileImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _decode(key, decode),
      scale: 1,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _decode(MeshTileImage key, ImageDecoderCallback decode) async {
    final (bytes, outcome) = await provider.loadWithRetry(key.url, skip: key.skip, cancel: key.cancel, delays: provider.imageRetryDelays);
    // Nothing to show after the retries: an empty tile for now, but never kept as the tile. Forgotten, so the next ask (a
    // pan, a zoom, the network coming back) fetches it.
    if (outcome == TileOutcome.failed || outcome == TileOutcome.offlineEmpty) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    }
    try {
      return await ui.ImmutableBuffer.fromUint8List(bytes).then(decode);
    } catch (_) {
      // undecodable bytes (a captive portal's HTML): empty tile, and forget it so the next ask tries again
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      return ui.ImmutableBuffer.fromUint8List(TileProvider.transparentImage).then(decode);
    }
  }

  @override
  bool operator ==(Object other) => other is MeshTileImage && other.url == url && other.skip == skip;

  @override
  int get hashCode => Object.hash(url, skip);
}
