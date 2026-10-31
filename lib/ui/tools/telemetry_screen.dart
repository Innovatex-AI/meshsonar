// Telemetry: ask this radio or a contact for its sensor readings (battery, temperature, position, ...).
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/heard.dart' show haversineM;
import '../../radio/inbound.dart';
import '../../radio/protocol.dart' show AdvType;
import '../../radio/tools/lpp.dart';
import '../../radio/tools/radio_tools.dart';
import '../../radio/tools/telemetry_tool.dart';
import '../app.dart';
import 'tool_kit.dart';
import 'tools_host.dart';

/// "45.0 °C" or "113.0 °F".
String formatTemperature(double celsius, {required bool imperial}) =>
    imperial ? '${(celsius * 9 / 5 + 32).toStringAsFixed(1)} °F' : '${celsius.toStringAsFixed(1)} °C';

String _typeWord(int t) => switch (t) { AdvType.chat => 'Chat', AdvType.repeater => 'Repeater', AdvType.room => 'Room', AdvType.sensor => 'Sensor', _ => 'Node' };

/// Repeaters, rooms and sensors first (they answer), then chat contacts; by name inside each group.
List<RadioContact> telemetryContactOrder(Iterable<RadioContact> all) {
  int rank(RadioContact c) => c.type == AdvType.chat ? 1 : 0;
  return all.toList()
    ..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
}

class TelemetryScreen extends StatelessWidget {
  const TelemetryScreen({super.key});

  @override
  Widget build(BuildContext context) => ToolPage(
        id: 'telemetry',
        title: 'Telemetry',
        builder: (context, host, tools) => _TelemetryBody(key: ValueKey(identityHashCode(tools)), host: host, tools: tools),
      );
}

class _TelemetryBody extends StatefulWidget {
  final ToolsHost host;
  final RadioTools tools;
  const _TelemetryBody({super.key, required this.host, required this.tools});
  @override
  State<_TelemetryBody> createState() => _TelemetryBodyState();
}

class _TelemetryBodyState extends State<_TelemetryBody> {
  bool _self = true;
  List<RadioContact>? _contacts;
  bool _loadingContacts = false;
  String? _contactsError;
  String? _picked;
  TelemetryResult? _shown;

  TelemetryTool get _t => widget.tools.telemetry;

  Future<void> _loadContacts() async {
    setState(() {
      _loadingContacts = true;
      _contactsError = null;
    });
    try {
      final c = await widget.tools.radio.contacts();
      if (!mounted) return;
      setState(() {
        _contacts = telemetryContactOrder(c);
        _loadingContacts = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingContacts = false;
        _contactsError = 'Could not read the radio’s contacts. Try again.';
      });
    }
  }

  Future<void> _readSelf() async {
    final r = await _t.requestSelf();
    if (mounted) setState(() => _shown = r);
  }

  Future<void> _ask() async {
    final c = _contacts?.where((c) => c.publicKeyHex == _picked).firstOrNull;
    if (c == null) return;
    final r = await _t.requestContact(c);
    if (mounted) setState(() => _shown = r);
  }

  @override
  Widget build(BuildContext context) {
    return ToolListener(
      sources: [_t.changed],
      builder: (context) {
        final t = Theme.of(context);
        final shown = _shown != null && _shown!.isSelf == _self ? _shown : null;
        return ListView(
          key: const Key('telemetry-list'),
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.xl),
          children: [
            SegmentedButton<bool>(
              key: const Key('telemetry-mode'),
              showSelectedIcon: false,
              style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.padded, minimumSize: WidgetStatePropertyAll(Size(kToolTarget, kToolTarget))),
              segments: const [
                ButtonSegment(value: true, label: Text('This radio'), tooltip: 'Read this radio’s sensors'),
                ButtonSegment(value: false, label: Text('A contact'), tooltip: 'Ask a contact over the air'),
              ],
              selected: {_self},
              onSelectionChanged: (s) {
                setState(() => _self = s.first);
                // Read the contact table only when it is wanted (it is a few hundred frames over Bluetooth).
                if (!_self && _contacts == null && !_loadingContacts) _loadContacts();
              },
            ),
            const SizedBox(height: Gap.m),
            if (_self) ..._selfControls(context) else ..._contactControls(context),
            if (_t.busy) ...[
              const SizedBox(height: Gap.m),
              Row(key: const Key('telemetry-busy'), children: [
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: Gap.m),
                Expanded(child: Text('Waiting for the answer…', style: t.textTheme.bodyMedium)),
              ]),
            ],
            if (shown != null) ...[
              const SizedBox(height: Gap.m),
              _ResultCard(result: shown, host: widget.host),
            ],
            _latest(context),
          ],
        );
      },
    );
  }

  List<Widget> _selfControls(BuildContext context) => [
        Text('Reads the sensors built into this radio. Nothing is sent over the air.', style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: Gap.m),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('telemetry-read-self'),
            style: FilledButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
            onPressed: _t.busy ? null : _readSelf,
            icon: const Icon(Icons.sensors),
            label: const Text('Read this radio'),
          ),
        ),
      ];

  List<Widget> _contactControls(BuildContext context) {
    final t = Theme.of(context);
    final contacts = _contacts;
    return [
      Text('A node answers only if it is set up to share telemetry, so silence is normal. Chat contacts usually do not answer.',
          style: t.textTheme.bodyMedium),
      const SizedBox(height: Gap.m),
      if (_loadingContacts)
        const Row(children: [SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: Gap.m), Text('Reading contacts…')])
      else if (_contactsError != null) ...[
        NoteCard(_contactsError!, key: const Key('telemetry-contacts-error'), kind: NoteKind.problem),
        const SizedBox(height: Gap.s),
        OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)), onPressed: _loadContacts, child: const Text('Try again')),
      ] else if (contacts == null || contacts.isEmpty)
        const NoteCard('This radio has no contacts yet. Use Discover nearby to find and add repeaters.', key: Key('telemetry-no-contacts'))
      else ...[
        Semantics(header: true, child: Text('Choose a contact', style: t.textTheme.titleSmall)),
        RadioGroup<String>(
          groupValue: _picked,
          onChanged: (v) => setState(() => _picked = v),
          child: Column(key: const Key('telemetry-contacts'), children: [
            for (final c in contacts)
              RadioListTile<String>(
                key: Key('telemetry-contact-${c.publicKeyHex.substring(0, 8)}'),
                value: c.publicKeyHex,
                title: Text(c.name.isEmpty ? 'Node ${c.publicKeyHex.substring(0, 8)}' : c.name),
                subtitle: Text('${_typeWord(c.type)} · ${c.publicKeyHex.substring(0, 8)}'),
              ),
          ]),
        ),
        const SizedBox(height: Gap.s),
        Align(
          alignment: Alignment.centerLeft,
          child: CooldownButton(
            key: const Key('telemetry-ask'),
            label: 'Ask for telemetry',
            icon: Icons.sensors,
            cooldown: _t.cooldown,
            busy: _t.busy,
            onPressed: _picked == null ? null : _ask,
          ),
        ),
        if (_picked == null) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text('Pick a contact first.', style: t.textTheme.bodySmall)),
        const SizedBox(height: Gap.s),
        AirtimeNote(tools: widget.tools, ms: _t.estimateAirtimeMs(), action: 'A telemetry request'),
      ],
    ];
  }

  Widget _latest(BuildContext context) {
    final t = Theme.of(context);
    final items = _t.latest.values.where((r) => r.ok).toList()..sort((a, b) => b.at.compareTo(a.at));
    if (items.isEmpty) return const SizedBox.shrink();
    final units = AppScope.unitsOf(context);
    final now = DateTime.now();
    return Column(key: const Key('telemetry-latest'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      const ToolHeading('Latest answers'),
      for (final r in items)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Semantics(
            container: true,
            label: '${r.who}: ${_summaryLine(r, units.temperatureImperial)}, ${fmtAgo(now.difference(r.at))}',
            excludeSemantics: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.who, style: t.textTheme.titleSmall),
              Text('${_summaryLine(r, units.temperatureImperial)} · ${fmtAgo(now.difference(r.at))}', style: t.textTheme.bodyMedium),
            ]),
          ),
        ),
    ]);
  }

  static String _summaryLine(TelemetryResult r, bool imperial) {
    final parts = <String>[
      if (r.battery != null) r.battery!.text,
      if (r.temperature != null) formatTemperature(r.temperature!.value!, imperial: imperial),
      if (r.position != null) 'position',
    ];
    return parts.isEmpty ? 'no readings' : parts.join(', ');
  }
}

class _ResultCard extends StatelessWidget {
  final TelemetryResult result;
  final ToolsHost host;
  const _ResultCard({required this.result, required this.host});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = result;
    final (NoteKind kind, String title) = switch (r.status) {
      TelemetryStatus.ok => (NoteKind.good, 'Answer from ${r.who}'),
      TelemetryStatus.empty => (NoteKind.info, 'No readings'),
      TelemetryStatus.silent => (NoteKind.info, 'No answer'),
      TelemetryStatus.noContact => (NoteKind.caution, 'Not a contact yet'),
      TelemetryStatus.refused => (NoteKind.caution, 'The radio refused'),
      TelemetryStatus.notConnected => (NoteKind.problem, 'No radio'),
      TelemetryStatus.tooSoon => (NoteKind.info, 'Please wait a moment'),
    };
    if (!r.ok) {
      final detail = r.status == TelemetryStatus.noContact ? '${r.detail ?? ''} Discover nearby can find and add it.' : (r.detail ?? '');
      return NoteCard(detail.trim(), key: const Key('telemetry-result'), kind: kind, title: title);
    }
    final imperial = AppScope.unitsOf(context).temperatureImperial;
    final units = AppScope.unitsOf(context);
    final pos = r.position;
    final rows = <(String, String)>[];
    for (final x in r.readings) {
      if (x.kind == LppKind.gps) continue;
      final text = x.kind == LppKind.temperature ? formatTemperature(x.value!, imperial: imperial) : x.text;
      rows.add((x.kind == LppKind.voltage ? 'Battery voltage' : x.label, text));
    }
    String? where;
    if (pos != null) {
      final from = host.lastPosition;
      where = '${pos.text}${r.isSelf || from == null ? '' : ', ${units.distance(haversineM(from.lat, from.lon, pos.lat!, pos.lon!), approx: true)} from you'}';
    }
    final now = DateTime.now();
    return Container(
      key: const Key('telemetry-result'),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.small)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: Text(title, style: t.textTheme.titleMedium)),
        const SizedBox(height: Gap.s),
        for (final (l, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Semantics(
              container: true,
              label: '$l $v',
              excludeSemantics: true,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 4, child: Text(l, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
                Expanded(flex: 5, child: Text(v, style: numberStyle(context, size: 18))),
              ]),
            ),
          ),
        if (where != null) ...[
          const SizedBox(height: Gap.s),
          Text('Position: $where', key: const Key('telemetry-position')),
          if (r.isSelf)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text('Shown here only. MeshSonar does not store or upload it.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ),
          const SizedBox(height: Gap.s),
          ToolMap(
            pins: [MapPin(point: LatLng(pos!.lat!, pos.lon!), label: r.who, icon: r.isSelf ? Icons.my_location : Icons.cell_tower)],
            semanticLabel: '${r.who} is at $where.',
            height: 180,
          ),
        ],
        const SizedBox(height: Gap.s),
        Text('Read at ${fmtClock(r.at)} (${fmtAgo(now.difference(r.at))})', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
