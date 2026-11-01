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
//      each cancelled when its tile leaves the screen, each with a timeout and NO retry. A failed tile is just empty (the chart
//      grid shows through) and tries again the next time it is asked for.
//   3. Circuit breaker. [TileFetchGate.failuresToOpen] failures in a row open the gate for [TileFetchGate.openFor]: tiles are
//      then served from the cache only, with no requests at all, until the gate lets one probe through (or the phone reports a
//      network change). No error spam, no frame stalls from doomed requests.
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
  final int maxConcurrent;
  final int failuresToOpen;
  final Duration openFor;
  final int maxWaiting;
  DateTime Function() clock;
  TileFetchGate({this.maxConcurrent = 6, this.failuresToOpen = 3, this.openFor = const Duration(seconds: 15), this.maxWaiting = 48, DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  int _running = 0;
  final ListQueue<_Waiter> _waiting = ListQueue(); // newest at the end: served first
  int _failuresInARow = 0;
  DateTime? _openUntil;
  bool _probing = false;
  bool _phoneOffline = false;

  int get running => _running;
  int get waiting => _waiting.length;

  /// True while the breaker is open (no requests are made).
  bool get isOpen {
    if (_phoneOffline) return true;
    final u = _openUntil;
    return u != null && clock().isBefore(u);
  }

  /// The phone's own view of the network (connectivity). Offline closes the door at once; online opens it and clears the count.
  void setPhoneOnline(bool online) {
    _phoneOffline = !online;
    if (online) {
      _openUntil = null;
      _failuresInARow = 0;
      _probing = false;
    }
  }

  bool get phoneOffline => _phoneOffline;

  /// May a request go out now? Open breaker: no, except one probe once [openFor] has passed.
  bool get mayRequest {
    if (_phoneOffline) return false;
    final u = _openUntil;
    if (u == null) return true;
    if (clock().isBefore(u)) return false;
    if (_probing) return false;
    return true;
  }

  /// Waits for a free slot. Null when [cancel] completed first, or the queue was too long and this request was dropped.
  Future<TilePermit?> acquire(Future<void> cancel) {
    if (!mayRequest) return Future.value(null);
    if (_openUntil != null) _probing = true; // half-open: this request is the probe
    if (_running < maxConcurrent) {
      _running++;
      return Future.value(TilePermit._(this));
    }
    final w = _Waiter();
    _waiting.addLast(w);
    while (_waiting.length > maxWaiting) {
      _waiting.removeFirst().completer.complete(null); // the oldest is surely off screen by now
    }
    unawaited(cancel.then((_) {
      if (!w.completer.isCompleted && _waiting.remove(w)) w.completer.complete(null);
    }));
    return w.completer.future;
  }

  void _release() {
    _running--;
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

  void recordSuccess() {
    _failuresInARow = 0;
    _openUntil = null;
    _probing = false;
  }

  void recordFailure() {
    _failuresInARow++;
    _probing = false;
    if (_failuresInARow >= failuresToOpen) {
      _openUntil = clock().add(openFor);
      // Everything waiting is for a network that is not there.
      while (_waiting.isNotEmpty) {
        _waiting.removeLast().completer.complete(null);
      }
    }
  }
}

class _Waiter {
  final Completer<TilePermit?> completer = Completer<TilePermit?>();
}

class TilePermit {
  final TileFetchGate _gate;
  bool _done = false;
  TilePermit._(this._gate);
  void release() {
    if (_done) return;
    _done = true;
    _gate._release();
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

  /// True when an offline pack draws this tile (no request, no cache read).
  final bool Function(int z, int x, int y)? shouldSkip;

  MeshTileProvider({
    super.headers,
    http.Client? client,
    TileFetchGate? gate,
    MapTileStats? stats,
    MapCachingProvider? cache,
    this.timeout = const Duration(seconds: 8),
    this.shouldSkip,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
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

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  // ---- the load, separate from the ImageProvider so tests call it directly ----

  /// Resolves one tile to image bytes (a transparent PNG when there is nothing to show).
  Future<Uint8List> load(String url, {required bool skip, required Future<void> cancel}) async {
    if (skip) {
      stats.record(TileOutcome.packCovered);
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
      stats.record(TileOutcome.cacheHit);
      return cached.bytes;
    }
    if (!gate.mayRequest) {
      if (cached != null) {
        stats.record(TileOutcome.staleServed);
        return cached.bytes;
      }
      stats.record(TileOutcome.offlineEmpty);
      return TileProvider.transparentImage;
    }
    var cancelled = false;
    unawaited(cancel.then((_) => cancelled = true));
    final permit = await gate.acquire(cancel);
    if (permit == null || cancelled) {
      permit?.release();
      if (cancelled) {
        stats.record(TileOutcome.cancelled);
      } else {
        // dropped from a long queue or the gate closed while waiting
        stats.record(cached != null ? TileOutcome.staleServed : TileOutcome.offlineEmpty);
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
          stats.record(TileOutcome.notModified);
          _store(url, res.headers, null);
          return cached.bytes;
        }
        if (res.statusCode == 200 && bytes.isNotEmpty) {
          gate.recordSuccess();
          stats.record(TileOutcome.networkOk);
          _store(url, res.headers, bytes);
          return bytes;
        }
        throw http.ClientException('HTTP ${res.statusCode}', Uri.parse(url));
      } on http.RequestAbortedException {
        timer.cancel();
        if (timedOut) {
          gate.recordFailure();
          stats.record(cached != null ? TileOutcome.staleServed : TileOutcome.failed);
        } else {
          stats.record(TileOutcome.cancelled);
        }
        return cached?.bytes ?? TileProvider.transparentImage;
      } catch (_) {
        timer.cancel();
        if (cancelled) {
          stats.record(TileOutcome.cancelled);
        } else {
          gate.recordFailure();
          stats.record(cached != null ? TileOutcome.staleServed : TileOutcome.failed);
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
    final bytes = await provider.load(key.url, skip: key.skip, cancel: key.cancel);
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
