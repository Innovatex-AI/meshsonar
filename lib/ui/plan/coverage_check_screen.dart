// Plan > Coverage check. "Is there measured coverage at this place?" answered from real drives: the measured coverage cells
// the app already holds for the viewed region (the data behind the website's /coverage map). Nothing is modelled and nothing
// is sent anywhere: the point never leaves the phone. Works offline whenever the cells are cached (the Drive tab keeps them).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../../app/app_state.dart';
import '../../core/plan/coverage_check.dart';
import '../../core/units.dart';
import '../app.dart';
import 'plan_common.dart';

class CoverageCheckScreen extends StatefulWidget {
  final LatLng? initialPoint;
  const CoverageCheckScreen({super.key, this.initialPoint});

  @override
  State<CoverageCheckScreen> createState() => _CoverageCheckScreenState();
}

class _CoverageCheckScreenState extends State<CoverageCheckScreen> {
  LatLng? _p;
  double _radiusM = 500;
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    _p = widget.initialPoint;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    final s = AppScope.read(context);
    if (s.networkCoverage == null && !s.networkCoverageLoading) {
      // Not during build: refreshing notifies the app state.
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(s.refreshNetworkCoverage()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final cov = s.networkCoverage;
    final p = _p;
    CoverageCheck? r;
    if (cov != null && p != null) r = checkCoverage(cov.cells, p.latitude, p.longitude, radiusM: _radiusM, reachM: cellReachM(cov.grid));
    return PlanPage(id: 'check', title: 'Coverage check', children: [
      Text(
        'Is there measured coverage at a place? Checked against real drives, not a model. The point stays on your phone.',
        style: t.textTheme.bodyMedium,
      ),
      const SizedBox(height: Gap.m),
      PlanCard(cardKey: const Key('check-inputs'), title: 'Where', children: [
        PlanMap(
          height: 260,
          pins: [if (p != null) PlanPin(p, 'A', PlanPinKind.point)],
          fitKey: p,
          onTap: (x) => setState(() => _p = x),
          semanticLabel: 'Map. Tap to choose the place to check. The place can also be typed below.',
        ),
        const SizedBox(height: Gap.m),
        PointField(id: 'check-point', label: 'Place', value: p, onChanged: (x) => setState(() => _p = x)),
        const SizedBox(height: Gap.s),
        PlanSegments<double>(
          label: 'Look within',
          segKey: const Key('check-radius'),
          selected: _radiusM,
          segments: [for (final m in const [250.0, 500.0, 1000.0, 2000.0]) ButtonSegment(value: m, label: Text(units.distance(m)))],
          onChanged: (v) => setState(() => _radiusM = v),
        ),
      ]),
      if (cov == null)
        PlanCard(title: 'Measured coverage', children: [
          if (s.networkCoverageFailed)
            PlanError('Could not load the measured coverage and none is stored yet. Check your connection.', onRetry: () => unawaited(s.refreshNetworkCoverage()))
          else
            const Center(key: Key('check-loading'), child: Padding(padding: EdgeInsets.all(Gap.l), child: CircularProgressIndicator())),
        ])
      else if (r == null)
        PlanCard(title: 'Measured coverage', children: [
          PlanNote('Choose a place on the map, type it, or use your location. ${cov.cells.length} measured cells are loaded for ${s.viewingRegion?.name ?? 'this region'}.', key: const Key('check-pick')),
          ..._summary(context, s),
        ])
      else
        _result(context, s, r, units),
    ]);
  }

  List<Widget> _summary(BuildContext context, AppState s) {
    final cov = s.networkCoverage!;
    final driven = cov.cells.where((c) => c.pings > 0).toList();
    final heard = driven.where((c) => c.heard > 0).length;
    return [
      PlanFacts([
        ('Driven cells loaded', '${driven.length}'),
        ('Cells where a repeater answered', driven.isEmpty ? '-' : '$heard (${(100 * heard / driven.length).round()} %)'),
        ('Data as of', cov.asOf),
      ]),
    ];
  }

  Widget _result(BuildContext context, AppState s, CoverageCheck r, Units units) {
    final t = Theme.of(context);
    final (IconData icon, String head, String body) = switch (r.verdict) {
      CoverageVerdict.covered => (Icons.check_circle, 'Covered', 'Drives here got answers from repeaters on ${(r.heardShare * 100).round()} % of their pings.'),
      CoverageVerdict.weak => (Icons.help_outline, 'Weak', 'Only ${(r.heardShare * 100).round()} % of the pings driven here were answered: this place is on the edge.'),
      CoverageVerdict.dead => (Icons.signal_wifi_off, 'Driven, nothing heard', 'People drove here and no repeater answered a single ping.'),
      CoverageVerdict.unmeasured => (Icons.explore_off, 'Not measured', 'Nobody has driven within ${units.distance(r.radiusM)} of this place in the data loaded.'),
    };
    final last = r.lastAt;
    return PlanCard(cardKey: const Key('check-result'), title: 'Result', children: [
      Row(children: [
        Icon(icon, size: 36, color: t.colorScheme.primary),
        const SizedBox(width: Gap.m),
        Expanded(child: Text(head, key: const Key('check-verdict'), style: t.textTheme.headlineSmall)),
      ]),
      const SizedBox(height: Gap.xs),
      Text(body, key: const Key('check-body')),
      const SizedBox(height: Gap.s),
      if (r.cells > 0)
        PlanFacts([
          ('Driven cells nearby', '${r.cells}, ${r.heardCells} with an answer'),
          ('Pings', '${r.pings}, ${r.heardPings} answered'),
          ('Best signal', r.bestSnr == null ? 'none recorded' : fmtDb(r.bestSnr!, signed: true)),
          ('Most repeaters in one cell', '${r.maxRepeaters}'),
          if (last != null) ('Last measured', last.toLocal().toString().substring(0, 10)),
        ])
      else if (r.nearestM != null)
        PlanFacts([('Nearest measured cell', '${units.distance(r.nearestM!)} away')]),
      const SizedBox(height: Gap.s),
      ..._summary(context, s),
      Text(
        'Cells are about ${units.distance(cellReachM(s.networkCoverage!.grid) * 2)} across at this zoom of the data; a place counts a cell if its centre is within the distance you picked plus half a cell. '
        'Measured coverage comes from MeshSonar drives and forwarded MeshMapper data; absence of data is not proof of no signal.',
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
    ]);
  }
}
