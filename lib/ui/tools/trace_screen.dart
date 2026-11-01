// Trace path: pick a chain of repeaters from the radio's contacts, send CMD_SEND_TRACE_PATH along it and show each hop's
// SNR, the route on a map with distances, and saved traces to compare. The radio answers only when it hears the LAST hop,
// and a missing hop is silence (research doc 2026-11-01, section B): the screen says so in words.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/units.dart' show Units;
import '../../radio/inbound.dart';
import '../../radio/protocol.dart' show AdvType;
import '../../radio/tools/radio_tools.dart';
import '../../radio/tools/tool_frames.dart' show maxTraceHops, traceHashSizes;
import '../../radio/tools/trace_tool.dart';
import '../app.dart';
import 'tool_kit.dart';
import 'tools_host.dart';

class TraceScreen extends StatelessWidget {
  const TraceScreen({super.key});

  @override
  Widget build(BuildContext context) => ToolPage(
        id: 'trace',
        title: 'Trace path',
        builder: (context, host, tools) => _TraceBody(key: ValueKey(identityHashCode(tools)), host: host, tools: tools),
      );
}

class _TraceBody extends StatefulWidget {
  final ToolsHost host;
  final RadioTools tools;
  const _TraceBody({super.key, required this.host, required this.tools});
  @override
  State<_TraceBody> createState() => _TraceBodyState();
}

class _TraceBodyState extends State<_TraceBody> {
  List<RadioContact> _contacts = const [];
  bool _loading = true;
  String? _loadError;
  final List<TraceStop> _hops = [];
  int _hashSize = 2;

  /// A saved (or latest) trace the person opened instead of the newest run.
  TraceResult? _viewed;
  final List<String> _compare = [];
  TraceComparison? _comparison;

  TraceTool get _trace => widget.tools.trace;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final list = await widget.tools.radio.contacts();
      if (!mounted) return;
      setState(() {
        _contacts = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not read the contact list from the radio. Check the connection and try again.';
      });
    }
  }

  List<RadioContact> get _pickable =>
      [for (final c in _contacts) if (c.type == AdvType.repeater || c.type == AdvType.room) c]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Future<void> _addHop() async {
    final c = await showModalBottomSheet<RadioContact>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _PickerSheet(contacts: _pickable),
    );
    if (c != null && mounted) setState(() => _hops.add(TraceStop.fromContact(c)));
  }

  Future<void> _run() async {
    setState(() => _viewed = null);
    await _trace.run(
      List.of(_hops),
      hashSize: _hashSize,
      origin: widget.host.lastPosition,
      known: _contacts,
    );
    if (mounted) setState(() {});
  }

  void _toggleCompare(String id) {
    setState(() {
      if (_compare.contains(id)) {
        _compare.remove(id);
      } else {
        if (_compare.length == 2) _compare.removeAt(0);
        _compare.add(id);
      }
      _comparison = null;
    });
  }

  void _doCompare() {
    final items = _trace.store.items;
    TraceResult? find(String id) => items.where((t) => t.id == id).firstOrNull;
    final a = find(_compare.first);
    final last = _trace.last;
    final b = _compare.length == 2 ? find(_compare[1]) : (last != null && last.ok ? last : null);
    if (a == null || b == null) return;
    setState(() => _comparison = compareTraces(a, b));
  }

  Future<void> _openWebsite() async {
    final site = widget.host.regionSite;
    final uri = site == null ? Uri.parse('https://meshsonar.com/tools/routes') : site.replace(path: '/tools/routes');
    await widget.host.openUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    final tools = widget.tools;
    return ToolListener(
      sources: [_trace.changed],
      builder: (context) {
        final t = Theme.of(context);
        final result = _viewed ?? _trace.last;
        final amb = findAmbiguousHops(_hops, _hashSize, _contacts);
        return RefreshIndicator(
          onRefresh: _loadContacts,
          child: SingleChildScrollView(
            key: const Key('trace-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                'Send one small packet along a chain of repeaters you choose. Each repeater reports how well it heard the packet. '
                'The last repeater in the chain must be one your radio can hear directly. If any repeater in the chain is missing or out of range, nothing comes back.',
                style: t.textTheme.bodyMedium,
              ),
              const ToolHeading('Path'),
              if (_loading)
                const Row(key: Key('trace-loading'), children: [
                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: Gap.m),
                  Flexible(child: Text('Reading your radio’s contacts')),
                ])
              else if (_loadError != null)
                NoteCard(_loadError!, kind: NoteKind.problem, title: 'Contacts not read')
              else if (_pickable.isEmpty)
                const NoteCard('Your radio has no repeaters in its contact list yet. Use Discover nearby to find some and add them.',
                    key: Key('trace-no-contacts'), title: 'No repeaters yet'),
              if (_hops.isEmpty && !_loading && _pickable.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.s),
                  child: Text('No hops chosen yet. Add the repeaters in the order the packet should travel.', key: const Key('trace-no-hops'), style: t.textTheme.bodyMedium),
                ),
              for (var i = 0; i < _hops.length; i++) _hopRow(context, i),
              const SizedBox(height: Gap.s),
              Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
                OutlinedButton.icon(
                  key: const Key('trace-add-hop'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
                  onPressed: _hops.length >= maxTraceHops || _pickable.isEmpty ? null : _addHop,
                  icon: const Icon(Icons.add),
                  label: Text(_hops.length >= maxTraceHops ? 'Longest path ($maxTraceHops hops)' : 'Add a hop'),
                ),
                if (_hops.isNotEmpty)
                  TextButton.icon(
                    key: const Key('trace-clear-hops'),
                    style: TextButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
                    onPressed: () => setState(_hops.clear),
                    icon: const Icon(Icons.clear_all),
                    label: const Text('Clear path'),
                  ),
                TextButton.icon(
                  key: const Key('trace-refresh'),
                  style: TextButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
                  onPressed: _loading ? null : _loadContacts,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh contacts'),
                ),
              ]),
              const ToolHeading('Hash size'),
              SegmentedButton<int>(
                key: const Key('trace-hash-size'),
                showSelectedIcon: false,
                style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(kToolTarget, kToolTarget))),
                segments: [for (final s in traceHashSizes) ButtonSegment(value: s, label: Text('$s byte${s == 1 ? '' : 's'}'), tooltip: '$s-byte hashes')],
                selected: {_hashSize},
                onSelectionChanged: (v) => setState(() => _hashSize = v.first),
              ),
              Padding(
                padding: const EdgeInsets.only(top: Gap.s),
                child: Text(
                  'The radio sends the first $_hashSize byte${_hashSize == 1 ? '' : 's'} of each repeater’s key. A 1-byte hash can match more than one repeater; 2 or 4 bytes tell them apart.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ),
              for (final a in amb)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  child: NoteCard(
                    'Hop ${a.index + 1} (${a.stop.name}) shares its ${_hashSize == 1 ? '1-byte' : '$_hashSize-byte'} hash with ${a.otherNames.join(', ')}. '
                    'The packet may go through the other one. Use a longer hash.',
                    key: Key('trace-ambiguous-${a.index}'),
                    kind: NoteKind.caution,
                    title: 'Ambiguous hop',
                  ),
                ),
              const SizedBox(height: Gap.l),
              CooldownButton(
                key: const Key('trace-send'),
                label: 'Send trace',
                icon: Icons.route,
                cooldown: _trace.cooldown,
                busy: _trace.running,
                onPressed: _hops.isEmpty ? null : _run,
              ),
              const SizedBox(height: Gap.s),
              AirtimeNote(tools: tools, ms: _trace.estimateAirtimeMs(_hops.isEmpty ? 1 : _hops.length, _hashSize), action: 'This trace'),
              const ToolHeading('Result'),
              if (result == null)
                Text('No trace yet. Choose a path and send it.', key: const Key('trace-no-result'), style: t.textTheme.bodyMedium)
              else
                _ResultCard(
                  key: const Key('trace-result'),
                  result: result,
                  saved: _trace.store.contains(result.id),
                  onSave: _viewed != null || !result.ok
                      ? null
                      : () async {
                          await _trace.saveLast();
                          if (mounted) setState(() {});
                        },
                ),
              if (result != null) ...[
                const SizedBox(height: Gap.m),
                OutlinedButton.icon(
                  key: const Key('trace-website'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
                  onPressed: _openWebsite,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Analyze routes on the website'),
                ),
              ],
              ..._savedSection(context),
            ]),
          ),
        );
      },
    );
  }

  Widget _hopRow(BuildContext context, int i) {
    final t = Theme.of(context);
    final h = _hops[i];
    final hash = h.hashHex(_hashSize);
    return Semantics(
      container: true,
      label: 'Hop ${i + 1}, ${h.name}, hash $hash${h.hasPosition ? ', position known' : ', position unknown'}',
      child: Padding(
        key: Key('trace-hop-$i'),
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 28, height: 28, child: NumberDot(i + 1, color: t.colorScheme.primary)),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(h.name, style: t.textTheme.titleSmall),
              Text('hash $hash${h.hasPosition ? '' : ' · position unknown'}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
          IconButton(
            key: Key('trace-hop-$i-up'),
            tooltip: 'Move hop ${i + 1} earlier',
            constraints: const BoxConstraints(minWidth: kToolTarget, minHeight: kToolTarget),
            onPressed: i == 0
                ? null
                : () => setState(() {
                      final x = _hops.removeAt(i);
                      _hops.insert(i - 1, x);
                    }),
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            key: Key('trace-hop-$i-down'),
            tooltip: 'Move hop ${i + 1} later',
            constraints: const BoxConstraints(minWidth: kToolTarget, minHeight: kToolTarget),
            onPressed: i == _hops.length - 1
                ? null
                : () => setState(() {
                      final x = _hops.removeAt(i);
                      _hops.insert(i + 1, x);
                    }),
            icon: const Icon(Icons.arrow_downward),
          ),
          IconButton(
            key: Key('trace-hop-$i-remove'),
            tooltip: 'Remove hop ${i + 1}',
            constraints: const BoxConstraints(minWidth: kToolTarget, minHeight: kToolTarget),
            onPressed: () => setState(() => _hops.removeAt(i)),
            icon: const Icon(Icons.close),
          ),
        ]),
      ),
    );
  }

  List<Widget> _savedSection(BuildContext context) {
    final t = Theme.of(context);
    final items = _trace.store.items;
    final last = _trace.last;
    final canCompare = _compare.length == 2 || (_compare.length == 1 && last != null && last.ok && !_compare.contains(last.id));
    return [
      const ToolHeading('Saved traces'),
      if (items.isEmpty)
        Text('Nothing saved. Save a trace that worked to compare it with a later one.', key: const Key('trace-no-saved'), style: t.textTheme.bodyMedium)
      else ...[
        for (final s in items) _savedRow(context, s),
        const SizedBox(height: Gap.s),
        FilledButton.icon(
          key: const Key('trace-compare'),
          style: FilledButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
          onPressed: canCompare ? _doCompare : null,
          icon: const Icon(Icons.compare_arrows),
          label: Text(_compare.length == 1 ? 'Compare with the latest trace' : 'Compare the two ticked traces'),
        ),
        if (_compare.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text('Tick two saved traces, or one saved trace to compare with the latest.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
      ],
      if (_comparison != null) _ComparisonCard(key: const Key('trace-comparison'), cmp: _comparison!),
    ];
  }

  Widget _savedRow(BuildContext context, TraceResult s) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final chain = s.hops.map((h) => h.stop.name).join(' → ');
    final km = s.totalKm;
    final line = '${s.ok ? 'Worked' : 'No answer'} · ${fmtClock(s.at)}${km == null ? '' : ' · ${units.distance(km * 1000)}'}';
    return Semantics(
      container: true,
      label: 'Saved trace. $chain. $line',
      child: Row(key: Key('trace-saved-${s.id}'), children: [
        Checkbox(
          key: Key('trace-saved-${s.id}-tick'),
          value: _compare.contains(s.id),
          onChanged: (_) => _toggleCompare(s.id),
        ),
        Expanded(
          child: InkWell(
            key: Key('trace-saved-${s.id}-open'),
            onTap: () => setState(() => _viewed = s),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kToolTarget),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(chain.isEmpty ? 'Empty path' : chain, style: t.textTheme.titleSmall),
                  Text(line, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ]),
              ),
            ),
          ),
        ),
        IconButton(
          key: Key('trace-saved-${s.id}-delete'),
          tooltip: 'Delete this saved trace',
          constraints: const BoxConstraints(minWidth: kToolTarget, minHeight: kToolTarget),
          onPressed: () async {
            await _trace.store.remove(s.id);
            if (!mounted) return;
            setState(() {
              _compare.remove(s.id);
              _comparison = null;
              if (_viewed?.id == s.id) _viewed = null;
            });
          },
          icon: const Icon(Icons.delete_outline),
        ),
      ]),
    );
  }
}

class _PickerSheet extends StatelessWidget {
  final List<RadioContact> contacts;
  const _PickerSheet({required this.contacts});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SafeArea(
      child: ListView(
        key: const Key('trace-picker'),
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: Gap.l),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
            child: Semantics(header: true, child: Text('Choose a repeater', style: t.textTheme.titleMedium)),
          ),
          for (final c in contacts)
            ListTile(
              key: Key('trace-pick-${c.publicKeyHex.substring(0, 8)}'),
              minVerticalPadding: Gap.s,
              leading: Icon(c.type == AdvType.room ? Icons.forum_outlined : Icons.cell_tower),
              title: Text(c.name.isEmpty ? 'Node ${c.publicKeyHex.substring(0, 8)}' : c.name),
              subtitle: Text('${c.type == AdvType.room ? 'Room' : 'Repeater'} · key ${c.publicKeyHex.substring(0, 8)} · ${c.lat == null ? 'position unknown' : 'position known'}'),
              onTap: () => Navigator.of(context).pop(c),
            ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final TraceResult result;
  final bool saved;
  final VoidCallback? onSave;
  const _ResultCard({super.key, required this.result, required this.saved, required this.onSave});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final mc = MeshSonarColors.of(context);
    final r = result;
    final (NoteKind kind, String title) = switch (r.status) {
      TraceStatus.ok => (NoteKind.good, 'Trace complete'),
      TraceStatus.silent => (NoteKind.caution, 'No answer'),
      TraceStatus.refused => (NoteKind.problem, 'The radio refused the trace'),
      TraceStatus.notConnected => (NoteKind.problem, 'No radio'),
      TraceStatus.tooSoon => (NoteKind.info, 'One moment'),
      TraceStatus.invalid => (NoteKind.info, 'Check the path'),
    };
    final note = r.ok
        ? 'Sent at ${fmtClock(r.at)}${r.elapsed == null ? '' : ', answered in ${(r.elapsed!.inMilliseconds / 1000).toStringAsFixed(1)} s'}. Hash size ${r.hashSize} byte${r.hashSize == 1 ? '' : 's'}.${r.detail == null ? '' : ' ${r.detail}'}'
        : '${r.detail ?? ''}${r.status == TraceStatus.silent ? ' Try a shorter path, or start with a repeater your radio hears directly.' : ''}';
    final start = (r.originLat != null && r.originLon != null) ? LatLng(r.originLat!, r.originLon!) : null;
    final pins = <MapPin>[
      if (start != null) MapPin(point: start, label: 'Your position', icon: Icons.person_pin_circle, color: t.colorScheme.primary),
      for (var i = 0; i < r.hops.length; i++)
        if (r.hops[i].stop.hasPosition)
          MapPin(point: LatLng(r.hops[i].stop.lat!, r.hops[i].stop.lon!), label: 'Hop ${i + 1}, ${r.hops[i].stop.name}', child: NumberDot(i + 1, color: mc.beacon)),
    ];
    final lines = <MapLine>[];
    LatLng? prev = start;
    for (final h in r.hops) {
      if (!h.stop.hasPosition) continue;
      final p = LatLng(h.stop.lat!, h.stop.lon!);
      if (prev != null) lines.add(MapLine([prev, p], mc.forPing(heard: h.snrDb != null, snr: h.snrDb)));
      prev = p;
    }
    final unplaced = [for (final h in r.hops) if (!h.stop.hasPosition) h.stop.name];
    final km = r.totalKm;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      NoteCard(note, kind: kind, title: title),
      if (r.ok) ...[
        const SizedBox(height: Gap.m),
        for (var i = 0; i < r.hops.length; i++) _hopResult(context, i, r.hops[i], units),
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: Semantics(
            container: true,
            label: 'Heard back at ${fmtSnr(r.finalSnrDb)}',
            excludeSemantics: true,
            child: Row(key: const Key('trace-final'), children: [
              const Icon(Icons.keyboard_return, size: 20),
              const SizedBox(width: Gap.s),
              Expanded(child: Text('Heard back at ${fmtSnr(r.finalSnrDb)}', style: t.textTheme.titleSmall)),
            ]),
          ),
        ),
        if (km != null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
              'Total distance ${units.distance(km * 1000)}${r.distancePartial ? ' (partial: ${unplaced.join(', ')} ${unplaced.length == 1 ? 'has' : 'have'} no known position)' : ''}',
              key: const Key('trace-total'),
              style: t.textTheme.bodyMedium,
            ),
          ),
        if (km == null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text('No distance: no position is known for this path.', key: const Key('trace-total'), style: t.textTheme.bodyMedium),
          ),
        const SizedBox(height: Gap.m),
        ToolMap(
          pins: pins,
          lines: lines,
          semanticLabel: pins.isEmpty
              ? 'No positions are known for this path, so there is no map.'
              : 'Map of the route: ${r.hops.length} hops${km == null ? '' : ', ${units.distance(km * 1000)} in total'}${unplaced.isEmpty ? '' : '. Not on the map, position unknown: ${unplaced.join(', ')}'}.',
        ),
        const SizedBox(height: Gap.s),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: saved
              ? const Row(mainAxisSize: MainAxisSize.min, key: Key('trace-saved-note'), children: [Icon(Icons.bookmark, size: 20), SizedBox(width: Gap.s), Text('Saved')])
              : OutlinedButton.icon(
                  key: const Key('trace-save'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
                  onPressed: onSave,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Save this trace'),
                ),
        ),
      ],
    ]);
  }

  Widget _hopResult(BuildContext context, int i, TraceHopResult h, Units units) {
    final t = Theme.of(context);
    final dist = h.distanceKm == null ? null : units.distance(h.distanceKm! * 1000);
    final text = 'Hop ${i + 1}, ${h.stop.name}, hash ${h.hashHex}. Heard it at ${fmtSnr(h.snrDb)}.'
        '${dist == null ? '' : ' $dist from the previous point.'}${h.ambiguous ? ' Ambiguous hash.' : ''}';
    return Semantics(
      container: true,
      label: text,
      excludeSemantics: true,
      child: Padding(
        key: Key('trace-result-hop-$i'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 28, height: 28, child: NumberDot(i + 1, color: t.colorScheme.primary)),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(h.stop.name, style: t.textTheme.titleSmall),
              Text('hash ${h.hashHex} · heard at ${fmtSnr(h.snrDb)}', style: t.textTheme.bodyMedium),
              if (dist != null) Text('$dist from the previous point', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              if (h.ambiguous)
                Row(children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: t.colorScheme.tertiary),
                  const SizedBox(width: Gap.xs),
                  const Flexible(child: Text('Ambiguous hash: another repeater shares it')),
                ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ComparisonCard extends StatelessWidget {
  final TraceComparison cmp;
  const _ComparisonCard({super.key, required this.cmp});

  static String _delta(double? d) {
    if (d == null) return 'no comparison';
    if (d.abs() < 0.5) return 'about the same (${fmtDb(d)})';
    return d > 0 ? 'better by ${fmtDb(d.abs())}' : 'worse by ${fmtDb(d.abs())}';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final deltas = cmp.deltas;
    final fin = cmp.finalA == null || cmp.finalB == null ? null : cmp.finalB! - cmp.finalA!;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Comparison: ${fmtClock(cmp.a.at)} against ${fmtClock(cmp.b.at)}', style: t.textTheme.titleSmall),
        if (!cmp.sameChain)
          const Padding(
            padding: EdgeInsets.only(top: Gap.s),
            child: NoteCard('These two traces went through different repeaters. Only the repeaters in the second trace are compared.', kind: NoteKind.caution, title: 'Different chains'),
          ),
        for (var i = 0; i < cmp.rows.length; i++)
          Semantics(
            container: true,
            excludeSemantics: true,
            label: '${cmp.rows[i].name}: first ${fmtSnr(cmp.rows[i].snrA)}, second ${fmtSnr(cmp.rows[i].snrB)}, ${_delta(deltas[i])}',
            child: Padding(
              key: Key('trace-cmp-row-$i'),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(cmp.rows[i].name, style: t.textTheme.titleSmall),
                Text('First ${fmtSnr(cmp.rows[i].snrA)}'),
                Text('Second ${fmtSnr(cmp.rows[i].snrB)}'),
                Text(_delta(deltas[i]), style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        Semantics(
          container: true,
          excludeSemantics: true,
          label: 'Heard back: first ${fmtSnr(cmp.finalA)}, second ${fmtSnr(cmp.finalB)}, ${_delta(fin)}',
          child: Padding(
            key: const Key('trace-cmp-final'),
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text('Heard back: first ${fmtSnr(cmp.finalA)}, second ${fmtSnr(cmp.finalB)}, ${_delta(fin)}', style: t.textTheme.bodyMedium),
          ),
        ),
      ]),
    );
  }
}
