// Tile source: cache first, stale beats blank, bounded and cancellable requests, a circuit breaker with no error spam, tiles the
// offline pack draws are never requested, and the source the map reports.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/ui/map/tile_source.dart';

class MemCache implements MapCachingProvider {
  final Map<String, CachedMapTile> tiles = {};
  int gets = 0;
  @override
  bool get isSupported => true;
  @override
  Future<CachedMapTile?> getTile(String url) async {
    gets++;
    return tiles[url];
  }

  @override
  Future<void> putTile({required String url, required CachedMapTileMetadata metadata, Uint8List? bytes}) async {
    final old = tiles[url];
    final b = bytes ?? old?.bytes;
    if (b != null) tiles[url] = (bytes: b, metadata: metadata);
  }
}

CachedMapTile tile(List<int> bytes, {required bool stale}) => (
  bytes: Uint8List.fromList(bytes),
  metadata: CachedMapTileMetadata(
    staleAt: DateTime.timestamp().add(Duration(hours: stale ? -1 : 1)),
    lastModified: null,
    etag: null,
  ),
);

/// A client that answers from a script and honours the abort trigger like the real one.
class ScriptClient extends http.BaseClient {
  final List<Uri> sent = [];
  int inFlight = 0, maxInFlight = 0;
  Future<http.StreamedResponse> Function(http.BaseRequest r)? handler;
  Duration delay;
  ScriptClient({this.delay = Duration.zero});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request.url);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      final abort = request is http.Abortable ? request.abortTrigger : null;
      final done = Completer<void>();
      Timer(delay, () {
        if (!done.isCompleted) done.complete();
      });
      var aborted = false;
      unawaited(abort?.then((_) {
        aborted = true;
        if (!done.isCompleted) done.complete();
      }));
      await done.future;
      if (aborted) throw http.RequestAbortedException(request.url);
      final h = handler;
      if (h != null) return await h(request);
      return http.StreamedResponse(Stream.value([1, 2, 3]), 200, headers: {'cache-control': 'max-age=3600', 'date': 'Sun, 01 Nov 2026 12:00:00 GMT'});
    } finally {
      inFlight--;
    }
  }
}

const url = 'https://tile.example/1/2/3.png';
final never = Completer<void>().future;

MeshTileProvider make(ScriptClient c, {MemCache? cache, TileFetchGate? gate, MapTileStats? stats, bool Function(int, int, int)? skip, Duration timeout = const Duration(seconds: 8)}) =>
    MeshTileProvider(client: c, cache: cache ?? MemCache(), gate: gate ?? TileFetchGate(), stats: stats ?? MapTileStats(), shouldSkip: skip, timeout: timeout);

void main() {
  test('a fresh cached tile is shown with no request', () async {
    final cache = MemCache()..tiles[url] = tile([9, 9], stale: false);
    final c = ScriptClient();
    final stats = MapTileStats();
    final b = await make(c, cache: cache, stats: stats).load(url, skip: false, cancel: never);
    expect(b, [9, 9]);
    expect(c.sent, isEmpty);
    expect(stats.total(TileOutcome.cacheHit), 1);
  });

  test('a network tile is shown and written to the cache', () async {
    final cache = MemCache();
    final c = ScriptClient();
    final stats = MapTileStats();
    final b = await make(c, cache: cache, stats: stats).load(url, skip: false, cancel: never);
    expect(b, [1, 2, 3]);
    expect(stats.total(TileOutcome.networkOk), 1);
    await Future<void>.delayed(Duration.zero);
    expect(cache.tiles[url]!.bytes, [1, 2, 3]);
  });

  test('a stale tile is refreshed when the network answers, and a 304 keeps the cached bytes', () async {
    final cache = MemCache()..tiles[url] = tile([7, 7], stale: true);
    final c = ScriptClient()..handler = (r) async => http.StreamedResponse(const Stream.empty(), 304, headers: {'cache-control': 'max-age=60', 'date': 'Sun, 01 Nov 2026 12:00:00 GMT'});
    final stats = MapTileStats();
    final b = await make(c, cache: cache, stats: stats).load(url, skip: false, cancel: never);
    expect(b, [7, 7]);
    expect(stats.total(TileOutcome.notModified), 1);
  });

  test('stale beats blank: a failed refresh shows the stale tile, with no exception', () async {
    final cache = MemCache()..tiles[url] = tile([7, 7], stale: true);
    final c = ScriptClient()..handler = (r) async => throw http.ClientException('no route');
    final stats = MapTileStats();
    final b = await make(c, cache: cache, stats: stats).load(url, skip: false, cancel: never);
    expect(b, [7, 7]);
    expect(stats.total(TileOutcome.staleServed), 1);
  });

  test('no cache and no network: a transparent tile, never an exception, never a retry', () async {
    final c = ScriptClient()..handler = (r) async => throw http.ClientException('no route');
    final stats = MapTileStats();
    final b = await make(c, stats: stats).load(url, skip: false, cancel: never);
    expect(b, TileProvider.transparentImage);
    expect(c.sent, hasLength(1), reason: 'one request, no retries');
    expect(stats.total(TileOutcome.failed), 1);
  });

  test('HTTP errors count as failures and show an empty tile', () async {
    final c = ScriptClient()..handler = (r) async => http.StreamedResponse(Stream.value([0]), 503);
    final b = await make(c).load(url, skip: false, cancel: never);
    expect(b, TileProvider.transparentImage);
  });

  test('three failures in a row open the breaker: later tiles are served from cache only, no requests at all', () async {
    var now = DateTime.utc(2026, 11, 1, 12);
    final gate = TileFetchGate(clock: () => now);
    final cache = MemCache()..tiles['https://tile.example/cached.png'] = tile([5], stale: true);
    final c = ScriptClient()..handler = (r) async => throw http.ClientException('offline');
    final p = make(c, cache: cache, gate: gate);
    for (var i = 0; i < 3; i++) {
      await p.load('https://tile.example/$i.png', skip: false, cancel: never);
    }
    expect(gate.isOpen, isTrue);
    final sentBefore = c.sent.length;
    final stats = p.stats;
    expect(await p.load('https://tile.example/cached.png', skip: false, cancel: never), [5], reason: 'the stale cached tile is shown offline');
    expect(await p.load('https://tile.example/new.png', skip: false, cancel: never), TileProvider.transparentImage);
    expect(c.sent.length, sentBefore, reason: 'no request while the breaker is open');
    expect(stats.total(TileOutcome.offlineEmpty), 1);

    // after the cool-down exactly one probe goes out; a success closes the breaker
    now = now.add(const Duration(seconds: 16));
    c.handler = null;
    final b = await p.load('https://tile.example/new.png', skip: false, cancel: never);
    expect(b, [1, 2, 3]);
    expect(gate.isOpen, isFalse);
  });

  test('the phone going offline closes the gate at once; coming back opens it', () async {
    final gate = TileFetchGate();
    final c = ScriptClient();
    final p = make(c, gate: gate);
    gate.setPhoneOnline(false);
    expect(await p.load(url, skip: false, cancel: never), TileProvider.transparentImage);
    expect(c.sent, isEmpty);
    gate.setPhoneOnline(true);
    expect(await p.load(url, skip: false, cancel: never), [1, 2, 3]);
  });

  test('concurrency is bounded, newest request first, and a cancelled tile never goes out', () async {
    final gate = TileFetchGate(maxConcurrent: 2);
    final c = ScriptClient(delay: const Duration(milliseconds: 30));
    final p = make(c, gate: gate);
    final cancelFirstWaiter = Completer<void>();
    final futures = <Future<Uint8List>>[
      for (var i = 0; i < 6; i++) p.load('https://tile.example/$i.png', skip: false, cancel: i == 3 ? cancelFirstWaiter.future : never),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 5));
    cancelFirstWaiter.complete();
    await Future.wait(futures);
    expect(c.maxInFlight, lessThanOrEqualTo(2));
    expect(c.sent.map((u) => u.path), isNot(contains('/3.png')), reason: 'cancelled while queued: no request');
    // 0 and 1 started at once; of the queued 2..5 the newest (5) went before 2
    final order = c.sent.map((u) => u.path).toList();
    expect(order.indexOf('/5.png'), lessThan(order.indexOf('/2.png')));
    expect(p.stats.total(TileOutcome.cancelled), 1);
  });

  test('an in-flight request is aborted when its tile leaves the screen', () async {
    final c = ScriptClient(delay: const Duration(seconds: 5));
    final cancel = Completer<void>();
    final f = make(c).load(url, skip: false, cancel: cancel.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    cancel.complete();
    expect(await f, TileProvider.transparentImage);
  });

  test('a request that never answers times out, counts as a failure, and does not hang the tile', () async {
    final c = ScriptClient(delay: const Duration(seconds: 30));
    final stats = MapTileStats();
    final b = await make(c, stats: stats, timeout: const Duration(milliseconds: 60)).load(url, skip: false, cancel: never);
    expect(b, TileProvider.transparentImage);
    expect(stats.total(TileOutcome.failed), 1);
  });

  test('a tile the offline pack draws is not requested and not read from the cache', () async {
    final c = ScriptClient();
    final cache = MemCache();
    final stats = MapTileStats();
    final b = await make(c, cache: cache, stats: stats, skip: (z, x, y) => true).load(url, skip: true, cancel: never);
    expect(b, TileProvider.transparentImage);
    expect(c.sent, isEmpty);
    expect(cache.gets, 0);
    expect(stats.total(TileOutcome.packCovered), 1);
  });

  test('stats windows: counts since the last take, pack hits and misses', () {
    final s = MapTileStats();
    s.record(TileOutcome.cacheHit);
    s.record(TileOutcome.cacheHit);
    s.record(TileOutcome.networkOk);
    s.recordPack(hit: true);
    s.recordPack(hit: false);
    final w = s.takeWindow();
    expect(w['cache_hit'], 2);
    expect(w['network_ok'], 1);
    expect(w['pack_hit'], 1);
    expect(w['pack_miss'], 1);
    expect(s.takeWindow()['cache_hit'], 0);
    expect(s.total(TileOutcome.cacheHit), 2, reason: 'totals keep counting');
  });

  group('the source the map shows', () {
    final t0 = DateTime.utc(2026, 11, 1, 12);
    MapTileStats statsAt(DateTime t) => MapTileStats()..clock = () => t;
    test('pack wins; recent network is online; offline with cache is "saved"; offline with nothing is "none"', () {
      final s = statsAt(t0);
      expect(currentMapSource(s, t0, packActive: true), MapSource.offlinePack);
      expect(currentMapSource(s, t0, packActive: false), MapSource.online, reason: 'nothing has happened yet: assume online');
      s.record(TileOutcome.networkOk);
      expect(currentMapSource(s, t0, packActive: false), MapSource.online);
      final off = statsAt(t0)..record(TileOutcome.staleServed);
      expect(currentMapSource(off, t0, packActive: false, gateOpen: true), MapSource.cachedOffline);
      final none = statsAt(t0)..record(TileOutcome.offlineEmpty);
      expect(currentMapSource(none, t0, packActive: false, gateOpen: true), MapSource.none);
    });
  });

  group('gate', () {
    test('queue drops the oldest beyond its cap', () async {
      final gate = TileFetchGate(maxConcurrent: 1, maxWaiting: 2);
      final first = await gate.acquire(never);
      final a = gate.acquire(never);
      final b = gate.acquire(never);
      final c = gate.acquire(never);
      expect(await a, isNull, reason: 'oldest waiter dropped');
      first!.release();
      final got = await c;
      expect(got, isNotNull, reason: 'newest is served first');
      got!.release();
      expect(await b, isNotNull);
    });
  });
}
