// Adverts: send this radio's advert (local or to the whole mesh) with a visible cooldown and an airtime note, and the list
// of every advert the radio has heard, with the region scope check. Logic lives in lib/radio/tools/advert_tool.dart.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/heard.dart' show haversineM;
import '../../core/units.dart' show Units;
import '../../radio/tools/advert_tool.dart';
import '../../radio/tools/radio_tools.dart';
import '../../radio/tools/rx_log.dart' show advertTypeName;
import '../../radio/tools/transport_code.dart';
import '../app.dart';
import 'advert_facts.dart';
import 'tool_kit.dart';
import 'tools_host.dart';

class AdvertsScreen extends StatelessWidget {
  const AdvertsScreen({super.key});

  @override
  Widget build(BuildContext context) => ToolPage(
        id: 'adverts',
        title: 'Adverts',
        about: 'Adverts announces your radio to others and lists every radio that has announced itself to yours.',
        builder: (context, host, tools) => _AdvertsBody(host: host, tools: tools),
      );
}

class _AdvertsBody extends StatefulWidget {
  final ToolsHost host;
  final RadioTools tools;
  const _AdvertsBody({required this.host, required this.tools});
  @override
  State<_AdvertsBody> createState() => _AdvertsBodyState();
}

class _AdvertsBodyState extends State<_AdvertsBody> {
  AdvertSendResult? _result;
  bool _sending = false;

  AdvertTool get _adverts => widget.tools.adverts;

  @override
  void initState() {
    super.initState();
    widget.tools.startListening();
    _adverts.scopeNames = widget.host.scopeNames;
  }

  Future<void> _send({required bool flood}) async {
    setState(() => _sending = true);
    final r = await _adverts.send(flood: flood);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _result = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ToolListener(
      sources: [_adverts.changed],
      builder: (context) => _list(context),
    );
  }

  Widget _list(BuildContext context) {
    final heard = _adverts.heard;
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final here = widget.host.lastPosition;
    final pins = <MapPin>[
      for (final a in heard)
        if (a.hasPosition) MapPin(point: LatLng(a.lat!, a.lon!), label: a.displayName),
      if (here != null) MapPin(point: LatLng(here.lat, here.lon), label: 'You', icon: Icons.my_location),
    ];
    final r = _result;
    final header = <Widget>[
      const ToolHeading('Announce your radio'),
      // Each button says how far it reaches right under it (was one paragraph for both, further down).
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CooldownButton(
          key: const Key('adverts-send-local'),
          label: 'Send local advert',
          icon: Icons.podcasts,
          cooldown: () => _adverts.cooldown(flood: false),
          busy: _sending,
          onPressed: () => _send(flood: false),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.m),
          child: Text('Reaches radios in direct range. One every 30 s.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
        CooldownButton(
          key: const Key('adverts-send-flood'),
          label: 'Send to the whole mesh',
          icon: Icons.campaign_outlined,
          filled: false,
          cooldown: () => _adverts.cooldown(flood: true),
          busy: _sending,
          onPressed: () => _send(flood: true),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text('Every repeater passes it on. One every 5 min.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
      ]),
      const SizedBox(height: Gap.m),
      AirtimeNote(tools: widget.tools, ms: _adverts.estimateAirtimeMs(), action: 'An advert'),
      const SizedBox(height: Gap.xs),
      Text('It carries your radio’s stored position only if Radio setup says so.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      if (r != null) ...[
        const SizedBox(height: Gap.m),
        KeyedSubtree(
          key: const Key('adverts-result'),
          child: NoteCard(r.message,
              kind: r.ok ? NoteKind.good : (r.status == AdvertSendStatus.cooldown ? NoteKind.info : NoteKind.problem),
              title: r.ok ? 'Advert sent' : (r.status == AdvertSendStatus.cooldown ? 'Not yet' : 'Not sent')),
        ),
      ],
      const ToolHeading('Heard by your radio'),
      if (heard.isNotEmpty) ...[
        ToolMap(
          pins: pins,
          height: 200,
          semanticLabel: pins.isEmpty ? 'None of the adverts heard carries a position.' : 'Map of ${heard.where((a) => a.hasPosition).length} advertising nodes with a known position.',
        ),
        const SizedBox(height: Gap.s),
        Row(key: const Key('adverts-header'), children: [
          Expanded(
            child: Text(
              '${heard.length} ${heard.length == 1 ? 'node' : 'nodes'} heard since ${fmtClock(heard.map((a) => a.firstSeen).reduce((a, b) => a.isBefore(b) ? a : b))}',
              style: t.textTheme.titleSmall,
            ),
          ),
          TextButton.icon(
            key: const Key('adverts-clear'),
            style: TextButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
            onPressed: _adverts.clear,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Clear'),
          ),
        ]),
        Text('Tap a node for its details. A heard advert is a hint, not proof of who sent it.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.s),
      ] else
        const NoteCard('On a quiet mesh this can take minutes: a node shows up here when it next announces itself. Leave this screen open.',
            key: Key('adverts-empty'), title: 'Nothing heard yet'),
    ];
    return ListView.builder(
      key: const Key('adverts-list'),
      padding: const EdgeInsets.all(Gap.l),
      itemCount: header.length + heard.length,
      itemBuilder: (context, i) {
        if (i < header.length) return header[i];
        final a = heard[i - header.length];
        return _AdvertRow(advert: a, host: widget.host, here: here, units: units);
      },
    );
  }
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String _where(HeardAdvert a) => a.hops == 0 ? 'Direct' : 'via ${a.path.join(' > ')}';

String _skewText(int secs) => 'Its clock is ${(secs.abs() / 60).round()} min off from yours';

IconData _scopeIcon(ScopeVerdict v) => switch (v) {
      ScopeVerdict.inScope => Icons.check_circle_outline,
      ScopeVerdict.otherScope => Icons.help_outline,
      ScopeVerdict.unscoped => Icons.public,
    };

class _AdvertRow extends StatelessWidget {
  final HeardAdvert advert;
  final ToolsHost host;
  final ({double lat, double lon})? here;
  final Units units;
  const _AdvertRow({required this.advert, required this.host, required this.here, required this.units});

  @override
  Widget build(BuildContext context) {
    final a = advert;
    final t = Theme.of(context);
    final now = DateTime.now();
    final dist = (here != null && a.hasPosition) ? haversineM(here!.lat, here!.lon, a.lat!, a.lon!) : null;
    final skewBig = a.clockSkewSecs != null && a.clockSkewSecs!.abs() > 120;
    final snr = a.snrDb;
    // Three short lines; the coordinates, dBm and first-heard time are one tap away in the details.
    final lines = <String>[
      '${_cap(advertTypeName(a.nodeType))}${a.inContacts ? ', in your contacts' : ''} · ${_where(a)}',
      'Signal ${fmtSnr(snr)}${dist == null ? '' : ' · ${units.distance(dist, approx: true)} from you'}',
      'Heard ${fmtAgo(now.difference(a.lastSeen))}${a.count == 1 ? '' : ' · ${a.count} times'}',
    ];
    return Card(
      key: Key('adverts-row-${a.shortKey}'),
      margin: const EdgeInsets.only(bottom: Gap.s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(Corners.card),
          onTap: () => _detail(context),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kToolTarget),
            child: Padding(
              padding: const EdgeInsets.all(Gap.m),
              child: Semantics(
                container: true,
                button: true,
                label: '${a.displayName}. ${lines.join('. ')}. Last heard at ${fmtClock(a.lastSeen)}. ${skewBig ? '${_skewText(a.clockSkewSecs!)}. ' : ''}Opens details.',
                excludeSemantics: true,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(a.displayName, style: t.textTheme.titleMedium)),
                    Icon(Icons.chevron_right, size: 20, color: t.colorScheme.onSurfaceVariant),
                  ]),
                  for (final l in lines) Text(l, style: t.textTheme.bodyMedium),
                  if (skewBig)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xs),
                      child: Row(children: [
                        Icon(Icons.schedule, size: 18, color: t.colorScheme.error),
                        const SizedBox(width: Gap.xs),
                        Expanded(child: Text(_skewText(a.clockSkewSecs!), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error))),
                      ]),
                    ),
                ]),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.s, 0, Gap.s, Gap.xs),
          child: TextButton.icon(
            key: Key('adverts-scope-${a.shortKey}'),
            style: TextButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
            onPressed: () => _scopeSheet(context),
            icon: Icon(_scopeIcon(a.scope.verdict)),
            label: Text('Region: ${a.scope.label}'),
          ),
        ),
      ]),
    );
  }

  void _scopeSheet(BuildContext context) {
    final names = host.scopeNames;
    showToolSheet(context, key: const Key('adverts-scope-sheet'), title: 'Region scope check', children: [
      Text('A scoped advert carries a 2-byte code worked out from the region’s name. MeshSonar recomputes that code for '
          '${names.isEmpty ? 'the region you are viewing (none is selected)' : names.join(', ')} and compares.'),
      const SizedBox(height: Gap.s),
      Text('Result for ${advert.displayName}: ${advert.scope.label}.', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: Gap.s),
      const Text('A mismatch only means “not this region”. A code cannot be turned back into a name, so MeshSonar cannot say which region it belongs to.'),
    ]);
  }

  void _detail(BuildContext context) {
    final a = advert;
    final routeLabel = switch (a.routeType) { 0 => 'Scoped flood', 1 => 'Flood', 2 => 'Direct', 3 => 'Scoped direct', _ => 'Route ${a.routeType}' };
    showToolSheet(context, key: const Key('adverts-detail'), title: a.displayName, children: [
      FactRows([
        ('Type', advertTypeName(a.nodeType)),
        ('Public key', a.keyHex),
        ('Route', routeLabel),
        ('Path', a.hops == 0 ? 'Direct, no repeater in between' : '${a.path.join(' > ')} (${a.hashSize}-byte hashes)'),
        ('Signal', '${fmtSnr(a.snrDb)}${a.rssiDbm == null ? '' : ', ${a.rssiDbm!.toStringAsFixed(0)} dBm'}'),
        if (here != null && a.hasPosition) ('Distance', '${units.distance(haversineM(here!.lat, here!.lon, a.lat!, a.lon!), approx: true)} from you'),
        ('Best signal', fmtSnr(a.bestSnrDb)),
        ('First heard', fmtClock(a.firstSeen)),
        ('Last heard', fmtClock(a.lastSeen)),
        ('Times heard', '${a.count}'),
        ('Clock difference', a.clockSkewSecs == null ? 'unknown' : '${a.clockSkewSecs! >= 0 ? '+' : '−'}${a.clockSkewSecs!.abs()} s (its clock minus yours)'),
        if (a.hasPosition) ('Position', '${a.lat!.toStringAsFixed(5)}, ${a.lon!.toStringAsFixed(5)}'),
        ('Region scope', a.scope.label),
        ('In your radio’s contacts', a.inContacts ? 'yes' : 'no'),
      ]),
    ]);
  }
}
