// The typed base client for the public `/v1` read API (meshsonar-infra docs/planning/analyzer-api-contract.md sections
// 1-7, AZ-0.4). This is the ONE place app code reads `/v1` from: later items (packets, nodes, observers, insights,
// channels, search: AZ-3.2 to AZ-3.11) add their calls next to the Network ones in network_api.dart and reuse this file.
//
// What it does:
// - Every answer except `/v1/regions` and `/v1/spec` is the envelope `{data, page?, meta}` (contract 1.2): [V1Envelope].
// - Errors are `{error: {code, message, param?, at?, retryAfter?, requestId}}` (contract 5): [V1Error].
// - Lists page with opaque cursors (`page.next`, `page.prev`; contract 3.1): [V1Page], [V1Pager].
// - ETag: requests go through the shared ETag wire client (etag_client.dart, `newRegionWireClient`), which sends
//   `If-None-Match`, turns a 304 into the stored body and, for the cacheable paths, serves the stored copy offline
//   ([V1Envelope.offlineAsOf] then says when it was fetched).
// - "Not live yet": while the server has no `/v1` routes, a path answers 404 without a v1 error body, or a page that is
//   not an envelope. That is [V1NotLive], so the caller can fall back to today's `/api/cmh/*` read without showing an
//   error. A host that said "not live" is not asked again for [notLiveMemory].
//
// Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../etag_client.dart';
import '../region_overview_api.dart' show RegionDataState, RegionDataStatus;

/// `meta.region`: the scope the server used (contract 1.1).
class V1Scope {
  final String slug, name;

  /// `region`, `group` or `network`; an unknown value is kept as sent.
  final String kind;
  const V1Scope({required this.slug, required this.name, required this.kind});

  static V1Scope? tryParse(Object? j) {
    if (j is! Map || j['slug'] is! String) return null;
    return V1Scope(slug: j['slug'] as String, name: j['name'] is String ? j['name'] as String : j['slug'] as String, kind: j['kind'] is String ? j['kind'] as String : 'region');
  }
}

/// One entry of `meta.sources` (contract 1.6).
class V1Source {
  final String id, kind, name, attribution, url;
  const V1Source({required this.id, required this.kind, required this.name, required this.attribution, required this.url});

  static V1Source? tryParse(String id, Object? j) {
    if (j is! Map) return null;
    String s(String k) => j[k] is String ? j[k] as String : '';
    return V1Source(id: id, kind: s('kind'), name: s('name').isEmpty ? id : s('name'), attribution: s('attribution'), url: s('url'));
  }
}

/// `meta.window` (contract 3.2).
class V1Window {
  final String name;
  final DateTime? from, to;
  final String? resolution, rollup;
  const V1Window({required this.name, this.from, this.to, this.resolution, this.rollup});

  static V1Window? tryParse(Object? j) {
    if (j is! Map || j['name'] is! String) return null;
    return V1Window(
      name: j['name'] as String,
      from: v1Time(j['from']),
      to: v1Time(j['to']),
      resolution: j['resolution'] is String ? j['resolution'] as String : null,
      rollup: j['rollup'] is String ? j['rollup'] as String : null,
    );
  }
}

/// `meta` of every envelope (contract 1.2). [raw] keeps the whole object for endpoint-specific echoes.
class V1Meta {
  final String apiVersion;
  final V1Scope? region;
  final DateTime? generatedAt, dataAt;

  /// The honest state of the data, the same type every region read already uses.
  final RegionDataStatus status;
  final Map<String, V1Source> sources;
  final V1Window? window;
  final Map<String, dynamic> raw;
  const V1Meta({
    required this.apiVersion,
    this.region,
    this.generatedAt,
    this.dataAt,
    required this.status,
    this.sources = const {},
    this.window,
    this.raw = const {},
  });

  factory V1Meta.fromJson(Map<String, dynamic> j) {
    final st = j['status'];
    final sources = <String, V1Source>{};
    final src = j['sources'];
    if (src is Map) {
      for (final e in src.entries) {
        final s = e.key is String ? V1Source.tryParse(e.key as String, e.value) : null;
        if (s != null) sources[s.id] = s;
      }
    }
    return V1Meta(
      apiVersion: j['apiVersion'] as String,
      region: V1Scope.tryParse(j['region']),
      generatedAt: v1Time(j['generatedAt']),
      dataAt: v1Time(j['dataAt']),
      // `meta.status` is {state, reason}; the data time is `dataAt`.
      status: st is Map
          ? RegionDataStatus(state: RegionDataStatus.fromJson(st).state, reason: RegionDataStatus.fromJson(st).reason, computedAt: v1Time(j['dataAt']))
          : const RegionDataStatus(state: RegionDataState.unavailable, reason: 'The server sent no status.'),
      sources: sources,
      window: V1Window.tryParse(j['window']),
      raw: j,
    );
  }
}

/// `page` on lists that page (contract 2, 3.1). Cursors are opaque: never build or parse one.
class V1Page {
  final int limit;
  final String? next, prev;
  final int? approxTotal;
  final String? order;
  const V1Page({required this.limit, this.next, this.prev, this.approxTotal, this.order});

  bool get hasMore => next != null;

  static V1Page? tryParse(Object? j) {
    if (j is! Map) return null;
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    return V1Page(
      limit: j['limit'] is num ? (j['limit'] as num).toInt() : 0,
      next: s(j['next']),
      prev: s(j['prev']),
      approxTotal: j['approxTotal'] is num ? (j['approxTotal'] as num).toInt() : null,
      order: s(j['order']),
    );
  }
}

/// One `/v1` answer: [data] parsed by the endpoint, plus [page] and [meta]. [offlineAsOf] is set when it is the stored
/// copy served because the network failed (label it "Offline - as of ...").
class V1Envelope<T> {
  final T data;
  final V1Page? page;
  final V1Meta meta;
  final DateTime? offlineAsOf;
  const V1Envelope({required this.data, this.page, required this.meta, this.offlineAsOf});

  bool get offline => offlineAsOf != null;
}

/// A `/v1` error answer, or a network failure ([offline]). [code] is the contract's stable machine code
/// (`bad_param`, `not_found`, `rate_limited`, `query_timeout`, ...); [message] is a plain sentence for people.
class V1Error implements Exception {
  final int? status;
  final String code;
  final String message;
  final String? param;
  final int? at;

  /// Seconds to wait (body `retryAfter`, else the `Retry-After` header) on 429 and 503.
  final int? retryAfter;
  final String? requestId;

  /// True when the server could not be reached at all (no connection, DNS, TLS, timeout).
  final bool offline;
  const V1Error({this.status, required this.code, required this.message, this.param, this.at, this.retryAfter, this.requestId, this.offline = false});

  /// Parses `{error: {...}}`; null when [body] is not a v1 error body (an old `{error: "text"}` or an HTML page).
  static V1Error? tryParse(int status, Object? body, {Map<String, String> headers = const {}}) {
    if (body is! Map || body['error'] is! Map) return null;
    final e = body['error'] as Map;
    if (e['code'] is! String) return null;
    final header = int.tryParse(headers['retry-after'] ?? '');
    return V1Error(
      status: status,
      code: e['code'] as String,
      message: e['message'] is String ? e['message'] as String : 'The server answered $status.',
      param: e['param'] is String ? e['param'] as String : null,
      at: e['at'] is num ? (e['at'] as num).toInt() : null,
      retryAfter: e['retryAfter'] is num ? (e['retryAfter'] as num).toInt() : header,
      requestId: e['requestId'] is String ? e['requestId'] as String : null,
    );
  }

  bool get notFound => code == 'not_found';
  bool get rateLimited => code == 'rate_limited';

  @override
  String toString() => message;
}

/// The host has no `/v1` route for this path yet (old server). Callers fall back to today's endpoint, quietly.
class V1NotLive implements Exception {
  final Uri url;
  final int? status;
  const V1NotLive(this.url, {this.status});
  @override
  String toString() => '/v1 is not live at ${url.host}${url.path}';
}

/// RFC 3339 time (contract 1.4), UTC; null when absent or unreadable.
DateTime? v1Time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;

/// Hosts that answered "not live" recently: `host` -> when. Shared by every [V1Client], cleared by [resetV1NotLive].
final Map<String, DateTime> _notLive = {};

/// How long a "not live" answer is believed before the host is asked again.
const Duration notLiveMemory = Duration(minutes: 30);

/// For tests (and a server URL change): forget which hosts had no `/v1`.
void resetV1NotLive() => _notLive.clear();

class V1Client {
  /// The host to ask (a region host such as https://cmh.meshsonar.com, or the hub); it sets the default scope.
  final String baseUrl;
  final http.Client _client;
  final Duration timeout;
  final DateTime Function() clock;
  V1Client(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 15), DateTime Function()? clock})
      : _client = client ?? newRegionWireClient(),
        clock = clock ?? DateTime.now;

  /// `<baseUrl>/v1/<path>?<query>` (empty query values are dropped).
  Uri uri(String path, [Map<String, String?>? query]) {
    final b = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final p = path.startsWith('/') ? path.substring(1) : path;
    final u = Uri.parse('$b/v1/$p');
    final q = {
      for (final e in (query ?? const <String, String?>{}).entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value!
    };
    return q.isEmpty ? u : u.replace(queryParameters: q);
  }

  /// True while this host recently said it has no `/v1` (callers skip straight to the fallback).
  bool get knownNotLive {
    final host = Uri.parse(baseUrl).host;
    final at = _notLive[host];
    if (at == null) return false;
    if (clock().difference(at) > notLiveMemory) {
      _notLive.remove(host);
      return false;
    }
    return true;
  }

  /// GET one enveloped read and parse its `data` with [parse]. Throws [V1Error] (answers and network failures) or
  /// [V1NotLive] (fall back).
  Future<V1Envelope<T>> get<T>(String path, T Function(Object? data) parse, {Map<String, String?>? query}) async {
    final (body, res) = await _getJson(uri(path, query));
    if (body is! Map<String, dynamic> || body['meta'] is! Map<String, dynamic> || (body['meta'] as Map)['apiVersion'] is! String || !body.containsKey('data')) {
      _markNotLive();
      throw V1NotLive(res.request?.url ?? uri(path, query), status: res.statusCode);
    }
    final T data;
    try {
      data = parse(body['data']);
    } catch (_) {
      throw const V1Error(code: 'unreadable', message: 'The server sent something unreadable.');
    }
    return V1Envelope(
      data: data,
      page: V1Page.tryParse(body['page']),
      meta: V1Meta.fromJson(body['meta'] as Map<String, dynamic>),
      offlineAsOf: offlineAsOfOf(res),
    );
  }

  /// GET a list endpoint, one page: each element of `data` through [item] (an element it cannot read is skipped).
  Future<V1Envelope<List<T>>> getPage<T>(String path, T? Function(Object? item) item,
          {Map<String, String?>? query, String? cursor, int? limit}) =>
      get<List<T>>(path, (d) {
        if (d is! List) throw const FormatException('data is not a list');
        return [for (final e in d) ?item(e)];
      }, query: {...?query, 'cursor': cursor, 'limit': limit?.toString()});

  /// GET a body without the envelope (`/v1/regions`, `/v1/spec`: contract 7). [parse] returns null for "not this
  /// shape", which counts as not live.
  Future<(T, DateTime?)> getBare<T extends Object>(String path, T? Function(Map<String, dynamic> body) parse, {Map<String, String?>? query}) async {
    final (body, res) = await _getJson(uri(path, query));
    final T? v = body is Map<String, dynamic> ? parse(body) : null;
    if (v == null) {
      _markNotLive();
      throw V1NotLive(uri(path, query), status: res.statusCode);
    }
    return (v, offlineAsOfOf(res));
  }

  void _markNotLive() => _notLive[Uri.parse(baseUrl).host] = clock();

  Future<(Object?, http.Response)> _getJson(Uri url) async {
    if (knownNotLive) throw V1NotLive(url);
    final http.Response res;
    try {
      res = await _client.get(url, headers: const {'accept': 'application/json'}).timeout(timeout);
    } on TimeoutException {
      throw const V1Error(code: 'timeout', message: 'The server took too long to answer.', offline: true);
    } on SocketException {
      throw const V1Error(code: 'offline', message: 'No connection to the server.', offline: true);
    } on http.ClientException {
      throw const V1Error(code: 'offline', message: 'No connection to the server.', offline: true);
    } on HandshakeException {
      throw const V1Error(code: 'offline', message: 'The secure connection to the server failed.', offline: true);
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      body = null; // an HTML page (the site's 404 or SPA shell) or nothing
    }
    if (res.statusCode == 200) return (body, res);
    final err = V1Error.tryParse(res.statusCode, body, headers: res.headers);
    if (err != null) throw err;
    // No v1 error body: an old server that has no such route (404/405/501), or a plain failure.
    if (res.statusCode == 404 || res.statusCode == 405 || res.statusCode == 501) {
      _markNotLive();
      throw V1NotLive(url, status: res.statusCode);
    }
    String? legacy;
    if (body is Map && body['error'] is String) legacy = body['error'] as String;
    throw V1Error(
      status: res.statusCode,
      code: res.statusCode == 429 ? 'rate_limited' : 'http_${res.statusCode}',
      message: legacy ?? 'The server answered ${res.statusCode}.',
      retryAfter: int.tryParse(res.headers['retry-after'] ?? ''),
    );
  }

  void close() => _client.close();
}

/// Walks a paged list one page at a time (contract 3.1): [next] fetches the following page with the cursor the last
/// one gave; [done] once `page.next` is null. Filters stay fixed for the life of a pager (a changed filter with an old
/// cursor is a 400 `bad_cursor`), so make a new pager when they change.
class V1Pager<T> {
  final Future<V1Envelope<List<T>>> Function(String? cursor) _fetch;
  String? _cursor;
  bool _done = false;
  final List<T> items = [];
  V1Pager(this._fetch);

  bool get done => _done;

  /// The next page's rows (also appended to [items]); empty once [done].
  Future<List<T>> next() async {
    if (_done) return const [];
    final env = await _fetch(_cursor);
    items.addAll(env.data);
    _cursor = env.page?.next;
    _done = _cursor == null;
    return env.data;
  }
}
