// Trace Viewer (build 71, stream D; website twin `/tools/trace`): one TRACE end to end. Two ways in:
// - a packet hash (typed, from a link, or picked from the region's recent traces): GET /v1/traces/{hash} gives the
//   targets, the SNR each hop heard, and who heard the trace when. A hash the server does not have says
//   "No server copy of this trace yet", which is normal for a trace nobody's observer heard.
// - a trace the connected radio just ran ([TraceViewerScreen.local], opened from the radio Trace tool): the same hop
//   layout from the radio's own answer, labelled "From your radio".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;

import '../../../core/v1/packet_models.dart' show HopConfidence;
import '../../../core/v1/tools_api.dart';
import '../../../radio/tools/trace_tool.dart' show TraceResult, TraceStatus;
import '../../design/state_views.dart';
import '../../design/app_symbols.dart';
import '../../design/tokens.dart';
import '../../map/still/path_layer.dart' show PathKey, activePathStyle;
import '../../map/still/path_map.dart' show StillPathMap;
import '../../map/still/still_nodes.dart';
import '../../region/region_common.dart' show agoText, clockUtc;
import '../nodes/node_routes.dart';
import '../packets/packet_detail_screen.dart' show openNetworkPacket;
import '../packets/packet_ui.dart' show HopConfidenceBadge;
import '../analytics/in_place_header.dart';
import 'tool_common.dart';
import 'tool_path_spec.dart';

final _hash = RegExp(r'^[0-9a-f]{16}$');

class TraceViewerScreen extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;

  /// A packet hash from a link; loaded straight away.
  final String? initialHash;

  /// A trace the radio ran; the screen then shows it and asks the server nothing.
  final TraceResult? local;

  /// Test seams.
  final ToolsApi? api;
  final DateTime Function()? clock;

  /// Test seam: the region's repeaters to place the hops on the route map. Null = the viewed region's loaded list
  /// ([stillRepeatersOf]); none loaded = no map.
  final List<StillNode>? nodes;

  /// Given: the tool sits in place inside the Tools section and its back arrow calls this (see ToolFrame).
  final VoidCallback? onClose;
  const TraceViewerScreen({super.key, required this.baseUrl, required this.regionSlug, this.initialHash, this.api, this.clock, this.nodes, this.onClose}) : local = null;

  /// The radio's own result of a trace.
  const TraceViewerScreen.local(TraceResult this.local, {super.key})
      : baseUrl = '',
        regionSlug = null,
        initialHash = null,
        api = null,
        clock = null,
        nodes = null,
        onClose = null;

  @override
  State<TraceViewerScreen> createState() => _TraceViewerScreenState();
}

class _TraceViewerScreenState extends State<TraceViewerScreen> {
  ToolsApi? _apiMade;
  ToolsApi get _api => _apiMade ??= widget.api ?? toolsApiFactory(widget.baseUrl);
  late final TextEditingController _text = TextEditingController(text: widget.initialHash ?? '');
  String? _inputError;

  // the open trace
  String? _asked;
  TraceView? _trace;
  bool _loading = false;
  bool _missing = false;
  String? _error;

  // the recent list
  List<RecentTrace>? _recent;
  String? _recentError;

  @override
  void initState() {
    super.initState();
    if (widget.local != null) return;
    final h = widget.initialHash?.trim().toLowerCase() ?? '';
    if (h.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(h));
    }
    _loadRecent();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    setState(() => _recentError = null);
    try {
      final r = await _api.recentTraces();
      if (mounted) setState(() => _recent = r);
    } catch (e) {
      if (mounted) setState(() => _recentError = toolErrorText(e));
    }
  }

  Future<void> _open(String raw) async {
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    final h = raw.trim().toLowerCase();
    if (!_hash.hasMatch(h)) {
      setState(() => _inputError = h.isEmpty ? 'Type a packet hash.' : 'A packet hash is 16 hex characters (0-9, a-f).');
      return;
    }
    _text.text = h;
    setState(() {
      _inputError = null;
      _asked = h;
      _trace = null;
      _missing = false;
      _error = null;
      _loading = true;
    });
    try {
      final t = await _api.trace(h);
      if (!mounted || _asked != h) return;
      setState(() => _trace = t);
    } catch (e) {
      if (!mounted || _asked != h) return;
      setState(() {
        if (e is V1Error && e.notFound) {
          _missing = true;
        } else {
          _error = toolErrorText(e);
        }
      });
    } finally {
      if (mounted && _asked == h) setState(() => _loading = false);
    }
  }

  void _close() => setState(() {
        _asked = null;
        _trace = null;
        _missing = false;
        _error = null;
        _loading = false;
      });

  @override
  Widget build(BuildContext context) {
    final local = widget.local;
    return ToolFrame(
      frameKey: const Key('tool-trace-viewer'),
      title: local != null ? 'Your trace' : 'Trace Viewer',
      onClose: widget.onClose,
      body: ListView(padding: kToolPagePadding, keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, children: local != null ? _localBody(context, local) : _serverBody(context)),
    );
  }

  // ---------------------------------------------------------------- server copy

  List<Widget> _serverBody(BuildContext context) {
    final asked = _asked, trace = _trace;
    return [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: TextField(
            key: const Key('trace-hash'),
            controller: _text,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            onSubmitted: _open,
            style: const TextStyle(fontFamily: 'monospace'),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Trace ID (its packet hash)',
              hintText: '16 hex characters',
              border: const OutlineInputBorder(),
              errorText: _inputError,
              errorMaxLines: 2,
              suffixIcon: _text.text.isEmpty
                  ? IconButton(
                      key: const Key('trace-paste'),
                      tooltip: 'Paste',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: _paste,
                      icon: const Icon(Icons.content_paste),
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(width: Gap.s),
        FilledButton(
          key: const Key('trace-view'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 56)),
          onPressed: _loading ? null : () => _open(_text.text),
          child: const Text('View'),
        ),
      ]),
      if (asked == null) ..._recentList(context),
      if (asked != null) ...[
        const SizedBox(height: Gap.s),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('trace-back-to-list'),
            style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
            onPressed: _close,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('All recent traces'),
          ),
        ),
        if (_loading) const Padding(padding: EdgeInsets.only(top: Gap.xl), child: SizedBox(height: 160, child: AppLoadingView(label: 'Loading the trace'))),
        if (_missing)
          Padding(
            padding: const EdgeInsets.only(top: Gap.l),
            child: AppEmptyView(
              key: const Key('trace-missing'),
              symbol: AppSymbols.exclamationCircle,
              title: 'No server copy of this trace yet',
              message: 'No observer has reported a TRACE with this hash. A trace shows up here once an observer hears it; try again in a minute.',
              actionLabel: 'Try again',
              onAction: () => _open(asked),
            ),
          ),
        if (_error != null) ...[
          ToolErrorLine(_error!, key: const Key('trace-error')),
          Align(alignment: Alignment.centerLeft, child: TextButton(style: TextButton.styleFrom(minimumSize: const Size(44, 44)), onPressed: () => _open(asked), child: const Text('Try again'))),
        ],
        if (trace != null) ..._traceDetail(context, trace),
      ],
    ];
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted || text.isEmpty) return;
    await _open(text);
  }

  List<Widget> _recentList(BuildContext context) {
    final t = Theme.of(context);
    final recent = _recent;
    final now = (widget.clock ?? DateTime.now)();
    return [
      const SizedBox(height: Gap.s),
      Row(children: [
        Expanded(child: Semantics(header: true, child: Text('Recent traces here', style: t.textTheme.titleMedium))),
        IconButton(
          key: const Key('trace-refresh-recent'),
          tooltip: 'Reload the recent traces',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: recent == null && _recentError == null ? null : _loadRecent,
          icon: const Icon(Icons.refresh),
        ),
      ]),
      if (recent != null && recent.isNotEmpty) Text('Tap one to see how far it got.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      if (recent == null && _recentError == null) const SizedBox(height: 140, child: AppLoadingView(label: 'Loading recent traces')),
      if (_recentError != null) ...[
        ToolErrorLine(_recentError!, key: const Key('trace-recent-error')),
        Align(alignment: Alignment.centerLeft, child: TextButton(style: TextButton.styleFrom(minimumSize: const Size(44, 44)), onPressed: _loadRecent, child: const Text('Try again'))),
      ],
      if (recent != null && recent.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: Text('No traces were heard here in the last 7 days. Send one with Send a trace (Tools, With your radio), or paste a trace ID above.',
              key: const Key('trace-recent-none'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
      if (recent != null)
        for (final r in recent)
          Semantics(
            button: true,
            label: 'Trace from ${agoText(r.firstSeen, now: now)}, ${r.hops} hop${r.hops == 1 ? '' : 's'}${r.observations == null ? '' : ', heard by ${r.observations}'}. Opens it.',
            excludeSemantics: true,
            child: InkWell(
              key: Key('trace-recent-${r.hash}'),
              onTap: () => _open(r.hash),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(
                          '${agoText(r.firstSeen, now: now)} · ${r.hops} hop${r.hops == 1 ? '' : 's'}${r.observations == null ? '' : ' · heard by ${r.observations}'}',
                          style: t.textTheme.bodyLarge,
                        ),
                        Text(r.hash, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: t.colorScheme.onSurfaceVariant)),
                      ]),
                    ),
                    Icon(Icons.chevron_right, size: 18, color: t.colorScheme.onSurfaceVariant),
                  ]),
                ),
              ),
            ),
          ),
    ];
  }

  List<Widget> _traceDetail(BuildContext context, TraceView v) {
    final t = Theme.of(context);
    final dim = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final total = v.targets.length;
    final headline = total == 0
        ? 'Targets unknown'
        : v.complete
            ? 'Complete: all $total hop${total == 1 ? '' : 's'} answered'
            : 'Got through ${v.completed} of $total hops';
    return [
      ToolCard(
        key: const Key('trace-summary'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(headline, style: t.textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Text(
            [
              'Heard ${v.observations.length} time${v.observations.length == 1 ? '' : 's'}',
              if (v.observations.length > 1) 'over ${(v.spread.inMilliseconds / 1000).toStringAsFixed(1)} s',
              if (v.copies.length > 1) '${v.copies.length} copies (one per hop count)',
              if (v.tag != null) 'tag ${v.tag}',
              if (v.hashSize > 0) '${v.hashSize * 2}-character hop IDs',
            ].join(' · '),
            style: dim,
          ),
          if (v.note != null) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(v.note!, key: const Key('trace-note'), style: dim)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('trace-open-packet'),
              style: TextButton.styleFrom(minimumSize: const Size(44, 48), padding: EdgeInsets.zero),
              onPressed: () => openNetworkPacket(context, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, hash: v.hash),
              icon: const Icon(Icons.chevron_right, size: 18),
              iconAlignment: IconAlignment.end,
              label: const Text('See the whole packet'),
            ),
          ),
        ]),
      ),
      if (v.hops.isNotEmpty) ...[
        const SizedBox(height: Gap.l),
        Semantics(header: true, child: Text('Hop by hop', style: t.textTheme.titleMedium)),
        Text('The number on the right is how well each hop heard the trace (higher is better). Tap a hop to open it.', style: dim),
        ..._map(context, v),
        for (final h in v.hops)
          ToolNodeRow(
            key: Key('trace-hop-${h.index}'),
            baseUrl: widget.baseUrl,
            regionSlug: widget.regionSlug,
            leading: '${h.index + 1}  ${h.prefix}',
            node: h.node,
            missing: h.confidence == HopConfidence.ambiguous ? 'Unclear which repeater' : 'Unknown repeater',
            detail: h.index >= v.completed
                ? 'Not reached'
                : h.node == null && h.confidence == HopConfidence.ambiguous
                    ? 'Several share this ID'
                    : HopConfidenceBadge.label(h.confidence),
            trailing: SnrBar(h.snrDb),
          ),
      ],
      const SizedBox(height: Gap.l),
      Semantics(header: true, child: Text('Heard by', style: t.textTheme.titleMedium)),
      if (v.observations.isNotEmpty) Text('The observers that reported this trace. Tap one to open it.', style: dim),
      if (v.observations.isEmpty) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text('No observer reports are kept for this trace.', style: dim)),
      for (var i = 0; i < v.observations.length; i++) _observation(context, v.observations[i], i),
    ];
  }

  /// The trace's hops joined in order on the numbered path map (the Map Definition's `symbols.path`; none without it, or without a
  /// loaded region repeater list to place the hops from). A hop with no position is listed under the map, never drawn, and the
  /// line stops there. The observers' positions are not in the answer, so none is drawn.
  List<Widget> _map(BuildContext context, TraceView v) {
    final style = activePathStyle();
    final nodes = widget.nodes ?? stillRepeatersOf(context, regionSlug: widget.regionSlug);
    if (style == null || nodes == null || nodes.isEmpty || v.hops.isEmpty) return const [];
    final t = Theme.of(context);
    final dim = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final spec = toolPathSpec([for (final h in v.hops) ToolHopInput(prefix: h.prefix, node: h.node, sure: h.confidence == HopConfidence.unique)], nodes);
    final unplaced = spec.unplaced;
    if (spec.placed.isEmpty) {
      return [Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('Map: none of this trace\'s hops has a position here, so there is nothing to draw.', key: const Key('trace-map-none'), style: dim))];
    }
    return [
      const SizedBox(height: Gap.s),
      StillPathMap(
        key: const Key('trace-map'),
        spec: spec,
        style: style,
        semanticLabel: 'The trace on the map: ${spec.placed.length} of ${spec.hops.length} hops placed.',
        repeaters: nodes,
      ),
      Padding(padding: const EdgeInsets.only(top: Gap.xs), child: PathKey(style: style, unplaced: unplaced.length, total: spec.hops.length)),
      if (unplaced.isNotEmpty) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text('Not drawn: ${unplacedListText(spec)}', key: const Key('trace-map-unplaced'), style: dim)),
      const SizedBox(height: Gap.xs),
    ];
  }

  Widget _observation(BuildContext context, TraceObservation o, int i) {
    final t = Theme.of(context);
    final name = o.observerName ?? (o.observerId.length > 12 ? '${o.observerId.substring(0, 12)}…' : o.observerId);
    final facts = [
      if (o.at != null) '${clockUtc(o.at)} UTC',
      if (o.hopsCompleted != null) 'after ${o.hopsCompleted} hop${o.hopsCompleted == 1 ? '' : 's'}',
      if (o.rssi != null) '${o.rssi!.round()} dBm',
      if (o.observerKind == 'outside') 'outside source',
      if (o.observerKind == 'phone') 'phone',
    ].join(' · ');
    return Semantics(
      button: true,
      label: 'Heard by $name. $facts. ${SnrBar.text(o.snr)}. Opens the observer.',
      excludeSemantics: true,
      child: InkWell(
        key: Key('trace-obs-$i'),
        onTap: () => openNetworkObserver(context, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug ?? '', observerId: o.observerId),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge),
                  if (facts.isNotEmpty) Text(facts, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ]),
              ),
              const SizedBox(width: Gap.s),
              SnrBar(o.snr),
              Icon(Icons.chevron_right, size: 18, color: t.colorScheme.onSurfaceVariant),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- the radio's own result

  List<Widget> _localBody(BuildContext context, TraceResult r) {
    final t = Theme.of(context);
    final dim = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final headline = switch (r.status) {
      TraceStatus.ok => 'Complete: all ${r.hops.length} hop${r.hops.length == 1 ? '' : 's'} answered',
      TraceStatus.silent => 'No answer',
      TraceStatus.refused => 'The radio refused the trace',
      TraceStatus.notConnected => 'No radio',
      TraceStatus.tooSoon => 'One moment',
      TraceStatus.invalid => 'Check the path',
    };
    final l = r.at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final km = r.totalKm;
    return [
      ToolCard(
        key: const Key('trace-local-summary'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const ToolPill('From your radio'),
          const SizedBox(height: Gap.s),
          Text(headline, style: t.textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Text(
            [
              'Sent ${two(l.hour)}:${two(l.minute)}:${two(l.second)}',
              if (r.elapsed != null) 'answered in ${(r.elapsed!.inMilliseconds / 1000).toStringAsFixed(1)} s',
              '${r.hashSize}-byte hashes',
              if (km != null) distanceText(context, km),
            ].join(' · '),
            style: dim,
          ),
          if (r.detail != null && r.detail!.isNotEmpty) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(r.detail!, style: dim)),
          if (r.finalSnrDb != null) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text('Your radio heard the answer at ${SnrBar.text(r.finalSnrDb)}.', style: t.textTheme.bodyMedium)),
        ]),
      ),
      if (r.hops.isNotEmpty) ...[
        const SizedBox(height: Gap.l),
        Semantics(header: true, child: Text('Hop by hop', style: t.textTheme.titleMedium)),
        Text('The number on the right is how well each hop heard the trace (higher is better).', style: dim),
        for (var i = 0; i < r.hops.length; i++)
          ToolNodeRow(
            key: Key('trace-hop-$i'),
            baseUrl: '',
            regionSlug: null,
            leading: '${i + 1}  ${r.hops[i].hashHex}',
            node: null,
            missing: r.hops[i].stop.name,
            detail: [
              if (r.hops[i].distanceKm != null) distanceText(context, r.hops[i].distanceKm!),
              if (r.hops[i].ambiguous) 'another node shares this hash',
            ].join(' · ').nullIfEmpty,
            trailing: SnrBar(r.hops[i].snrDb),
          ),
      ],
      const SizedBox(height: Gap.l),
      Text('This is your radio\'s own answer. Once an observer hears the trace, the network\'s copy is in Tools, Trace Viewer.', style: dim),
    ];
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
