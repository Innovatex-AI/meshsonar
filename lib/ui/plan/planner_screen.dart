// Plan > Planner, native: ask the planning engine where to build next. The query is the website's (objective, how many sites, mount
// height, link tier, which kinds of place, today's network or the live one); the server runs the website's own engine and the
// answer is a numbered build sequence with its links, the gain of each step and why it was picked, drawn on the map. The last
// question and its answer are kept on the phone, so reopening the screen (even offline) shows them again.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/etag_client.dart' show sharedEtagCache;
import '../../core/plan/plan_native_api.dart';
import '../../core/plan/plan_sites.dart' show groupInt;
import '../../core/plan/planner_query.dart';
import '../../core/region_dataset_fetch.dart';
import '../../core/region_cache.dart' show asOfLabel;
import '../theme.dart';
import 'plan_engine_common.dart';
import 'recommended_screen.dart' show phaseColor;

class PlannerScreen extends StatefulWidget {
  final PlanNativeApi? api;

  /// A question to start from (the scenario lab's "Plan next sites"); it runs at once.
  final PlannerQuery? initial;
  const PlannerScreen({super.key, this.api, this.initial});
  @override
  State<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends State<PlannerScreen> {
  static const _lastKey = 'plan-native-last-planner-v1';
  PlannerQuery _q = const PlannerQuery();
  RegionFetch<PlannerResult>? _res;
  bool _running = false, _started = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final init = widget.initial;
    if (init != null) {
      setState(() => _q = init);
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
      return;
    }
    final c = sharedEtagCache;
    if (c == null) return;
    final r = await c.read(_lastKey);
    if (r == null || !mounted) return;
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final q = PlannerQuery.decode(j['pq'] as String? ?? '');
      setState(() => _q = q.copyWith(
            prebuiltSites: [if (j['sites'] is List) for (final x in j['sites'] as List) if (x is String) x],
            prebuiltCand: [if (j['cand'] is List) for (final x in j['cand'] as List) if (x is String) x],
          ));
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    } catch (_) {}
  }

  Future<void> _run() async {
    if (!mounted) return;
    final api = widget.api ?? planApiFor(context);
    final q = _q;
    setState(() {
      _running = true;
      _started = true;
    });
    final r = await api.planner(q);
    if (!mounted) return;
    setState(() {
      _res = r;
      _running = false;
    });
    if (r.ok) {
      sharedEtagCache?.put(_lastKey, jsonEncode({'pq': q.encode(), 'sites': q.prebuiltSites, 'cand': q.prebuiltCand}));
    }
  }

  void _set(PlannerQuery q) => setState(() => _q = q);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = _q;
    return Scaffold(
      appBar: AppBar(title: const Text('Planner')),
      body: SafeArea(
        top: false,
        child: planColumn(key: const Key('planner-list'), [
          planHeader(context, 'Planner', 'Ask the planning engine your own questions about where to build next.'),
          planSection(context, 'Your question', key: const Key('planner-form'), children: [
            Text('Start from', style: t.textTheme.labelLarge),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              key: const Key('planner-start'),
              segments: [
                const ButtonSegment(value: 'today', label: Text('Today')),
                const ButtonSegment(value: 'live', label: Text('Live network')),
                if (q.start == 'scenario') const ButtonSegment(value: 'scenario', label: Text('Scenario')),
              ],
              selected: {q.start},
              onSelectionChanged: (s) => _set(q.copyWith(start: s.first)),
            ),
            const SizedBox(height: Gap.m),
            Text('What matters most', style: t.textTheme.labelLarge),
            DropdownButton<PlannerObjective>(
              key: const Key('planner-objective'),
              isExpanded: true,
              value: q.objective,
              items: [for (final o in PlannerObjective.values) DropdownMenuItem(value: o, child: Text(plannerObjectiveLabel[o]!))],
              onChanged: (o) => o == null ? null : _set(q.copyWith(objective: o)),
            ),
            Text(plannerObjectiveRule[q.objective]!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.m),
            Text('How many sites: ${q.maxSites}', style: t.textTheme.labelLarge),
            Slider(
              key: const Key('planner-sites'),
              min: 1,
              max: plannerMaxSites.toDouble(),
              divisions: plannerMaxSites - 1,
              value: q.maxSites.toDouble(),
              label: '${q.maxSites}',
              onChanged: (v) => _set(q.copyWith(maxSites: v.round())),
            ),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Mount height', style: t.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  SegmentedButton<int>(
                    key: const Key('planner-height'),
                    segments: [ButtonSegment(value: 20, label: Text(mountName(20))), ButtonSegment(value: 33, label: Text(mountName(33)))],
                    selected: {q.height},
                    onSelectionChanged: (s) => _set(q.copyWith(height: s.first)),
                  ),
                ]),
              ),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Link tier', style: t.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  SegmentedButton<String>(
                    key: const Key('planner-tier'),
                    segments: const [ButtonSegment(value: 'likely', label: Text('Likely+')), ButtonSegment(value: 'possible', label: Text('Possible+'))],
                    selected: {q.tier},
                    onSelectionChanged: (s) => _set(q.copyWith(tier: s.first)),
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: Gap.m),
            Text('Kinds of place', style: t.textTheme.labelLarge),
            Wrap(spacing: 8, children: [
              for (final k in plannerKinds)
                FilterChip(
                  key: Key('planner-kind-$k'),
                  label: Text(plannerKindLabel[k]!),
                  selected: q.kinds.contains(k),
                  onSelected: (on) {
                    final next = on ? [...q.kinds, k] : q.kinds.where((x) => x != k).toList();
                    if (next.isNotEmpty) _set(q.copyWith(kinds: [for (final x in plannerKinds) if (next.contains(x)) x]));
                  },
                ),
            ]),
            if (q.start == 'scenario' && (q.prebuiltSites.isNotEmpty || q.prebuiltCand.isNotEmpty))
              Padding(
                padding: const EdgeInsets.only(top: Gap.s),
                child: Text('Already built in your scenario: ${[...q.prebuiltSites, ...q.prebuiltCand].join(', ')}.', style: t.textTheme.bodySmall),
              ),
            const SizedBox(height: Gap.m),
            FilledButton.icon(
              key: const Key('planner-run'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: _running ? null : _run,
              icon: const Icon(Icons.search),
              label: Text(_running ? 'Asking the engine…' : 'Ask the engine'),
            ),
          ]),
          if (_running) const Padding(padding: EdgeInsets.all(Gap.l), child: Center(key: Key('planner-running'), child: CircularProgressIndicator())),
          if (!_running && _res != null) _result(context, _res!),
          if (!_started && _res == null) Text('Choose what matters, then ask. The engine plans on today\'s network, or the live one.', style: t.textTheme.bodyMedium),
        ]),
      ),
    );
  }

  Widget _result(BuildContext context, RegionFetch<PlannerResult> f) {
    final t = Theme.of(context);
    if (!f.ok) {
      return Card(
        key: const Key('planner-error'),
        child: Padding(
          padding: const EdgeInsets.all(Gap.m),
          child: Row(children: [
            const Icon(Icons.info_outline),
            const SizedBox(width: Gap.m),
            Expanded(child: Text(f.error ?? 'The planner could not answer.')),
            TextButton(onPressed: _run, child: const Text('Try again')),
          ]),
        ),
      );
    }
    final r = f.data!;
    final reps = r.targets;
    final markers = <PlanMarker>[];
    final lines = <PlanLine>[];
    for (final s in r.steps) {
      for (final x in s.sites) {
        final at = LatLng(x.lat, x.lon);
        markers.add(PlanMarker(at, label: '${x.order}', color: phaseColor(context, s.phase), size: 26));
        for (final l in x.links.take(3)) {
          final p = reps[l.to];
          if (p != null) lines.add(PlanLine(at, LatLng(p.lat, p.lon), tierColor(context, l.tier).withValues(alpha: 0.75), width: 1.5));
        }
      }
    }
    final seen = {for (final l in lines) l.b};
    final m = MeshSonarColors.of(context);
    final targetMarkers = [for (final b in seen) PlanMarker(b, color: m.beacon, size: 10)];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (f.offlineAsOf != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.s),
          child: Row(key: const Key('planner-offline'), children: [
            const Icon(Icons.cloud_off, size: 16),
            const SizedBox(width: 6),
            Expanded(child: Text('${asOfLabel(f.offlineAsOf!, DateTime.now().toUtc(), offline: true)}. This is the last answer for this question.', style: t.textTheme.labelMedium)),
          ]),
        ),
      if (r.liveRequestedButMissing)
        Padding(padding: const EdgeInsets.only(bottom: Gap.s), child: Text('There is no live network stored for this region yet, so this plan starts from today\'s network.', key: const Key('planner-live-missing'), style: t.textTheme.bodyMedium)),
      Wrap(key: const Key('planner-figures'), spacing: 8, runSpacing: 8, children: [
        PlanFigure('Sites', '${r.siteCount}', hint: '${r.pool} considered'),
        PlanFigure('Repeaters in the main mesh', '${r.startMainMesh} → ${r.endMainMesh}', hint: 'of ${r.repeaterCount}'),
        PlanFigure('People within ${radiusText(context, 3)}', '${groupInt(r.startPeople)} → ${groupInt(r.endPeople)}'),
        if (r.startSpof != null && r.steps.isNotEmpty && r.steps.last.spof != null) PlanFigure('Single points of failure', '${r.startSpof} → ${r.steps.last.spof}'),
      ]),
      const SizedBox(height: Gap.s),
      Text(r.stopText, style: t.textTheme.bodySmall),
      if (r.steps.isEmpty)
        Padding(padding: const EdgeInsets.only(top: Gap.m), child: Text('No site improves the network under these settings.', key: const Key('planner-empty'), style: t.textTheme.bodyLarge)),
      if (markers.isNotEmpty) ...[
        const SizedBox(height: Gap.m),
        PlanMap(markers: [...targetMarkers, ...markers], lines: lines, height: 300),
        Text('Numbers are the build order; colour is the phase. Lines run to what each site links to.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ],
      const SizedBox(height: Gap.m),
      for (final s in r.steps) _StepCard(step: s, result: r),
      Text('Odds at ${mountName(r.query?.height ?? 33)}: lidar = tree depth measured on USGS 3DEP point clouds; tree = estimated from ESA WorldCover; terrain = no trees. ${r.asOf != null ? 'Baseline as of ${r.asOf!.substring(0, 10)}.' : ''}',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ]);
  }
}

class _StepCard extends StatelessWidget {
  final PlannerStepOut step;
  final PlannerResult result;
  const _StepCard({required this.step, required this.result});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = step;
    const phases = {1: 'Connect', 2: 'Reach', 3: 'Densify'};
    return Card(
      key: Key('planner-step-${s.step}'),
      margin: const EdgeInsets.only(bottom: Gap.s),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.circle, size: 12, color: phaseColor(context, s.phase)),
            const SizedBox(width: 6),
            Text('Step ${s.step}${s.pair ? ' (linked pair)' : ''} · ${phases[s.phase]}', style: t.textTheme.titleSmall),
          ]),
          for (final x in s.sites) ...[
            const SizedBox(height: 4),
            Text('${x.order}. ${x.name}', style: t.textTheme.bodyLarge),
            if ((x.sub ?? '').isNotEmpty || (x.town ?? '').isNotEmpty) Text([x.sub, x.town].whereType<String>().where((e) => e.isNotEmpty).join(' · '), style: t.textTheme.bodySmall),
            for (final l in x.links.take(3))
              Padding(
                padding: const EdgeInsets.only(left: Gap.m, top: 2),
                child: Row(children: [
                  Expanded(child: Text('→ ${_target(l)}${l.km != null ? ' (${kmText(context, l.km!)})' : ''}', style: t.textTheme.bodySmall)),
                  TierChip(l.tier),
                  const SizedBox(width: 6),
                  Text('${oddsPct(l.p)} ${l.model}', style: t.textTheme.labelSmall),
                ]),
              ),
          ],
          const SizedBox(height: 4),
          Text(
            'Adds ${signedInt(s.joins)} repeater${s.joins == 1 ? '' : 's'} to the main mesh (now ${s.mainMesh}) and ${signedInt(s.newPeople)} people within ${radiusText(context, 3)} (now ${groupInt(s.people)})'
            '${s.spofDelta != null && s.spofDelta != 0 ? '; single points of failure ${s.spofDelta! > 0 ? 'down' : 'up'} ${s.spofDelta!.abs()}' : ''}.',
            style: t.textTheme.bodySmall,
          ),
          if (s.why.isNotEmpty) Text(s.why, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary)),
        ]),
      ),
    );
  }

  String _target(PlannerLink l) => result.targets[l.to]?.name ?? (l.to.length > 12 ? l.to.substring(0, 8) : l.to);
}
