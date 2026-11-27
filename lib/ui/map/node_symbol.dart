// The ONE node symbol set on every map (MAP slice 3, Map Definition `symbols.set`, plan 4.3): shape by role, ring by freshness,
// an optional tint by a variable, neutral ink otherwise. The shapes arrive as 24 x 24 SVG path strings; [SvgPath] turns them into
// a Flutter [Path] and [NodeSymbolPainter] draws them the way the website's sprite sheet does. Observers, phones, companions,
// sensors and the small maps' repeaters use this; the Drive map's repeater atlas (repeater_sprites.dart) draws the same
// tower-in-a-circle and rounded square from the definition's `symbols.repeater`.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/map_definition_v2.dart';
import '../../core/map_prefs.dart';
import '../../core/region_repeaters_api.dart' show RegionRepeater, RepeaterActivity;
import 'active_map_definition.dart';

/// A minimal SVG path reader: M m L l H h V v Q q C c A a Z z with implicit repeats; what `symbols.set` uses.
abstract final class SvgPath {
  static final RegExp _tok = RegExp(r'[A-Za-z]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?');

  /// The path of [d]; an unreadable string gives the part drawn so far.
  static Path parse(String d) {
    final t = _tok.allMatches(d).map((m) => m.group(0)!).toList();
    final p = Path();
    var i = 0;
    var cmd = '';
    var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0;
    double n() => double.parse(t[i++]);
    bool isCmd(String s) => RegExp(r'^[A-Za-z]$').hasMatch(s);
    try {
      while (i < t.length) {
        if (isCmd(t[i])) cmd = t[i++];
        final rel = cmd == cmd.toLowerCase();
        switch (cmd.toUpperCase()) {
          case 'M':
            final nx = n(), ny = n();
            x = rel ? x + nx : nx;
            y = rel ? y + ny : ny;
            sx = x;
            sy = y;
            p.moveTo(x, y);
            cmd = rel ? 'l' : 'L'; // further pairs are line-tos
          case 'L':
            final nx = n(), ny = n();
            x = rel ? x + nx : nx;
            y = rel ? y + ny : ny;
            p.lineTo(x, y);
          case 'H':
            final nx = n();
            x = rel ? x + nx : nx;
            p.lineTo(x, y);
          case 'V':
            final ny = n();
            y = rel ? y + ny : ny;
            p.lineTo(x, y);
          case 'Q':
            final cx = n(), cy = n(), nx = n(), ny = n();
            p.quadraticBezierTo(rel ? x + cx : cx, rel ? y + cy : cy, rel ? x + nx : nx, rel ? y + ny : ny);
            x = rel ? x + nx : nx;
            y = rel ? y + ny : ny;
          case 'C':
            final c1x = n(), c1y = n(), c2x = n(), c2y = n(), nx = n(), ny = n();
            p.cubicTo(rel ? x + c1x : c1x, rel ? y + c1y : c1y, rel ? x + c2x : c2x, rel ? y + c2y : c2y, rel ? x + nx : nx, rel ? y + ny : ny);
            x = rel ? x + nx : nx;
            y = rel ? y + ny : ny;
          case 'A':
            final rx = n(), ry = n(), rot = n(), large = n(), sweep = n(), nx = n(), ny = n();
            x = rel ? x + nx : nx;
            y = rel ? y + ny : ny;
            p.arcToPoint(Offset(x, y), radius: Radius.elliptical(rx, ry), rotation: rot, largeArc: large != 0, clockwise: sweep != 0);
          case 'Z':
            p.close();
            x = sx;
            y = sy;
          default:
            return p;
        }
      }
    } on FormatException {
      return p;
    } on RangeError {
      return p;
    }
    return p;
  }
}

/// Draws one role of the set at [size] logical points: the badge filled with the neutral fill (or the [tint]), the glyph and the
/// outline in ink, and the freshness ring (solid, dashed or none, faded when stale).
class NodeSymbolPainter extends CustomPainter {
  final NodeSymbolSet set;
  final SymbolRole role;
  final String freshness;
  final bool dark;

  /// ARGB of the tint (colour-by), or null = neutral.
  final int? tint;

  /// Extra opacity (a moving phone fades over 10 minutes).
  final double opacity;
  NodeSymbolPainter({required this.set, required this.role, this.freshness = 'fresh', required this.dark, this.tint, this.opacity = 1});

  static final Map<String, (Path, List<(Path, bool)>)> _paths = {};

  (Path, List<(Path, bool)>) _geometry() => _paths.putIfAbsent('${role.id}|${role.badge}', () {
    if (_paths.length > 64) _paths.clear();
    return (SvgPath.parse(role.badge), [for (final g in role.glyph) (SvgPath.parse(g.d), g.fill)]);
  });

  @override
  void paint(Canvas canvas, Size size) {
    final f = set.fresh(freshness) ?? (set.freshness.isNotEmpty ? set.freshness.first : null);
    final neutral = set.neutral(dark);
    final fill = Color(tint ?? neutral.fill);
    final ink = Color(tint == null ? neutral.ink : set.onTint(dark));
    final outline = Color(neutral.ink);
    final k = size.shortestSide / set.viewBox;
    final fade = (f?.opacity ?? 1) * opacity;
    canvas.save();
    canvas.scale(k);
    final (badge, glyph) = _geometry();
    if (fade < 1) canvas.saveLayer(Rect.fromLTWH(0, 0, set.viewBox, set.viewBox), Paint()..color = Color.fromRGBO(0, 0, 0, fade));
    canvas.drawPath(badge, Paint()..color = fill);
    canvas.drawPath(
      badge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = set.strokePx
        ..strokeJoin = StrokeJoin.round
        ..color = outline,
    );
    for (final (path, isFill) in glyph) {
      canvas.drawPath(
        path,
        Paint()
          ..style = isFill ? PaintingStyle.fill : PaintingStyle.stroke
          ..strokeWidth = set.strokePx
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = ink,
      );
    }
    final ring = f?.ring ?? 'none';
    if (ring != 'none') {
      final c = Offset(set.viewBox / 2, set.viewBox / 2);
      final rp = Path()..addOval(Rect.fromCircle(center: c, radius: set.ringR));
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = set.ringWidth
        ..color = outline;
      if (ring == 'solid') {
        canvas.drawPath(rp, paint);
      } else {
        final on = set.ringDash.isNotEmpty ? set.ringDash.first : 3.4, off = set.ringDash.length > 1 ? set.ringDash[1] : 2.6;
        for (final m in rp.computeMetrics()) {
          final count = math.max(1, (m.length / (on + off)).round());
          final step = m.length / count;
          for (var j = 0; j < count; j++) {
            canvas.drawPath(m.extractPath(j * step, j * step + step * on / (on + off)), paint);
          }
        }
      }
    }
    if (fade < 1) canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(NodeSymbolPainter o) =>
      o.role != role || o.freshness != freshness || o.dark != dark || o.tint != tint || o.opacity != opacity || o.set != set;
}

/// One node symbol as a widget (a marker, a legend row, a list leading icon). [size] defaults to the set's size times the
/// person's Icon size; a legend row passes its own.
class NodeSymbol extends StatelessWidget {
  final String role;
  final String freshness;
  final String? tint;
  final String tintVariable;
  final double? size;
  final double opacity;
  final bool? dark;

  /// True = this is a map marker: scaled by the person's Icon size.
  final bool scaled;
  const NodeSymbol({
    super.key,
    required this.role,
    this.freshness = 'fresh',
    this.tint,
    this.tintVariable = 'status',
    this.size,
    this.opacity = 1,
    this.dark,
    this.scaled = true,
  });

  @override
  Widget build(BuildContext context) {
    final set = ActiveMapDefinition.current.nodeSymbols;
    final r = set.role(role) ?? set.role('unknown') ?? set.roles.first;
    final isDark = dark ?? Theme.of(context).brightness == Brightness.dark;
    final tints = tint == null ? null : set.tints[tintVariable]?.where((t) => t.id == tint).firstOrNull;
    return Semantics(
      label: r.label,
      excludeSemantics: true,
      child: ListenableBuilder(
        listenable: MapPrefs.shared,
        builder: (context, _) {
          final px = size ?? set.sizePx * (scaled ? MapPrefs.shared.iconScale : 1.0);
          return CustomPaint(
            size: Size.square(px),
            painter: NodeSymbolPainter(set: set, role: r, freshness: freshness, dark: isDark, tint: tints?.of(isDark), opacity: opacity),
          );
        },
      ),
    );
  }
}

/// The ARGB of tint [id] under "Colour nodes by" [variable] (`status`, `hash`, `role`) in the definition's symbol set, or null
/// (neutral, or a variable or id the definition does not list). Build 77: the one lookup for the repeater painter (Drive and
/// Live) and the node symbol widget.
int? nodeTintArgb(String variable, String? id, {required bool dark}) {
  if (id == null || variable == 'none') return null;
  final set = ActiveMapDefinition.current.nodeSymbols;
  return set.tints[variable]?.where((t) => t.id == id).firstOrNull?.of(dark);
}

/// The tint id of a roster repeater under "Colour nodes by" [variable] (the Drive map's repeaters; Live reads its own rows).
String? rosterTintId(RegionRepeater r, String variable) => switch (variable) {
  'status' => switch (r.status) {
    RepeaterActivity.active || RepeaterActivity.fresh => 'active',
    RepeaterActivity.quiet => 'degraded',
    RepeaterActivity.stale => 'silent',
  },
  'role' => r.role,
  'hash' => r.hashSizeBytes == null ? 'unknown' : (r.hashSizeBytes! >= 2 ? 'multi' : 'one'),
  _ => null,
};
