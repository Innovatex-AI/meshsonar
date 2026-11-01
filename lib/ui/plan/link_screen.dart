// Plan > Point-to-point link. Pick two points (type them, use your location, or tap the map), set the antenna heights and
// read: line of sight, Fresnel clearance, the tightest point, the website's terrain-only odds and a link-budget margin.
// Terrain: the app asks the website's `score-link` endpoint once for the ground profile between the two points (AWS Terrain
// Tiles / USGS 3DEP, up to 40 km; only the two points' coordinates are sent), then does ALL the maths on the phone
// (lib/core/plan/link_model.dart, ports of the website's mesh.ts / profile.ts / coverage.ts, verified against numbers
// generated from them), so changing an antenna height needs no second request. The last profile is kept: reopening the same
// pair offline still scores. Bare-earth terrain only: trees and buildings are not in the profile (the website says the same).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' show LatLng;

import '../../core/plan/link_model.dart';
import '../../core/plan/plan_api.dart';
import '../../core/plan/plan_store.dart';
import '../app.dart';
import 'plan_common.dart';

const double _minFt = 3, _maxFt = 200, _maxKm = 40, _minKm = 0.1;

class LinkScreen extends StatefulWidget {
  /// Test seams.
  final PlanStore? store;
  final http.Client Function()? client;
  final LatLng? initialA, initialB;
  const LinkScreen({super.key, this.store, this.client, this.initialA, this.initialB});

  @override
  State<LinkScreen> createState() => _LinkScreenState();
}

class _LinkScreenState extends State<LinkScreen> {
  LatLng? _a, _b;
  String _placing = 'A';
  double _haFt = 20, _hbFt = 26;
  bool _loading = false;
  PlanResult<ScoredProfile>? _res;
  LatLng? _scoredA, _scoredB;
  final Latest _latest = Latest();
  late final PlanStore _store;
  bool _init = false;

  @override
  void initState() {
    super.initState();
    _a = widget.initialA;
    _b = widget.initialB;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    _store = widget.store ?? AppScope.read(context).planStore;
    if (_a != null && _b != null) unawaited(_fromStore());
  }

  double? get _km => _a == null || _b == null ? null : haversineKm(_a!.latitude, _a!.longitude, _b!.latitude, _b!.longitude);

  /// A pair opened before is shown at once from the stored profile.
  Future<void> _fromStore() async {
    final r = await planStored(_store, ScoreLinkApi.keyFor(_a!.latitude, _a!.longitude, _b!.latitude, _b!.longitude), ScoredProfile.parse);
    if (!mounted || r == null || _res != null) return;
    setState(() {
      _res = r;
      _scoredA = _a;
      _scoredB = _b;
    });
  }

  void _setPoint(String which, LatLng? p) {
    setState(() {
      if (which == 'A') {
        _a = p;
      } else {
        _b = p;
      }
      if (p != null && which == 'A' && _b == null) _placing = 'B';
    });
  }

  void _swap() => setState(() {
        final t = _a;
        _a = _b;
        _b = t;
        final h = _haFt;
        _haFt = _hbFt;
        _hbFt = h;
      });

  Future<void> _run() async {
    final a = _a, b = _b, km = _km;
    if (a == null || b == null || km == null || km > _maxKm || km < _minKm) return;
    final n = _latest.next();
    setState(() {
      _loading = true;
    });
    final r = await ScoreLinkApi(AppScope.read(context).planBaseUrl, _store, client: widget.client).profile(a.latitude, a.longitude, b.latitude, b.longitude);
    if (!mounted || !_latest.isCurrent(n)) return;
    setState(() {
      _loading = false;
      _res = r;
      if (r.ok) {
        _scoredA = a;
        _scoredB = b;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final km = _km;
    final units = AppScope.unitsOf(context);
    final tooFar = km != null && km > _maxKm;
    final tooClose = km != null && km < _minKm;
    final stale = _res?.ok == true && (_scoredA != _a || _scoredB != _b);
    final canRun = _a != null && _b != null && !tooFar && !tooClose && !_loading;
    return PlanPage(id: 'link', title: 'Point-to-point link', children: [
      Text(
        'A terrain check between any two points: line of sight, clearance and the odds the link works. Terrain only: trees and buildings are not in the profile. '
        'The two points\' coordinates go to the website to read the ground between them; nothing else is sent.',
        style: t.textTheme.bodyMedium,
      ),
      const SizedBox(height: Gap.m),
      PlanCard(
        cardKey: const Key('link-points'),
        title: 'The two ends',
        children: [
          PlanMap(
            height: 260,
            pins: [if (_a != null) PlanPin(_a!, 'A', PlanPinKind.a), if (_b != null) PlanPin(_b!, 'B', PlanPinKind.b)],
            line: [if (_a != null && _b != null) ...[_a!, _b!]],
            fitKey: '${_a}_$_b',
            onTap: (p) => _setPoint(_placing, p),
            semanticLabel: 'Map. Tap to place point $_placing. Points can also be typed below.',
          ),
          const SizedBox(height: Gap.m),
          PointField(id: 'link-a', label: 'Point A', value: _a, placing: _placing == 'A', onPlace: () => setState(() => _placing = 'A'), onChanged: (p) => _setPoint('A', p)),
          const SizedBox(height: Gap.s),
          PlanSlider(
            id: 'link-ha',
            label: 'Antenna height at A',
            valueText: units.height(_haFt * ftM),
            value: _haFt,
            min: _minFt,
            max: _maxFt,
            onChanged: (v) => setState(() => _haFt = v.roundToDouble()),
          ),
          PointField(id: 'link-b', label: 'Point B', value: _b, placing: _placing == 'B', onPlace: () => setState(() => _placing = 'B'), onChanged: (p) => _setPoint('B', p)),
          const SizedBox(height: Gap.s),
          PlanSlider(
            id: 'link-hb',
            label: 'Antenna height at B',
            valueText: units.height(_hbFt * ftM),
            value: _hbFt,
            min: _minFt,
            max: _maxFt,
            onChanged: (v) => setState(() => _hbFt = v.roundToDouble()),
          ),
          Wrap(spacing: Gap.m, crossAxisAlignment: WrapCrossAlignment.center, children: [
            TextButton.icon(key: const Key('link-swap'), onPressed: _a == null && _b == null ? null : _swap, icon: const Icon(Icons.swap_vert), label: const Text('Swap ends')),
            if (km != null) Text('${units.distance(km * 1000)} straight line', key: const Key('link-km')),
          ]),
          if (tooFar) PlanNote('The points are ${units.distance(km * 1000)} apart; the terrain check accepts up to ${units.distance(_maxKm * 1000)}.', warn: true, icon: Icons.warning_amber, key: const Key('link-toofar')),
          if (tooClose) PlanNote('The points are less than ${units.distance(_minKm * 1000)} apart. Move one of them.', warn: true, icon: Icons.warning_amber, key: const Key('link-tooclose')),
          const SizedBox(height: Gap.s),
          FilledButton.icon(
            key: const Key('link-run'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: canRun ? _run : null,
            icon: _loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.timeline),
            label: Text(_a == null || _b == null ? 'Place A and B to check' : _loading ? 'Reading the terrain...' : 'Check this link'),
          ),
        ],
      ),
      if (_res != null && !_res!.ok) PlanCard(title: 'Could not check the link', children: [PlanError(_res!.error!, onRetry: canRun ? _run : null)]),
      if (_res?.ok == true) _result(context, _res!, stale),
    ]);
  }

  Widget _result(BuildContext context, PlanResult<ScoredProfile> res, bool stale) {
    final t = Theme.of(context);
    final p = res.data!;
    final units = AppScope.unitsOf(context);
    final haM = _haFt * ftM, hbM = _hbFt * ftM;
    final a = analyseLink(p.groundM, p.km, haM, hbM);
    final c = a.clear;
    final (IconData tierIcon, String tierWord) = switch (a.tier) {
      LinkTier.strong => (Icons.check_circle, 'Strong'),
      LinkTier.likely => (Icons.check_circle_outline, 'Likely'),
      LinkTier.possible => (Icons.help_outline, 'Possible'),
      LinkTier.stretch => (Icons.warning_amber, 'Stretch'),
    };
    final odds = a.odds * 100;
    final worstM = c.worstClearM;
    return PlanCard(
      cardKey: const Key('link-result'),
      title: 'Result',
      lead: stale ? null : null,
      children: [
        if (res.offlineAsOf != null) OfflineAsOf(res.offlineAsOf!),
        if (stale) const PlanNote('The points changed. Check the link again to read the new ground.', icon: Icons.refresh, key: Key('link-stale')),
        Row(children: [
          Icon(tierIcon, size: 36, color: t.colorScheme.primary),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${odds < 1 ? '<1' : odds.toStringAsFixed(0)}% terrain odds', key: const Key('link-odds'), style: numberStyle(context, size: 28)),
              Text('$tierWord link', key: const Key('link-tier'), style: t.textTheme.titleSmall),
            ]),
          ),
        ]),
        const SizedBox(height: Gap.s),
        PlanNote(
          c.lineOfSight
              ? 'Clear line of sight: the ground stays ${units.shortLength(worstM.abs())} or more below the line between the antennas.'
              : 'No line of sight: the ground rises above the line between the antennas for ${units.distance(c.blockedM.toDouble())} of the path.',
          icon: c.lineOfSight ? Icons.visibility : Icons.visibility_off,
          key: const Key('link-los'),
        ),
        PlanNote(
          c.fresnelClear
              ? 'The first Fresnel zone is clear enough: at least 60 % of it is open along the whole path.'
              : 'The first Fresnel zone is obstructed: only ${(c.worstRatio * 100).clamp(-999, 999).toStringAsFixed(0)} % of it is open at the tightest point, ${units.distance(c.worstKm * 1000)} from A (the rule of thumb is 60 %).',
          icon: c.fresnelClear ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          key: const Key('link-fresnel'),
        ),
        const SizedBox(height: Gap.s),
        ProfileChart(analysis: a, haM: haM, hbM: hbM, endLabel: 'B   ${units.distance(a.km * 1000)}'),
        const SizedBox(height: Gap.s),
        PlanFacts([
          ('Distance', units.distance(p.km * 1000)),
          ('Terrain obstruction', '${a.bullDb.toStringAsFixed(1)} dB (Bullington)'),
          ('Tightest point', '${units.distance(c.worstKm * 1000)} from A, ${worstM >= 0 ? '${units.height(worstM)} clear' : '${units.height(-worstM)} of ground above the line'}'),
          ('Path loss estimate', '${a.pathLossDb.toStringAsFixed(1)} dB (free space ${a.fspl.toStringAsFixed(1)} + terrain ${a.diffractionDb.toStringAsFixed(1)} + clutter ${a.clutterDb.toStringAsFixed(1)})'),
          ('Link margin estimate', '${fmtDb(a.marginDb, signed: true)} at 22 dBm and 3 dBi each end'),
          ('Antennas', '${units.height(haM)} / ${units.height(hbM)} above ground'),
        ]),
        const SizedBox(height: Gap.s),
        Text(
          'Odds are the website\'s terrain-only model (distance and terrain, fitted on live repeater pairs); the margin uses its link budget at MeshCore\'s US default radio '
          '(SF7, 62.5 kHz) with a calibrated clutter allowance for trees and buildings. Estimates, not a promise. Ground: ${p.source}.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The ground between A and B with earth curvature (k = 4/3, the same bulge the numbers use), the antenna-to-antenna line
/// and the 60 % first Fresnel zone around it. The summary is in words under it; this is the picture.
class ProfileChart extends StatelessWidget {
  final LinkAnalysis analysis;
  final double haM, hbM;

  /// The label at the B end (carries the distance in the person's units).
  final String endLabel;
  const ProfileChart({super.key, required this.analysis, required this.haM, required this.hbM, required this.endLabel});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final c = analysis.clear;
    return Semantics(
      container: true,
      image: true,
      label: 'Ground profile over ${analysis.km.toStringAsFixed(1)} kilometres. '
          '${c.lineOfSight ? 'The line between the antennas clears the ground.' : 'The ground rises above the line between the antennas.'}',
      child: SizedBox(
        key: const Key('link-profile'),
        height: 190,
        child: CustomPaint(
          size: Size.infinite,
          painter: _ProfilePainter(analysis, haM, hbM, endLabel, ground: t.colorScheme.outline, line: t.colorScheme.primary, fresnel: t.colorScheme.primary.withValues(alpha: 0.18), blocked: m.silent, text: t.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _ProfilePainter extends CustomPainter {
  final LinkAnalysis a;
  final double haM, hbM;
  final String endLabel;
  final Color ground, line, fresnel, blocked, text;
  _ProfilePainter(this.a, this.haM, this.hbM, this.endLabel, {required this.ground, required this.line, required this.fresnel, required this.blocked, required this.text});

  @override
  void paint(Canvas canvas, Size size) {
    final n = a.groundM.length;
    final dTot = a.km * 1000;
    final bulged = [for (var i = 0; i < n; i++) a.groundM[i] + a.distKm[i] * 1000 * (dTot - a.distKm[i] * 1000) / (2 * keM)];
    final tipA = bulged.first + haM, tipB = bulged.last + hbM;
    double lineAt(double d) => tipA + (tipB - tipA) * d / dTot;
    double r1(double d) => d <= 0 || d >= dTot ? 0 : math.sqrt(lambdaM * d * (dTot - d) / dTot);
    var lo = double.infinity, hi = -double.infinity;
    for (var i = 0; i < n; i++) {
      final d = a.distKm[i] * 1000;
      lo = math.min(lo, bulged[i]);
      hi = math.max(hi, math.max(bulged[i], lineAt(d) + fresnelShare * r1(d)));
    }
    lo -= 8;
    hi += 8;
    const padL = 6.0, padB = 18.0;
    final w = size.width - padL, h = size.height - padB;
    double x(double d) => padL + d / dTot * w;
    double y(double e) => h - (e - lo) / (hi - lo) * h;

    final fz = Path()..moveTo(x(0), y(lineAt(0)));
    for (var i = 0; i < n; i++) {
      final d = a.distKm[i] * 1000;
      fz.lineTo(x(d), y(lineAt(d) + fresnelShare * r1(d)));
    }
    for (var i = n - 1; i >= 0; i--) {
      final d = a.distKm[i] * 1000;
      fz.lineTo(x(d), y(lineAt(d) - fresnelShare * r1(d)));
    }
    fz.close();
    canvas.drawPath(fz, Paint()..color = fresnel);

    final g = Path()..moveTo(x(0), h);
    for (var i = 0; i < n; i++) {
      g.lineTo(x(a.distKm[i] * 1000), y(bulged[i]));
    }
    g
      ..lineTo(x(dTot), h)
      ..close();
    canvas.drawPath(g, Paint()..color = ground.withValues(alpha: 0.35));
    canvas.drawPath(g, Paint()..color = ground..style = PaintingStyle.stroke..strokeWidth = 1.5);

    // Where the ground is above the line.
    for (var i = 0; i < n; i++) {
      final d = a.distKm[i] * 1000;
      if (bulged[i] > lineAt(d)) canvas.drawCircle(Offset(x(d), y(bulged[i])), 2.5, Paint()..color = blocked);
    }
    canvas.drawLine(Offset(x(0), y(tipA)), Offset(x(dTot), y(tipB)), Paint()..color = line..strokeWidth = 2);
    for (final (d, e) in [(0.0, tipA), (dTot, tipB)]) {
      canvas.drawCircle(Offset(x(d), y(e)), 4, Paint()..color = line);
    }
    final tp = TextPainter(
      text: TextSpan(text: 'A', style: TextStyle(color: text, fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x(0), size.height - 14));
    final tb = TextPainter(text: TextSpan(text: endLabel, style: TextStyle(color: text, fontSize: 11)), textDirection: TextDirection.ltr)..layout();
    tb.paint(canvas, Offset(size.width - tb.width, size.height - 14));
  }

  @override
  bool shouldRepaint(_ProfilePainter old) => old.a != a || old.haM != haM || old.hbM != hbM || old.endLabel != endLabel;
}
