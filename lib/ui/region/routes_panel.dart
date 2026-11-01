// The Routes tab of the Region hub: the website's /network/routes (flood routes), native. Two views:
//   One packet  - pick a recent flood or paste a 16-hex packet hash and see how it spread (flood_trace_view.dart);
//   All floods  - who carries the floods over the last 24 hours or 7 days: carry share, the corridors floods use, how far
//                 they travel and where they stop, measured hops on a map, 1-byte hash collisions.
// Data: `tool-routes` (lib/core/flood_routes_api.dart), cached by the ETag client so the last good answer works offline.
// Paths are only what this region's observers decoded; 1-byte hop hashes are resolved by the server, never guessed.
// Not here: the website's "Simulate" view (it scores links on the Columbus-only terrain grid and the planner's modeled links), and
// the aggregate's comparison against the planner's modeled links; both belong to the planning tools, not to measured network data.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../core/flood_routes_api.dart';
import '../../core/region_cache.dart' show asOfLabel;
import '../../core/region_dataset_fetch.dart';
import '../charts/bar_chart.dart';
import '../charts/chart_frame.dart';
import '../map/coverage_map.dart';
import '../theme.dart';
import 'flood_trace_view.dart';
import 'region_common.dart' show groupInt;

enum RoutesView { packet, all }

String _pct(double x, {int digits = 1}) => x > 0 && x < 0.001 ? '<0.1%' : '${(x * 100).toStringAsFixed(digits)}%';

/// Opens the Routes screen on its own (from the Trace screen and the packet detail), already tracing [hash] when given.
Future<void> openFloodRoutes(BuildContext context, {required String baseUrl, required String regionSlug, String? hash}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Flood routes')),
        body: RoutesPanel(baseUrl: baseUrl, regionSlug: regionSlug, initialHash: hash),
      ),
    ));

class RoutesPanel extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;
  final String? initialHash;
  final http.Client? client;
  final bool tiles;
  const RoutesPanel({super.key, required this.baseUrl, required this.regionSlug, this.initialHash, this.client, this.tiles = true});

  @override
  State<RoutesPanel> createState() => _RoutesPanelState();
}

class _RoutesPanelState extends State<RoutesPanel> {
  late final FloodRoutesApi _api = FloodRoutesApi(widget.baseUrl, client: widget.client);
  RoutesView _view = RoutesView.packet;
  final _hashCtl = TextEditingController();
  String? _hashError;
  String? _hash;
  Future<RegionFetch<RecentFloods>>? _recent;
  Future<RegionFetch<FloodTrace>>? _trace;
  int _hours = 24;
  Future<RegionFetch<FloodAggregate>>? _agg;
  bool _autoPicked = false;

  @override
  void initState() {
    super.initState();
    _recent = _api.recent();
    final h = widget.initialHash == null ? null : normalizePacketHash(widget.initialHash!);
    if (h != null) _select(h);
  }

  @override
  void didUpdateWidget(RoutesPanel old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl) {
      _hash = null;
      _trace = null;
      _agg = null;
      _autoPicked = false;
      _recent = FloodRoutesApi(widget.baseUrl, client: widget.client).recent();
    }
  }

  @override
  void dispose() {
    _hashCtl.dispose();
    super.dispose();
  }

  void _select(String hash) {
    setState(() {
      _hash = hash;
      _hashCtl.text = hash;
      _hashError = null;
      _trace = _api.trace(hash);
    });
  }

  void _submit() {
    final h = normalizePacketHash(_hashCtl.text);
    if (h == null) {
      setState(() => _hashError = 'A packet hash is 16 hex characters, e.g. 73af46d9fd880617.');
      return;
    }
    _select(h);
  }

  void _loadAgg() => setState(() {
        _agg = _api.aggregate(_hours);
      });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListView(
      key: const Key('routes-list'),
      padding: const EdgeInsets.all(Gap.l),
      children: [
        Text('Flood routes', style: t.textTheme.titleLarge),
        const SizedBox(height: 2),
        Text(
          'How a flood packet spreads through the mesh. Paths are only what ${widget.regionSlug.toUpperCase()} observers decoded; 1-byte hop hashes are resolved by the server, never guessed.',
          style: t.textTheme.bodySmall?.copyWith(color: MeshSonarColors.of(context).textMuted),
        ),
        const SizedBox(height: Gap.s),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<RoutesView>(
            key: const Key('routes-views'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: RoutesView.packet, label: Text('One packet'), icon: Icon(Icons.alt_route)),
              ButtonSegment(value: RoutesView.all, label: Text('All floods'), icon: Icon(Icons.hub_outlined)),
            ],
            selected: {_view},
            onSelectionChanged: (v) {
              setState(() => _view = v.first);
              if (_view == RoutesView.all && _agg == null) _loadAgg();
            },
          ),
        ),
        const SizedBox(height: Gap.m),
        if (_view == RoutesView.packet) ..._packetView(context) else ..._allView(context),
      ],
    );
  }

  // ---------------------------------------------------------------- one packet
  List<Widget> _packetView(BuildContext context) {
    final t = Theme.of(context);
    return [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: TextField(
            key: const Key('routes-hash'),
            controller: _hashCtl,
            decoration: InputDecoration(labelText: 'Packet hash', hintText: '16 hex characters', errorText: _hashError, isDense: true),
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: Gap.s),
        FilledButton.icon(key: const Key('routes-trace'), onPressed: _submit, icon: const Icon(Icons.search), label: const Text('Trace')),
      ]),
      const SizedBox(height: Gap.m),
      FutureBuilder<RegionFetch<RecentFloods>>(
        future: _recent,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(padding: EdgeInsets.all(Gap.l), child: Center(child: CircularProgressIndicator(key: Key('routes-recent-loading'))));
          }
          final r = snap.data;
          if (r == null || !r.ok) {
            return _notice(context, 'routes-recent-error', Icons.cloud_off, 'Recent floods could not load. ${r?.error ?? snap.error ?? ''}', () => setState(() {
                  _recent = _api.recent();
                }));
          }
          final d = r.data!;
          if (d.unavailable) {
            return _notice(context, 'routes-nofeed', Icons.info_outline,
                'Single-packet lookup is not available for this region yet: it needs an outside flood feed that has no data here. Packets heard by our own observers, with their paths, are on the Packets tab.', null);
          }
          if (!_autoPicked && _hash == null && d.best != null) {
            _autoPicked = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _hash == null) _select(d.best!.hash);
            });
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (r.offlineAsOf != null) _offline(context, r.offlineAsOf!),
            Theme(
              data: t.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const Key('routes-recent'),
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: false,
                title: Text('Recent floods (${d.packets.length} in 24 h)', style: t.textTheme.titleSmall),
                children: [
                  if (d.packets.isEmpty) const Padding(padding: EdgeInsets.all(Gap.m), child: Text('No flood packets in the last 24 hours.')),
                  for (final p in d.packets.take(60))
                    ListTile(
                      key: Key('routes-recent-${p.hash}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      selected: p.hash == _hash,
                      leading: CircleAvatar(radius: 16, child: Text('${p.hops}', style: const TextStyle(fontSize: 13))),
                      title: Text('${floodPayloadName(p.payloadType)}${p.originName == null ? '' : ' from ${p.originName}'}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${clockUtc(p.firstSeen)}, ${p.observations} observation${p.observations == 1 ? '' : 's'}${p.firstRelayName == null ? '' : ', via ${p.firstRelayName}'}'),
                      onTap: () => _select(p.hash),
                    ),
                ],
              ),
            ),
          ]);
        },
      ),
      const SizedBox(height: Gap.s),
      if (_trace == null)
        const Text('Pick a recent flood or paste a hash to draw how it spread.', key: Key('routes-choose'))
      else
        FutureBuilder<RegionFetch<FloodTrace>>(
          key: ValueKey(_hash),
          future: _trace,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator(key: Key('routes-trace-loading'))));
            }
            final r = snap.data;
            if (r == null || !r.ok) {
              return _notice(
                context,
                r?.notFound == true ? 'routes-trace-notfound' : 'routes-trace-error',
                r?.notFound == true ? Icons.search_off : Icons.cloud_off,
                r?.notFound == true
                    ? 'No packet with that hash was found, or this region has no outside flood feed to look it up in.'
                    : 'The trace could not load. ${r?.error ?? snap.error ?? ''}',
                r?.notFound == true ? null : () => _select(_hash!),
              );
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (r.offlineAsOf != null) _offline(context, r.offlineAsOf!),
              FloodTraceView(trace: r.data!, tiles: widget.tiles),
            ]);
          },
        ),
    ];
  }

  // ---------------------------------------------------------------- all floods
  List<Widget> _allView(BuildContext context) {
    return [
      Row(children: [
        Expanded(
          child: SegmentedButton<int>(
            key: const Key('routes-hours'),
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: 24, label: Text('24 hours')), ButtonSegment(value: 168, label: Text('7 days'))],
            selected: {_hours},
            onSelectionChanged: (v) {
              _hours = v.first;
              _loadAgg();
            },
          ),
        ),
        IconButton(key: const Key('routes-refresh'), tooltip: 'Refresh', onPressed: _loadAgg, icon: const Icon(Icons.refresh)),
      ]),
      const SizedBox(height: Gap.s),
      FutureBuilder<RegionFetch<FloodAggregate>>(
        key: ValueKey(_agg),
        future: _agg,
        builder: (context, snap) {
          if (_agg == null || snap.connectionState != ConnectionState.done) {
            return Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Column(children: [
                const CircularProgressIndicator(key: Key('routes-agg-loading')),
                const SizedBox(height: Gap.s),
                Text('Pulling ${_hours == 168 ? '7 days' : '24 hours'} of floods and every observation${_hours == 168 ? ' (about 15 seconds)' : ''}', textAlign: TextAlign.center),
              ]),
            );
          }
          final r = snap.data;
          if (r == null || !r.ok) {
            return _notice(
              context,
              r?.notFound == true ? 'routes-agg-nofeed' : 'routes-agg-error',
              r?.notFound == true ? Icons.info_outline : Icons.cloud_off,
              r?.notFound == true ? 'Flood paths are not available for this region yet: they need an outside flood feed that has no data here.' : 'Flood paths could not load. ${r?.error ?? snap.error ?? ''}',
              r?.notFound == true ? null : _loadAgg,
            );
          }
          final d = r.data!;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (r.offlineAsOf != null) _offline(context, r.offlineAsOf!),
            if (d.hashes == 0)
              const Padding(padding: EdgeInsets.all(Gap.l), child: Text('No flood packets in this window.', key: Key('routes-agg-empty')))
            else
              _Aggregate(d: d, tiles: widget.tiles),
          ]);
        },
      ),
    ];
  }

  Widget _offline(BuildContext context, DateTime asOf) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.s),
        child: Row(key: const Key('routes-offline'), children: [
          Icon(Icons.cloud_off, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(child: Text(asOfLabel(asOf, DateTime.now().toUtc(), offline: true), style: Theme.of(context).textTheme.labelMedium)),
        ]),
      );

  Widget _notice(BuildContext context, String key, IconData icon, String text, VoidCallback? retry) => Padding(
        key: Key(key),
        padding: const EdgeInsets.symmetric(vertical: Gap.m),
        child: Row(children: [
          Icon(icon),
          const SizedBox(width: Gap.m),
          Expanded(child: Text(text)),
          if (retry != null) TextButton(onPressed: retry, child: const Text('Retry')),
        ]),
      );
}

class _Aggregate extends StatefulWidget {
  final FloodAggregate d;
  final bool tiles;
  const _Aggregate({required this.d, required this.tiles});
  @override
  State<_Aggregate> createState() => _AggregateState();
}

class _AggregateState extends State<_Aggregate> {
  bool _allCarry = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final win = d.hours == 168 ? '7 days' : '24 hours';
    final resolved = d.resolvedShare;
    Widget section(String title, Widget child, {String? lead, String? key}) => Padding(
          key: key == null ? null : Key(key),
          padding: const EdgeInsets.only(top: Gap.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.textTheme.titleMedium),
            if (lead != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(lead, style: t.textTheme.bodySmall?.copyWith(color: m.textMuted))),
            const SizedBox(height: Gap.s),
            child,
          ]),
        );
    final carry = [for (final c in d.carry) if (!c.id.startsWith('hop:')) c];
    final shownCarry = _allCarry ? carry : carry.take(20).toList();
    final maxShare = carry.isEmpty ? 1.0 : carry.first.share.clamp(1e-9, 1.0);
    final corridors = [for (final s in d.corridors) if (s.ids.every((i) => !i.startsWith('hop:'))) s].take(15).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(key: const Key('routes-agg-figures'), spacing: 8, runSpacing: 8, children: [
        _fig(context, groupInt(d.hashes), 'flood packets in $win'),
        _fig(context, '${(100 * d.withRelay / d.hashes).toStringAsFixed(0)}%', 'relayed at least once', hint: '${groupInt(d.withRelay)} packets'),
        _fig(context, groupInt(d.observations), 'observations of them'),
        _fig(context, resolved == null ? 'none' : '${(resolved * 100).toStringAsFixed(0)}%', 'hops pinned to one repeater', hint: 'of ${groupInt(d.hops)} hops'),
      ]),
      if (d.truncated)
        Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('There were more packets than the tool pulls in one pass; the oldest were left out.', style: t.textTheme.bodySmall)),
      if (resolved != null && resolved < 0.7)
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: Text(
            '${((1 - resolved) * 100).toStringAsFixed(0)}% of hops cannot be pinned to one repeater in this window, mostly 1-byte path hashes (${groupInt(d.oneByteHops)} hops). Carry shares below count only identified hops.',
            key: const Key('routes-agg-warn'),
            style: t.textTheme.bodyMedium,
          ),
        ),
      section(
        'Who actually carries the floods',
        carry.isEmpty
            ? const Text('No relayed flood in this window.')
            : Column(children: [
                for (final c in shownCarry)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Expanded(flex: 5, child: Text(c.displayName, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Expanded(
                        flex: 4,
                        child: ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: c.share / maxShare, minHeight: 8)),
                      ),
                      SizedBox(width: 58, child: Text(_pct(c.share), textAlign: TextAlign.end, style: t.textTheme.labelMedium)),
                    ]),
                  ),
                if (carry.length > 20)
                  TextButton(onPressed: () => setState(() => _allCarry = !_allCarry), child: Text(_allCarry ? 'Show top 20' : 'Show all ${carry.length}')),
              ]),
        lead: 'Share = unique flood packets whose path includes the repeater, over all ${groupInt(d.hashes)} floods.',
        key: 'routes-carry',
      ),
      if (d.links.isNotEmpty) section('Hops floods used', _linkMap(context), lead: 'Thicker lines carried more floods. Only hops between two repeaters with a known position are drawn.', key: 'routes-links'),
      section(
        'The corridors floods use most',
        corridors.isEmpty
            ? const Text('No relay chain of two or more identified repeaters in this window.')
            : Column(children: [
                for (var i = 0; i < corridors.length; i++)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(radius: 13, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                    title: Text(corridors[i].labels.join('  →  ')),
                    subtitle: Text('${_pct(corridors[i].share)} of floods, ${groupInt(corridors[i].hashes)} packets'),
                  ),
              ]),
        lead: 'Ordered relay chains, counted once per packet, over the last $win.',
        key: 'routes-corridors',
      ),
      section('How far floods travel', _hopChart(context), lead: 'Relay count of each packet\'s longest observed path; 0 means heard straight from the sender.', key: 'routes-hops'),
      section(
        'Where floods end',
        d.ends.isEmpty
            ? const Text('Nothing was relayed in this window.')
            : Column(children: [
                for (final e in d.ends.take(10))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Expanded(flex: 5, child: Text(e.displayName, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Expanded(
                        flex: 4,
                        child: ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: d.ends.first.hashes == 0 ? 0 : e.hashes / d.ends.first.hashes, minHeight: 8)),
                      ),
                      SizedBox(width: 48, child: Text(d.withRelay == 0 ? '' : '${(100 * e.hashes / d.withRelay).toStringAsFixed(0)}%', textAlign: TextAlign.end, style: t.textTheme.labelMedium)),
                    ]),
                  ),
              ]),
        lead: 'The last relay on each packet\'s deepest path. Usually the relays nearest our observers, so read it as where we stop hearing floods.',
        key: 'routes-ends',
      ),
      section(
        '1-byte path hashes that point at more than one repeater',
        !d.hasCollisionData
            ? const Text('No collision data.')
            : d.collisionsError != null
                ? Text('The hash-collision analysis did not load: ${d.collisionsError}')
                : d.collisions.isEmpty
                    ? const Text('Every repeater here has a distinct first key byte.')
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (final c in d.collisions.take(30))
                          Padding(
                            padding: const EdgeInsets.only(bottom: Gap.s),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${c.prefix} shared by ${c.nodes.length} repeaters${c.seenAsOneByteHop > 0 ? '; seen as a 1-byte hop ${groupInt(c.seenAsOneByteHop)} times' : ''}',
                                  style: t.textTheme.titleSmall),
                              for (final n in c.nodes)
                                Text('  ${n.name ?? shortId(n.pubkey)}  ${n.pubkey.substring(0, 8)}${n.hashSize == null ? '' : '  sends ${n.hashSize}-byte hashes'}', style: t.textTheme.bodySmall),
                            ]),
                          ),
                      ]),
        lead: 'A repeater sending 1-byte path hashes is named by the first byte of its key. Where repeaters share that byte, paths through them cannot be pinned down.',
        key: 'routes-collisions',
      ),
    ]);
  }

  Widget _fig(BuildContext context, String value, String label, {String? hint}) {
    final t = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 130),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: t.textTheme.titleMedium),
        Text(label, style: t.textTheme.labelMedium),
        if (hint != null) Text(hint, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _linkMap(BuildContext context) {
    final d = widget.d;
    final cs = Theme.of(context).colorScheme;
    final maxH = d.links.fold<int>(1, (a, l) => l.hashes > a ? l.hashes : a);
    final lines = <Polyline>[];
    final pts = <LatLng>[];
    for (final l in d.links) {
      final a = d.locations[l.a], b = d.locations[l.b];
      if (a == null || b == null) continue;
      final pa = LatLng(a.$1, a.$2), pb = LatLng(b.$1, b.$2);
      pts..add(pa)..add(pb);
      lines.add(Polyline(points: [pa, pb], strokeWidth: 1.2 + 4.5 * (l.hashes / maxH), color: cs.primary.withValues(alpha: .75)));
    }
    if (lines.isEmpty) return const Text('None of these hops has a known position on both ends.', key: Key('routes-links-nomap'));
    return ClipRRect(
      borderRadius: BorderRadius.circular(Corners.card),
      child: SizedBox(
        height: 300,
        child: FlutterMap(
          key: const Key('routes-links-map'),
          options: MapOptions(
            initialCenter: pts.first,
            initialZoom: 9,
            initialCameraFit: CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(28), maxZoom: 13),
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag),
          ),
          children: [
            if (widget.tiles) TileLayer(urlTemplate: CoverageMap.tileUrl, userAgentPackageName: CoverageMap.userAgentPackageName, maxNativeZoom: 19),
            PolylineLayer(polylines: lines),
          ],
        ),
      ),
    );
  }

  Widget _hopChart(BuildContext context) {
    final d = widget.d;
    final t = Theme.of(context);
    const cap = 12;
    final head = [for (final h in d.hopHistogram) if (h.$1 < cap) h];
    final tail = d.hopHistogram.where((h) => h.$1 >= cap).fold<int>(0, (a, h) => a + h.$2);
    final labels = [for (final h in head) '${h.$1}', if (tail > 0) '$cap+'];
    final values = <double?>[for (final h in head) h.$2.toDouble(), if (tail > 0) tail.toDouble()];
    final med = d.medianHops;
    return ChartFrame(
      id: 'routes-hops',
      title: 'Deepest path per flood',
      summary: 'Median ${med ?? 'unknown'} hops. ${labels.indexed.map((e) => '${e.$2} hops ${values[e.$1]!.round()}').join(', ')}.',
      height: 170,
      caption: 'Packets by the relay count of their longest observed path.',
      table: ChartTable(head: const ['Hops', 'Packets', 'Share'], rows: [
        for (final (i, l) in labels.indexed) [l, groupInt(values[i]!.round()), _pct(values[i]! / d.hashes)],
      ]),
      chart: BarChart(
        labels: labels,
        series: [BarSeries(name: 'Packets', values: values, color: t.colorScheme.primary)],
        colorOf: (i, v) => labels[i] == '${med ?? -1}' ? t.colorScheme.onSurface : null,
      ),
    );
  }
}
