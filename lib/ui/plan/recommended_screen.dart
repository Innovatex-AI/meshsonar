// Plan > Recommended build, native: the planning engine's build sequence phase by phase (Connect, Reach, Densify), the engine against
// the original 20-site plan, an editable budget and the risk register. The numbers are the website's Plan > Recommended page
// (the server runs its own functions); the budget maths runs here so unit costs can be edited offline and are kept on the phone.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/etag_client.dart' show sharedEtagCache;
import '../../core/plan/plan_native_api.dart';
import '../../core/plan/plan_overview.dart';
import '../../core/plan/plan_sites.dart' show groupInt;
import '../theme.dart';
import 'plan_common.dart';

class RecommendedScreen extends StatefulWidget {
  final PlanNativeApi? api;
  const RecommendedScreen({super.key, this.api});
  @override
  State<RecommendedScreen> createState() => _RecommendedScreenState();
}

class _RecommendedScreenState extends State<RecommendedScreen> {
  String _run = 'likely';
  Map<PlanCase, PlanUnitCost>? _edited;
  static const _budgetKey = 'plan-native-budget-v1';

  @override
  void initState() {
    super.initState();
    _loadBudget();
  }

  Future<void> _loadBudget() async {
    final c = sharedEtagCache;
    if (c == null) return;
    final r = await c.read(_budgetKey);
    if (r == null || !mounted) return;
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final m = <PlanCase, PlanUnitCost>{};
      for (final k in PlanCase.values) {
        final u = PlanUnitCost.parse(j[k.name]);
        if (u != null) m[k] = u;
      }
      if (m.isNotEmpty) setState(() => _edited = m);
    } catch (_) {}
  }

  void _saveBudget() {
    final c = sharedEtagCache, e = _edited;
    if (c == null) return;
    if (e == null) {
      c.put(_budgetKey, '{}');
    } else {
      c.put(_budgetKey, jsonEncode({for (final x in e.entries) x.key.name: x.value.toJson()}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.api ?? planApiFor(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Recommended build')),
      body: SafeArea(
        top: false,
        child: PlanFetchView<PlanOverview>(
          id: 'rec',
          load: api.overview,
          reloadKey: api.baseUrl,
          available: (d) => d.available,
          unavailableText: (d) => d.reason ?? 'The planning engine has not produced a plan for this region yet.',
          build: (context, d, reload) => _body(context, d),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, PlanOverview d) {
    final run = d.runs[_run] ?? d.runs.values.first;
    final t = Theme.of(context);
    final avail = d.runs.keys.toList();
    return planColumn(key: const Key('rec-list'), [
      planHeader(context, 'Recommended build', 'The engine\'s recommended build, phase by phase, with the budget and the risks.'),
      if (avail.length > 1)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.m),
          child: SegmentedButton<String>(
            key: const Key('rec-run'),
            segments: [for (final k in avail) ButtonSegment(value: k, label: Text(d.runs[k]!.label))],
            selected: {run.run},
            onSelectionChanged: (s) => setState(() => _run = s.first),
          ),
        ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        PlanFigure('Sites', '${run.totalSites}', hint: '${run.label} links, ${mountName(33)}'),
        PlanFigure('Live repeaters in the main mesh', '${run.todayMainMesh} → ${run.groups.isEmpty ? run.todayMainMesh : run.groups.last.mainMesh}', hint: 'of ${run.liveRepeaters}'),
        PlanFigure('People within ${radiusText(context, 3)}', '${groupInt(run.todayPeople)} → ${groupInt(run.groups.isEmpty ? run.todayPeople : run.groups.last.people)}'),
        PlanFigure('Links lidar-verified', '${run.linksLidar} of ${run.linksTotal}'),
      ]),
      const SizedBox(height: Gap.m),
      _SequenceMap(run: run, overview: d),
      for (final p in run.phases) _PhaseCard(phase: p, run: run),
      _EngineVsOriginal(run: run),
      _Budget(run: run, budget: d.budget, edited: _edited, onEdit: (e) {
        setState(() => _edited = e);
        _saveBudget();
      }),
      _Risks(run: run),
      Text('Built ${run.builtUtc.length >= 10 ? run.builtUtc.substring(0, 10) : run.builtUtc}. ${run.method}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ]);
  }
}

Color phaseColor(BuildContext context, int phase) {
  final m = MeshSonarColors.of(context);
  return phase == 1 ? m.levelStrong : (phase == 2 ? m.levelFair : m.levelWeak);
}

class _SequenceMap extends StatelessWidget {
  final PlanRun run;
  final PlanOverview overview;
  const _SequenceMap({required this.run, required this.overview});
  @override
  Widget build(BuildContext context) {
    final markers = <PlanMarker>[];
    final lines = <PlanLine>[];
    final m = MeshSonarColors.of(context);
    final reps = {for (final r in overview.repeaters) r.key: r};
    for (final p in run.phases) {
      for (final g in p.groups) {
        var n = g.ordFrom;
        for (final s in g.sites) {
          if (!s.hasPoint) continue;
          final at = LatLng(s.lat!, s.lon!);
          markers.add(PlanMarker(at, label: '$n', color: phaseColor(context, p.id), size: 26));
          n++;
          for (final l in s.links.take(3)) {
            final r = reps[l.to];
            if (r != null) lines.add(PlanLine(at, LatLng(r.lat, r.lon), tierColor(context, l.tier).withValues(alpha: 0.7), width: 1.5));
          }
        }
      }
    }
    if (markers.isEmpty) return const SizedBox.shrink();
    final seen = {for (final l in lines) l.b};
    final repMarkers = [for (final b in seen) PlanMarker(b, color: m.beacon, size: 10)];
    return planSection(context, 'Build order on the map', lead: 'Numbers are the build order; colour is the phase (Connect, Reach, Densify). Lines run to the live repeaters each site links to.', children: [
      PlanMap(markers: [...repMarkers, ...markers], lines: lines, height: 300),
    ]);
  }
}

class _PhaseCard extends StatelessWidget {
  final PlanPhase phase;
  final PlanRun run;
  const _PhaseCard({required this.phase, required this.run});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: Key('rec-phase-${phase.id}'),
      margin: const EdgeInsets.only(bottom: Gap.m),
      child: ExpansionTile(
        initiallyExpanded: phase.id == 1,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(Icons.circle, color: phaseColor(context, phase.id), size: 14),
        title: Text('${phase.id}. ${phase.name}', style: t.textTheme.titleMedium),
        subtitle: Text('${phase.sites} site${phase.sites == 1 ? '' : 's'}: ${signedInt(phase.joins)} repeaters in the main mesh, ${signedInt(phase.newPeople)} people within ${radiusText(context, 3)}'),
        childrenPadding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.m),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(phase.rule, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.s),
          for (final g in phase.groups) _GroupTile(group: g),
        ],
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  final PlanGroup group;
  const _GroupTile({required this.group});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final g = group;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(g.isPair ? 'Sites ${g.ordFrom} and ${g.ordTo} (a linked pair)' : 'Site ${g.ordFrom}', style: t.textTheme.titleSmall),
        for (final s in g.sites) ...[
          Text('${s.planSite != null ? '${s.planSite}  ' : ''}${s.name}', style: t.textTheme.bodyLarge),
          if (s.sub != null) Text(s.sub!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          for (final l in s.links.take(4))
            Padding(
              padding: const EdgeInsets.only(left: Gap.m, top: 2),
              child: Row(children: [
                Expanded(child: Text('→ ${l.name}${l.short != null ? ' (${l.short})' : ''}', style: t.textTheme.bodySmall)),
                TierChip(l.tier),
                const SizedBox(width: 6),
                Text('${oddsPct(l.p)}${l.lidar ? ' lidar' : ' est.'}', style: t.textTheme.labelSmall),
              ]),
            ),
          if (s.links.length > 4) Padding(padding: const EdgeInsets.only(left: Gap.m, top: 2), child: Text('+ ${s.links.length - 4} more links', style: t.textTheme.labelSmall)),
        ],
        const SizedBox(height: 4),
        Text('Adds ${signedInt(g.joins)} to the main mesh (now ${g.mainMesh}) and ${signedInt(g.newPeople)} people within ${radiusText(context, 3)} (now ${groupInt(g.people)}).', style: t.textTheme.bodySmall),
        if (g.bridged.isNotEmpty)
          Text('Brings in: ${g.bridged.map((b) => b.size > 1 ? '${b.label} (${b.size} repeaters)' : b.label).join(', ')}.', style: t.textTheme.bodySmall),
        Text(g.gate, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        if (!g.verified) Text('Some links here are estimated from tree cover, not lidar-verified.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _EngineVsOriginal extends StatefulWidget {
  final PlanRun run;
  const _EngineVsOriginal({required this.run});
  @override
  State<_EngineVsOriginal> createState() => _EngineVsOriginalState();
}

class _EngineVsOriginalState extends State<_EngineVsOriginal> {
  bool _people = false;
  @override
  Widget build(BuildContext context) {
    final run = widget.run;
    final t = Theme.of(context);
    final o12 = run.waves12, o20 = run.all20;
    final lastStep = run.groups.isEmpty ? 0 : run.groups.last.stepNo;
    double eng(SeriesPoint s) => (_people ? s.people : s.mainMesh).toDouble();
    final engine = [for (final s in run.series) (s.x, eng(s))];
    final orig = <(int, double)>[
      (0, (_people ? run.todayPeople : run.todayMainMesh).toDouble()),
      if (o12 != null) (o12.sites, (_people ? o12.people : o12.mainMesh).toDouble()),
      if (o20 != null) (o20.sites, (_people ? o20.people : o20.mainMesh).toDouble()),
    ];
    String sentence = 'The original plan is not scored in this data.';
    if (o12 != null && o20 != null) {
      final at = run.valueAt(o12.sites, people: _people);
      int? reach;
      for (final g in run.groups) {
        if ((_people ? g.people : g.mainMesh) >= (_people ? o20.people : o20.mainMesh)) {
          reach = g.stepNo;
          break;
        }
      }
      final unit = _people ? 'people within ${radiusText(context, 3)}' : 'live repeaters in the main mesh';
      String f(int n) => _people ? groupInt(n) : '$n';
      sentence = 'With ${o12.sites} sites the engine\'s sequence has ${f(at)} $unit against ${f(_people ? o12.people : o12.mainMesh)} for the original Waves 1–2; '
          '${reach != null ? 'it matches the original plan\'s ${o20.sites}-site total (${f(_people ? o20.people : o20.mainMesh)}) after $reach site${reach == 1 ? '' : 's'}.' : 'the original plan\'s ${o20.sites}-site total is ${f(_people ? o20.people : o20.mainMesh)}.'}';
    }
    return planSection(context, 'Against the original 20-site plan', lead: sentence, key: const Key('rec-vs'), children: [
      SegmentedButton<bool>(
        segments: const [ButtonSegment(value: false, label: Text('Main mesh')), ButtonSegment(value: true, label: Text('People'))],
        selected: {_people},
        onSelectionChanged: (s) => setState(() => _people = s.first),
      ),
      const SizedBox(height: Gap.s),
      Semantics(
        label: 'Chart of ${_people ? 'people within ${radiusText(context, 3)}' : 'live repeaters in the main mesh'} by sites built, engine against the original plan',
        child: SizedBox(
          height: 180,
          child: CustomPaint(
            size: Size.infinite,
            painter: SeriesChartPainter(engine, orig, t.colorScheme.primary, t.colorScheme.tertiary, t.colorScheme.outline, t.textTheme.labelSmall!),
          ),
        ),
      ),
      Row(children: [
        Icon(Icons.horizontal_rule, color: t.colorScheme.primary),
        Text(' Engine (${run.label})   ', style: t.textTheme.labelMedium),
        Icon(Icons.more_horiz, color: t.colorScheme.tertiary),
        Text(' Original plan', style: t.textTheme.labelMedium),
      ]),
      const SizedBox(height: Gap.s),
      Text('Engine: ${engine.where((e) => e.$1 <= lastStep && e.$1 % 5 == 0 || e.$1 == lastStep).map((e) => '${e.$1} sites ${_people ? groupInt(e.$2) : e.$2.round()}').join(', ')}.', style: t.textTheme.bodySmall),
      if (o12 != null && o20 != null)
        Text('Original: Waves 1–2 (${o12.siteIds.join(', ')}) ${_people ? groupInt(o12.people) : o12.mainMesh}; all ${o20.sites} ${_people ? groupInt(o20.people) : o20.mainMesh}. Between those points it was not modelled.', style: t.textTheme.bodySmall),
    ]);
  }
}

class _Budget extends StatelessWidget {
  final PlanRun run;
  final PlanBudget? budget;
  final Map<PlanCase, PlanUnitCost>? edited;
  final void Function(Map<PlanCase, PlanUnitCost>?) onEdit;
  const _Budget({required this.run, required this.budget, required this.edited, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final b = budget;
    if (b == null) {
      return planSection(context, 'Budget', key: const Key('rec-budget'), children: [const Text('No investment assumptions in this data.')]);
    }
    final cases = {for (final c in PlanCase.values) c: edited?[c] ?? b.cases[c]!};
    final poleSites = [for (final i in run.budgetInputs) ...i.sites.where(b.poleTop.contains)];
    final byCase = {for (final c in PlanCase.values) c: waveCosts(run.budgetInputs, b.poleTop, cases[c]!)};
    final lines = <(String, double Function(PlanUnitCost), PlanUnitCost Function(PlanUnitCost, double))>[
      ('Hardware, per site', (u) => u.hw, (u, v) => u.copyWith(hw: v)),
      ('Mounting allowance, per site', (u) => u.mount, (u, v) => u.copyWith(mount: v)),
      if (poleSites.isNotEmpty) ('Pole-top install, per pole-top site', (u) => u.pole, (u, v) => u.copyWith(pole: v)),
    ];
    String lab(PlanCase c) => c == PlanCase.low ? 'Low' : (c == PlanCase.high ? 'High' : 'Expected');
    final poleZero = poleSites.isNotEmpty && PlanCase.values.every((c) => cases[c]!.pole == 0);
    return planSection(
      context,
      'Budget',
      key: const Key('rec-budget'),
      lead: 'Planning figures for the ${run.label} sequence, not quotes. Edit any unit cost; totals update and are kept on this phone.',
      children: [
        for (final l in lines) ...[
          Text(l.$1, style: t.textTheme.labelLarge),
          const SizedBox(height: 4),
          Row(children: [
            for (final c in PlanCase.values)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: Gap.s),
                  child: _CostField(
                    key: Key('rec-cost-${l.$1.split(',').first.split(' ').first.toLowerCase()}-${c.name}'),
                    label: lab(c),
                    value: l.$2(cases[c]!),
                    onChanged: (v) => onEdit({...cases, c: l.$3(cases[c]!, v)}),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: Gap.s),
        ],
        TextButton(key: const Key('rec-budget-reset'), onPressed: edited == null ? null : () => onEdit(null), child: const Text('Reset to the defaults')),
        const Divider(),
        Text('Cumulative cost', style: t.textTheme.labelLarge),
        for (var i = 0; i < run.phases.length && i < byCase[PlanCase.expected]!.length; i++) ...[
          const SizedBox(height: Gap.xs),
          Text('Through ${run.phases[i].name} (${run.phases[i].endSites} sites)', style: t.textTheme.bodyMedium),
          Text(
            'Expected ${costPer(byCase[PlanCase.expected]![i].cumCost, byCase[PlanCase.expected]![i].cumJoined) == null ? '—' : usd(costPer(byCase[PlanCase.expected]![i].cumCost, byCase[PlanCase.expected]![i].cumJoined)!)} per repeater joined, '
            '${costPerThousand(byCase[PlanCase.expected]![i].cumCost, byCase[PlanCase.expected]![i].cumPeople) == null ? '—' : usd(costPerThousand(byCase[PlanCase.expected]![i].cumCost, byCase[PlanCase.expected]![i].cumPeople)!)} per 1,000 people',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          Row(children: [
            for (final c in PlanCase.values)
              Expanded(child: Text('${lab(c)}: ${usd(byCase[c]![i].cumCost)}', key: Key('rec-total-$i-${c.name}'), style: c == PlanCase.expected ? t.textTheme.titleSmall : t.textTheme.bodyMedium)),
          ]),
        ],
        if (poleZero) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('Pole-top install is \$0 until quotes arrive, so totals understate ${poleSites.join(', ')}.', key: const Key('rec-pole-warn'))),
        const SizedBox(height: Gap.s),
        Text('Cost = sites × (hardware + mounting) + pole-top sites × pole-top install. ${b.hardware.basis}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _CostField extends StatefulWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  const _CostField({super.key, required this.label, required this.value, required this.onChanged});
  @override
  State<_CostField> createState() => _CostFieldState();
}

class _CostFieldState extends State<_CostField> {
  late final TextEditingController _c = TextEditingController(text: _fmt(widget.value));
  static String _fmt(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toString();
  @override
  void didUpdateWidget(_CostField old) {
    super.didUpdateWidget(old);
    final cur = double.tryParse(_c.text);
    if (cur != widget.value && (cur != null || widget.value != 0)) {
      if (cur == null || (cur - widget.value).abs() > 1e-9) _c.text = _fmt(widget.value);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: widget.label, prefixText: '\$', isDense: true),
        onChanged: (s) {
          final v = double.tryParse(s);
          widget.onChanged(v == null || v < 0 ? 0 : v);
        },
      );
}

class _Risks extends StatelessWidget {
  final PlanRun run;
  const _Risks({required this.run});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return planSection(context, 'Risk register', key: const Key('rec-risks'), lead: 'What could undo Connect + Reach. Each exposure is measured from the data.', children: [
      if (run.risks.isEmpty) const Text('No risks measured for this plan.'),
      for (final r in run.risks)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.title, style: t.textTheme.titleSmall),
            Text('${r.exposureValue} ${r.exposureUnit}', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.primary)),
            Text(r.what, style: t.textTheme.bodySmall),
            if (r.mitigation.isNotEmpty) Text('What to do: ${r.mitigation}', style: t.textTheme.bodySmall),
          ]),
        ),
    ]);
  }
}
