// The terrain profile of one link (release 0.38 Link mode, improvement 6 "profile scrubbing"): the ground between A and B
// drawn with the earth's curve (k = 4/3, the same bulge link_model.dart uses), the straight line of sight from antenna A to
// antenna B, the first Fresnel zone around it, the blocking ridge, and a crosshair the person drags along the chart. The
// readout sits at the finger (distance from A, ground, how far the line clears it and how much of the Fresnel zone is
// open); the Link mode puts the same spot on the map. VoiceOver: the chart is one adjustable element (swipe up / down
// moves the crosshair a twentieth of the path) whose value is the readout.
//
// Keys: 'link-profile' (the chart), 'link-profile-paint'.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/plan/link_model.dart' show keM, fresnelShare;
import '../../../core/plan_contract.dart' show PlanProfile;
import '../../../core/units.dart' show Units;

/// One spot along the profile, at [t] (0 = A, 1 = B) of the way.
@immutable
class ProfilePoint {
  final double t, km;

  /// Ground at the spot, metres above sea level (bare earth, no curve), and with the earth's curve added.
  final double groundM, bulgedM;

  /// Height of the straight antenna line there (same datum as [bulgedM]).
  final double lineM;

  /// Radius of the first Fresnel zone there, metres.
  final double zoneM;
  const ProfilePoint({required this.t, required this.km, required this.groundM, required this.bulgedM, required this.lineM, required this.zoneM});

  /// Metres between the line of sight and the ground (negative: the ground is above the line).
  double get clearM => lineM - bulgedM;

  /// Share of the first Fresnel zone that is open, percent (100 at the ends, negative when the line is blocked).
  double get fresnelPct => zoneM <= 0 ? 100 : math.min(100, clearM / zoneM * 100);
}

/// The profile at [t] (0..1): ground interpolated between the samples, the line from A's antenna to B's.
ProfilePoint profilePointAt(PlanProfile p, double haM, double hbM, double lambdaM, double t) {
  final g = p.groundM;
  final n = g.length;
  final tt = t.clamp(0.0, 1.0);
  final totalKm = p.distanceKm.last;
  final x = tt * (n - 1);
  final i = x.floor().clamp(0, n - 2);
  final f = x - i;
  final ground = g[i] + (g[i + 1] - g[i]) * f;
  final dTot = totalKm * 1000;
  final d1 = tt * dTot, d2 = dTot - d1;
  final bulge = d1 * d2 / (2 * keM);
  final h1 = g.first + haM, h2 = g.last + hbM;
  final line = h1 + (h2 - h1) * tt;
  final zone = dTot > 0 && d1 > 0 && d2 > 0 ? math.sqrt(lambdaM * d1 * d2 / dTot) : 0.0;
  return ProfilePoint(t: tt, km: totalKm * tt, groundM: ground, bulgedM: ground + bulge, lineM: line, zoneM: zone);
}

/// The crosshair readout in plain words.
String profileReadout(ProfilePoint p, Units units, {String aName = 'A'}) {
  final where = '${units.distance(p.km * 1000)} from $aName: ground ${units.height(p.groundM)}';
  if (p.clearM < 0) return '$where, ${units.height(-p.clearM)} above the line of sight (blocked)';
  return '$where, line of sight ${units.height(p.clearM)} above it, ${p.fresnelPct.clamp(0, 100).round()} % of the Fresnel zone open';
}

class ProfileChart extends StatelessWidget {
  final PlanProfile profile;
  final double haM, hbM, lambdaM;

  /// Distance from A of the blocking ridge, km (marked with a flag).
  final double? ridgeKm;

  /// The line of sight's colour (the verdict's).
  final Color lineColour;

  /// Where the crosshair is (0..1), null before the first touch.
  final double? scrubT;
  final ValueChanged<double> onScrub;
  final String aName, bName;
  final Units units;
  final double height;
  const ProfileChart({
    super.key = const Key('link-profile'),
    required this.profile,
    required this.haM,
    required this.hbM,
    required this.lambdaM,
    required this.lineColour,
    required this.onScrub,
    required this.units,
    this.ridgeKm,
    this.scrubT,
    this.aName = 'A',
    this.bName = 'B',
    this.height = 180,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final at = scrubT;
    final point = at == null ? null : profilePointAt(profile, haM, hbM, lambdaM, at);
    final readout = point == null ? 'Touch and drag along the chart to read the terrain.' : profileReadout(point, units, aName: aName);
    void step(double by) => onScrub(((at ?? 0.5) + by).clamp(0.0, 1.0));
    final colours = _ChartColours(
      ground: t.colorScheme.onSurfaceVariant,
      groundFill: t.colorScheme.surfaceContainerHighest,
      zone: lineColour.withValues(alpha: 0.18),
      zoneEdge: lineColour.withValues(alpha: 0.55),
      line: lineColour,
      cross: t.colorScheme.onSurface,
      bubble: t.colorScheme.inverseSurface,
      bubbleText: t.colorScheme.onInverseSurface,
      ridge: t.colorScheme.error,
      label: t.colorScheme.onSurfaceVariant,
    );
    // The in-chart labels stay legible at large text without swallowing the chart; the readout under the chart (Link
    // mode) carries the same words at the person's full text size.
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.4);
    return Semantics(
      container: true,
      label: 'Terrain profile from $aName to $bName, ${units.distance(profile.distanceKm.last * 1000)}',
      value: readout,
      increasedValue: profileReadout(profilePointAt(profile, haM, hbM, lambdaM, ((at ?? 0.5) + 0.05).clamp(0.0, 1.0)), units, aName: aName),
      decreasedValue: profileReadout(profilePointAt(profile, haM, hbM, lambdaM, ((at ?? 0.5) - 0.05).clamp(0.0, 1.0)), units, aName: aName),
      onIncrease: () => step(0.05),
      onDecrease: () => step(-0.05),
      child: ExcludeSemantics(
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          void at0(Offset local) => onScrub((local.dx / w).clamp(0.0, 1.0));
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => at0(d.localPosition),
            onHorizontalDragStart: (d) => at0(d.localPosition),
            onHorizontalDragUpdate: (d) => at0(d.localPosition),
            child: SizedBox(
              width: w,
              height: height,
              child: CustomPaint(
                key: const Key('link-profile-paint'),
                painter: _ProfilePainter(
                  profile: profile,
                  haM: haM,
                  hbM: hbM,
                  lambdaM: lambdaM,
                  ridgeKm: ridgeKm,
                  point: point,
                  colours: colours,
                  units: units,
                  aName: aName,
                  bName: bName,
                  textScaler: scaler,
                  style: t.textTheme.labelSmall ?? const TextStyle(fontSize: 11),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _ChartColours {
  final Color ground, groundFill, zone, zoneEdge, line, cross, bubble, bubbleText, ridge, label;
  const _ChartColours({
    required this.ground,
    required this.groundFill,
    required this.zone,
    required this.zoneEdge,
    required this.line,
    required this.cross,
    required this.bubble,
    required this.bubbleText,
    required this.ridge,
    required this.label,
  });
}

class _ProfilePainter extends CustomPainter {
  final PlanProfile profile;
  final double haM, hbM, lambdaM;
  final double? ridgeKm;
  final ProfilePoint? point;
  final _ChartColours colours;
  final Units units;
  final String aName, bName;
  final TextScaler textScaler;
  final TextStyle style;
  _ProfilePainter({
    required this.profile,
    required this.haM,
    required this.hbM,
    required this.lambdaM,
    required this.ridgeKm,
    required this.point,
    required this.colours,
    required this.units,
    required this.aName,
    required this.bName,
    required this.textScaler,
    required this.style,
  });

  TextPainter _text(String s, Color c, {double maxWidth = double.infinity, FontWeight? weight}) =>
      TextPainter(text: TextSpan(text: s, style: style.copyWith(color: c, fontWeight: weight)), textDirection: TextDirection.ltr, textScaler: textScaler, maxLines: 2, ellipsis: '…')
        ..layout(maxWidth: maxWidth);

  @override
  void paint(Canvas canvas, Size size) {
    final n = profile.groundM.length;
    if (n < 2 || size.width <= 0 || size.height <= 0) return;
    // Points along the path: every sample, plus enough for a smooth Fresnel zone on a short profile.
    final steps = math.max(n - 1, 64);
    final pts = [for (var i = 0; i <= steps; i++) profilePointAt(profile, haM, hbM, lambdaM, i / steps)];
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final p in pts) {
      lo = math.min(lo, p.bulgedM);
      hi = math.max(hi, math.max(p.bulgedM, p.lineM + p.zoneM));
    }
    final span = math.max(hi - lo, 10.0);
    final labelH = _text('A', colours.label).height;
    final top = labelH + 6, bottom = size.height - labelH - 4;
    final yMin = lo - span * 0.12, yMax = hi + span * 0.08;
    double x(double t) => t * size.width;
    double y(double m) => bottom - (m - yMin) / (yMax - yMin) * (bottom - top);

    // Ground, filled down to the bottom.
    final ground = Path()..moveTo(0, bottom);
    for (final p in pts) {
      ground.lineTo(x(p.t), y(p.bulgedM));
    }
    ground
      ..lineTo(size.width, bottom)
      ..close();
    canvas.drawPath(ground, Paint()..color = colours.groundFill);
    final groundLine = Path();
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      i == 0 ? groundLine.moveTo(x(p.t), y(p.bulgedM)) : groundLine.lineTo(x(p.t), y(p.bulgedM));
    }
    canvas.drawPath(groundLine, Paint()
      ..color = colours.ground
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);

    // The first Fresnel zone around the line, and its 60 % lower edge (the rule of thumb the verdict uses).
    final zone = Path();
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      i == 0 ? zone.moveTo(x(p.t), y(p.lineM + p.zoneM)) : zone.lineTo(x(p.t), y(p.lineM + p.zoneM));
    }
    for (final p in pts.reversed) {
      zone.lineTo(x(p.t), y(p.lineM - p.zoneM));
    }
    zone.close();
    canvas.drawPath(zone, Paint()..color = colours.zone);
    final edge = Path();
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      final yy = y(p.lineM - fresnelShare * p.zoneM);
      i == 0 ? edge.moveTo(x(p.t), yy) : edge.lineTo(x(p.t), yy);
    }
    canvas.drawPath(edge, Paint()
      ..color = colours.zoneEdge
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);

    // Masts and the line of sight.
    final a = pts.first, b = pts.last;
    final mast = Paint()
      ..color = colours.ground
      ..strokeWidth = 2;
    canvas.drawLine(Offset(1, y(a.bulgedM)), Offset(1, y(a.lineM)), mast);
    canvas.drawLine(Offset(size.width - 1, y(b.bulgedM)), Offset(size.width - 1, y(b.lineM)), mast);
    canvas.drawLine(Offset(0, y(a.lineM)), Offset(size.width, y(b.lineM)), Paint()
      ..color = colours.line
      ..strokeWidth = 2.5);

    // The blocking ridge.
    final rk = ridgeKm;
    final total = profile.distanceKm.last;
    if (rk != null && total > 0) {
      final rp = profilePointAt(profile, haM, hbM, lambdaM, rk / total);
      final rx = x(rp.t), ry = y(rp.bulgedM);
      final flag = Path()
        ..moveTo(rx, ry)
        ..lineTo(rx, ry - 18)
        ..lineTo(rx + 10, ry - 14)
        ..lineTo(rx, ry - 10);
      canvas.drawPath(flag, Paint()
        ..color = colours.ridge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
      canvas.drawCircle(Offset(rx, ry), 3.5, Paint()..color = colours.ridge);
    }

    // End labels and the length.
    final la = _text(aName, colours.label, maxWidth: size.width * 0.4, weight: FontWeight.w600);
    la.paint(canvas, const Offset(2, 0));
    final lb = _text(bName, colours.label, maxWidth: size.width * 0.4, weight: FontWeight.w600);
    lb.paint(canvas, Offset(size.width - lb.width - 2, 0));
    final len = _text(units.distance(total * 1000), colours.label);
    len.paint(canvas, Offset((size.width - len.width) / 2, size.height - len.height));

    // The crosshair and the readout at the finger.
    final p = point;
    if (p != null) {
      final cx = x(p.t);
      canvas.drawLine(Offset(cx, top - 2), Offset(cx, bottom), Paint()
        ..color = colours.cross
        ..strokeWidth = 1.2);
      canvas.drawCircle(Offset(cx, y(p.bulgedM)), 4, Paint()..color = colours.cross);
      canvas.drawCircle(Offset(cx, y(p.lineM)), 4, Paint()..color = colours.line);
      final words = p.clearM < 0
          ? '${units.distance(p.km * 1000)} · ${units.height(-p.clearM)} blocked'
          : '${units.distance(p.km * 1000)} · ${units.height(p.clearM)} clear · ${p.fresnelPct.clamp(0, 100).round()} %';
      final tp = _text(words, colours.bubbleText, maxWidth: size.width * 0.7, weight: FontWeight.w600);
      const pad = 5.0;
      final bw = tp.width + pad * 2, bh = tp.height + pad * 2;
      final bx = (cx - bw / 2).clamp(0.0, math.max(0.0, size.width - bw)).toDouble();
      final by = top;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(8)), Paint()..color = colours.bubble);
      tp.paint(canvas, Offset(bx + pad, by + pad));
    }
  }

  @override
  bool shouldRepaint(_ProfilePainter old) =>
      old.profile != profile ||
      old.haM != haM ||
      old.hbM != hbM ||
      old.lambdaM != lambdaM ||
      old.ridgeKm != ridgeKm ||
      old.point?.t != point?.t ||
      old.colours.line != colours.line ||
      old.aName != aName ||
      old.bName != bName ||
      old.textScaler != textScaler;
}
