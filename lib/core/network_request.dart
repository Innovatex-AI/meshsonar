// What a request to open the Network tab carries (AZ-3.1), in the style of PlanRequest (lib/ui/shell/shell_controller.dart):
// the section, the region, and optionally the node / packet / observer / channel it is about and a time window. It
// parses from and serialises to the website's routes (analyzer-api-contract.md section 8, the web route table:
// `/packets`, `/packets/:hash`, `/nodes`, `/nodes/:key` (old `/repeaters/*`), `/observers`, `/observers/:id`,
// `/channels`, `/channels/:id`, `/insights?tab=`, `/map?panel=`), so a shared web link opens the same view in the app and
// the app can share a link that opens on the site.
//
// Region: the region host sets it (`https://cmh.meshsonar.com/packets`), or `?region=<slug>` on the hub
// (`https://meshsonar.com/packets?region=cmh`), or `?region=` on the app scheme (`meshsonar://network/packets?region=cmh`).
// No region = whatever region the app is viewing. Serialising writes the region host form (the site's own address).
// Time window: `window=<15m..400d>` or `since` / `until` (RFC 3339), never both (contract 3.2).
//
// Pure Dart: no Flutter imports.
/// The five Network sections, in display order.
enum NetworkSection {
  now('Now'),
  packets('Packets'),
  nodes('Nodes'),
  map('Map'),
  insights('Insights');

  final String label;
  const NetworkSection(this.label);
}

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

  /// Insights tab (`/insights?tab=signal`), an open set of lowercase names.
  final String? insightsTab;

  /// Map panel (`/map?panel=live`).
  final String? mapPanel;

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
    this.insightsTab,
    this.mapPanel,
    this.observersList = false,
  });

  const NetworkRequest.section(this.section, {this.region, this.window})
      : nodeKey = null,
        packetHash = null,
        observerId = null,
        channelId = null,
        since = null,
        until = null,
        insightsTab = null,
        mapPanel = null,
        observersList = false;

  /// A node's page (Nodes section). [key] must be 64 hex.
  NetworkRequest.node(String key, {this.region})
      : section = NetworkSection.nodes,
        nodeKey = key.toLowerCase(),
        packetHash = null,
        observerId = null,
        channelId = null,
        window = null,
        since = null,
        until = null,
        insightsTab = null,
        mapPanel = null,
        observersList = false;

  /// A packet (Packets section). [hash] must be 16 hex.
  NetworkRequest.packet(String hash, {this.region})
      : section = NetworkSection.packets,
        packetHash = hash.toLowerCase(),
        nodeKey = null,
        observerId = null,
        channelId = null,
        window = null,
        since = null,
        until = null,
        insightsTab = null,
        mapPanel = null,
        observersList = false;

  /// An observer (Nodes section, Observers view).
  const NetworkRequest.observer(String this.observerId, {this.region})
      : section = NetworkSection.nodes,
        nodeKey = null,
        packetHash = null,
        channelId = null,
        window = null,
        since = null,
        until = null,
        insightsTab = null,
        mapPanel = null,
        observersList = false;

  /// A channel (Insights section, Channels tab: AZ-3.7 / AZ-3.9 fill it).
  const NetworkRequest.channel(String this.channelId, {this.region})
      : section = NetworkSection.insights,
        insightsTab = 'channels',
        nodeKey = null,
        packetHash = null,
        observerId = null,
        window = null,
        since = null,
        until = null,
        mapPanel = null,
        observersList = false;

  /// The request in a copy with another region (deep links that name none take the viewed one).
  NetworkRequest withRegion(String? r) => NetworkRequest(
      section: section,
      region: r,
      nodeKey: nodeKey,
      packetHash: packetHash,
      observerId: observerId,
      channelId: channelId,
      window: window,
      since: since,
      until: until,
      insightsTab: insightsTab,
      mapPanel: mapPanel,
      observersList: observersList);

  /// The `/observers` list (Nodes section, Observers view) rather than the node directory.
  final bool observersList;

  /// True when it asks for the Observers view of Nodes (an observer id, or the `/observers` list).
  bool get observersView => observerId != null || observersList;

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

    NetworkRequest make(NetworkSection s, {String? node, String? hash, String? observer, String? channel, String? tab, String? panel, bool observersList = false}) =>
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
          insightsTab: tab,
          mapPanel: panel,
          observersList: observersList,
        );

    if (segs.isEmpty) return make(NetworkSection.now);
    final head = segs.first.toLowerCase();
    final id = segs.length > 1 ? segs[1] : null;
    if (segs.length > 2) return null;
    switch (head) {
      case 'now':
        return id == null ? make(NetworkSection.now) : null;
      case 'packets':
        if (id == null) {
          return make(NetworkSection.packets,
              node: filter('node', _nodeKey), hash: filter('hash', _packetHash), observer: filter('observer', _observer, lower: false), channel: filter('channel', _channel, lower: false));
        }
        final h = id.toLowerCase();
        return _packetHash.hasMatch(h) ? make(NetworkSection.packets, hash: h) : null;
      case 'nodes':
      case 'repeaters':
        if (id == null) return make(NetworkSection.nodes);
        final k = id.toLowerCase();
        return _nodeKey.hasMatch(k) ? make(NetworkSection.nodes, node: k) : null;
      case 'observers':
        if (id == null || id == 'compare') return make(NetworkSection.nodes, observersList: true);
        // Outside observer ids carry a colon; first-party ids are 64-hex keys (either case accepted, contract 13.5).
        final o = _nodeKey.hasMatch(id.toLowerCase()) ? id.toLowerCase() : id;
        return _observer.hasMatch(o) ? make(NetworkSection.nodes, observer: o) : null;
      case 'channels':
        if (id == null) return make(NetworkSection.insights, tab: 'channels');
        return _channel.hasMatch(id) ? make(NetworkSection.insights, tab: 'channels', channel: id) : null;
      case 'insights':
      case 'analysis':
        if (id != null) return null;
        return make(NetworkSection.insights, tab: filter('tab', _tab));
      case 'map':
        if (id != null) return null;
        return make(NetworkSection.map, panel: filter('panel', _tab));
      case 'live':
        // The site's old Live page; the contract's route is /map?panel=live.
        return id == null ? make(NetworkSection.map, panel: 'live') : null;
      default:
        return null;
    }
  }


  // ---------------------------------------------------------------- serialising

  String get _path {
    switch (section) {
      case NetworkSection.now:
        return '/';
      case NetworkSection.packets:
        return packetHash != null && nodeKey == null && observerId == null && channelId == null ? '/packets/$packetHash' : '/packets';
      case NetworkSection.nodes:
        if (nodeKey != null) return '/nodes/$nodeKey';
        if (observerId != null) return '/observers/${Uri.encodeComponent(observerId!)}';
        return observersList ? '/observers' : '/nodes';
      case NetworkSection.insights:
        if (channelId != null) return '/channels/${Uri.encodeComponent(channelId!)}';
        if (insightsTab == 'channels') return '/channels';
        return '/insights';
      case NetworkSection.map:
        return '/map';
    }
  }

  Map<String, String> get _query {
    final q = <String, String>{};
    if (section == NetworkSection.packets && _path == '/packets') {
      if (nodeKey != null) q['node'] = nodeKey!;
      if (packetHash != null) q['hash'] = packetHash!;
      if (observerId != null) q['observer'] = observerId!;
      if (channelId != null) q['channel'] = channelId!;
    }
    if (section == NetworkSection.insights && insightsTab != null && insightsTab != 'channels') q['tab'] = insightsTab!;
    if (section == NetworkSection.map && mapPanel != null) q['panel'] = mapPanel!;
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
      other.insightsTab == insightsTab &&
      other.mapPanel == mapPanel &&
      other.observersList == observersList;

  @override
  int get hashCode => Object.hash(section, region, nodeKey, packetHash, observerId, channelId, window, since, until, insightsTab, mapPanel, observersList);

  @override
  String toString() => 'NetworkRequest(${section.name}${region == null ? '' : ' $region'})';
}
