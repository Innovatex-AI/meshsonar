// Repeater badge sprites (Drive plan 6.2, 6.3). Every repeater on the map is one of 3 freshness states x {repeater, room}
// x 6 variants (donut, badge 20 / 24, heard 28, selected 34, selected + heard). They are rasterised once per theme /
// DPR / palette into one atlas image and drawn with one `drawRawAtlas` call per frame, so hundreds of badges cost one
// draw call. Until the atlas is ready (and in widget tests, where `toImage` never completes) the same drawing code
// paints each badge straight onto the canvas ([paintRepeaterSprite]), so the picture is identical either way.
//
// Shape language, so colour-blind and greyscale users still tell the states apart (asserted by tests):
//   Fresh  (advert <= 24 h)  solid fill, white / dark tower glyph
//   Recent (<= 7 d)          35% tint, 2 pt coloured ring, coloured glyph
//   Stale  (> 7 d or never)  hollow, dashed ring, glyph at 70%
// Rooms are rounded squares (radius 30%), repeaters circles. The tower glyph + the white ring is the repeater
// signature; pings are plain dots and never use it.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/region_repeaters_api.dart' show RepeaterActivity;
import '../../design/map_tokens.dart';

/// Three-state freshness of a repeater (plan 6.3, D10).
enum RepeaterFreshness { fresh, recent, stale }

/// Website parity: the global list's age bands 0..3 (24 h / 7 d / 30 d / older). 30 d and older merge into Stale.
RepeaterFreshness freshnessOfAdvertBand(int band) => band <= 0
    ? RepeaterFreshness.fresh
    : (band == 1 ? RepeaterFreshness.recent : RepeaterFreshness.stale);

/// Roster status: active and new are Fresh, quiet is Recent, stale is Stale.
RepeaterFreshness freshnessOfActivity(RepeaterActivity a) => switch (a) {
  RepeaterActivity.active || RepeaterActivity.fresh => RepeaterFreshness.fresh,
  RepeaterActivity.quiet => RepeaterFreshness.recent,
  RepeaterActivity.stale => RepeaterFreshness.stale,
};

/// A roster band ordinal (see `rosterRows`) as a freshness.
RepeaterFreshness freshnessOfRosterBand(int band) =>
    freshnessOfActivity(band >= 0 && band < RepeaterActivity.values.length ? RepeaterActivity.values[band] : RepeaterActivity.stale);

/// From a last advert: <= 24 h Fresh, <= 7 d Recent, older or never Stale.
RepeaterFreshness freshnessOfAge(DateTime? lastSeen, DateTime now) {
  if (lastSeen == null) return RepeaterFreshness.stale;
  final s = now.difference(lastSeen).inSeconds;
  if (s <= 86400) return RepeaterFreshness.fresh;
  if (s <= 7 * 86400) return RepeaterFreshness.recent;
  return RepeaterFreshness.stale;
}

/// Screen reader word for a state.
String freshnessWord(RepeaterFreshness f) => switch (f) {
  RepeaterFreshness.fresh => 'advertised in the last 24 hours',
  RepeaterFreshness.recent => 'advertised in the last 7 days',
  RepeaterFreshness.stale => 'not advertised for over 7 days',
};

/// Fill colour of a state in [b] (the tokens of plan 6.3).
Color freshnessColor(RepeaterFreshness f, Brightness b) => switch (f) {
  RepeaterFreshness.fresh => MapTokens.repeaterFresh(b),
  RepeaterFreshness.recent => MapTokens.repeaterAging(b),
  RepeaterFreshness.stale => MapTokens.repeaterStale(b),
};

/// Badge sizes by level of detail. Logical points.
enum SpriteVariant {
  donut(14),
  badge(20),
  badgeLarge(24),
  heard(28),
  selected(34),
  selectedHeard(34);

  final double diameter;
  const SpriteVariant(this.diameter);
  bool get hasTick => this == heard || this == selectedHeard;
  bool get isSelected => this == selected || this == selectedHeard;
  double get radius => diameter / 2;
}

/// The variant for the zoom (plan 6.2): below 11 a donut, 11-13 the 20 pt badge, 13 and up the 24 pt badge; heard this
/// drive 28 pt with a tick (from z11); selected 34 pt (with the tick when also heard).
SpriteVariant spriteVariantFor(double zoom, {bool heard = false, bool selected = false}) {
  if (selected) return heard ? SpriteVariant.selectedHeard : SpriteVariant.selected;
  if (zoom < 11) return SpriteVariant.donut;
  if (heard) return SpriteVariant.heard;
  return zoom >= 13 ? SpriteVariant.badgeLarge : SpriteVariant.badge;
}

/// One sprite: what it looks like.
@immutable
class RepeaterSpriteSpec {
  final RepeaterFreshness freshness;
  final bool room;
  final SpriteVariant variant;
  const RepeaterSpriteSpec(this.freshness, this.room, this.variant);

  int get index => (variant.index * 2 + (room ? 1 : 0)) * 3 + freshness.index;

  @override
  bool operator ==(Object other) => other is RepeaterSpriteSpec && other.index == index;
  @override
  int get hashCode => index;

  static const int count = 36;
  static RepeaterSpriteSpec ofIndex(int i) => RepeaterSpriteSpec(
    RepeaterFreshness.values[i % 3],
    (i ~/ 3) % 2 == 1,
    SpriteVariant.values[i ~/ 6],
  );
}

/// Everything besides the spec that changes how a sprite looks. Also the atlas cache key.
@immutable
class RepeaterSpriteTheme {
  final Brightness brightness;

  /// High contrast palette setting: keyline at 100% alpha and a 3 pt ring.
  final bool highContrast;

  /// Selection halo colour and the heard tick colour.
  final Color accent, ok;
  const RepeaterSpriteTheme({required this.brightness, required this.accent, required this.ok, this.highContrast = false});

  @override
  bool operator ==(Object other) =>
      other is RepeaterSpriteTheme &&
      other.brightness == brightness &&
      other.highContrast == highContrast &&
      other.accent.toARGB32() == accent.toARGB32() &&
      other.ok.toARGB32() == ok.toARGB32();
  @override
  int get hashCode => Object.hash(brightness, highContrast, accent.toARGB32(), ok.toARGB32());
}

/// Atlas cache key: theme + DPR (+ palette, which is part of the theme).
@immutable
class RepeaterSpriteKey {
  final RepeaterSpriteTheme theme;
  final double dpr;
  const RepeaterSpriteKey(this.theme, this.dpr);
  @override
  bool operator ==(Object other) => other is RepeaterSpriteKey && other.theme == theme && other.dpr == dpr;
  @override
  int get hashCode => Object.hash(theme, dpr);
  @override
  String toString() => 'RepeaterSpriteKey(${theme.brightness.name}, hc=${theme.highContrast}, dpr=$dpr)';
}

/// Cell edge (logical points) of the atlas grid: the biggest sprite (34 pt + 3 pt halo + keyline) with air around it.
const double kSpriteCell = 44;
const int _cols = 6;

Path _shape(Offset c, double r, bool room) => room
    ? (Path()..addRRect(RRect.fromRectAndRadius(Rect.fromCircle(center: c, radius: r), Radius.circular(r * 0.6))))
    : (Path()..addOval(Rect.fromCircle(center: c, radius: r)));

void _dashed(Canvas canvas, Path path, Paint paint, double on, double off) {
  for (final m in path.computeMetrics()) {
    final n = math.max(1, (m.length / (on + off)).round());
    final step = m.length / n;
    for (var i = 0; i < n; i++) {
      canvas.drawPath(m.extractPath(i * step, i * step + step * on / (on + off)), paint);
    }
  }
}

void _glyph(Canvas canvas, Offset c, double d, Color color) {
  final gs = d * 0.5; // glyph height: >= 10 pt for every badge that gets one
  final stroke = math.max(1.5, gs * 0.13);
  final p = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = stroke
    ..strokeCap = StrokeCap.round
    ..color = color;
  final top = Offset(c.dx, c.dy - gs * 0.26);
  // Mast and a short base.
  canvas.drawLine(top, Offset(c.dx, c.dy + gs * 0.5), p);
  canvas.drawLine(Offset(c.dx - gs * 0.24, c.dy + gs * 0.5), Offset(c.dx + gs * 0.24, c.dy + gs * 0.5), p);
  // One arc per side.
  final arcRect = Rect.fromCircle(center: top, radius: gs * 0.42);
  canvas.drawArc(arcRect, -0.75, 1.5, false, p);
  canvas.drawArc(arcRect, math.pi - 0.75, 1.5, false, p);
  canvas.drawCircle(top, stroke * 0.7, Paint()..color = color);
}

/// Paints one sprite centred on [c] at logical scale (the atlas calls this at DPR scale too).
void paintRepeaterSprite(Canvas canvas, Offset c, RepeaterSpriteSpec spec, RepeaterSpriteTheme theme) {
  final b = theme.brightness;
  final v = spec.variant;
  final r = v.radius;
  final fill = freshnessColor(spec.freshness, b);
  final ringColor = MapTokens.mapHalo(b); // white (light) / #12161B (dark): the repeater signature
  final base = ringColor;
  final donut = v == SpriteVariant.donut;
  final ringW = donut ? 1.5 : (theme.highContrast ? 3.0 : 2.0);

  if (v.isSelected) {
    canvas.drawPath(
      _shape(c, r + 2.5, spec.room),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = theme.accent,
    );
  }
  // Keyline: 1 pt outside the ring, 25% ink (100% in high contrast).
  canvas.drawPath(
    _shape(c, r + 0.5, spec.room),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = MapTokens.mapInk(b).withValues(alpha: theme.highContrast ? 1 : 0.25),
  );
  canvas.drawPath(_shape(c, r, spec.room), Paint()..color = ringColor);
  final ri = r - ringW;
  final inner = _shape(c, ri, spec.room);

  if (donut) {
    // 3 pt coloured ring, light centre, no glyph. Stale is a dashed ring, Recent has a tinted centre.
    canvas.drawPath(inner, Paint()..color = base);
    switch (spec.freshness) {
      case RepeaterFreshness.fresh:
        canvas.drawPath(inner, Paint()..color = fill);
        canvas.drawPath(_shape(c, ri - 3, spec.room), Paint()..color = base);
      case RepeaterFreshness.recent:
        canvas.drawPath(inner, Paint()..color = fill);
        canvas.drawPath(_shape(c, ri - 3, spec.room), Paint()..color = Color.alphaBlend(fill.withValues(alpha: 0.35), base));
      case RepeaterFreshness.stale:
        _dashed(
          canvas,
          _shape(c, ri - 1.5, spec.room),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = fill,
          2.2,
          1.6,
        );
    }
  } else {
    canvas.drawPath(inner, Paint()..color = base);
    final glyph = MapTokens.repeaterGlyph(b);
    switch (spec.freshness) {
      case RepeaterFreshness.fresh:
        canvas.drawPath(inner, Paint()..color = fill);
        _glyph(canvas, c, v.diameter, glyph);
      case RepeaterFreshness.recent:
        canvas.drawPath(inner, Paint()..color = fill.withValues(alpha: 0.35));
        canvas.drawPath(
          _shape(c, ri - 1, spec.room),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = fill,
        );
        _glyph(canvas, c, v.diameter, fill);
      case RepeaterFreshness.stale:
        _dashed(
          canvas,
          _shape(c, ri - 0.75, spec.room),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = fill,
          3,
          2,
        );
        _glyph(canvas, c, v.diameter, fill.withValues(alpha: 0.7));
    }
  }

  if (v.hasTick) {
    // 8 pt green tick, top right, outlined in the ring colour so it reads on any fill.
    final t = c + Offset(r * 0.74, -r * 0.74);
    canvas.drawCircle(t, 5.5, Paint()..color = ringColor);
    canvas.drawCircle(t, 4, Paint()..color = theme.ok);
    final tick = Path()
      ..moveTo(t.dx - 2, t.dy + 0.1)
      ..lineTo(t.dx - 0.5, t.dy + 1.6)
      ..lineTo(t.dx + 2.1, t.dy - 1.4);
    canvas.drawPath(
      tick,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white,
    );
  }
}

/// The rasterised sprites for one [RepeaterSpriteKey].
class RepeaterSpriteAtlas {
  final RepeaterSpriteKey key;
  final ui.Image image;

  /// Source rectangle per sprite index, in image pixels: l, t, r, b.
  final Float32List rects;
  final double cellPx;
  RepeaterSpriteAtlas._(this.key, this.image, this.rects, this.cellPx);

  static Future<RepeaterSpriteAtlas> build(RepeaterSpriteKey key) async {
    final dpr = key.dpr;
    final cellPx = (kSpriteCell * dpr).roundToDouble();
    final rows = (RepeaterSpriteSpec.count / _cols).ceil();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rects = Float32List(RepeaterSpriteSpec.count * 4);
    final cell = cellPx / dpr; // logical size of a cell after rounding to whole pixels
    for (var i = 0; i < RepeaterSpriteSpec.count; i++) {
      final col = i % _cols, row = i ~/ _cols;
      canvas.save();
      canvas.scale(dpr);
      paintRepeaterSprite(canvas, Offset((col + 0.5) * cell, (row + 0.5) * cell), RepeaterSpriteSpec.ofIndex(i), key.theme);
      canvas.restore();
      rects[i * 4] = col * cellPx;
      rects[i * 4 + 1] = row * cellPx;
      rects[i * 4 + 2] = (col + 1) * cellPx;
      rects[i * 4 + 3] = (row + 1) * cellPx;
    }
    final img = await recorder.endRecording().toImage((cellPx * _cols).toInt(), (cellPx * rows).toInt());
    return RepeaterSpriteAtlas._(key, img, rects, cellPx);
  }

  void dispose() => image.dispose();

  static final Paint _paint = Paint()..filterQuality = FilterQuality.low;

  /// Draws [count] sprites in one call: [specs] index-aligned with [centres] (x, y pairs, logical points).
  void draw(Canvas canvas, Float32List centres, List<int> specIndex, int count) {
    if (count == 0) return;
    final dpr = key.dpr;
    final inv = 1 / dpr;
    final xf = Float32List(count * 4);
    final src = Float32List(count * 4);
    for (var i = 0; i < count; i++) {
      final cx = centres[i * 2], cy = centres[i * 2 + 1];
      // Snap the sprite to whole device pixels so it stays crisp while the map pans.
      final tx = ((cx * dpr) - cellPx / 2).roundToDouble() * inv;
      final ty = ((cy * dpr) - cellPx / 2).roundToDouble() * inv;
      xf[i * 4] = inv;
      xf[i * 4 + 1] = 0;
      xf[i * 4 + 2] = tx;
      xf[i * 4 + 3] = ty;
      final s = specIndex[i] * 4;
      src[i * 4] = rects[s];
      src[i * 4 + 1] = rects[s + 1];
      src[i * 4 + 2] = rects[s + 2];
      src[i * 4 + 3] = rects[s + 3];
    }
    canvas.drawRawAtlas(image, xf, src, null, null, null, _paint);
  }
}

/// Builds atlases on demand and keeps the last few (a theme or DPR change builds the new one; the old stays drawn
/// through the fallback path until it is ready). Listeners repaint when one arrives.
class RepeaterSprites extends ChangeNotifier {
  RepeaterSprites._();
  static final RepeaterSprites instance = RepeaterSprites._();

  final Map<RepeaterSpriteKey, RepeaterSpriteAtlas> _ready = {};
  final Set<RepeaterSpriteKey> _building = {};

  /// Atlases built so far (tests: one per distinct key, never one per frame).
  int builds = 0;

  /// The atlas for [key], or null while it is being built (the caller paints without it).
  RepeaterSpriteAtlas? atlasFor(RepeaterSpriteKey key) {
    final hit = _ready.remove(key);
    if (hit != null) {
      _ready[key] = hit; // most recently used last
      return hit;
    }
    if (_building.add(key)) {
      builds++;
      RepeaterSpriteAtlas.build(key).then(
        (a) {
          _building.remove(key);
          _ready[key] = a;
          while (_ready.length > 3) {
            final oldest = _ready.keys.first;
            _ready.remove(oldest)?.dispose();
          }
          notifyListeners();
        },
        onError: (Object _) {
          _building.remove(key);
        },
      );
    }
    return null;
  }

  @visibleForTesting
  void clear() {
    for (final a in _ready.values) {
      a.dispose();
    }
    _ready.clear();
    _building.clear();
    builds = 0;
  }
}
