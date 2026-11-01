// Plan > Site explorer > link: the terrain between two sites (or a site and a live repeater) from the planning data: ground, trees
// and buildings, the antenna line and the 60% first Fresnel zone, with sliders for both antenna heights. The clearance maths runs on
// the phone (lib/core/plan/link_profile.dart, checked against the website's numbers). The budget is an estimate with no foliage loss.
import 'package:flutter/material.dart';

import '../../core/heard.dart' show bearingDeg, compass;
import '../../core/plan/link_profile.dart';
import '../../core/plan/plan_native_api.dart';
import '../../core/units.dart' show Units;
import '../app.dart';
import 'plan_engine_common.dart';

class LinkScreen extends StatelessWidget {
  final PlanNativeApi? api;
  final String a, b;
  const LinkScreen({super.key, this.api, required this.a, required this.b});
  @override
  Widget build(BuildContext context) {
    final api0 = api ?? planApiFor(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Link profile')),
      body: SafeArea(
        top: false,
        child: PlanFetchView<LinkProfile>(
          id: 'link',
          load: () => api0.link(a, b),
          reloadKey: '${api0.baseUrl}|$a|$b',
          available: (d) => d.found,
          unavailableText: (d) => 'No stored terrain profile for this pair. Profiles exist for ${d.profileCount} scored candidate pairs.',
          build: (context, d, reload) => _LinkBody(p: d),
        ),
      ),
    );
  }
}

class _LinkBody extends StatefulWidget {
  final LinkProfile p;
  const _LinkBody({required this.p});
  @override
  State<_LinkBody> createState() => _LinkBodyState();
}

class _LinkBodyState extends State<_LinkBody> {
  late double _hA, _hB;
  double _tx = 22, _gain = 6, _cable = 1;
  static const _maxM = 12.2; // 40 ft

  @override
  void initState() {
    super.initState();
    final s = widget.p.storedHeights(33);
    _hA = s.$1.clamp(0, _maxM);
    _hB = s.$2.clamp(0, _maxM);
  }

  bool _is(int h) {
    final s = widget.p.storedHeights(h);
    return (_hA - s.$1).abs() < 0.15 && (_hB - s.$2).abs() < 0.15;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final t = Theme.of(context);
    final u = AppScope.unitsOf(context);
    final cur = p.clearance(_hA, _hB);
    final A = p.ends.isNotEmpty ? p.ends.first : null, B = p.ends.length > 1 ? p.ends[1] : null;
    final atStored = _is(20) ? 20 : (_is(33) ? 33 : 0);
    final verdict = cur.worstRatio < 0
        ? '${cur.worstWhat == 'canopy' ? 'Tree canopy' : (cur.worstWhat == 'building' ? 'A building' : 'Ground')} rises above the antenna line'
        : (cur.worstRatio < fresnelShare ? 'The line is open but the Fresnel zone is crowded' : 'The line and 60% of the Fresnel zone are clear');
    double? brg;
    if (A?.lat != null && B?.lat != null) brg = bearingDeg(A!.lat!, A.lon!, B!.lat!, B.lon!);
    final lead = '$verdict at ${u.height(_hA) == u.height(_hB) ? u.height(_hA) : '${u.height(_hA)} and ${u.height(_hB)}'}. ${u.distance(p.km * 1000)}${brg != null ? ', bearing ${brg.round()}° ${compass(brg)}' : ''}.';
    final cols = <(String, Clearance, String)>[
      (mountName(20), p.clearanceStored(20), p.odds == null ? '—' : '${p.odds!.tier20} ${oddsPct(p.odds!.odds20)}'),
      (mountName(33), p.clearanceStored(33), p.odds == null ? '—' : '${p.odds!.tier33} ${oddsPct(p.odds!.odds33)}'),
      if (atStored == 0) ('${u.height(_hA)} / ${u.height(_hB)}', cur, '${mountName(20)} / ${mountName(33)} only'),
    ];
    String r1(double n) => n.toStringAsFixed(1);
    String signedDb(double n) => '${n >= 0 ? '+' : '−'}${r1(n.abs())} dB';
    LinkBudget bud(Clearance c) => linkBudget(c, _tx, _gain, _cable);
    final rows = <(String, String Function((String, Clearance, String)))>[
      ('Lidar tier, odds', (x) => x.$3),
      ('Tightest point', (x) => x.$2.worstClearM < 0 ? '${u.distance(-x.$2.worstClearM)} above' : '${(x.$2.worstRatio * 100).round()}% F1'),
      ('60% Fresnel zone clear', (x) => '${(x.$2.clearShare * 100).round()}%'),
      ('Line blocked', (x) => u.distance(x.$2.blockedM.toDouble())),
      ('Canopy on line', (x) => u.distance(x.$2.canopyM.toDouble())),
      ('Budget margin (est.)', (x) => signedDb(bud(x.$2).marginDb)),
    ];
    return planColumn(key: const Key('link-body'), [
      planHeader(context, '${A?.name ?? p.a} to ${B?.name ?? p.b}', lead),
      planSection(context, 'Antenna heights', key: const Key('link-heights'), children: [
        _slider('A', A?.name ?? p.a, _hA, (v) => setState(() => _hA = v), const Key('link-ha')),
        _slider('B', B?.name ?? p.b, _hB, (v) => setState(() => _hB = v), const Key('link-hb')),
        Wrap(spacing: 8, children: [
          ChoiceChip(
            key: const Key('link-20'),
            label: Text(mountName(20)),
            selected: atStored == 20,
            onSelected: (_) => setState(() {
              final s = p.storedHeights(20);
              _hA = s.$1.clamp(0, _maxM);
              _hB = s.$2.clamp(0, _maxM);
            }),
          ),
          ChoiceChip(
            key: const Key('link-33'),
            label: Text(mountName(33)),
            selected: atStored == 33,
            onSelected: (_) => setState(() {
              final s = p.storedHeights(33);
              _hA = s.$1.clamp(0, _maxM);
              _hB = s.$2.clamp(0, _maxM);
            }),
          ),
        ]),
      ]),
      planSection(context, 'Path profile', lead: 'Brown is ground, green is trees, grey is buildings and other surface; the line is the antenna line with its 60% Fresnel zone around it. Red marks where the surface is above the line.', children: [
        Semantics(
          label: 'Terrain profile between the two ends, ${u.distance(p.km * 1000)}. ${u.distance(cur.blockedM.toDouble())} of the path are blocked, ${u.distance(cur.canopyM.toDouble())} of them by tree canopy.',
          child: SizedBox(key: const Key('link-chart'), height: 220, child: CustomPaint(size: Size.infinite, painter: _ProfilePainter(cur, t.colorScheme.outline, t.textTheme.labelSmall!, u))),
        ),
        for (final o in cur.obstructions)
          Text('${u.distance(o.km * 1000)}: ${o.what} reaches ${o.above >= 0 ? '${u.distance(o.above)} above' : '${u.distance(-o.above)} below'} the line (${(o.ratio * 100).round()}% of the first Fresnel zone clear).', style: t.textTheme.bodySmall),
      ]),
      planSection(context, 'Figures', key: const Key('link-figures'), children: [
        Table(
          columnWidths: const {0: FlexColumnWidth(1.6)},
          children: [
            TableRow(children: [const SizedBox.shrink(), for (final c in cols) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(c.$1, style: t.textTheme.labelLarge, textAlign: TextAlign.end))]),
            for (final r in rows)
              TableRow(children: [
                Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(r.$1, style: t.textTheme.bodySmall)),
                for (final c in cols) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(r.$2(c), style: t.textTheme.bodyMedium, textAlign: TextAlign.end)),
              ]),
          ],
        ),
        ExpansionTile(
          key: const Key('link-radio'),
          tilePadding: EdgeInsets.zero,
          title: const Text('Radio settings for the budget'),
          children: [
            _num('Transmit power', 'dBm', _tx, 0, 30, (v) => setState(() => _tx = v)),
            _num('Antenna gains, both ends', 'dBi', _gain, -5, 20, (v) => setState(() => _gain = v)),
            _num('Cable and connector loss', 'dB', _cable, 0, 10, (v) => setState(() => _cable = v)),
          ],
        ),
        Text('Odds and tiers come from the lidar link model. Clearance and budget are computed from the ${p.d.length}-sample terrain profile; the budget models no foliage loss or fading, so treat it as optimistic through canopy.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    ]);
  }

  Widget _slider(String end, String name, double v, ValueChanged<double> on, Key key) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$end: $name — ${AppScope.unitsOf(context).height(v)}', style: Theme.of(context).textTheme.labelLarge),
        Slider(key: key, min: 0, max: _maxM, divisions: 61, value: v, label: AppScope.unitsOf(context).height(v), semanticFormatterCallback: (x) => AppScope.unitsOf(context).height(x), onChanged: on),
      ]);

  Widget _num(String label, String unit, double v, double lo, double hi, ValueChanged<double> on) =>
      Row(children: [Expanded(child: Text('$label: ${v.toStringAsFixed(1)} $unit')), SizedBox(width: 160, child: Slider(min: lo, max: hi, divisions: ((hi - lo) * 2).round(), value: v.clamp(lo, hi), onChanged: on))]);
}

class _ProfilePainter extends CustomPainter {
  final Clearance c;
  final Color axis;
  final TextStyle label;
  final Units u;
  const _ProfilePainter(this.c, this.axis, this.label, this.u);

  @override
  void paint(Canvas canvas, Size size) {
    if (c.rows.length < 2) return;
    const left = 40.0, bottom = 20.0, top = 6.0, right = 6.0;
    final w = size.width - left - right, h = size.height - top - bottom;
    final maxKm = c.rows.last.km <= 0 ? 1 : c.rows.last.km;
    final lo = c.floor, hi = c.top;
    double px(double km) => left + w * km / maxKm;
    double py(double v) => top + h * (1 - (v - lo) / (hi - lo));
    final ground = Path()..moveTo(px(c.rows.first.km), py(lo));
    for (final r in c.rows) {
      ground.lineTo(px(r.km), py(r.ground));
    }
    ground
      ..lineTo(px(c.rows.last.km), py(lo))
      ..close();
    canvas.drawPath(ground, Paint()..color = const Color(0xFF8D6E4A).withValues(alpha: 0.75));
    for (var i = 0; i + 1 < c.rows.length; i++) {
      final a = c.rows[i], b = c.rows[i + 1];
      final p = Path()
        ..moveTo(px(a.km), py(a.ground))
        ..lineTo(px(a.km), py(a.surface))
        ..lineTo(px(b.km), py(b.surface))
        ..lineTo(px(b.km), py(b.ground))
        ..close();
      canvas.drawPath(p, Paint()..color = (a.tree ? const Color(0xFF3F8F4F) : const Color(0xFF8A8F98)).withValues(alpha: 0.85));
    }
    final band = Path()..moveTo(px(c.rows.first.km), py(c.rows.first.fresnelHi));
    for (final r in c.rows) {
      band.lineTo(px(r.km), py(r.fresnelHi));
    }
    for (final r in c.rows.reversed) {
      band.lineTo(px(r.km), py(r.fresnelLo));
    }
    band.close();
    canvas.drawPath(band, Paint()..color = const Color(0xFF3B82F6).withValues(alpha: 0.18));
    canvas.drawLine(Offset(px(c.rows.first.km), py(c.rows.first.line)), Offset(px(c.rows.last.km), py(c.rows.last.line)),
        Paint()
          ..color = const Color(0xFF1D4ED8)
          ..strokeWidth = 2);
    final red = Paint()
      ..color = const Color(0xFFD64545)
      ..strokeWidth = 3;
    for (final r in c.rows) {
      if (r.blocked) canvas.drawLine(Offset(px(r.km), py(r.line)), Offset(px(r.km), py(r.surface)), red);
    }
    final ap = Paint()
      ..color = axis
      ..strokeWidth = 1;
    canvas.drawLine(Offset(left, top), Offset(left, top + h), ap);
    canvas.drawLine(Offset(left, top + h), Offset(left + w, top + h), ap);
    void text(String s, Offset at, {bool rightAlign = false}) {
      final tp = TextPainter(text: TextSpan(text: s, style: label), textDirection: TextDirection.ltr, textScaler: TextScaler.noScaling)..layout();
      tp.paint(canvas, rightAlign ? Offset(at.dx - tp.width, at.dy - tp.height / 2) : Offset(at.dx - tp.width / 2, at.dy));
    }

    text(u.height(hi.roundToDouble()), Offset(left - 3, top + 6), rightAlign: true);
    text(u.height(lo.roundToDouble()), Offset(left - 3, top + h - 6), rightAlign: true);
    text('0', Offset(left, top + h + 4));
    text(u.distance(maxKm * 1000), Offset(left + w - 14, top + h + 4));
  }

  @override
  bool shouldRepaint(_ProfilePainter old) => old.c != c;
}
