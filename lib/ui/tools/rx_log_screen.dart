// Rx log: a live list of every packet the radio hears, decoded to its header only. The privacy rules (no message text, no
// decryption, bounded memory) are enforced in lib/radio/tools/rx_log.dart; this screen says them out loud.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../radio/tools/radio_tools.dart';
import '../../radio/tools/rx_log.dart';
import '../../radio/tools/transport_code.dart';
import '../theme.dart';
import 'advert_facts.dart';
import 'tool_kit.dart';
import 'tools_host.dart';

class RxLogScreen extends StatelessWidget {
  const RxLogScreen({super.key});

  @override
  Widget build(BuildContext context) => ToolPage(
        id: 'rx-log',
        title: 'Rx log',
        builder: (context, host, tools) => _RxLogBody(host: host, tools: tools),
      );
}

class _RxLogBody extends StatefulWidget {
  final ToolsHost host;
  final RadioTools tools;
  const _RxLogBody({required this.host, required this.tools});
  @override
  State<_RxLogBody> createState() => _RxLogBodyState();
}

class _RxLogBodyState extends State<_RxLogBody> {
  RxLogFilter _filter = const RxLogFilter();
  String? _copied;

  RxLog get _log => widget.tools.rxLog;

  @override
  void initState() {
    super.initState();
    widget.tools.startListening();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    final c = await widget.host.knownChannels();
    if (mounted) _log.knownChannels = c;
  }

  Future<void> _export() async {
    final rows = _log.entries(_filter).length;
    await Clipboard.setData(ClipboardData(text: _log.exportCsv(_filter)));
    if (!mounted) return;
    setState(() => _copied = 'Copied $rows ${rows == 1 ? 'row' : 'rows'} (headers only, no message text)');
  }

  void _toggleType(int type) {
    final types = {..._filter.types};
    if (!types.add(type)) types.remove(type);
    setState(() => _filter = _filter.copyWith(types: types));
  }

  @override
  Widget build(BuildContext context) {
    return ToolListener(sources: [_log.changed], builder: _build);
  }

  Widget _build(BuildContext context) {
    final t = Theme.of(context);
    final entries = _log.entries(_filter);
    final counts = _log.countsByType;
    final typeKeys = counts.keys.toList()..sort();
    final header = <Widget>[
      NoteCard(
        'This shows packet headers only. The text of channel messages is never read or stored. Channels you have joined are only '
        'named, by checking a short code; nothing is decrypted. The log keeps the last ${_log.capacity} packets in memory and '
        'forgets them when the app closes.',
        key: const Key('rxlog-privacy'),
        title: 'Privacy',
      ),
      const SizedBox(height: Gap.m),
      Wrap(spacing: Gap.s, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OutlinedButton.icon(
          key: const Key('rxlog-pause'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
          onPressed: _log.paused ? _log.resume : _log.pause,
          icon: Icon(_log.paused ? Icons.play_arrow : Icons.pause),
          label: Text(_log.paused ? 'Resume' : 'Pause'),
        ),
        OutlinedButton.icon(
          key: const Key('rxlog-clear'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
          onPressed: _log.clear,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Clear'),
        ),
        OutlinedButton.icon(
          key: const Key('rxlog-export'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
          onPressed: _export,
          icon: const Icon(Icons.copy_all_outlined),
          label: const Text('Copy as CSV'),
        ),
        OutlinedButton.icon(
          key: const Key('rxlog-filter'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
          onPressed: _openFilter,
          icon: const Icon(Icons.filter_list),
          label: const Text('Filter'),
        ),
        IconButton(
          key: const Key('rxlog-refresh'),
          tooltip: 'Reload the channels you have joined',
          constraints: const BoxConstraints(minWidth: kToolTarget, minHeight: kToolTarget),
          onPressed: _loadChannels,
          icon: const Icon(Icons.refresh),
        ),
      ]),
      if (_copied != null)
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: Text(_copied!, key: const Key('rxlog-copied'), style: t.textTheme.bodyMedium),
        ),
      if (_log.paused)
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: NoteCard('Paused: ${_log.missedWhilePaused} ${_log.missedWhilePaused == 1 ? 'packet' : 'packets'} not listed. They are still counted.',
              key: const Key('rxlog-paused'), kind: NoteKind.caution),
        ),
      const SizedBox(height: Gap.m),
      Text(
        '${_log.total} heard, ${_log.length} kept${_log.invalid > 0 ? ', ${_log.invalid} not valid packets' : ''}',
        key: const Key('rxlog-totals'),
        style: t.textTheme.titleSmall,
      ),
      if (typeKeys.isNotEmpty)
        Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
          for (final k in typeKeys)
            FilterChip(
              key: Key('rxlog-type-$k'),
              label: Text('${payloadTypeName(k)} ${counts[k]}'),
              selected: _filter.types.contains(k),
              onSelected: (_) => _toggleType(k),
            ),
        ]),
      if (!_filter.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Row(children: [
            Expanded(child: Text('Filter on: ${entries.length} shown of ${_log.length} kept', key: const Key('rxlog-filter-note'), style: t.textTheme.bodyMedium)),
            TextButton(
              key: const Key('rxlog-filter-clear'),
              style: TextButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
              onPressed: () => setState(() => _filter = const RxLogFilter()),
              child: const Text('Clear filter'),
            ),
          ]),
        ),
      const SizedBox(height: Gap.s),
      if (entries.isEmpty)
        const NoteCard('Nothing heard yet. A quiet mesh can stay silent for minutes. Your own radio’s sends and replies appear here too.',
            key: Key('rxlog-empty')),
    ];
    return ListView.builder(
      key: const Key('rxlog-list'),
      padding: const EdgeInsets.all(Gap.l),
      itemCount: header.length + entries.length,
      itemBuilder: (context, i) {
        if (i < header.length) return header[i];
        return _RxRow(entry: entries[i - header.length], host: widget.host);
      },
    );
  }

  void _openFilter() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        void apply(RxLogFilter f) {
          setState(() => _filter = f);
          setSheet(() {});
        }

        final types = _log.countsByType.keys.toList()..sort();
        final routes = _log.countsByRoute.keys.toList()..sort();
        return SafeArea(
          child: SingleChildScrollView(
            key: const Key('rxlog-filter-sheet'),
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(header: true, child: Text('Filter', style: Theme.of(ctx).textTheme.titleLarge)),
              const ToolHeading('Packet types'),
              Wrap(spacing: Gap.s, children: [
                for (final k in types)
                  FilterChip(
                    key: Key('rxlog-filter-type-$k'),
                    label: Text(payloadTypeName(k)),
                    selected: _filter.types.contains(k),
                    onSelected: (on) => apply(_filter.copyWith(types: on ? {..._filter.types, k} : ({..._filter.types}..remove(k)))),
                  ),
              ]),
              const ToolHeading('Routes'),
              Wrap(spacing: Gap.s, children: [
                for (final r in routes)
                  FilterChip(
                    key: Key('rxlog-filter-route-$r'),
                    label: Text(routeName(r)),
                    selected: _filter.routes.contains(r),
                    onSelected: (on) => apply(_filter.copyWith(routes: on ? {..._filter.routes, r} : ({..._filter.routes}..remove(r)))),
                  ),
              ]),
              const ToolHeading('Fewest hops'),
              Wrap(spacing: Gap.s, children: [
                for (final h in [0, 1, 2, 3])
                  ChoiceChip(
                    key: Key('rxlog-filter-hops-$h'),
                    label: Text(h == 0 ? 'Any' : (h == 3 ? '3 or more' : '$h or more')),
                    selected: _filter.minHops == h,
                    onSelected: (_) => apply(_filter.copyWith(minHops: h)),
                  ),
              ]),
              SwitchListTile(
                key: const Key('rxlog-filter-known'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Only channels I have joined'),
                value: _filter.knownChannelsOnly,
                onChanged: (v) => apply(_filter.copyWith(knownChannelsOnly: v)),
              ),
            ]),
          ),
        );
      }),
    );
  }
}

String _routeWords(RxLogEntry e) {
  final p = e.packet;
  if (p == null) return 'not a valid packet';
  final r = routeName(p.routeType);
  final hops = p.hopCount == 0 ? 'direct' : '${p.hopCount} ${p.hopCount == 1 ? 'hop' : 'hops'}, ${p.pathHashSize}-byte hashes';
  return '$r, $hops';
}

String? _scopeWords(RxLogEntry e, List<String> names) {
  final p = e.packet;
  if (p == null || !p.hasTransportCodes) return null;
  final r = checkScope(p, names);
  return r.verdict == ScopeVerdict.inScope ? r.label : 'scoped, not to a region you are viewing';
}

class _RxRow extends StatelessWidget {
  final RxLogEntry entry;
  final ToolsHost host;
  const _RxRow({required this.entry, required this.host});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final t = Theme.of(context);
    final scope = _scopeWords(e, host.scopeNames);
    final signal = [
      if (e.snrDb != null) fmtDb(e.snrDb),
      if (e.rssiDbm != null) '${e.rssiDbm!.toStringAsFixed(0)} dBm',
      '${e.length} bytes',
    ].join(', ');
    final lines = <String>[
      _routeWords(e),
      if (e.pathHex.isNotEmpty) 'Path ${e.pathHex.join(' > ')}',
      signal,
      ?scope,
    ];
    return Card(
      key: Key('rxlog-row-${e.seq}'),
      margin: const EdgeInsets.only(bottom: Gap.xs),
      child: InkWell(
        borderRadius: BorderRadius.circular(Corners.card),
        onTap: () => _detail(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kToolTarget),
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Semantics(
              container: true,
              button: true,
              label: '${fmtClock(e.at)}. ${e.summary}. ${lines.join('. ')}. Opens details.',
              excludeSemantics: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${fmtClock(e.at)}  ${e.summary}', style: t.textTheme.titleSmall),
                for (final l in lines) Text(l, style: t.textTheme.bodySmall),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  void _detail(BuildContext context) {
    final e = entry;
    final p = e.packet;
    final a = e.advert;
    showToolSheet(context, key: const Key('rxlog-detail'), title: e.summary, children: [
      FactRows([
        ('Heard at', fmtClock(e.at)),
        if (p != null) ...[
          ('Route', routeName(p.routeType)),
          ('Packet type', payloadTypeName(p.payloadType)),
          ('Version', '${p.payloadVersion}'),
          ('Hash size', '${p.pathHashSize} ${p.pathHashSize == 1 ? 'byte' : 'bytes'}'),
          ('Hops', '${p.hopCount}'),
          ('Path', p.path.isEmpty ? 'none (heard directly)' : e.pathHex.join(' > ')),
          if (p.hasTransportCodes) ('Transport codes', '${_hex16(p.transportCode1)} ${_hex16(p.transportCode2)}'),
          ?(_scopeWords(e, host.scopeNames) == null ? null : ('Region scope', _scopeWords(e, host.scopeNames)!)),
          if (e.isGroup) ('Channel hash byte', e.channelHashHex ?? 'none'),
          if (e.isGroup) ('Channel', e.knownChannel == null ? 'another channel (not one you have joined)' : 'known channel: ${e.knownChannel}'),
        ],
        ('SNR', fmtSnr(e.snrDb)),
        ('RSSI', e.rssiDbm == null ? 'unknown' : '${e.rssiDbm!.toStringAsFixed(0)} dBm'),
        ('Length', '${e.length} bytes'),
        if (a != null) ...[
          ('Advert name', a.name.isEmpty ? '(none)' : a.name),
          ('Advert type', advertTypeName(a.nodeType)),
          ('Advert key', a.publicKeyHex),
          if (a.hasPosition) ('Advert position', '${a.lat!.toStringAsFixed(5)}, ${a.lon!.toStringAsFixed(5)}'),
        ],
      ]),
      if (e.isGroup)
        const Padding(
          padding: EdgeInsets.only(top: Gap.s),
          child: Text('Message text is never shown here.'),
        ),
    ]);
  }

  static String _hex16(int? v) => v == null ? '----' : '0x${v.toRadixString(16).padLeft(4, '0')}';
}
