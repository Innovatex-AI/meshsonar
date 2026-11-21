// Path Inspector (build 71, stream D; website twin `/tools/path`): type a packet's hop prefixes and see the full routes
// they most likely stand for, best first (POST /v1/tools/path-inspect). Hops may be separated by spaces, commas or
// arrows; a parse error shows under the field. A candidate under the server's threshold is labelled Speculative in
// words. Tapping a hop opens the node.
import 'package:flutter/material.dart';

import '../../../core/v1/tools_api.dart';
import '../../design/state_views.dart';
import '../../design/app_symbols.dart';
import '../../design/tokens.dart';
import '../analytics/in_place_header.dart';
import 'tool_common.dart';

class PathInspectorScreen extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;

  /// A hop list from a link; inspected straight away when it parses.
  final String? initialHops;

  /// Test seam.
  final ToolsApi? api;

  /// Given: the tool sits in place inside the Tools section and its back arrow calls this (see ToolFrame).
  final VoidCallback? onClose;
  const PathInspectorScreen({super.key, required this.baseUrl, required this.regionSlug, this.initialHops, this.api, this.onClose});

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
      final r = await _api.pathInspect(input.hops, hashSize: input.hashSize);
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
      body: ListView(padding: kToolPagePadding, children: [
          Text('Type the hop prefixes from a packet, in order. The app shows the full routes they most likely stand for.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.m),
          TextField(
            key: const Key('path-hops'),
            controller: _text,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _run(),
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'Hop prefixes',
              hintText: 'a1 3f c4   or   a1 > 3f > c4',
              border: const OutlineInputBorder(),
              errorText: _inputError,
              errorMaxLines: 3,
            ),
          ),
          const SizedBox(height: Gap.m),
          Text('Hash size (used when the hops are typed with no spaces)', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          SegmentedButton<int>(
            key: const Key('path-hash-size'),
            showSelectedIcon: false,
            style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(44, 44))),
            segments: const [
              ButtonSegment(value: 1, label: Text('1 byte')),
              ButtonSegment(value: 2, label: Text('2 bytes')),
              ButtonSegment(value: 3, label: Text('3 bytes')),
            ],
            selected: {_hashSize},
            onSelectionChanged: (s) => setState(() => _hashSize = s.first),
          ),
          const SizedBox(height: Gap.m),
          FilledButton(
            key: const Key('path-inspect'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy ? null : _run,
            child: Text(_busy ? 'Inspecting…' : 'Inspect'),
          ),
          if (_error != null) ToolErrorLine(_error!, key: const Key('path-error')),
          if (r != null) ..._results(context, r),
        ]),
    );
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
          message: 'No known repeaters in this region match these prefixes in this order. Check the hops and the hash size.',
        ),
      ];
    }
    return [
      const SizedBox(height: Gap.l),
      Semantics(header: true, child: Text('${r.candidates.length} likely route${r.candidates.length == 1 ? '' : 's'} for ${_asked.join(' → ')}', style: t.textTheme.titleMedium)),
      if (r.unknownHops.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text('No known node for: ${r.unknownHops.join(', ')}', key: const Key('path-unknown'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
      for (final c in r.candidates) _candidate(context, c),
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
        if (open)
          for (var i = 0; i < c.hops.length; i++)
            ToolNodeRow(
              key: Key('path-candidate-${c.rank}-hop-$i'),
              baseUrl: widget.baseUrl,
              regionSlug: widget.regionSlug,
              leading: c.hops[i].prefix,
              node: c.hops[i].node,
              missing: 'No known node',
              detail: c.hops[i].hopScore == null ? null : '${(c.hops[i].hopScore! * 100).round()}% for this hop',
            ),
        if (open) const SizedBox(height: Gap.xs),
      ]),
    );
  }
}
