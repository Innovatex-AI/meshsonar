// Path Inspector (build 71, stream D; website twin `/tools/path`): type a packet's hop prefixes and see the full routes
// they most likely stand for, best first (POST /v1/tools/path-inspect). Hops may be separated by spaces, commas or
// arrows; a parse error shows under the field. A candidate under the server's threshold is labelled Speculative in
// words. Tapping a hop opens the node.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;

import '../../../core/v1/tools_api.dart';
import '../../design/state_views.dart';
import '../../design/app_symbols.dart';
import '../../design/tokens.dart';
import '../../map/still/path_layer.dart' show PathKey, activePathStyle;
import '../../map/still/path_map.dart' show StillPathMap;
import '../../map/still/still_nodes.dart';
import '../analytics/in_place_header.dart';
import 'tool_common.dart';
import 'tool_path_spec.dart';

class PathInspectorScreen extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;

  /// A hop list from a link; inspected straight away when it parses.
  final String? initialHops;

  /// The observer that heard these hops (from a packet copy's "Work out the likely route"): sent with the request so
  /// the server ranks routes that end near it. Dropped as soon as the person edits the hops.
  final String? initialObserver;

  /// Test seam.
  final ToolsApi? api;

  /// Test seam: the region's repeaters to place the hops on the route map. Null = the viewed region's loaded list
  /// ([stillRepeatersOf]); none loaded = no map.
  final List<StillNode>? nodes;

  /// Given: the tool sits in place inside the Tools section and its back arrow calls this (see ToolFrame).
  final VoidCallback? onClose;
  const PathInspectorScreen({super.key, required this.baseUrl, required this.regionSlug, this.initialHops, this.initialObserver, this.api, this.nodes, this.onClose});

  @override
  State<PathInspectorScreen> createState() => _PathInspectorScreenState();
}

class _PathInspectorScreenState extends State<PathInspectorScreen> {
  late final ToolsApi _api = widget.api ?? toolsApiFactory(widget.baseUrl);
  late final TextEditingController _text = TextEditingController(text: widget.initialHops ?? '');
  int _hashSize = 1;
  String? _inputError;
  String? _error;
  bool _busy = false;
  PathInspectResult? _result;
  List<String> _asked = const [];
  int? _open;

  @override
  void initState() {
    super.initState();
    if ((widget.initialHops ?? '').trim().isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_busy || !mounted) return;
    FocusScope.of(context).unfocus();
    final input = parseHopInput(_text.text, hashSize: _hashSize);
    if (!input.ok) {
      setState(() {
        _inputError = input.error;
        _result = null;
        _error = null;
      });
      return;
    }
    setState(() {
      _inputError = null;
      _error = null;
      _busy = true;
      _hashSize = input.hashSize;
    });
    try {
      // The observer only belongs to the hops it came with.
      final observer = _text.text.trim() == (widget.initialHops ?? '').trim() ? widget.initialObserver : null;
      final r = await _api.pathInspect(input.hops, hashSize: input.hashSize, observer: observer);
      if (!mounted) return;
      setState(() {
        _result = r;
        _asked = input.hops;
        _open = r.candidates.isEmpty ? null : r.candidates.first.rank;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _result = null;
        _error = toolErrorText(e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = _result;
    return ToolFrame(
      frameKey: const Key('tool-path'),
      title: 'Path Inspector',
      onClose: widget.onClose,
      body: ListView(padding: kToolPagePadding, keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, children: [
          TextField(
            key: const Key('path-hops'),
            controller: _text,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _run(),
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'Hops from a packet, in order',
              hintText: 'a1 3f c4',
              helperText: 'The short IDs in a packet\'s path. Spaces, commas or > between them.',
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
              errorText: _inputError,
              errorMaxLines: 3,
              suffixIcon: _text.text.isEmpty
                  ? IconButton(
                      key: const Key('path-paste'),
                      tooltip: 'Paste',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: _paste,
                      icon: const Icon(Icons.content_paste),
                    )
                  : IconButton(
                      key: const Key('path-clear'),
                      tooltip: 'Clear',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: () => setState(() {
                        _text.clear();
                        _inputError = null;
                      }),
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
          // The size of a hop is read from the spacing; it has to be asked only when the hops are typed as one run.
          if (_needsSize) ...[
            const SizedBox(height: Gap.m),
            Text('No spaces between the hops: how long is each one?', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.xs),
            SegmentedButton<int>(
              key: const Key('path-hash-size'),
              showSelectedIcon: false,
              style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(44, 44))),
              segments: const [
                ButtonSegment(value: 1, label: Text('2 characters')),
                ButtonSegment(value: 2, label: Text('4')),
                ButtonSegment(value: 3, label: Text('6')),
              ],
              selected: {_hashSize},
              onSelectionChanged: (s) => setState(() => _hashSize = s.first),
            ),
          ],
          const SizedBox(height: Gap.m),
          FilledButton(
            key: const Key('path-inspect'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy ? null : _run,
            child: Text(_busy ? 'Finding routes…' : 'Find routes'),
          ),
          if (_busy && r == null) const Padding(padding: EdgeInsets.only(top: Gap.xl), child: SizedBox(height: 160, child: AppLoadingView(label: 'Matching the hops to repeaters'))),
          if (_error != null) ...[
            ToolErrorLine(_error!, key: const Key('path-error')),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(key: const Key('path-retry'), style: TextButton.styleFrom(minimumSize: const Size(44, 44)), onPressed: _busy ? null : _run, child: const Text('Try again')),
            ),
          ],
          if (r == null && !_busy && _error == null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.l),
              child: Text('You get the most likely full routes, best first, each on a map. Tap a repeater in a route to open it.',
                  key: const Key('path-idle'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ),
          if (r != null) ..._results(context, r),
        ]),
    );
  }

  /// One run of hex with no separator, too long to be a single hop: only then does the hop length have to be asked.
  bool get _needsSize {
    final x = _text.text.trim();
    return x.length > 2 && !x.contains(RegExp(r'[^0-9a-fA-F]'));
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted || text.isEmpty) return;
    setState(() {
      _text.text = text;
      _inputError = null;
    });
  }

  List<Widget> _results(BuildContext context, PathInspectResult r) {
    final t = Theme.of(context);
    if (r.candidates.isEmpty) {
      return [
        const SizedBox(height: Gap.l),
        const AppEmptyView(
          key: Key('path-none'),
          symbol: AppSymbols.exclamationCircle,
          title: 'No route found',
          message: 'No known repeaters in this region match these hops in this order. Check for a typo, or a hop that is out of order.',
        ),
      ];
    }
    return [
      const SizedBox(height: Gap.l),
      Semantics(header: true, child: Text('${r.candidates.length} likely route${r.candidates.length == 1 ? '' : 's'} for ${_asked.join(' → ')}', style: t.textTheme.titleMedium)),
      if (r.unknownHops.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text('No known repeater for: ${r.unknownHops.join(', ')}', key: const Key('path-unknown'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
      for (final c in r.candidates) _candidate(context, c),
    ];
  }

  /// The open route on the numbered path map (the Map Definition's `symbols.path`; none without it, or without a loaded region
  /// repeater list to place the hops from). Hops with no position are listed under the map, never drawn.
  List<Widget> _map(BuildContext context, PathCandidate c) {
    final style = activePathStyle();
    final nodes = widget.nodes ?? stillRepeatersOf(context, regionSlug: widget.regionSlug);
    if (style == null || nodes == null || nodes.isEmpty) return const [];
    final t = Theme.of(context);
    final spec = toolPathSpec([for (final h in c.hops) ToolHopInput(prefix: h.prefix, node: h.node, sure: h.hopScore != null && h.hopScore! >= 0.99)], nodes);
    final unplaced = spec.unplaced;
    return [
      if (spec.placed.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.xs),
          child: Text('Map: none of this route\'s hops has a position here, so there is nothing to draw.', key: const Key('path-map-none'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        )
      else ...[
        StillPathMap(
          key: Key('path-map-${c.rank}'),
          spec: spec,
          style: style,
          semanticLabel: 'Route ${c.rank} on the map: ${spec.placed.length} of ${spec.hops.length} hops placed.',
          repeaters: nodes,
        ),
        Padding(padding: const EdgeInsets.only(top: Gap.xs), child: PathKey(style: style, unplaced: unplaced.length, total: spec.hops.length)),
        if (unplaced.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.xs),
            child: Text('Not drawn: ${unplacedListText(spec)}', key: const Key('path-map-unplaced'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
      ],
    ];
  }

  Widget _candidate(BuildContext context, PathCandidate c) {
    final t = Theme.of(context);
    final open = _open == c.rank;
    final names = c.hops.map((h) => h.node?.label ?? h.prefix).join(' → ');
    final facts = ['${(c.score * 100).round()}% match', if (c.totalKm != null) distanceText(context, c.totalKm!)].join(' · ');
    return ToolCard(
      key: Key('path-candidate-${c.rank}'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(
          button: true,
          label: 'Route ${c.rank}, $facts${c.speculative ? ', speculative' : ''}. $names. ${open ? 'Hide' : 'Show'} the hops.',
          excludeSemantics: true,
          child: InkWell(
            key: Key('path-candidate-${c.rank}-toggle'),
            onTap: () => setState(() => _open = open ? null : c.rank),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.s),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Wrap(spacing: Gap.s, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Text('Route ${c.rank}', style: t.textTheme.titleSmall),
                        Text(facts, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                        if (c.speculative) const ToolPill('Speculative'),
                      ]),
                      if (!open) Text(names, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    ]),
                  ),
                  Icon(open ? Icons.expand_less : Icons.expand_more, color: t.colorScheme.onSurfaceVariant),
                ]),
              ),
            ),
          ),
        ),
        if (open) ..._map(context, c),
        if (open)
          for (var i = 0; i < c.hops.length; i++)
            ToolNodeRow(
              key: Key('path-candidate-${c.rank}-hop-$i'),
              baseUrl: widget.baseUrl,
              regionSlug: widget.regionSlug,
              leading: c.hops[i].prefix,
              node: c.hops[i].node,
              missing: 'No known repeater',
              detail: c.hops[i].hopScore == null ? null : '${(c.hops[i].hopScore! * 100).round()}% sure',
            ),
        if (open) const SizedBox(height: Gap.xs),
      ]),
    );
  }
}
