// ETag on the wire for the public, cacheable GETs (region-*, regions-index, public-coverage, site-config, public-stats,
// leaderboard, /v1/regions). The server shares a 120 req/min/IP limit across these, so: send `If-None-Match` with the
// stored ETag, and on `304` serve the stored body (a 304 is cheap and does not need the body re-sent). Every 200 is
// stored on disk (ETag + body + fetch time). When the network fails, the stored copy is served and [offlineSince]
// says when it was fetched, so the UI can label it "Offline - as of 3h ago". Spec: parity spec C.2 / C.6 / WP-R5.
//
// It is an [http.Client] wrapper: callers keep calling `.get()` and see a plain 200 either way. Requests with a
// driver key, and anything that is not a GET to a cacheable path, pass straight through untouched.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'region_cache.dart';

/// Paths (after the host) this client may cache. Everything else is passed through.
final _cacheablePath = RegExp(r'^/(api/cmh/(region-[a-z-]+|regions-index|public-coverage|site-config|public-stats|leaderboard)|v1/regions)/?$');

class EtagClient extends http.BaseClient {
  final http.Client _inner;
  final RegionCache _cache;

  /// Serve the stored copy when the live request fails (network error, timeout, 5xx). Off for callers that already
  /// have their own offline handling.
  final bool serveStale;

  /// How long to wait for the network before falling back to a stored copy (only when one exists).
  final Duration staleAfter;

  /// Set while the most recent cacheable answer came from the disk copy because the network failed; cleared by the
  /// next live answer. This is the "as of" time of the data on screen.
  DateTime? offlineSince;

  EtagClient(this._inner, this._cache, {this.serveStale = true, this.staleAfter = const Duration(seconds: 12)});

  static bool isCacheable(Uri u) => _cacheablePath.hasMatch(u.path);

  /// File-safe, length-bounded key for a URL (host + path + a hash of the full URL incl. the query).
  static String keyFor(Uri u) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(u.toString())) {
      h = ((h ^ b) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    final base = '${u.host}${u.path}'.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return '${base.length > 80 ? base.substring(0, 80) : base}_${h.toRadixString(16)}';
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    if (request.method != 'GET' || !isCacheable(uri) || request.headers.containsKey('x-driver-key')) {
      return _inner.send(request);
    }
    final key = keyFor(uri);
    final cached = await _cache.read(key);
    final req = http.Request('GET', uri)..headers.addAll(request.headers);
    if (cached?.etag != null) req.headers['if-none-match'] = cached!.etag!;

    http.Response? live;
    Object? failure;
    try {
      var f = _inner.send(req).then(http.Response.fromStream);
      if (cached != null && serveStale) f = f.timeout(staleAfter);
      live = await f;
    } catch (e) {
      failure = e;
    }

    if (live != null && live.statusCode == 304 && cached != null) {
      offlineSince = null;
      unawaited(_cache.put(key, cached.body, etag: cached.etag)); // touch: "as of" and LRU position
      return _respond(200, utf8.encode(cached.body), live.headers, etag: cached.etag, from: '304');
    }
    if (live != null && live.statusCode == 200) {
      offlineSince = null;
      final etag = live.headers['etag'];
      try {
        await _cache.put(key, utf8.decode(live.bodyBytes), etag: etag);
      } catch (_) {} // not UTF-8 text or disk trouble: just not cached
      return _respond(200, live.bodyBytes, live.headers, from: 'network');
    }
    final serverDown = live != null && live.statusCode >= 500;
    if (serveStale && cached != null && (failure != null || serverDown)) {
      offlineSince = cached.fetchedAt;
      return _respond(200, utf8.encode(cached.body), const {}, etag: cached.etag, from: 'offline', asOf: cached.fetchedAt);
    }
    if (live == null) throw failure!; // nothing stored to fall back on: the caller's own error handling takes over
    return _respond(live.statusCode, live.bodyBytes, live.headers, reason: live.reasonPhrase);
  }

  http.StreamedResponse _respond(int status, List<int> bytes, Map<String, String> headers,
      {String? etag, String? from, DateTime? asOf, String? reason}) {
    final h = <String, String>{
      'content-type': headers['content-type'] ?? 'application/json; charset=utf-8',
      'content-length': '${bytes.length}',
      'etag': ?etag,
      'x-meshsonar-cache': ?from,
      'x-meshsonar-as-of': ?asOf?.toUtc().toIso8601String(),
    };
    return http.StreamedResponse(Stream.value(Uint8List.fromList(bytes)), status,
        contentLength: bytes.length, headers: h, reasonPhrase: reason);
  }

  @override
  void close() => _inner.close();
}

/// Wraps the shared client so a caller's `finally { c.close(); }` does not close it for everyone else.
class _Borrowed extends http.BaseClient {
  final http.Client _c;
  _Borrowed(this._c);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _c.send(request);
  @override
  void close() {}
}

EtagClient? _shared;
RegionCache? _sharedCache;

/// The app-wide ETag client for the region data fetchers, or null before [installSharedEtagClient] (tests, which then
/// get plain clients).
EtagClient? get sharedEtagClient => _shared;

/// Called once at startup (lib/app/wiring.dart) with the cache directory.
void installSharedEtagClient(Directory dir) {
  _sharedCache = RegionCache(dir, maxEntries: 150);
  _shared = EtagClient(http.Client(), _sharedCache!);
}

/// For tests: install [client] (or clear with null).
void setSharedEtagClientForTest(EtagClient? client) {
  _shared = client;
  _sharedCache = null;
}

/// The client for [HttpCmatClient]: ETag/304 on its public GETs (regions-index, public-coverage, site-config), but no
/// stale-on-failure, because AppState already serves and labels its own offline copy of those. Uploads and anything
/// carrying a driver key pass straight through. A plain client when the shared one is not installed.
http.Client newCmatWireClient() => _sharedCache == null ? http.Client() : EtagClient(http.Client(), _sharedCache!, serveStale: false);

/// The default HTTP client of the region data fetchers: the shared ETag client when installed, else a plain one.
/// Safe to `close()` after use either way.
http.Client newRegionWireClient() => _shared == null ? http.Client() : _Borrowed(_shared!);
