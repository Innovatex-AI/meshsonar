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
    if (flood) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('adverts-flood-confirm'),
          title: const Text('Send an advert to the whole mesh?'),
          content: Text('Every repeater that hears it will send it on, so it costs airtime across the whole mesh, not just yours '
              '(about ${fmtAir(_adverts.estimateAirtimeMs())} for your radio alone). Your radio already sends adverts by itself, '
              'and that is usually enough.'),
          actions: [
            TextButton(
              key: const Key('adverts-flood-cancel'),
              style: TextButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('adverts-flood-go'),
              style: FilledButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send to the whole mesh'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
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
      const ToolHeading('Send your advert'),
      Wrap(spacing: Gap.m, runSpacing: Gap.s, children: [
        CooldownButton(
          key: const Key('adverts-send-local'),
          label: 'Send local advert',
          icon: Icons.podcasts,
          cooldown: () => _adverts.cooldown(flood: false),
          busy: _sending,
          onPressed: () => _send(flood: false),
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
      ]),
      const SizedBox(height: Gap.s),
      Text('A local advert is heard only by radios in direct range (one every 30 s). A whole-mesh advert is repeated by every repeater (one every 5 min).',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.s),
      AirtimeNote(tools: widget.tools, ms: _adverts.estimateAirtimeMs(), action: 'An advert'),
      const SizedBox(height: Gap.s),
      Text('Your advert includes your radio’s stored position only if Radio setup says so.',
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
      const ToolHeading('Heard'),
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
        Text('A heard advert is a hint, not proof of who sent it.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.s),
      ] else
        const NoteCard('Nothing heard yet. On a quiet mesh this can take minutes. Adverts only show up when a node sends one.',
            key: Key('adverts-empty')),
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
    final lines = <String>[
      '${_cap(advertTypeName(a.nodeType))}${a.inContacts ? ', in your contacts' : ''}',
      _where(a),
      '${fmtSnr(snr)}${a.rssiDbm == null ? '' : ', ${a.rssiDbm!.toStringAsFixed(0)} dBm'}',
      'Seen ${fmtAgo(now.difference(a.lastSeen))}, ${a.count} ${a.count == 1 ? 'time' : 'times'}, first ${fmtAgo(now.difference(a.firstSeen))}',
      if (a.hasPosition) '${a.lat!.toStringAsFixed(4)}, ${a.lon!.toStringAsFixed(4)}${dist == null ? '' : ', ${units.distance(dist, approx: true)} from you'}',
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
                  Text(a.displayName, style: t.textTheme.titleMedium),
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
            label: Text('Region scope check: ${a.scope.label}'),
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
