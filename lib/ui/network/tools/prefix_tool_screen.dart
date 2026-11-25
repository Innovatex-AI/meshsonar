// Prefix Tool (build 71, stream D; website twin `/analytics/prefix-tool`): is a hash prefix free for a new repeater,
// which nodes already use it nearby, and free ones to pick (GET /v1/insights/hashes/prefix). The region overview loads
// at once; typing a prefix (2, 4 or 6 hex, or a whole key) checks it at every size it covers.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../../core/v1/tools_api.dart';
import '../../design/app_surfaces.dart' show showAppToast;
import '../../design/state_views.dart';
import '../../theme.dart';
import '../analytics/in_place_header.dart';
import 'tool_common.dart';

class PrefixToolScreen extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;
  final String? initialPrefix;

  /// Test seam.
  final ToolsApi? api;

  /// Given: the tool sits in place inside the Tools section and its back arrow calls this (see ToolFrame).
  final VoidCallback? onClose;
  const PrefixToolScreen({super.key, required this.baseUrl, required this.regionSlug, this.initialPrefix, this.api, this.onClose});

  @override
  State<PrefixToolScreen> createState() => _PrefixToolScreenState();
}

class _PrefixToolScreenState extends State<PrefixToolScreen> {
  late final ToolsApi _api = widget.api ?? toolsApiFactory(widget.baseUrl);
  late final TextEditingController _text = TextEditingController(text: widget.initialPrefix ?? '');
  String? _inputError;
  String? _error;
  bool _busy = false;
  bool _showNote = false;
  PrefixReport? _report;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (!mounted) return;
    final bad = prefixInputError(_text.text);
    if (bad != null) {
      setState(() => _inputError = bad);
      return;
    }
    final seq = ++_seq;
    setState(() {
      _inputError = null;
      _error = null;
      _busy = true;
    });
    try {
      final r = await _api.prefix(prefix: _text.text);
      if (mounted && seq == _seq) setState(() => _report = r);
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = toolErrorText(e));
    } finally {
      if (mounted && seq == _seq) setState(() => _busy = false);
    }
  }

  void _pick(String prefix) {
    _text.text = prefix;
    FocusScope.of(context).unfocus();
    _check();
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return ToolFrame(
      frameKey: const Key('tool-prefix'),
      title: 'Prefix Tool',
      onClose: widget.onClose,
      body: ListView(padding: kToolPagePadding, keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                key: const Key('prefix-input'),
                controller: _text,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _check(),
                style: const TextStyle(fontFamily: 'monospace'),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Repeater ID to check',
                  hintText: 'a1, a1b2 or a1b2c3',
                  helperText: 'The first 2, 4 or 6 characters of a repeater\'s key, or the whole key.',
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  errorText: _inputError,
                  errorMaxLines: 2,
                  suffixIcon: _text.text.isEmpty
                      ? null
                      : IconButton(
                          key: const Key('prefix-clear'),
                          tooltip: 'Clear',
                          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                          onPressed: () {
                            _text.clear();
                            _check();
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
            ),
            const SizedBox(width: Gap.s),
            FilledButton(
              key: const Key('prefix-check'),
              style: FilledButton.styleFrom(minimumSize: const Size(72, 56)),
              onPressed: _busy
                  ? null
                  : () {
                      FocusScope.of(context).unfocus();
                      _check();
                    },
              child: const Text('Check'),
            ),
          ]),
          if (_busy && r != null) const Padding(padding: EdgeInsets.only(top: Gap.s), child: LinearProgressIndicator(key: Key('prefix-busy'), minHeight: 3)),
          if (_busy && r == null) const Padding(padding: EdgeInsets.only(top: Gap.xl), child: SizedBox(height: 160, child: AppLoadingView(label: 'Reading the prefixes in use'))),
          if (_error != null) ...[
            ToolErrorLine(_error!, key: const Key('prefix-error')),
            Align(alignment: Alignment.centerLeft, child: TextButton(style: TextButton.styleFrom(minimumSize: const Size(44, 44)), onPressed: _check, child: const Text('Try again'))),
          ],
          if (r != null) ..._body(context, r),
        ]),
    );
  }

  List<Widget> _body(BuildContext context, PrefixReport r) {
    final t = Theme.of(context);
    final dim = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final checks = [for (final c in r.checks) if (c.prefix != null) c];
    final overview = [
      if (r.repeaters != null) '${r.repeaters} repeaters and rooms${r.radiusKm == null ? '' : ' within ${distanceText(context, r.radiusKm!)}'}',
      if (r.freeOneByte != null) '${r.freeOneByte} one-byte prefix${r.freeOneByte == 1 ? '' : 'es'} still free',
    ].join(' · ');
    return [
      if (r.query != null && checks.isNotEmpty) ...[
        const SizedBox(height: Gap.l),
        Semantics(header: true, child: Text('Result for ${r.query!.length > 12 ? '${r.query!.substring(0, 12)}…' : r.query}', style: t.textTheme.titleMedium)),
        for (final c in checks) _check1(context, c),
      ],
      if (r.suggestions.isNotEmpty) ...[
        const SizedBox(height: Gap.l),
        Semantics(header: true, child: Text('Free IDs you could use', style: t.textTheme.titleMedium)),
        Text('Tap one to check it.', style: dim),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
          for (final s in r.suggestions)
            ActionChip(
              key: Key('prefix-suggestion-${s.prefix}'),
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: Text('${s.prefix}  ·  ${s.bytes} byte${s.bytes == 1 ? '' : 's'}', style: const TextStyle(fontFamily: 'monospace')),
              tooltip: s.nearestUseKm == null ? 'Not in use nearby' : 'Nearest use ${distanceText(context, s.nearestUseKm!)} away',
              onPressed: () => _pick(s.prefix),
            ),
        ]),
      ],
      const SizedBox(height: Gap.l),
      Semantics(header: true, child: Text('Around here', style: t.textTheme.titleMedium)),
      if (overview.isNotEmpty) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(overview, key: const Key('prefix-overview'), style: t.textTheme.bodyMedium)),
      if (r.recommendation != null)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(r.overviewNote ?? '${r.recommendation}-byte prefixes recommended.', key: const Key('prefix-recommendation'), style: t.textTheme.bodyMedium),
        ),
      // The server's long explanation: one tap away, not a paragraph under every answer.
      if (r.note != null) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('prefix-about'),
            style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: EdgeInsets.zero),
            onPressed: () => setState(() => _showNote = !_showNote),
            icon: Icon(_showNote ? Icons.expand_less : Icons.expand_more, size: 18),
            label: const Text('How this is worked out'),
          ),
        ),
        if (_showNote) Text(r.note!, key: const Key('prefix-note'), style: dim),
      ],
    ];
  }

  Widget _check1(BuildContext context, PrefixCheck c) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final (String word, Color colour, IconData icon) = c.reserved
        ? ('Reserved', t.colorScheme.onSurfaceVariant, Icons.block)
        : c.free
            ? ('Free', mc.snrStrong, Icons.check_circle_outline)
            : ('Taken', t.colorScheme.error, Icons.error_outline);
    final dim = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return ToolCard(
      key: Key('prefix-check-${c.bytes}'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, size: 20, color: colour),
          const SizedBox(width: Gap.s),
          Expanded(child: Text('${c.prefix}  ·  ${c.bytes} byte${c.bytes == 1 ? '' : 's'}', style: t.textTheme.titleSmall?.copyWith(fontFamily: 'monospace'))),
          Text(word, style: t.textTheme.titleSmall?.copyWith(color: colour)),
        ]),
        if (c.reserved) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text('This ID is set aside and cannot be used. Pick another.', style: dim)),
        if (c.free && !c.reserved) ...[
          Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text('No repeater nearby uses it. A new repeater can.', style: dim)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key('prefix-copy-${c.bytes}'),
              style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: EdgeInsets.zero),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: c.prefix!));
                if (context.mounted) showAppToast(context, 'Copied ${c.prefix}');
              },
              icon: const Icon(Icons.copy, size: 18),
              label: Text('Copy ${c.prefix}'),
            ),
          ),
        ],
        if (!c.free && !c.reserved)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
              '${c.conflicts.length} node${c.conflicts.length == 1 ? ' already uses' : 's already use'} it${c.nearestConflictKm == null ? '' : ', the nearest ${distanceText(context, c.nearestConflictKm!)} away'}. Tap one to open it.',
              style: dim,
            ),
          ),
        for (var i = 0; i < c.conflicts.length; i++)
          ToolNodeRow(
            key: Key('prefix-check-${c.bytes}-conflict-$i'),
            baseUrl: widget.baseUrl,
            regionSlug: widget.regionSlug,
            leading: c.conflicts[i].key.substring(0, c.conflicts[i].key.length < 6 ? c.conflicts[i].key.length : 6),
            node: c.conflicts[i],
            detail: _roleWord(c.conflicts[i].role),
          ),
      ]),
    );
  }

  /// "repeater" -> "Repeater" (the server sends the role in lower case).
  static String? _roleWord(String? role) => role == null || role.isEmpty ? role : role[0].toUpperCase() + role.substring(1);
}
