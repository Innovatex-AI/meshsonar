// Repeater badge sprites (Drive plan 6.2, 6.3). Every repeater on the map is one of 3 freshness states x {repeater, room}
// x 6 variants (donut, badge 20 / 24, heard 28, selected 34, selected + heard). They are rasterised once per theme /
// DPR / palette into one atlas image and drawn with one `drawRawAtlas` call per frame, so hundreds of badges cost one
// draw call. Until the atlas is ready (and in widget tests, where `toImage` never completes) the same drawing code
// paints each badge straight onto the canvas ([paintRepeaterSprite]), so the picture is identical either way.
//
// The symbol is the Map Definition's (`symbols.repeater`, the website draws the same, plan §2.4): a neutral tower on a disc,
// and the state is the RING, never a colour, so colour-blind and greyscale users tell the states apart (asserted by tests):
//   Fresh  (advert <= 24 h)  solid ring
//   Recent (<= 7 d)          dashed ring
//   Stale  (> 7 d or never)  no ring, the whole symbol faded (definition opacity, 0.45)
// Icon, disc and ring colours per theme come from the definition. Rooms are rounded squares (radius 30%), repeaters circles.
// Pings are plain dots and never use the tower.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/map_definition.dart' show MapDefinition;
import '../../../core/region_repeaters_api.dart' show RepeaterActivity;
import '../../design/map_tokens.dart';
import '../active_map_definition.dart';

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

/// The definition's repeater symbol in one theme (`symbols.repeater`, `symbols.selection`, `symbols.cluster`).
@immutable
class RepeaterSymbolStyle {
  final Color icon, disc, ring, selection, clusterFill, clusterStroke, clusterText;

  /// Opacity of a stale repeater (`states[stale].opacity`).
  final double staleOpacity;
  const RepeaterSymbolStyle({
    required this.icon,
    required this.disc,
    required this.ring,
    required this.selection,
    required this.clusterFill,
    required this.clusterStroke,
    required this.clusterText,
    required this.staleOpacity,
  });

  static RepeaterSymbolStyle of(Brightness b, [MapDefinition? definition]) {
    final d = definition ?? ActiveMapDefinition.current;
    final dark = b == Brightness.dark;
    Color c(String sym, String key) => Color(d.symbolColour(sym, key, dark: dark));
    final states = (d.symbol('repeater')['states'] as List? ?? const []).whereType<Map>();
    final stale = states.where((s) => s['id'] == 'stale').firstOrNull;
    return RepeaterSymbolStyle(
      icon: c('repeater', 'icon'),
      disc: c('repeater', 'disc'),
      ring: c('repeater', 'ring'),
      selection: c('selection', 'x'),
      clusterFill: c('cluster', 'fill'),
      clusterStroke: c('cluster', 'stroke'),
      clusterText: c('cluster', 'text'),
      staleOpacity: (stale?['opacity'] as num?)?.toDouble() ?? 0.45,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RepeaterSymbolStyle &&
      other.icon == icon &&
      other.disc == disc &&
      other.ring == ring &&
      other.selection == selection &&
      other.clusterFill == clusterFill &&
      other.clusterStroke == clusterStroke &&
      other.clusterText == clusterText &&
      other.staleOpacity == staleOpacity;
  @override
  int get hashCode => Object.hash(icon, disc, ring, selection, clusterFill, clusterStroke, clusterText, staleOpacity);
}

/// Everything besides the spec that changes how a sprite looks. Also the atlas cache key.
@immutable
class RepeaterSpriteTheme {
  final Brightness brightness;

  /// The system's Increase Contrast setting (MediaQuery.highContrast): keyline at 100% alpha and a thicker ring.
  final bool highContrast;

  /// The heard tick colour; [accent] is kept for callers, the selection halo is the definition's selection colour.
  final Color accent, ok;

  /// The definition's symbol colours (default: the active definition, [brightness]).
  final RepeaterSymbolStyle symbol;
  RepeaterSpriteTheme({required this.brightness, required this.accent, required this.ok, this.highContrast = false, RepeaterSymbolStyle? symbol})
    : symbol = symbol ?? RepeaterSymbolStyle.of(brightness);

  @override
  bool operator ==(Object other) =>
      other is RepeaterSpriteTheme &&
      other.brightness == brightness &&
      other.highContrast == highContrast &&
      other.accent.toARGB32() == accent.toARGB32() &&
      other.ok.toARGB32() == ok.toARGB32() &&
      other.symbol == symbol;
  @override
  int get hashCode => Object.hash(brightness, highContrast, accent.toARGB32(), ok.toARGB32(), symbol);
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

/// The definition's tower: a caret (mast and two legs) with a cross-bar, as the website draws it.
void _glyph(Canvas canvas, Offset c, double d, Color color) {
  final gs = d * 0.46;
  final p = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.4, gs * 0.16)
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = color;
  final top = Offset(c.dx, c.dy - gs * 0.5);
  final l = Offset(c.dx - gs * 0.42, c.dy + gs * 0.5), r = Offset(c.dx + gs * 0.42, c.dy + gs * 0.5);
  canvas.drawPath(Path()..moveTo(l.dx, l.dy)..lineTo(top.dx, top.dy)..lineTo(r.dx, r.dy), p);
  canvas.drawLine(Offset(c.dx - gs * 0.22, c.dy + gs * 0.08), Offset(c.dx + gs * 0.22, c.dy + gs * 0.08), p);
}

/// Paints one sprite centred on [c] at logical scale (the atlas calls this at DPR scale too).
void paintRepeaterSprite(Canvas canvas, Offset c, RepeaterSpriteSpec spec, RepeaterSpriteTheme theme) {
  final v = spec.variant;
  final sym = theme.symbol;
  final r = v.radius;
  final donut = v == SpriteVariant.donut;
  final stale = spec.freshness == RepeaterFreshness.stale;
  // The disc sits inside the ring's track: ring width + a 1 pt gap, so a ring-less (stale) symbol keeps the same disc size.
  final ringW = donut ? 1.5 : (theme.highContrast ? 2.6 : 1.8);
  final discR = r - ringW - 1.2;

  if (v.isSelected) {
    canvas.drawPath(
      _shape(c, r + 2.5, spec.room),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = sym.selection,
    );
  }
  if (stale) canvas.saveLayer(Rect.fromCircle(center: c, radius: r + 4), Paint()..color = Color.fromRGBO(0, 0, 0, sym.staleOpacity));
  // The disc with a 1 pt keyline in the ring colour (so a disc on a same-coloured map still has an edge).
  canvas.drawPath(_shape(c, discR, spec.room), Paint()..color = sym.disc);
  canvas.drawPath(
    _shape(c, discR, spec.room),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = theme.highContrast ? 1.5 : 1
      ..color = sym.ring.withValues(alpha: theme.highContrast ? 1 : 0.6),
  );
  if (!donut) _glyph(canvas, c, discR * 2, sym.icon);
  final ringPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = ringW
    ..color = sym.ring;
  final ringPath = _shape(c, r - ringW / 2, spec.room);
  switch (spec.freshness) {
    case RepeaterFreshness.fresh:
      canvas.drawPath(ringPath, ringPaint);
    case RepeaterFreshness.recent:
      _dashed(canvas, ringPath, ringPaint, donut ? 2 : 2.4, donut ? 1.6 : 1.8);
    case RepeaterFreshness.stale:
      break; // no ring; faded below
  }
  if (stale) canvas.restore();

  if (v.hasTick) {
    // 8 pt green tick, top right, outlined in the disc colour so it reads on any map.
    final t = c + Offset(r * 0.74, -r * 0.74);
    canvas.drawCircle(t, 5.5, Paint()..color = sym.disc);
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
