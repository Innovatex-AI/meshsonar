// What a request to open the Network tab carries (AZ-3.1), in the style of PlanRequest (lib/ui/shell/shell_controller.dart):
// the section, the region, and optionally the node / packet / observer / channel it is about and a time window. It
// parses from and serialises to the website's routes (analyzer-api-contract.md section 8, the web route table:
// `/packets`, `/packets/:hash`, `/nodes`, `/nodes/:key` (old `/repeaters/*`), `/observers`, `/observers/:id`,
// `/channels`, `/channels/:id`, `/analytics/:slug`, `/tools/*`, `/scope-audit`, `/status`, `/pulse`, `/live`,
// `/map?panel=live&packet=`; the retired `/insights?tab=` and `/analysis` open their Analytics twin), so a shared web link
// opens the same view in the app and the app can share a link that opens on the site.
//
// Region: the region host sets it (`https://cmh.meshsonar.com/packets`), or `?region=<slug>` on the hub
// (`https://meshsonar.com/packets?region=cmh`), or `?region=` on the app scheme (`meshsonar://network/packets?region=cmh`).
// No region = whatever region the app is viewing. Serialising writes the region host form (the site's own address).
// Time window: `window=<15m..400d>` or `since` / `until` (RFC 3339), never both (contract 3.2).
//
// Packets list filters (AZ-3.2): every `/v1/packets` filter rides in [NetworkRequest.packetFilter] with the contract's
// own parameter names (`type`, `route`, `observer`, `node`, `hash`, `channel`, `scope`, `source`, `filter`), so a list
// state is a link the website opens too. A single node / observer / channel / whole hash also fills the older
// [NetworkRequest.nodeKey] etc. fields (AZ-3.1 links); [NetworkRequest.listFilter] is the two merged.
//
// Pure Dart: no Flutter imports.
import 'v1/packet_filter.dart';

/// The Network sections. A region shows [networkRegionSections] in that order (build 72: Live first, no Home); "All
/// regions" shows [networkHubSections], where [regions] is its first section (the hub has no live map on the phone).
enum NetworkSection {
  live('Live'),
  packets('Packets'),
  nodes('Nodes'),
  channels('Channels'),
  observers('Observers'),
  analytics('Analytics'),
  tools('Tools'),

  /// "All regions" only: the network summary, the global search and the busiest regions.
  regions('Regions');

  final String label;
  const NetworkSection(this.label);

  /// Looks a section up by name. Older names still resolve: `home` (build 71) and `now` = Live, the section the tab opens
  /// on since Home was removed in build 72 (its findings and overview are under Analytics); `map` = Live; `insights` =
  /// Analytics.
  static NetworkSection? byName(String? name) {
    switch (name) {
      case 'home':
      case 'now':
      case 'map':
        return NetworkSection.live;
      case 'insights':
        return NetworkSection.analytics;
    }
    for (final s in NetworkSection.values) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// A region's sections, in strip order.
const List<NetworkSection> networkRegionSections = [
  NetworkSection.live,
  NetworkSection.packets,
  NetworkSection.nodes,
  NetworkSection.channels,
  NetworkSection.observers,
  NetworkSection.analytics,
  NetworkSection.tools,
];

/// The sections that work with no region (the "All regions" view on the hub), in strip order.
const List<NetworkSection> networkHubSections = [NetworkSection.regions, NetworkSection.channels, NetworkSection.analytics, NetworkSection.tools];

/// The two native panels that were the Home section until build 72, now the first rows of Analytics. App-internal
/// analytics slugs (`/analytics/findings`, `/analytics/region-overview`): the site has no page under them.
const String analyticsFindingsSlug = 'findings';
const String analyticsRegionOverviewSlug = 'region-overview';

/// The site's analytics tab an old `/insights?tab=` name opens now (the site's Analytics replaced Insights).
/// `channels` is not here: it is its own section.
const Map<String, String> legacyInsightsTabs = {
  'analysis': 'overview',
  'overview': 'overview',
  'hashes': 'hash-stats',
  'roles': 'roles',
  'routes': 'route-patterns',
  'rf': 'rf-signal',
  'signal': 'rf-signal',
  'health': 'rf-health',
  'topology': 'topology',
};

/// Tools whose site address is not `/tools/<id>` (id to path). Every other tool id serialises as `/tools/<id>`.
const Map<String, String> networkToolPaths = {
  'definition': '/tools/region',
  'prefix': '/analytics/prefix-tool',
  'scope-audit': '/scope-audit',
  'compare': '/observers/compare',
  'status': '/status',
};

/// The named windows of the contract (1.4).
const Set<String> networkWindows = {'15m', '1h', '3h', '6h', '24h', '7d', '30d', '90d', '400d'};

/// Subdomains of meshsonar.com that are not regions (never read as a region slug).
const Set<String> networkNonRegionHosts = {'www', 'api', 'tiles', 'mqtt', 'docs', 'status'};

const String networkApexHost = 'meshsonar.com';

final _nodeKey = RegExp(r'^[0-9a-f]{64}$');
final _packetHash = RegExp(r'^[0-9a-f]{16}$');
final _slug = RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$');
final _tab = RegExp(r'^[a-z][a-z0-9-]{0,31}$');
final _channel = RegExp(r'^(public|tag:[^\s/]{1,64}|enc:[0-9a-f]{2})$');
final _observer = RegExp(r'^[A-Za-z0-9_.:-]{1,160}$');
final _observation = RegExp(r'^[A-Za-z0-9_.:@+-]{1,200}$');
final _toolArg = RegExp(r'^[A-Za-z0-9_.:,>-]{1,512}$');

/// Immutable: every field is final and equality is by value.
class NetworkRequest {
  final NetworkSection section;

  /// Region slug (`cmh`); null = the region the app is viewing.
  final String? region;

  /// Node public key, 64 lowercase hex.
  final String? nodeKey;

  /// Packet hash, 16 lowercase hex.
  final String? packetHash;

  /// Observer id: a 64-hex key, or `<sourceId>:<their id>` for an outside observer (contract 1.3).
  final String? observerId;

  /// Channel id: `public`, `tag:<name>` (case kept), `enc:<hh>` (contract 1.3).
  final String? channelId;

  /// A named window ([networkWindows]); exclusive with [since] / [until].
  final String? window;
  final DateTime? since, until;

  /// Analytics tab slug (`/analytics/rf-signal`), an open set of lowercase names; null = the list.
  final String? analyticsTab;

  /// Tool id (Tools section): `path`, `trace`, `prefix`, `scope-audit`, `compare`, `definition`, `status`, `decode`, or
  /// another `/tools/<name>` passed through; null = the list.
  final String? tool;

  /// The tool's argument from a link: a trace or packet hash (`/tools/trace/<hash>`), a prefix (`?prefix=`), a hop
  /// list (`?hops=`).
  final String? toolArg;

  /// True for `/pulse`: Live with the pulse sheet open.
  final bool pulse;

  /// Live map: the time to show (`/map?panel=live&t=<RFC 3339>&packet=<hash>`, the packet detail's `links.replay`).
  final DateTime? mapTime;

  /// Live map: draw only this one reception of [packetHash] and play it from the sender through each hop to its
  /// observer (`&observation=<id>`, the packet page's "Replay on map"). Null draws every path of the packet.
  final String? observationId;

  const NetworkRequest({
    required this.section,
    this.region,
    this.nodeKey,
    this.packetHash,
    this.observerId,
    this.channelId,
    this.window,
    this.since,
    this.until,
    this.analyticsTab,
    this.tool,
    this.toolArg,
    this.pulse = false,
    this.packetFilter,
    this.mapTime,
    this.observationId,
  });

  const NetworkRequest.section(NetworkSection section, {String? region, String? window}) : this(section: section, region: region, window: window);

  /// A node's page (Nodes section). [key] must be 64 hex.
  NetworkRequest.node(String key, {String? region}) : this(section: NetworkSection.nodes, nodeKey: key.toLowerCase(), region: region);

  /// A packet (Packets section). [hash] must be 16 hex.
  NetworkRequest.packet(String hash, {String? region}) : this(section: NetworkSection.packets, packetHash: hash.toLowerCase(), region: region);

  /// An observer's page (Observers section).
  const NetworkRequest.observer(String observerId, {String? region}) : this(section: NetworkSection.observers, observerId: observerId, region: region);

  /// A channel (Channels section).
  const NetworkRequest.channel(String channelId, {String? region}) : this(section: NetworkSection.channels, channelId: channelId, region: region);

  /// One analytics tab of the site (Analytics section).
  const NetworkRequest.analytics(String slug, {String? region}) : this(section: NetworkSection.analytics, analyticsTab: slug, region: region);

  /// One tool (Tools section), with its argument when it has one.
  const NetworkRequest.toolOf(String tool, {String? arg, String? region}) : this(section: NetworkSection.tools, tool: tool, toolArg: arg, region: region);

  /// The live map drawing one packet's path (Network > Live), at [at] (the packet detail's "Show on map").
  /// With [observation], only that one reception is drawn and replayed ("Replay on map").
  NetworkRequest.mapPacket(String hash, {String? region, DateTime? at, String? observation})
      : this(section: NetworkSection.live, packetHash: hash.toLowerCase(), mapTime: at?.toUtc(), region: region, observationId: observation);

  NetworkRequest _copy({String? Function()? region, PacketFilter? Function()? packetFilter}) => NetworkRequest(
      section: section,
      region: region == null ? this.region : region(),
      nodeKey: nodeKey,
      packetHash: packetHash,
      observerId: observerId,
      channelId: channelId,
      window: window,
      since: since,
      until: until,
      analyticsTab: analyticsTab,
      tool: tool,
      toolArg: toolArg,
      pulse: pulse,
      packetFilter: packetFilter == null ? this.packetFilter : packetFilter(),
      mapTime: mapTime,
      observationId: observationId);

  /// The request in a copy with another region (deep links that name none take the viewed one).
  NetworkRequest withRegion(String? r) => _copy(region: () => r);

  /// The Packets list filters beyond the single [nodeKey] / [observerId] / [channelId] / [packetHash]; null = none.
  final PacketFilter? packetFilter;

  /// Everything the Packets list filters on: [packetFilter] with the single fields merged in.
  PacketFilter get listFilter {
    final f = packetFilter ?? PacketFilter.none;
    return f.copyWith(
      nodes: nodeKey == null || f.nodes.contains(nodeKey) ? null : [nodeKey!, ...f.nodes],
      observers: observerId == null || f.observers.contains(observerId) ? null : [observerId!, ...f.observers],
      channels: channelId == null ? null : {channelId!, ...f.channels},
      hash: f.hash == null && packetHash != null && section == NetworkSection.packets && _hasListFilter ? packetHash : null,
    );
  }

  bool get _hasListFilter => nodeKey != null || observerId != null || channelId != null || (packetFilter != null && !packetFilter!.isEmpty);

  /// A Packets list request carrying [filter] (and the window), for share links of a list state.
  static NetworkRequest packetList(PacketFilter filter, {String? region, String? window, DateTime? since, DateTime? until}) => NetworkRequest(
      section: NetworkSection.packets, region: region, window: window, since: since, until: until, packetFilter: filter.isEmpty ? null : filter);

  /// True when it opens the Observers section (the list or one observer). Kept for callers written before build 71.
  bool get observersView => section == NetworkSection.observers;

  // ---------------------------------------------------------------- parsing

  /// Reads a Network link: `https://meshsonar.com/<route>`, `https://<region>.meshsonar.com/<route>`, or
  /// `meshsonar://network/<route>`. Null for anything that is not one (another host, a plan link, an unknown route, an
  /// identifier of the wrong shape).
  static NetworkRequest? parse(Uri u) {
    String? region;
    List<String> segs;
    if (u.scheme == 'meshsonar') {
      if (u.host != 'network') return null;
      segs = [for (final s in u.pathSegments) if (s.isNotEmpty) s];
    } else if (u.scheme == 'https' || u.scheme == 'http') {
      final h = u.host.toLowerCase();
      if (h == networkApexHost) {
        region = null;
      } else if (h.endsWith('.$networkApexHost')) {
        final sub = h.substring(0, h.length - networkApexHost.length - 1);
        if (sub.contains('.') || networkNonRegionHosts.contains(sub) || !_slug.hasMatch(sub)) return null;
        region = sub;
      } else {
        return null;
      }
      segs = [for (final s in u.pathSegments) if (s.isNotEmpty) s];
    } else {
      return null;
    }
    final q = u.queryParameters;
    final qRegion = q['region']?.toLowerCase();
    if (qRegion != null && qRegion.isNotEmpty) {
      if (!_slug.hasMatch(qRegion)) return null;
      region = qRegion;
    }

    // Time window: a bad one is dropped (the link still opens the view), both forms together keep the named one.
    String? window = q['window'];
    if (window != null && !networkWindows.contains(window)) window = null;
    DateTime? since = window == null ? DateTime.tryParse(q['since'] ?? '')?.toUtc() : null;
    DateTime? until = window == null ? DateTime.tryParse(q['until'] ?? '')?.toUtc() : null;
    if (since != null && until != null && !until.isAfter(since)) {
      since = null;
      until = null;
    }

    String? filter(String k, RegExp re, {bool lower = true}) {
      final v = q[k];
      if (v == null || v.isEmpty) return null;
      final x = lower ? v.toLowerCase() : v;
      return re.hasMatch(x) ? x : null;
    }

    NetworkRequest make(NetworkSection s,
            {String? node, String? hash, String? observer, String? channel, String? tab, String? tool, String? arg, bool pulse = false, DateTime? mapTime, String? observation}) =>
        NetworkRequest(
          section: s,
          region: region,
          nodeKey: node,
          packetHash: hash,
          observerId: observer,
          channelId: channel,
          window: window,
          since: since,
          until: until,
          analyticsTab: tab,
          tool: tool,
          toolArg: arg,
          pulse: pulse,
          mapTime: mapTime,
          observationId: observation,
        );

    // The region home `/` (and the old `/now`, `/home`) opens Live: the app has no Home section since build 72.
    if (segs.isEmpty) return make(NetworkSection.live);
    final head = segs.first.toLowerCase();
    final id = segs.length > 1 ? segs[1] : null;
    final third = segs.length > 2 ? segs[2] : null;
    if (segs.length > 3) return null;
    // Only `/tools/trace/<hash>` has three parts.
    if (third != null && !(head == 'tools' && id == 'trace')) return null;
    switch (head) {
      case 'now':
      case 'home':
        return id == null ? make(NetworkSection.live) : null;
      case 'pulse':
        return id == null ? make(NetworkSection.live, pulse: true) : null;
      case 'regions':
        return id == null ? make(NetworkSection.regions) : null;
      case 'packets':
        if (id == null) {
          final node = filter('node', _nodeKey), hash = filter('hash', _packetHash);
          final observer = filter('observer', _observer, lower: false), channel = filter('channel', _channel, lower: false);
          final rest = Map.of(q)
            ..remove('region')
            ..remove('window')
            ..remove('since')
            ..remove('until');
          if (node != null) rest.remove('node');
          if (hash != null) rest.remove('hash');
          if (observer != null) rest.remove('observer');
          if (channel != null) rest.remove('channel');
          final pf = PacketFilter.fromQuery(rest);
          final r = make(NetworkSection.packets, node: node, hash: hash, observer: observer, channel: channel);
          return pf.isEmpty ? r : r.withFilter(pf);
        }
        final h = id.toLowerCase();
        return _packetHash.hasMatch(h) ? make(NetworkSection.packets, hash: h) : null;
      case 'nodes':
      case 'repeaters':
        if (id == null) return make(NetworkSection.nodes);
        final k = id.toLowerCase();
        return _nodeKey.hasMatch(k) ? make(NetworkSection.nodes, node: k) : null;
      case 'observers':
        if (id == null) return make(NetworkSection.observers);
        if (id == 'compare') return make(NetworkSection.tools, tool: 'compare');
        // Outside observer ids carry a colon; first-party ids are 64-hex keys (either case accepted, contract 13.5).
        final o = _nodeKey.hasMatch(id.toLowerCase()) ? id.toLowerCase() : id;
        return _observer.hasMatch(o) ? make(NetworkSection.observers, observer: o) : null;
      case 'channels':
        if (id == null) return make(NetworkSection.channels);
        return _channel.hasMatch(id) ? make(NetworkSection.channels, channel: id) : null;
      case 'analytics':
        if (id == null) return make(NetworkSection.analytics);
        final slug = id.toLowerCase();
        if (!_tab.hasMatch(slug)) return null;
        // The Prefix Tool sits under /analytics on the site and is a native tool here.
        if (slug == 'prefix-tool') return make(NetworkSection.tools, tool: 'prefix', arg: filter('prefix', _toolArg));
        return make(NetworkSection.analytics, tab: slug);
      case 'insights':
      case 'analysis':
        // The site's Analytics replaced Insights: an old tab name opens its twin there.
        if (id != null) return null;
        final old = filter('tab', _tab);
        if (old == 'channels') return make(NetworkSection.channels);
        return make(NetworkSection.analytics, tab: old == null ? null : (legacyInsightsTabs[old] ?? 'overview'));
      case 'tools':
        if (id == null) return make(NetworkSection.tools);
        final name = id.toLowerCase();
        if (!_tab.hasMatch(name)) return null;
        if (name == 'trace') {
          if (third == null) return make(NetworkSection.tools, tool: 'trace');
          final h = third.toLowerCase();
          return _toolArg.hasMatch(h) ? make(NetworkSection.tools, tool: 'trace', arg: h) : null;
        }
        if (name == 'region') return make(NetworkSection.tools, tool: 'definition');
        if (name == 'path') return make(NetworkSection.tools, tool: 'path', arg: filter('hops', _toolArg, lower: false));
        return make(NetworkSection.tools, tool: name);
      case 'scope-audit':
        return id == null ? make(NetworkSection.tools, tool: 'scope-audit') : null;
      case 'status':
        return id == null ? make(NetworkSection.tools, tool: 'status') : null;
      case 'map':
      case 'live':
        // `/live` is the site's Live view; `/map?panel=live&packet=&t=` is the same map drawing one packet (links.replay).
        if (id != null) return null;
        final mt = DateTime.tryParse(q['t'] ?? q['at'] ?? '')?.toUtc();
        final ph = filter('packet', _packetHash);
        // One reception only makes sense with its packet.
        return make(NetworkSection.live, hash: ph, mapTime: mt, observation: ph == null ? null : filter('observation', _observation, lower: false));
      default:
        return null;
    }
  }

  /// This request with [f] as its [packetFilter] (null when empty).
  NetworkRequest withFilter(PacketFilter? f) => _copy(packetFilter: () => f == null || f.isEmpty ? null : f);

  // ---------------------------------------------------------------- serialising

  String get _path {
    switch (section) {
      case NetworkSection.regions:
        return '/regions';
      case NetworkSection.packets:
        return packetHash != null && !_hasListFilter ? '/packets/$packetHash' : '/packets';
      case NetworkSection.nodes:
        return nodeKey != null ? '/nodes/$nodeKey' : '/nodes';
      case NetworkSection.observers:
        return observerId != null ? '/observers/${Uri.encodeComponent(observerId!)}' : '/observers';
      case NetworkSection.channels:
        return channelId != null ? '/channels/${Uri.encodeComponent(channelId!)}' : '/channels';
      case NetworkSection.analytics:
        return analyticsTab != null ? '/analytics/$analyticsTab' : '/analytics';
      case NetworkSection.tools:
        final t = tool;
        if (t == null) return '/tools';
        if (t == 'trace' && toolArg != null) return '/tools/trace/$toolArg';
        return networkToolPaths[t] ?? '/tools/$t';
      case NetworkSection.live:
        if (packetHash != null || mapTime != null) return '/map';
        return pulse ? '/pulse' : '/live';
    }
  }

  Map<String, String> get _query {
    final q = <String, String>{};
    if (section == NetworkSection.packets && _path == '/packets') {
      final f = listFilter;
      q.addAll(f.toQuery());
      if (packetHash != null && f.hash == null) q['hash'] = packetHash!;
    }
    if (section == NetworkSection.tools && toolArg != null) {
      if (tool == 'prefix') q['prefix'] = toolArg!;
      if (tool == 'path') q['hops'] = toolArg!;
    }
    if (section == NetworkSection.live && _path == '/map') {
      q['panel'] = 'live';
      if (mapTime != null) q['t'] = mapTime!.toUtc().toIso8601String();
      if (packetHash != null) q['packet'] = packetHash!;
      if (packetHash != null && observationId != null) q['observation'] = observationId!;
    }
    if (window != null) {
      q['window'] = window!;
    } else {
      if (since != null) q['since'] = since!.toUtc().toIso8601String();
      if (until != null) q['until'] = until!.toUtc().toIso8601String();
    }
    return q;
  }

  /// The website link: the region's own host when there is a region (the site's address for that view), else the hub.
  Uri toWebUri() {
    final q = _query;
    return Uri(scheme: 'https', host: region == null ? networkApexHost : '$region.$networkApexHost', path: _path, queryParameters: q.isEmpty ? null : q);
  }

  /// The app link (`meshsonar://network/<route>?region=`), for places a web link would open the site instead.
  Uri toAppUri() {
    final q = {..._query, 'region': ?region};
    final p = _path == '/' ? '' : _path;
    return Uri(scheme: 'meshsonar', host: 'network', path: p, queryParameters: q.isEmpty ? null : q);
  }

  @override
  bool operator ==(Object other) =>
      other is NetworkRequest &&
      other.section == section &&
      other.region == region &&
      other.nodeKey == nodeKey &&
      other.packetHash == packetHash &&
      other.observerId == observerId &&
      other.channelId == channelId &&
      other.window == window &&
      other.since == since &&
      other.until == until &&
      other.analyticsTab == analyticsTab &&
      other.tool == tool &&
      other.toolArg == toolArg &&
      other.pulse == pulse &&
      other.packetFilter == packetFilter &&
      other.mapTime == mapTime &&
      other.observationId == observationId;

  @override
  int get hashCode => Object.hash(section, region, nodeKey, packetHash, observerId, channelId, window, since, until, analyticsTab, tool, toolArg, pulse, packetFilter, mapTime, observationId);

  @override
  String toString() => 'NetworkRequest(${section.name}${region == null ? '' : ' $region'})';
}
