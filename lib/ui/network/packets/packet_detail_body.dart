// The body of a packet detail (AZ-3.2), the same for every source (the network's `/v1` detail, today's region read,
// the phone's own radio, a pasted packet): summary header, the decoded message (Public and hashtag only), decoded
// fields by type, the resolved path with per-hop confidence said honestly, "show on map", the observations table, the
// byte inspector, and the source attribution. Screens wrap it (packet_detail_screen.dart, decode_packet_screen.dart).
// Small screen order (build 71): the first screen answers what, when, who heard it and how far: header facts, the
// message, then "Who heard it" (the first [packetObserversShown], the rest behind "Show all"). The long parts (every
// hop of every path, the byte inspector) sit behind tappable headers, closed until asked for ([expandSections] opens
// them from the start, for "Decode a packet" where the bytes are the point).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/v1/packets_api.dart';
import '../../app.dart' show AppScope;
import '../../design/app_surfaces.dart' show showAppToast;
import '../../map/layers/repeater_map_source.dart' show kRosterLayerId;
import '../../map/main_map_focus.dart';
import '../../map/still/path_layer.dart';
import '../../map/still/path_map.dart';
import '../../map/still/still_nodes.dart' show stillRepeatersOf;
import '../../region/region_common.dart' show RegionOfflineAsOf, clockUtc, dayUtc;
import '../../shell/shell_controller.dart' show ShellController;
import '../../theme.dart';
import 'byte_inspector.dart';
import 'packet_ui.dart';

/// The path of [d] to draw on its small map: the path with the most placed hops (the first on a tie), its hops numbered in order.
/// A unique hop is certain and a likely one is likely; ambiguous, unknown and other hops have no position and are not drawn.
/// Null when no hop of any path can be placed.
PathSpec? packetPathSpec(PacketDetail d) {
  PathSpec? best;
  var bestPlaced = 0;
  for (final p in d.paths) {
    final hops = <PathHop>[
      for (final h in p.hops)
        () {
          final pos = h.confidence == HopConfidence.unique || h.confidence == HopConfidence.likely ? h.position : null;
          return PathHop(
            n: h.index + 1,
            name: h.node?.label ?? h.prefix,
            lat: pos?.lat,
            lon: pos?.lon,
            certainty: h.confidence == HopConfidence.unique ? PathCertainty.certain : PathCertainty.likely,
          );
        }(),
    ];
    final placed = hops.where((h) => h.placed).length;
    if (placed > bestPlaced) {
      bestPlaced = placed;
      best = PathSpec(hops: hops);
    }
  }
  return best;
}

/// Extra lines a screen adds about other sources of the same packet.
class PacketCrossSource {
  /// "Your radio heard this too": the radio's SNR / RSSI and when (null = it did not hear it, or no radio).
  final ({double? snr, double? rssi, DateTime at})? radio;

  /// "Also heard by the network: N observers" (null = unknown or not on the server).
  final int? networkObservers;

  /// Opens the network's copy (shown with [networkObservers]).
  final VoidCallback? onOpenNetwork;
  const PacketCrossSource({this.radio, this.networkObservers, this.onOpenNetwork});
}

/// Observers listed before "Show all", and candidates listed under a hop several nodes share.
const int packetObserversShown = 5;
const int packetHopCandidatesShown = 3;

/// A long section of the packet page behind a tappable header (at least 48 pt), closed until asked for.
/// Keys: `packet-fold-<id>` on the header tile.
class PacketFold extends StatelessWidget {
  final String id, title;
  final String? subtitle;
  final bool initiallyExpanded;
  final List<Widget> children;
  const PacketFold({super.key, required this.id, required this.title, this.subtitle, this.initiallyExpanded = false, required this.children});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.s),
      child: Theme(
        data: t.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: Key('packet-fold-$id'),
          initiallyExpanded: initiallyExpanded,
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: Semantics(header: true, child: Text(title, style: t.textTheme.titleMedium)),
          subtitle: subtitle == null ? null : Text(subtitle!, key: Key('packet-fold-$id-summary'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          children: children,
        ),
      ),
    );
  }
}

/// "Who heard it": the first [packetObserversShown] observers, the rest behind "Show all N".
class _ObserverList extends StatefulWidget {
  final PacketDetail d;
  final VoidCallback? onLoadMore;
  final bool loadingMore;
  const _ObserverList({required this.d, this.onLoadMore, this.loadingMore = false});
  @override
  State<_ObserverList> createState() => _ObserverListState();
}

class _ObserverListState extends State<_ObserverList> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final rows = _all ? d.observations : d.observations.take(packetObserversShown).toList();
    final hidden = d.observations.length - rows.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PacketSectionTitle('Who heard it (${d.observationCount})'),
      if (d.observationsExpired)
        const PacketNote('The per-observer rows of this packet are older than 14 days and were removed; the counts above are kept.'),
      for (final o in rows)
        Container(
          key: ValueKey('packet-obs-${o.id}'),
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.colorScheme.outlineVariant.withValues(alpha: 0.5)))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text('${o.observer.name}${o.observer.kind == 'outside' ? ' (outside feed)' : (o.observer.kind == 'phone' ? ' (phone)' : '')}',
                    style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              ),
              if (o.snr != null) Text(snrText(o.snr), style: t.textTheme.labelLarge?.copyWith(color: snrColor(context, o.snr!))),
            ]),
            Text(
              [
                clockUtc(o.at),
                if (o.rssi != null) '${o.rssi!.round()} dBm',
                // a long path would fill the row: say how far it came; the hops themselves are under Paths
                o.path.isEmpty ? 'heard direct' : (o.path.length > 6 ? 'after ${o.path.length} hops' : 'path ${o.path.join(' > ')}'),
              ].join(' · '),
              style: muted,
            ),
          ]),
        ),
      if (hidden > 0)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(key: const Key('packet-obs-all'), onPressed: () => setState(() => _all = true), child: Text('Show all ${d.observations.length} listed')),
        ),
      if ((_all || hidden == 0) && d.observationsNext != null && widget.onLoadMore != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('packet-obs-more'),
            onPressed: widget.loadingMore ? null : widget.onLoadMore,
            child: Text(widget.loadingMore ? 'Loading…' : 'Show more observers'),
          ),
        ),
    ]);
  }
}

class PacketDetailBody extends StatelessWidget {
  final PacketDetail d;
  final Map<String, V1Source> sources;
  final PacketCrossSource cross;

  /// Bytes from another source when [d] has none (today's region read + the radio heard it).
  final PacketDetail? bytesFrom;
  final bool? nodeListTrusted;
  final String? nodeListReason;
  final VoidCallback? onLoadMoreObservations;
  final bool loadingMore;
  final VoidCallback? onRetry;

  /// The website twin of this view.
  final Uri? web;
  final DateTime Function() clock;

  /// Draws this packet's path on the live map (Network > Map, AZ-3.3); null for a packet the network has no copy of
  /// (the phone's own radio, a pasted packet), which opens the map around its named hops instead.
  final VoidCallback? onShowOnMap;

  /// The region this packet was read from; with it the route map draws that region's loaded repeaters behind the path (when the
  /// app is viewing the same region). Null (a pasted or radio packet) = none.
  final String? regionSlug;

  /// Start with Paths and Bytes open (the decode tool, and tests that read them).
  final bool expandSections;
  const PacketDetailBody({
    this.onShowOnMap,
    this.regionSlug,
    this.expandSections = false,
    super.key,
    required this.d,
    this.sources = const {},
    this.cross = const PacketCrossSource(),
    this.bytesFrom,
    this.nodeListTrusted,
    this.nodeListReason,
    this.onLoadMoreObservations,
    this.loadingMore = false,
    this.onRetry,
    this.web,
    this.clock = DateTime.now,
  });

  @override
  Widget build(BuildContext context) {
    final inspect = d.hasBytes ? d : (bytesFrom?.hasBytes == true ? bytesFrom : null);
    final fields = d.decoded.isNotEmpty ? d : (bytesFrom ?? d);
    return ListView(
      key: const Key('packet-detail-body'),
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl * 2),
      children: [
        if (d.offlineAsOf != null) RegionOfflineAsOf(asOf: d.offlineAsOf!, onRetry: onRetry),
        _header(context),
        if (cross.radio != null)
          PacketNote(
            'Your radio heard this too: ${snrText(cross.radio!.snr)}${cross.radio!.rssi == null ? '' : ', ${cross.radio!.rssi!.round()} dBm'}, at ${clockUtc(cross.radio!.at)}.',
            key: const Key('packet-radio-heard'),
            icon: Icons.settings_input_antenna,
          ),
        if (cross.networkObservers != null)
          Container(
            key: const Key('packet-network-heard'),
            child: PacketNote(
              'Also heard by the network: ${cross.networkObservers} observer${cross.networkObservers == 1 ? '' : 's'}.',
              icon: Icons.hub_outlined,
            ),
          ),
        if (cross.networkObservers != null && cross.onOpenNetwork != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(key: const Key('packet-open-network'), onPressed: cross.onOpenNetwork, child: const Text("Open the network's copy")),
          ),
        if (d.anomaly != null) PacketNote(d.anomaly!, icon: Icons.warning_amber_rounded),
        for (final m in d.missing) PacketNote(m, key: ValueKey('packet-missing-$m')),
        if (d.message != null) _message(context, d.message!),
        if (d.observations.isNotEmpty || d.observationsExpired || d.observationCount > 0) _observations(context),
        if (fields.decoded.isNotEmpty) ...[
          const PacketSectionTitle('Decoded'),
          ..._decodedRows(context, fields),
        ],
        if (d.paths.isNotEmpty || d.type == 9) _paths(context),
        PacketFold(
          id: 'bytes',
          title: 'Bytes',
          subtitle: inspect?.raw == null ? 'Not sent by this source' : '${inspect!.raw!.length ~/ 2} bytes, every field labelled',
          initiallyExpanded: expandSections,
          children: [
            if (inspect != null) ...[
              if (inspect != d) const PacketNote('These bytes are from your radio: this server does not send packet bytes yet.', key: Key('packet-bytes-from-radio')),
              if (inspect.source == PacketSource.v1 && !inspect.rawVerified)
                const PacketNote('The server could not confirm these bytes against the packet hash.', icon: Icons.warning_amber_rounded),
              ByteInspector(key: ValueKey('inspector-${inspect.hash}'), raw: inspect.raw!, ranges: inspect.bytes),
            ] else
              const PacketNote('No bytes to show for this packet from this source.', key: Key('packet-no-bytes')),
          ],
        ),
        if (sources.isNotEmpty) _attribution(context),
        if (web != null) WebTwinLine(web!),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final t = Theme.of(context);
    final now = clock().toUtc();
    final srcNames = [for (final s in d.src) sources[s]?.name ?? s];
    final sourceText = switch (d.source) {
      PacketSource.myRadio => 'Your radio',
      PacketSource.pasted => 'Pasted, decoded on this phone',
      PacketSource.serverDecode => 'Pasted, decoded by the MeshSonar server',
      _ => srcNames.isEmpty ? 'MeshSonar' : srcNames.join(', '),
    };
    final facts = <(String, String)>[
      ('Type', packetTypeLabel(d.typeName)),
      ('Route', packetRouteLabel(d.route)),
      if (d.firstSeen != null) ('Heard', '${dayUtc(d.firstSeen)} (${ageText(d.firstSeen!, now)} ago)'),
      if (d.size != null) ('Size', '${d.size} bytes'),
      ('Hops', d.type == 9 ? '${(d.decodedFields['hopsCompleted'] ?? d.hops)} completed' : (d.hops == 0 ? 'none (heard direct)' : '${d.hops}')),
      if (d.hashSize != null && d.hashSize! > 0) ('Hop code size', '${d.hashSize} byte${d.hashSize == 1 ? '' : 's'}'),
      if (d.source == PacketSource.v1 || d.source == PacketSource.legacy) ('Observers', '${d.observerCount}'),
      if (d.localSnr != null) ('SNR here', snrText(d.localSnr)),
      ('Source', sourceText),
      if (d.scope != null) ('Scope', d.scope!.label),
      if (d.channel != null) ('Channel', d.channel!.label),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_title(), key: const Key('packet-detail-title'), style: t.textTheme.titleLarge),
      const SizedBox(height: Gap.xs),
      Row(children: [
        Expanded(child: SelectableText(d.hash, key: const Key('packet-detail-hash'), style: t.textTheme.bodyMedium?.copyWith(fontFamily: 'Menlo', fontFamilyFallback: const ['Courier', 'monospace']))),
        IconButton(
          key: const Key('packet-copy-hash'),
          tooltip: 'Copy the packet hash',
          icon: const Icon(Icons.copy, size: 20),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: d.hash));
            showAppToast(context, 'Hash copied');
          },
        ),
      ]),
      const SizedBox(height: Gap.xs),
      for (final f in facts)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 120, child: Text(f.$1, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
            Expanded(child: Text(f.$2, style: t.textTheme.bodyMedium)),
          ]),
        ),
    ]);
  }

  String _title() {
    final t = packetTypeLabel(d.typeName);
    if (d.origin?.name != null) return '$t: ${d.origin!.name}';
    if (d.channel != null && (d.typeName == 'GRP_TXT' || d.typeName == 'GRP_DATA')) return '$t on ${d.channel!.label}';
    return t;
  }

  Widget _message(BuildContext context, PacketMessage m) {
    final t = Theme.of(context);
    return Container(
      key: const Key('packet-message'),
      margin: const EdgeInsets.only(top: Gap.m),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.card)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(m.channel.label, style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary)),
        if (m.sender != null) Text('Says it is ${m.sender}', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xs),
        Text(m.hidden || m.text == null ? 'This message is hidden.' : m.text!, style: t.textTheme.bodyLarge),
        const SizedBox(height: Gap.xs),
        Text('Anyone with the channel key can write any name: the sender is not verified.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  List<Widget> _decodedRows(BuildContext context, PacketDetail src) {
    final f = src.decodedFields;
    String? s(String k) => f[k] is String && (f[k] as String).isNotEmpty ? f[k] as String : null;
    String names(Object? v) => [if (v is List) for (final n in v) if (n is Map) (n['name'] ?? n['key'] ?? '').toString()].where((e) => e.isNotEmpty).join(', ');
    final rows = <(String, String)>[];
    switch (src.decodedKind) {
      case 'advert':
        final sig = f['signature'] is Map ? f['signature'] as Map : const {};
        final pos = f['position'] is Map ? f['position'] as Map : null;
        rows.addAll([
          if (s('name') != null) ('Name', s('name')!),
          ('Role', s('role') ?? 'unknown'),
          if (s('publicKey') != null) ('Public key', s('publicKey')!),
          ('Position', pos == null ? 'not advertised' : '${pos['lat']}, ${pos['lon']}'),
          if (s('timestamp') != null) ('Advert time', dayUtc(DateTime.tryParse(s('timestamp')!))),
          ('Signature', sig['checked'] == true ? (sig['valid'] == true ? 'Valid' : 'Not valid') : 'Not checked on the phone'),
          if (f['clockSkewS'] is num) ('Clock', '${(f['clockSkewS'] as num).round()} s ${(f['clockSkewS'] as num) >= 0 ? 'ahead' : 'behind'}'),
          if (f['battery'] is num) ('Battery', '${f['battery']} mV'),
          if (f['temperatureC'] is num) ('Temperature', AppScope.unitsOf(context).temperature((f['temperatureC'] as num).toDouble())),
        ]);
      case 'group':
        final pt = f['plaintext'] is Map ? f['plaintext'] as Map : null;
        rows.addAll([
          ('Status', byteValueText(s('decodeStatus'))),
          if (s('keySource') != null) ('Key', switch (s('keySource')) { 'builtin_public' => 'The Public channel key', 'hashtag_list' => 'Hashtag channel key (from its name)', _ => s('keySource')! }),
          if (s('channelHash') != null) ('Channel hash', s('channelHash')!),
          if (s('mac') != null) ('MAC', s('mac')!),
          if (pt != null && pt['timestamp'] is String) ('Sent (sender clock)', dayUtc(DateTime.tryParse(pt['timestamp'] as String))),
          if (pt != null && pt['data'] is String) ('Data', pt['data'] as String),
          if (s('note') != null) ('Note', s('note')!),
        ]);
      case 'direct':
        rows.addAll([
          ('Destination hash', '${s('destHash') ?? '?'}${names(f['destCandidates']).isEmpty ? '' : ' (could be ${names(f['destCandidates'])})'}'),
          ('Source hash', '${s('srcHash') ?? '?'}${names(f['srcCandidates']).isEmpty ? '' : ' (could be ${names(f['srcCandidates'])})'}'),
          if (s('mac') != null) ('MAC', s('mac')!),
          ('Content', 'Encrypted end to end'),
          if (s('note') != null) ('Note', s('note')!),
        ]);
      case 'anonReq':
        final sender = f['sender'] is Map ? (f['sender'] as Map)['name'] : null;
        rows.addAll([
          ('Destination hash', s('destHash') ?? '?'),
          ('Sender key', s('senderKey') ?? '?'),
          if (sender is String) ('Sender', sender),
          ('Content', 'Encrypted end to end'),
        ]);
      case 'ack':
        rows.add(('Checksum', s('crc') ?? 'cut short'));
      case 'trace':
        final snr = [if (f['snr'] is List) for (final v in f['snr'] as List) if (v is num) v.toDouble()];
        rows.addAll([
          ('Tag', s('tag') ?? '?'),
          ('Auth code', '${f['authCode'] ?? '?'}'),
          ('Hop code size', '${f['hashSize'] ?? '?'} byte'),
          ('Targets', [if (f['targets'] is List) ...(f['targets'] as List).map((e) => '$e')].join(' > ')),
          ('Hops completed', '${f['hopsCompleted'] ?? snr.length}'),
          if (snr.isNotEmpty) ('SNR per hop', snr.map(snrText).join(', ')),
        ]);
      case 'control':
        rows.addAll([for (final e in f.entries) if (e.value != null) (e.key, byteValueText(e.value))]);
      case 'multipart':
        rows.addAll([('Remaining', '${f['remaining'] ?? '?'}'), ('Inner type', '${f['innerType'] ?? '?'}')]);
      default:
        rows.addAll([for (final e in f.entries) if (e.value != null) (e.key, byteValueText(e.value))]);
    }
    final t = Theme.of(context);
    return [
      for (final r in rows)
        Padding(
          key: ValueKey('decoded-${r.$1}'),
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 120, child: Text(r.$1, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
            Expanded(child: Text(r.$2, style: t.textTheme.bodyMedium)),
          ]),
        ),
    ];
  }

  Widget _paths(BuildContext context) {
    final t = Theme.of(context);
    final positions = <LatLng>[
      for (final p in d.paths)
        for (final h in p.hops)
          if (h.position != null) LatLng(h.position!.lat, h.position!.lon)
    ];
    final longest = d.paths.fold<int>(0, (m, p) => p.hops.length > m ? p.hops.length : m);
    final named = d.paths.fold<int>(0, (m, p) => m + p.hops.where((h) => h.confidence == HopConfidence.unique || h.confidence == HopConfidence.likely).length);
    final total = d.paths.fold<int>(0, (m, p) => m + p.hops.length);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PacketFold(
        id: 'paths',
        title: d.type == 9 ? 'Trace hops' : (d.paths.length > 1 ? 'Paths (${d.paths.length})' : 'Path'),
        subtitle: d.paths.isEmpty
            ? 'No hops: heard straight from its sender'
            : '${d.paths.length > 1 ? 'Up to $longest' : '$longest'} ${longest == 1 ? 'hop' : 'hops'} · $named of $total named',
        initiallyExpanded: expandSections,
        children: [
          if (nodeListTrusted == false)
            PacketNote(plainServerText(nodeListReason) ?? 'The node list is not complete here, so no hop is named with more than "likely".', icon: Icons.rule),
          for (final p in d.paths) _path(context, p),
          if (d.paths.isEmpty) const PacketNote('No hops: the packet was heard straight from its sender.'),
        ],
      ),
      ..._pathMap(context),
      const SizedBox(height: Gap.s),
      if (onShowOnMap != null)
        OutlinedButton.icon(
          key: const Key('packet-show-on-map'),
          icon: const Icon(Icons.route),
          label: const Text('Show the path on the live map'),
          onPressed: onShowOnMap,
        )
      else if (positions.isNotEmpty)
        OutlinedButton.icon(
          key: const Key('packet-show-on-map'),
          icon: const Icon(Icons.map_outlined),
          label: const Text('Show this area on the map'),
          onPressed: () {
            final c = LatLng(positions.map((e) => e.latitude).reduce((a, b) => a + b) / positions.length,
                positions.map((e) => e.longitude).reduce((a, b) => a + b) / positions.length);
            MainMapFocus.request(c, 11, showLayers: const {kRosterLayerId});
            final shell = ShellController.of(context);
            Navigator.of(context).popUntil((r) => r.isFirst);
            shell?.openDrive();
          },
        ),
      Text(
        onShowOnMap != null
            ? 'Draws it from its origin through the relays to each observer: solid for hops known for sure, dashed for likely ones, faint grey for hops nobody can place.'
            : (positions.isNotEmpty
                ? 'Opens the map around the named hops. The network has no copy of this packet to draw on the live map.'
                : 'The network has no copy of this packet to draw on the live map.'),
        key: const Key('packet-map-note'),
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
    ]);
  }

  /// MAP slice 5: the packet's route on a small map (page `path`): the numbered, named hops, solid for a hop known for sure and
  /// dashed for a likely one. A hop nobody can place keeps its number, is listed in the Path section and breaks the line. Needs
  /// the definition's `symbols.path`; without it the page is what build 73 showed (no map). Draws the path with the
  /// most placed hops ([packetPathSpec]); the observers' positions are not in the packet detail, so none is drawn.
  List<Widget> _pathMap(BuildContext context) {
    final style = activePathStyle();
    if (style == null || d.paths.isEmpty) return const [];
    final spec = packetPathSpec(d);
    if (spec == null) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: Gap.s),
        child: StillPathMap(
          key: const Key('packet-path-map'),
          spec: spec,
          style: style,
          semanticLabel: 'Map of the route: ${spec.placed.length} of ${spec.hops.length} hops have a position.',
          repeaters: stillRepeatersOf(context, regionSlug: regionSlug),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: Gap.xs),
        child: PathKey(style: style, unplaced: spec.unplaced.length, total: spec.hops.length),
      ),
    ];
  }

  Widget _path(BuildContext context, PacketPath p) {
    final t = Theme.of(context);
    final heardBy = [for (final o in d.observations) if (o.pathId == p.id) o.observer.name];
    return Container(
      key: ValueKey('packet-path-${p.id}'),
      margin: const EdgeInsets.only(bottom: Gap.s),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(border: Border.all(color: t.colorScheme.outlineVariant), borderRadius: BorderRadius.circular(Corners.chip)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          p.direction == 'remaining' ? 'Route still ahead (a direct packet: each hop removes itself)' : 'Hops travelled, first repeater first',
          style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        if (heardBy.isNotEmpty) Text('Heard this way by ${heardBy.toSet().join(', ')}', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        for (final h in p.hops) _hop(context, p, h),
      ]),
    );
  }

  Widget _hop(BuildContext context, PacketPath p, PacketHop h) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    String score(double? s) => s == null ? '' : ' (${(s.clamp(0.0, 1.0) * 100).round()}% likely)';
    final line = switch (h.confidence) {
      HopConfidence.unique => h.node?.label ?? 'One node has this code',
      HopConfidence.likely => '${h.node?.label ?? 'A node'}${score(h.score)}',
      HopConfidence.ambiguous => '${h.candidatesTotal > 0 ? h.candidatesTotal : 'Several'} nodes share this code; none is clearly the one',
      HopConfidence.unknown =>
        h.evidence.contains('not_resolved_on_phone') ? 'Not matched on the phone' : (h.evidence.contains('outside_region') ? 'Outside this region' : 'No known node has this code'),
      HopConfidence.other => 'Not known to this app version',
    };
    final shown = h.confidence == HopConfidence.ambiguous ? h.candidates : const <HopCandidate>[];
    return Semantics(
      container: true,
      label: 'Hop ${h.index + 1}, code ${h.prefix}, ${HopConfidenceBadge.label(h.confidence)}: $line${h.snrDb == null ? '' : ', SNR ${snrText(h.snrDb)}'}',
      child: ExcludeSemantics(
        child: Padding(
          key: ValueKey('packet-hop-${p.id}-${h.index}'),
          padding: const EdgeInsets.only(top: Gap.s),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${h.index + 1}', style: t.textTheme.labelLarge),
              Text(h.prefix, style: t.textTheme.bodyMedium?.copyWith(fontFamily: 'Menlo', fontFamilyFallback: const ['Courier', 'monospace'])),
              HopConfidenceBadge(h.confidence),
              if (h.snrDb != null) Text(snrText(h.snrDb), style: t.textTheme.labelMedium?.copyWith(color: snrColor(context, h.snrDb!))),
            ]),
            Text(line, style: t.textTheme.bodyMedium),
            for (final c in shown.take(packetHopCandidatesShown))
              Padding(
                padding: const EdgeInsets.only(left: Gap.m, top: 2),
                child: Text(
                  '${c.node.label}${c.score == null ? '' : ', ${(c.score!.clamp(0.0, 1.0) * 100).round()}% likely'}${c.distanceKm == null ? '' : ', ${AppScope.unitsOf(context).distance(c.distanceKm! * 1000)} away'}',
                  style: muted,
                ),
              ),
            if (h.confidence == HopConfidence.ambiguous && h.candidatesTotal > shown.take(packetHopCandidatesShown).length)
              Padding(padding: const EdgeInsets.only(left: Gap.m), child: Text('and ${h.candidatesTotal - shown.take(packetHopCandidatesShown).length} more', style: muted)),
          ]),
        ),
      ),
    );
  }

  Widget _observations(BuildContext context) => _ObserverList(d: d, onLoadMore: onLoadMoreObservations, loadingMore: loadingMore);

  Widget _attribution(BuildContext context) {
    final t = Theme.of(context);
    final used = [for (final s in d.src) ?sources[s]];
    if (used.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PacketSectionTitle('Sources'),
      for (final s in used) Text('${s.name}: ${s.attribution.isEmpty ? s.url : s.attribution}', style: t.textTheme.bodySmall),
    ]);
  }
}
