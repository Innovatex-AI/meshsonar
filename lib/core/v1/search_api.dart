// One search for the Network tab (AZ-3.5): node name, key prefix, packet hash, observer and region, on
// `GET /v1/search` (analyzer-api-contract.md 8.8), with a local fallback over what the app already has (the node
// roster it keeps for the map, the region list, the observers it read) when `/v1` is not live or the phone is offline.
// Every hit carries the NetworkRequest that opens it, built the same way the website builds its URLs, so a search
// result, a share link and a deep link all land on the same page.
//
// Pure Dart: no Flutter imports.
import 'package:http/http.dart' as http;

import '../network_request.dart';
import 'packet_filter.dart';
import 'v1_client.dart';

export 'v1_client.dart';

/// The kinds a hit can be (contract 8.8); [other] for one this build does not know.
enum SearchKind { node, packet, observer, channel, message, region, other }

SearchKind searchKindOf(String? s) => switch (s) {
      'node' => SearchKind.node,
      'packet' => SearchKind.packet,
      'observer' => SearchKind.observer,
      'channel' => SearchKind.channel,
      'message' => SearchKind.message,
      'region' => SearchKind.region,
      _ => SearchKind.other,
    };

class SearchHit {
  final SearchKind kind;

  /// `name`, `key`, `hash`, `text`, `none`.
  final String match;
  final String title;
  final String? subtitle;

  /// Region slug the hit lives in; null = the viewed one.
  final String? region;

  /// Where it opens in the app (null when the app has no page for it yet).
  final NetworkRequest? request;
  final Uri? web;
  const SearchHit({required this.kind, required this.match, required this.title, this.subtitle, this.region, this.request, this.web});

  static String _short(String k) => k.length > 12 ? '${k.substring(0, 12)}…' : k;

  /// One `results[]` entry of `/v1/search`; null when unreadable.
  static SearchHit? tryParse(Object? j) {
    if (j is! Map || j['kind'] is! String) return null;
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    final kind = searchKindOf(j['kind'] as String);
    final region = s(j['region']);
    final url = s(j['url']);
    final web = url == null ? null : Uri.tryParse(url);
    var req = web == null ? null : NetworkRequest.parse(web);
    String title;
    String? sub;
    switch (kind) {
      case SearchKind.node:
        final n = j['node'] is Map ? j['node'] as Map : const {};
        final key = s(n['key']) ?? '';
        title = s(n['name']) ?? _short(key);
        sub = [s(n['role']) ?? 'node', if (key.isNotEmpty) _short(key)].join(' · ');
        if (req == null && RegExp(r'^[0-9a-f]{64}$').hasMatch(key.toLowerCase())) req = NetworkRequest.node(key, region: region);
      case SearchKind.packet:
        final p = j['packet'] is Map ? j['packet'] as Map : j;
        final hash = s(p['hash']) ?? '';
        title = 'Packet ${hash.isEmpty ? '' : hash}'.trim();
        sub = s(p['summary']) ?? s(p['typeName']);
        if (req == null && RegExp(r'^[0-9a-f]{16}$').hasMatch(hash.toLowerCase())) req = NetworkRequest.packet(hash, region: region);
      case SearchKind.observer:
        final o = j['observer'] is Map ? j['observer'] as Map : const {};
        final id = s(o['id']) ?? '';
        title = s(o['name']) ?? _short(id);
        sub = 'Observer${s(o['kind']) == null ? '' : ' · ${s(o['kind'])}'}';
        if (req == null && id.isNotEmpty) req = NetworkRequest.observer(id, region: region);
      case SearchKind.channel:
        final c = j['channel'] is Map ? j['channel'] as Map : const {};
        title = s(c['name']) ?? s(c['id']) ?? 'Channel';
        sub = 'Channel';
      case SearchKind.message:
        final c = j['channel'] is Map ? j['channel'] as Map : const {};
        title = s(j['snippet']) ?? 'Message';
        sub = 'Message on ${s(c['name']) ?? s(c['id']) ?? 'a channel'}';
        // The message id is the packet hash that carried it (contract 13.8): the app opens that packet.
        final id = s(j['messageId']);
        if (id != null && RegExp(r'^[0-9a-f]{16}$').hasMatch(id)) req = NetworkRequest.packet(id, region: region);
      case SearchKind.region:
        final r = j['region'] is Map ? j['region'] as Map : const {};
        final slug = s(r['slug']) ?? region ?? '';
        title = s(r['name']) ?? slug.toUpperCase();
        sub = 'Region${slug.isEmpty ? '' : ' · ${slug.toUpperCase()}'}';
        req ??= slug.isEmpty ? null : NetworkRequest.section(NetworkSection.live, region: slug);
        return SearchHit(kind: kind, match: s(j['match']) ?? 'name', title: title, subtitle: sub, region: slug.isEmpty ? null : slug, request: req, web: web);
      case SearchKind.other:
        title = s(j['title']) ?? s(j['kind']) ?? 'Result';
    }
    return SearchHit(kind: kind, match: s(j['match']) ?? 'none', title: title, subtitle: sub, region: region is String ? region : null, request: req, web: web);
  }
}

/// What the phone can search without the server.
class LocalSearchIndex {
  /// Nodes the app knows: key (64 hex, lowercase), name.
  final List<({String key, String? name, String role})> nodes;
  final List<({String slug, String name})> regions;
  final List<({String id, String name})> observers;

  /// The region the person is viewing (hits are opened in it).
  final String? region;
  const LocalSearchIndex({this.nodes = const [], this.regions = const [], this.observers = const [], this.region});

  static const LocalSearchIndex empty = LocalSearchIndex();
}

final _hex = RegExp(r'^[0-9a-f]+$');

/// The local fallback: the same kinds and matching rules as `/v1/search` (8.8) over [ix]. Name matches rank exact,
/// then starts-with, then contains; at most [perKind] of each kind.
List<SearchHit> localSearch(String query, LocalSearchIndex ix, {int perKind = 5}) {
  final q = query.trim().toLowerCase();
  if (q.length < 2) return const [];
  final hex = _hex.hasMatch(q);
  final out = <SearchHit>[];

  int rank(String? name) {
    final n = (name ?? '').toLowerCase();
    if (n == q) return 0;
    if (n.startsWith(q)) return 1;
    if (n.contains(q)) return 2;
    return 9;
  }

  // Packets: a whole hash opens it; 8 to 15 hex lists the packets that start with it.
  if (hex && q.length == 16) {
    out.add(SearchHit(kind: SearchKind.packet, match: 'hash', title: 'Packet $q', subtitle: 'Open this packet', region: ix.region, request: NetworkRequest.packet(q, region: ix.region)));
  } else if (hex && q.length >= 8 && q.length < 16) {
    out.add(SearchHit(
        kind: SearchKind.packet,
        match: 'hash',
        title: 'Packets starting $q',
        subtitle: 'Packet hash prefix',
        region: ix.region,
        request: NetworkRequest.packetList(PacketFilter(hash: q), region: ix.region)));
  }

  // Nodes by name, then by key prefix.
  final nodeHits = <(int, SearchHit)>[];
  final seen = <String>{};
  for (final n in ix.nodes) {
    final key = n.key.toLowerCase();
    final r = rank(n.name);
    final byKey = hex && key.startsWith(q);
    if (r > 2 && !byKey) continue;
    if (!seen.add(key)) continue;
    nodeHits.add((
      byKey && r > 2 ? 3 : r,
      SearchHit(
        kind: SearchKind.node,
        match: r <= 2 ? 'name' : 'key',
        title: n.name ?? '${key.substring(0, key.length.clamp(0, 12))}…',
        subtitle: '${n.role} · ${key.substring(0, key.length.clamp(0, 12))}…',
        region: ix.region,
        request: _nodeKey.hasMatch(key) ? NetworkRequest.node(key, region: ix.region) : null,
      )
    ));
  }
  nodeHits.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.title.toLowerCase().compareTo(b.$2.title.toLowerCase()));
  out.addAll(nodeHits.take(perKind).map((e) => e.$2));

  // A short hex is also a hop prefix: the packets through it.
  if (hex && q.length >= 2 && q.length <= 6 && q.length.isEven) {
    out.add(SearchHit(
        kind: SearchKind.packet,
        match: 'key',
        title: 'Packets through hop $q',
        subtitle: 'Hop prefix',
        region: ix.region,
        request: NetworkRequest.packetList(PacketFilter(prefix: q), region: ix.region)));
  }

  // Observers by name or id.
  final obs = [
    for (final o in ix.observers)
      if (rank(o.name) <= 2 || o.id.toLowerCase().startsWith(q)) o
  ]..sort((a, b) => rank(a.name).compareTo(rank(b.name)));
  out.addAll(obs.take(perKind).map((o) => SearchHit(
      kind: SearchKind.observer, match: rank(o.name) <= 2 ? 'name' : 'key', title: o.name, subtitle: 'Observer', region: ix.region, request: NetworkRequest.observer(o.id, region: ix.region))));

  // Regions by slug or name.
  final regs = [
    for (final r in ix.regions)
      if (r.slug.toLowerCase() == q || r.slug.toLowerCase().startsWith(q) || rank(r.name) <= 2) r
  ]..sort((a, b) {
      final ea = a.slug.toLowerCase() == q ? -1 : rank(a.name), eb = b.slug.toLowerCase() == q ? -1 : rank(b.name);
      return ea != eb ? ea.compareTo(eb) : a.name.compareTo(b.name);
    });
  out.addAll(regs.take(perKind).map((r) => SearchHit(
      kind: SearchKind.region, match: 'name', title: r.name, subtitle: 'Region · ${r.slug.toUpperCase()}', region: r.slug, request: NetworkRequest.section(NetworkSection.live, region: r.slug))));
  return out;
}

final _nodeKey = RegExp(r'^[0-9a-f]{64}$');

/// A search answer.
class SearchRead {
  final String query;
  final List<SearchHit> hits;

  /// True when the phone answered from what it has (no `/v1/search`, or no connection).
  final bool local;

  /// Why the answer is local: `not_live` or `offline`; null for a server answer.
  final String? localReason;
  final Set<SearchKind> truncated;
  const SearchRead({required this.query, required this.hits, this.local = false, this.localReason, this.truncated = const {}});
}

class SearchApi {
  final String baseUrl;
  final V1Client v1;
  SearchApi(this.baseUrl, {http.Client? client, DateTime Function()? clock}) : v1 = V1Client(baseUrl, client: client, clock: clock);

  /// `/v1/search` for [query] (2 to 64 characters), else [localSearch] over [local]. Throws [V1Error] only for a
  /// server answer that is an error other than "offline" (bad_param, rate_limited).
  Future<SearchRead> search(String query, {LocalSearchIndex local = LocalSearchIndex.empty, int perKind = 5}) async {
    final q = query.trim();
    if (q.length < 2) return SearchRead(query: q, hits: const []);
    final qq = q.length > 64 ? q.substring(0, 64) : q;
    try {
      final env = await v1.get('search', (d) {
        if (d is! Map) throw const FormatException('search data is not an object');
        final hits = [if (d['results'] is List) for (final r in d['results'] as List) ?SearchHit.tryParse(r)];
        final tr = <SearchKind>{
          if (d['truncated'] is Map)
            for (final e in (d['truncated'] as Map).entries)
              if (e.value == true && e.key is String) searchKindOf(e.key as String)
        };
        return SearchRead(query: qq, hits: hits, truncated: tr);
      }, query: {'q': qq, 'perKind': '$perKind'});
      // A stored copy (offline) is still the server's answer for this query.
      return env.data;
    } on V1NotLive {
      return SearchRead(query: qq, hits: localSearch(qq, local, perKind: perKind), local: true, localReason: 'not_live');
    } on V1Error catch (e) {
      if (!e.offline) rethrow;
      return SearchRead(query: qq, hits: localSearch(qq, local, perKind: perKind), local: true, localReason: 'offline');
    }
  }

  void close() => v1.close();
}

/// Tests replace this to inject a fake HTTP client.
SearchApi Function(String baseUrl) searchApiFactory = (b) => SearchApi(b);
