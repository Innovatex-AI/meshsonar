// Discover nearby: one zero-hop NODE_DISCOVER_REQ; nearby repeaters, rooms and sensors answer with their key and the SNR at
// which THEY heard the request, and this radio measures the answer, so both directions are shown. Repeaters answer at most
// 4 requests per 2 minutes, so the tool counts them and shows the wait as a cooldown, never an error.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../radio/protocol.dart' show AdvType;
import '../../radio/tools/discover_tool.dart';
import '../../radio/tools/radio_tools.dart';
import '../app.dart';
import 'tool_kit.dart';
import 'tools_host.dart';

class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) => ToolPage(
        id: 'discover',
        title: 'Discover nearby',
        builder: (context, host, tools) => _DiscoverBody(key: ValueKey(identityHashCode(tools)), host: host, tools: tools),
      );
}

class _DiscoverBody extends StatefulWidget {
  final ToolsHost host;
  final RadioTools tools;
  const _DiscoverBody({super.key, required this.host, required this.tools});
  @override
  State<_DiscoverBody> createState() => _DiscoverBodyState();
}

class _DiscoverBodyState extends State<_DiscoverBody> {
  final Set<int> _types = {AdvType.repeater, AdvType.room, AdvType.sensor};
  String? _addNote;

  DiscoverTool get _d => widget.tools.discover;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    try {
      final list = await widget.tools.radio.contacts();
      if (mounted) _d.setContacts(list);
    } catch (_) {
      // Names and "already added" are a nicety; the scan works without them.
    }
  }

  Future<void> _scan() async {
    setState(() => _addNote = null);
    await _d.scan(types: _types);
    if (mounted) setState(() {});
  }

  Future<void> _add(DiscoveredNode n) async {
    final err = await _d.addToContacts(n);
    if (!mounted) return;
    final text = err ?? '${n.displayName} is now in your radio’s contacts.';
    setState(() => _addNote = text);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  static String _typeWord(int t) => switch (t) { AdvType.repeater => 'Repeater', AdvType.room => 'Room', AdvType.sensor => 'Sensor', AdvType.chat => 'Chat node', _ => 'Node' };

  @override
  Widget build(BuildContext context) {
    final tools = widget.tools;
    return ToolListener(
      sources: [_d.changed],
      builder: (context) {
        final t = Theme.of(context);
        final scanning = _d.status == DiscoverStatus.scanning;
        final results = _d.results;
        return SingleChildScrollView(
          key: const Key('discover-list'),
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              'A scan sends one tiny packet that only radios in direct range hear. Nearby repeaters, rooms and sensors answer, and MeshSonar measures the signal in both directions.',
              style: t.textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.s),
            Text('Repeaters answer 4 scans every 2 minutes, so MeshSonar counts them for you.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const ToolHeading('Look for'),
            Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
              for (final (type, label) in [(AdvType.repeater, 'Repeaters'), (AdvType.room, 'Rooms'), (AdvType.sensor, 'Sensors')])
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: kToolTarget),
                  child: FilterChip(
                    key: Key('discover-type-$type'),
                    label: Text(label),
                    selected: _types.contains(type),
                    onSelected: scanning
                        ? null
                        : (on) => setState(() {
                              if (on) {
                                _types.add(type);
                              } else if (_types.length > 1) {
                                _types.remove(type);
                              }
                            }),
                  ),
                ),
            ]),
            const SizedBox(height: Gap.l),
            CooldownButton(
              key: const Key('discover-scan'),
              label: 'Scan now',
              icon: Icons.radar,
              cooldown: _d.cooldown,
              busy: scanning,
              onPressed: _scan,
            ),
            const SizedBox(height: Gap.s),
            Text('Scans left: ${_d.requestsLeft} of 4', key: const Key('discover-left'), style: t.textTheme.bodyMedium),
            const SizedBox(height: Gap.xs),
            AirtimeNote(tools: tools, ms: _d.estimateAirtimeMs(), action: 'A scan'),
            const SizedBox(height: Gap.m),
            if (scanning)
              Semantics(
                liveRegion: true,
                child: Row(key: const Key('discover-scanning'), children: [
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: Gap.m),
                  Flexible(child: Text('Listening for answers… ${results.length} found')),
                ]),
              )
            else
              ..._statusNote(),
            if (_addNote != null)
              Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text(_addNote!, key: const Key('discover-add-note'), style: t.textTheme.bodyMedium)),
            if (results.isNotEmpty) ...[
              const ToolHeading('Found'),
              _map(context, results),
              const SizedBox(height: Gap.s),
              for (var i = 0; i < results.length; i++) _row(context, i, results[i]),
            ],
          ]),
        );
      },
    );
  }

  List<Widget> _statusNote() {
    final m = _d.message;
    return switch (_d.status) {
      DiscoverStatus.cooldown => [NoteCard(m ?? 'Wait a little before the next scan.', key: const Key('discover-cooldown'), title: 'Waiting for the next scan')],
      DiscoverStatus.refused || DiscoverStatus.notConnected => [NoteCard(m ?? 'The scan did not go out.', key: const Key('discover-problem'), kind: NoteKind.problem, title: 'Scan failed')],
      DiscoverStatus.done when _d.results.isEmpty => [NoteCard(m ?? 'Nothing answered.', key: const Key('discover-empty'), kind: NoteKind.caution, title: 'Nothing answered')],
      DiscoverStatus.idle => [Text('No scan yet. Tap Scan now.', key: const Key('discover-idle'), style: Theme.of(context).textTheme.bodyMedium)],
      _ => const [],
    };
  }

  Widget _map(BuildContext context, List<DiscoveredNode> results) {
    final mc = MeshSonarColors.of(context);
    final me = widget.host.lastPosition;
    final placed = [for (final n in results) if (n.lat != null && n.lon != null) n];
    final unplaced = results.length - placed.length;
    final label = placed.isEmpty
        ? 'No position is known for the ${results.length} node${results.length == 1 ? '' : 's'} found, so there is no map.'
        : 'Map of ${placed.length} node${placed.length == 1 ? '' : 's'} found${unplaced == 0 ? '' : ', and $unplaced more without a known position'}.';
    return ToolMap(
      pins: [
        if (me != null && placed.isNotEmpty)
          MapPin(point: LatLng(me.lat, me.lon), label: 'You', icon: Icons.person_pin_circle, color: Theme.of(context).colorScheme.primary),
        for (final n in placed) MapPin(point: LatLng(n.lat!, n.lon!), label: n.displayName, icon: Icons.cell_tower, color: mc.forPing(heard: true, snr: n.weakestSnrDb)),
      ],
      semanticLabel: label,
    );
  }

  Widget _row(BuildContext context, int i, DiscoveredNode n) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final me = widget.host.lastPosition;
    final km = me == null ? null : _d.distanceKm(n, me.lat, me.lon);
    final dist = km == null ? null : units.distance(km * 1000);
    final hearYou = 'They hear you at ${fmtSnr(n.snrTheyHeardDb)}';
    final youHear = 'You hear them at ${fmtSnr(n.snrHeardDb)} (${n.rssiDbm.round()} dBm)';
    final label = '${n.displayName}, ${_typeWord(n.nodeType)}. $hearYou. $youHear.${dist == null ? '' : ' $dist away.'}${n.inContacts ? ' In your contacts.' : ''}';
    return Padding(
      key: Key('discover-result-$i'),
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(
          container: true,
          label: label,
          excludeSemantics: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.displayName, style: t.textTheme.titleSmall),
            Text('${_typeWord(n.nodeType)} · key ${n.shortKey}${n.hasFullKey ? '' : ' (start only)'}${dist == null ? '' : ' · $dist away'}',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.xs),
            Text(hearYou, key: Key('discover-result-$i-out')),
            Text(youHear, key: Key('discover-result-$i-in')),
          ]),
        ),
        const SizedBox(height: Gap.xs),
        if (n.inContacts)
          Row(key: Key('discover-result-$i-added'), mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check_circle_outline, size: 20, color: t.colorScheme.primary),
            const SizedBox(width: Gap.xs),
            const Flexible(child: Text('In your contacts')),
          ])
        else ...[
          OutlinedButton.icon(
            key: Key('discover-result-$i-add'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
            onPressed: n.hasFullKey ? () => _add(n) : null,
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Add to contacts'),
          ),
          if (!n.hasFullKey)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text('Only the start of this node’s key came back, so it cannot be added. Scan again.',
                  key: Key('discover-result-$i-why'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ),
        ],
      ]),
    );
  }
}
