// Plan > Build tracker, native and read-only: where each site in the recommended build stands (proposed, contacting the host, host
// approved, hardware ready, installed, live on okimesh, dropped), who owns it, its mount height and the next action, plus recent
// changes. The people installing update it on the website; host contact details are never shown here.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/plan/plan_native_api.dart';
import '../../core/plan/plan_tracker.dart';
import '../theme.dart';
import 'plan_common.dart';

class TrackerScreen extends StatefulWidget {
  final PlanNativeApi? api;
  const TrackerScreen({super.key, this.api});
  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  String? _status;
  String _q = '';
  bool _map = false;

  @override
  Widget build(BuildContext context) {
    final api = widget.api ?? planApiFor(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Build tracker')),
      body: SafeArea(
        top: false,
        child: PlanFetchView<PlanTracker>(
          id: 'trk',
          load: api.tracker,
          reloadKey: api.baseUrl,
          available: (d) => d.available && d.sites.isNotEmpty,
          unavailableText: (d) => d.reason ?? 'No sites are being tracked for this region yet.',
          build: (context, d, reload) => _body(context, d),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, PlanTracker d) {
    final t = Theme.of(context);
    final q = _q.trim().toLowerCase();
    final sites = [
      for (final s in d.sites)
        if ((_status == null || s.status == _status) && (q.isEmpty || '${s.name} ${s.id} ${s.owner ?? ''} ${s.area}'.toLowerCase().contains(q))) s,
    ];
    Color statusColor(String st) {
      final m = MeshSonarColors.of(context);
      switch (st) {
        case 'Live on okimesh':
        case 'Installed':
          return m.levelStrong;
        case 'Dropped':
          return m.silent;
        case 'Proposed':
          return t.colorScheme.outline;
        default:
          return m.levelFair;
      }
    }

    return planColumn(key: const Key('trk-list'), [
      planHeader(context, 'Build tracker', 'Who is installing what, and where each site stands.'),
      Wrap(spacing: 8, runSpacing: 4, children: [
        ChoiceChip(key: const Key('trk-all'), label: Text('All ${d.sites.length}'), selected: _status == null, onSelected: (_) => setState(() => _status = null)),
        for (final st in d.statuses) ChoiceChip(key: Key('trk-status-$st'), label: Text('$st ${d.counts[st] ?? 0}'), selected: _status == st, onSelected: (on) => setState(() => _status = on ? st : null)),
      ]),
      TextField(key: const Key('trk-search'), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Site, owner or area', isDense: true), onChanged: (v) => setState(() => _q = v)),
      Align(
        alignment: Alignment.centerRight,
        child: SegmentedButton<bool>(
          key: const Key('trk-view'),
          showSelectedIcon: false,
          segments: const [ButtonSegment(value: false, label: Text('List')), ButtonSegment(value: true, label: Text('Map'))],
          selected: {_map},
          onSelectionChanged: (s) => setState(() => _map = s.first),
        ),
      ),
      if (_map)
        PlanMap(markers: [for (final s in sites) if (s.lat != null && s.lon != null) PlanMarker(LatLng(s.lat!, s.lon!), label: s.order == null ? null : '${s.order}', color: statusColor(s.status), size: 24)], height: 340)
      else ...[
        if (sites.isEmpty) Padding(padding: const EdgeInsets.all(Gap.l), child: Text('No site matches.', key: const Key('trk-empty'), style: t.textTheme.bodyLarge)),
        for (final s in sites)
          Card(
            key: Key('trk-site-${s.id}'),
            margin: const EdgeInsets.only(bottom: Gap.s),
            child: Padding(
              padding: const EdgeInsets.all(Gap.m),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${s.tag}  ${s.name}', style: t.textTheme.titleSmall)),
                  Icon(Icons.circle, size: 10, color: statusColor(s.status)),
                  const SizedBox(width: 4),
                  Text(s.status, style: t.textTheme.labelMedium),
                ]),
                Text('${s.phaseName}${s.area.isNotEmpty ? ' · ${s.area}' : ''}${s.hostType.isNotEmpty ? ' · ${s.hostType}' : ''}', style: t.textTheme.bodySmall),
                const SizedBox(height: 4),
                Text('Next: ${s.nextAction}', style: t.textTheme.bodyMedium),
                if (s.owner != null || s.mountHeight != null || s.publicKey != null)
                  Text([if (s.owner != null) 'Owner ${s.owner}', if (s.mountHeight != null) s.mountHeight!, if (s.publicKey != null) 'key ${s.publicKey}…'].join(' · '), style: t.textTheme.bodySmall),
                if (s.notes != null) Text(s.notes!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                if (s.updatedAt != null) Text('Updated ${s.updatedAt!.toIso8601String().substring(0, 10)}${s.updatedBy != null ? ' by ${s.updatedBy}' : ''}', style: t.textTheme.labelSmall),
              ]),
            ),
          ),
      ],
      if (d.history.isNotEmpty)
        planSection(context, 'Recent changes', key: const Key('trk-history'), children: [
          for (final h in d.history.take(20))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('${h.at?.toIso8601String().substring(0, 10) ?? ''}  ${d.siteName(h.siteId)}: ${h.lines.join('; ')}${h.by.isEmpty ? '' : ' (${h.by})'}', style: t.textTheme.bodySmall),
            ),
        ]),
      if (d.editNote != null) Text(d.editNote!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ]);
  }
}
