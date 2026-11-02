// Repeater name labels (Drive plan 6.4): the name beside each repeater badge, so nobody has to tap a badge to find out
// what it is. One painter for everything the map draws (heard and known repeaters, the roster, the network), so labels
// from different lists avoid each other, and one label per badge. Rules, pure in [placeRepeaterLabels] (unit tested):
//   - Zoom-dependent: nothing below [kLabelMinZoomHeard]; repeaters heard this drive from there, everyone else from
//     [kLabelMinZoom]; a per-zoom budget ([labelBudgetForZoom]) caps the count.
//   - Priority: selected, heard on the last ping, heard this drive, advert in the last hour, nearest to the phone, rest.
//   - Collision-avoided on a 96 pt spatial grid: right, left, above, below the badge (gap = badge radius + 4); a label
//     is dropped, never shrunk, when none fits without covering a badge, a label, a cluster, an overlay or the edge.
//   - Cost control: placement runs only when the zoom moved by more than 0.1, the camera by more than 24 pt, or the
//     data / insets changed; in between the placed labels follow the map (they are stored as geo anchor + offset).
//   - Hysteresis ([LabelFader]): a label that stops fitting is kept 300 ms and fades out over 120 ms (Reduce Motion: no
//     fade, still the hold), a new one fades in over 120 ms.
//   - Look: system font semibold 13 pt (14 from z14, never below 12), a 3 pt halo, or a 0.88 alpha pill on Street and
//     Topo whose own raster labels sit underneath. Stale repeaters use the same ink at 70%.
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../design/map_tokens.dart';
import 'clustered_points_layer.dart' show visibleSlice;
import 'repeater_map_source.dart';
import 'repeater_painter_layer.dart';
import 'repeater_sprites.dart' show RepeaterFreshness;

/// Below this zoom no label is drawn at all.
const double kLabelMinZoomHeard = 9;

/// Repeaters not heard this drive get a label from this zoom.
const double kLabelMinZoom = 11;

/// Longest a label gets before the ellipsis (logical px, before Dynamic Type).
const double kLabelMaxWidth = 150;

/// Placement grid cell edge.
const double kLabelGridCell = 96;

/// Re-place when the zoom changed by more than this, or the camera moved by more than [kLabelMoveThreshold] points.
const double kLabelZoomThreshold = 0.1;
const double kLabelMoveThreshold = 24;

const Duration kLabelHold = Duration(milliseconds: 300);
const Duration kLabelFade = Duration(milliseconds: 120);

/// Most labels drawn at [zoom] (selected and heard ones count first).
int labelBudgetForZoom(double zoom) {
  if (zoom < kLabelMinZoomHeard) return 0;
  if (zoom < kLabelMinZoom) return 12;
  if (zoom < 12) return 24;
  if (zoom < 13) return 40;
  if (zoom < 14) return 56;
  return 80;
}

/// Label font size: 13 pt from z12, 14 pt from z14, never below 12.
double labelFontSizeForZoom(double zoom) => zoom >= 14 ? 14 : (zoom >= 12 ? 13 : 12);

/// Placement priorities (lower is placed first).
abstract final class LabelPriority {
  static const int selected = 0, heardLast = 1, heard = 2, freshAdvert = 3, rest = 4, linkTag = 9;
}

/// One thing the placer knows about. Candidates with [label] false are not labelled but still block other labels.
class LabelCandidate {
  final String id;
  final String text;

  /// Marker centre on screen.
  final Offset anchor;

  /// Half the marker's footprint.
  final double markerRadius;

  /// See [LabelPriority].
  final int priority;

  /// Screen distance to "here" (ties inside a priority are broken by it).
  final double distance;
  final bool label;
  final bool stale;

  /// Where the label may sit instead of beside a marker (link distance tags: points along the line, best first).
  final List<Offset>? slots;
  const LabelCandidate({
    required this.id,
    required this.text,
    required this.anchor,
    required this.markerRadius,
    required this.priority,
    required this.distance,
    this.label = true,
    this.stale = false,
    this.slots,
  });
}

/// A label that fits.
class PlacedLabel {
  final LabelCandidate candidate;

  /// Where the text box goes (halo / pill padding included).
  final Rect rect;

  /// Index into [LabelCandidate.slots] it took, or -1.
  final int slot;
  const PlacedLabel(this.candidate, this.rect, {this.slot = -1});
}

class _GridEntry {
  final Rect rect;
  final String? owner;
  const _GridEntry(this.rect, this.owner);
}

/// Uniform grid over rectangles: an overlap query touches only the cells the rectangle covers.
class RectGrid {
  final double cell;
  final Map<int, List<_GridEntry>> _cells = {};
  int checks = 0;
  RectGrid([this.cell = kLabelGridCell]);

  static int _key(int cx, int cy) => (cx + 4096) * 8192 + (cy + 4096);

  void add(Rect r, [String? owner]) {
    final e = _GridEntry(r, owner);
    final x0 = (r.left / cell).floor(), x1 = (r.right / cell).floor();
    final y0 = (r.top / cell).floor(), y1 = (r.bottom / cell).floor();
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        (_cells[_key(x, y)] ??= []).add(e);
      }
    }
  }

  /// True when [r] overlaps something other than [skipOwner]'s own entries.
  bool overlaps(Rect r, {String? skipOwner}) {
    final x0 = (r.left / cell).floor(), x1 = (r.right / cell).floor();
    final y0 = (r.top / cell).floor(), y1 = (r.bottom / cell).floor();
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        final l = _cells[_key(x, y)];
        if (l == null) continue;
        for (final e in l) {
          checks++;
          if (e.owner != null && e.owner == skipOwner) continue;
          if (e.rect.overlaps(r)) return true;
        }
      }
    }
    return false;
  }
}

/// Greedy collision-avoided placement. [measure] gives a label's size (padding included). [obstacles] are rectangles
/// no label may touch (cluster bubbles, overlays). Pure: same input, same output.
List<PlacedLabel> placeRepeaterLabels({
  required List<LabelCandidate> candidates,
  required Size Function(String text) measure,
  required Rect bounds,
  List<Rect> obstacles = const [],
  required int budget,
  double gap = 4,
  RectGrid? grid,
}) {
  if (budget <= 0) return const [];
  final order = [for (final c in candidates) if (c.label) c]
    ..sort((a, b) {
      final p = a.priority.compareTo(b.priority);
      if (p != 0) return p;
      final d = a.distance.compareTo(b.distance);
      return d != 0 ? d : a.id.compareTo(b.id);
    });
  final g = grid ?? RectGrid();
  for (final o in obstacles) {
    g.add(o);
  }
  for (final c in candidates) {
    if (c.slots != null) continue; // tags have no badge
    g.add(Rect.fromCircle(center: c.anchor, radius: c.markerRadius), c.id);
  }
  bool inside(Rect box) => !(box.left < bounds.left || box.right > bounds.right || box.top < bounds.top || box.bottom > bounds.bottom);
  final placed = <PlacedLabel>[];
  for (final c in order) {
    if (placed.length >= budget) break;
    final s = measure(c.text);
    if (c.slots != null) {
      for (var i = 0; i < c.slots!.length; i++) {
        final box = Rect.fromCenter(center: c.slots![i], width: s.width, height: s.height);
        if (!inside(box) || g.overlaps(box, skipOwner: c.id)) continue;
        placed.add(PlacedLabel(c, box, slot: i));
        g.add(box, c.id);
        break;
      }
      continue;
    }
    final a = c.anchor, r = c.markerRadius + gap;
    final tries = [
      Rect.fromLTWH(a.dx + r, a.dy - s.height / 2, s.width, s.height), // right
      Rect.fromLTWH(a.dx - r - s.width, a.dy - s.height / 2, s.width, s.height), // left
      Rect.fromLTWH(a.dx - s.width / 2, a.dy - r - s.height, s.width, s.height), // above
      Rect.fromLTWH(a.dx - s.width / 2, a.dy + r, s.width, s.height), // below
    ];
    for (final box in tries) {
      if (!inside(box) || g.overlaps(box, skipOwner: c.id)) continue;
      placed.add(PlacedLabel(c, box));
      g.add(box, c.id);
      break;
    }
  }
  return placed;
}

/// A label on its way in, out, or steady.
class ShownLabel {
  final PlacedLabel label;
  final double alpha;
  const ShownLabel(this.label, this.alpha);
}

class _Shown {
  PlacedLabel label;
  final Duration firstSeen;
  bool wanted = true;
  Duration unwantedSince = Duration.zero;
  _Shown(this.label, this.firstSeen);
}

/// Hysteresis for labels (plan 6.4): keeps a label [hold] after it stopped fitting, fades over [fade]. Pure: time is
/// passed in.
class LabelFader {
  final Duration hold, fade;
  final bool reduceMotion;
  LabelFader({this.hold = kLabelHold, this.fade = kLabelFade, this.reduceMotion = false});

  final Map<String, _Shown> _m = {};
  bool _animating = false;

  /// True while any label is fading in, held or fading out (the host keeps asking for frames).
  bool get animating => _animating;

  /// [placed] is the newest placement (null = unchanged since the last call); [visibleIds] are the candidates still
  /// on screen (a held label whose repeater left the screen goes at once).
  List<ShownLabel> update(List<PlacedLabel>? placed, Set<String> visibleIds, Duration now) {
    if (placed != null) {
      final ids = {for (final p in placed) p.candidate.id};
      for (final p in placed) {
        final e = _m[p.candidate.id];
        if (e == null) {
          _m[p.candidate.id] = _Shown(p, now);
        } else {
          e.label = p;
          e.wanted = true;
        }
      }
      _m.forEach((id, e) {
        if (!ids.contains(id) && e.wanted) {
          e.wanted = false;
          e.unwantedSince = now;
        }
      });
    }
    final out = <ShownLabel>[];
    var anim = false;
    final drop = <String>[];
    final end = reduceMotion ? hold : hold + fade;
    _m.forEach((id, e) {
      final held = e.wanted ? Duration.zero : now - e.unwantedSince;
      if (!visibleIds.contains(id) || held > end) {
        drop.add(id);
        return;
      }
      var alpha = 1.0;
      if (!e.wanted) {
        anim = true;
        if (held > hold && !reduceMotion) alpha = 1 - (held - hold).inMicroseconds / fade.inMicroseconds;
      } else if (!reduceMotion) {
        final age = now - e.firstSeen;
        if (age < fade) {
          alpha = age.inMicroseconds / fade.inMicroseconds;
          anim = true;
        }
      }
      out.add(ShownLabel(e.label, alpha.clamp(0.0, 1.0)));
    });
    drop.forEach(_m.remove);
    _animating = anim;
    return out;
  }
}

/// A link distance tag ("1.0 mi") the labels place on the line between [a] and [b].
class LinkTagInput {
  final String id;
  final LatLng a, b;
  final String text;
  final Color color;
  const LinkTagInput({required this.id, required this.a, required this.b, required this.text, required this.color});

  static const List<double> slotsAlong = [0.5, 0.4, 0.6, 0.3, 0.7];
  LatLng at(double t) => LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
}

/// The flutter_map child.
class RepeaterNameLabels extends StatefulWidget {
  /// The lists that are on, in priority order (roster before network).
  final List<(RepeaterMapSource source, String layerId)> sources;

  /// The drive's heard and known repeaters (the same list the painter layer draws).
  final List<RepeaterBadge> badges;

  /// Key of the selected repeater (its label gets a second line), or null.
  final String? selectedKey;

  /// The selected repeater's second line ("Heard now · +4.5 dB · 2.3 km").
  final String? selectedDetail;

  /// Link distance tags, placed last along their lines.
  final List<LinkTagInput> linkTags;

  /// Spots the map writes its own small captions on (range-ring distances): names keep clear of them.
  final List<LatLng> blockers;

  /// "Here" for the nearest-first rule; null = the map centre.
  final LatLng? origin;

  /// The puck: names keep 1.5 x its radius clear of it.
  final LatLng? puck;

  /// Screen rectangles (map coordinates) labels must stay out of: overlays drawn by the parent.
  final List<Rect> Function(Size mapSize)? avoid;

  /// Extra margin at the map edges labels must keep clear of.
  final EdgeInsets inset;

  /// Street and Topo: every label sits on a 0.88 alpha pill (their own raster labels are underneath).
  final bool pill;

  /// False: only the link distance tags are drawn (the "Repeater names" layer switch is off).
  final bool showNames;

  const RepeaterNameLabels({
    super.key,
    required this.sources,
    this.badges = const [],
    this.linkTags = const [],
    this.blockers = const [],
    this.selectedKey,
    this.selectedDetail,
    this.origin,
    this.puck,
    this.avoid,
    this.inset = EdgeInsets.zero,
    this.pill = false,
    this.showNames = true,
  });

  static const ValueKey<String> paintKey = ValueKey('repeater-name-labels-paint');

  @override
  State<RepeaterNameLabels> createState() => RepeaterNameLabelsState();
}

class _PlacedGeo {
  final PlacedLabel placed;

  /// Where the label's anchor is on the map; the label sits at the anchor's screen position + [rel].
  final LatLng geo;
  final Offset rel;
  _PlacedGeo(this.placed, this.geo, this.rel);
}

class RepeaterNameLabelsState extends State<RepeaterNameLabels> {
  /// How many times placement ran (tests and profiling: "placements/s").
  int placements = 0;

  final Map<String, _PlacedGeo> _geo = {};
  Set<String> _visible = const {};
  Object? _version;
  double _zoom = -1;
  Offset _refScreen = Offset.zero;
  LatLng? _refCenter;
  double _rotation = 0;
  Size _size = Size.zero;
  LabelFader _fader = LabelFader();
  bool _reduce = false;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final cs = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6);
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce != _reduce) {
      _reduce = reduce;
      _fader = LabelFader(reduceMotion: reduce);
      _version = null;
    }
    final zoom = camera.zoom;
    final hasSelected = widget.selectedKey != null;
    if (zoom < kLabelMinZoomHeard && !hasSelected && widget.linkTags.isEmpty) {
      _geo.clear();
      return const SizedBox.shrink();
    }
    final size = camera.size;
    final fontSize = labelFontSizeForZoom(zoom);
    final version = Object.hash(
      identityHashCode(widget.badges),
      identityHashCode(widget.linkTags),
      Object.hashAll([for (final (s, l) in widget.sources) Object.hash(identityHashCode(s.indexOf(l)), identityHashCode(s.pointsOf(l)))]),
      widget.selectedKey,
      widget.selectedDetail,
      widget.pill,
      brightness,
      scaler.scale(12),
      widget.inset,
      widget.blockers.length,
      widget.puck,
      fontSize,
    );
    final moved = _refCenter == null ? double.infinity : (camera.latLngToScreenOffset(_refCenter!) - _refScreen).distance;
    final need = _version != version ||
        (zoom - _zoom).abs() > kLabelZoomThreshold ||
        moved > kLabelMoveThreshold ||
        size != _size ||
        (camera.rotation - _rotation).abs() > 1;
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    List<PlacedLabel>? fresh;
    if (need) {
      fresh = _place(camera, brightness, scaler, fontSize, size);
      _version = version;
      _zoom = zoom;
      _size = size;
      _rotation = camera.rotation;
      _refCenter = camera.center;
      _refScreen = camera.latLngToScreenOffset(camera.center);
      placements++;
    }
    final shown = _fader.update(fresh, _visible, now);
    if (shown.isEmpty) {
      if (_fader.animating) _again();
      return const SizedBox.shrink();
    }
    if (_fader.animating) _again();

    final draw = <DrawnLabel>[];
    for (final s in shown) {
      final g = _geo[s.label.candidate.id];
      if (g == null) continue;
      final anchor = camera.latLngToScreenOffset(g.geo);
      final rel = g.rel;
      draw.add(DrawnLabel(
        rect: (anchor + rel) & s.label.rect.size,
        text: s.label.candidate.text,
        alpha: s.alpha,
        stale: s.label.candidate.stale,
        tag: s.label.candidate.slots != null,
        tagColor: s.label.candidate.slots != null ? _tagColor(s.label.candidate.id) : null,
        selected: s.label.candidate.priority == LabelPriority.selected,
      ));
    }
    return IgnorePointer(
      child: ExcludeSemantics(
        child: CustomPaint(
          key: RepeaterNameLabels.paintKey,
          painter: LabelPainter(
            labels: draw,
            ink: MapTokens.mapInk(brightness),
            halo: MapTokens.mapHalo(brightness),
            pill: widget.pill,
            fontSize: fontSize,
            scaler: scaler,
            surface: cs.surface,
          ),
          size: size,
        ),
      ),
    );
  }

  void _again() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) setState(() {});
  });

  Color _tagColor(String id) {
    for (final t in widget.linkTags) {
      if (t.id == id) return t.color;
    }
    return Colors.grey;
  }

  List<PlacedLabel> _place(MapCamera camera, Brightness brightness, TextScaler scaler, double fontSize, Size size) {
    final zoom = camera.zoom;
    final sources = <RepeaterSceneSource>[];
    final sel = <int>[];
    for (final (source, layerId) in widget.sources.reversed) {
      final index = source.indexOf(layerId);
      if (index == null || index.indexedCount == 0) continue;
      final pts = source.pointsOf(layerId);
      sources.add(RepeaterSceneSource(layerId, pts, index, visibleSlice(index, camera)));
      sel.add(widget.selectedKey == null ? -1 : pts.indexOf(widget.selectedKey!));
    }
    final scene = buildRepeaterScene(camera: camera, sources: sources, badges: widget.badges, selectedKey: widget.selectedKey, selectedPoint: sel);
    final here = camera.latLngToScreenOffset(widget.origin ?? camera.center);
    final onScreen = Offset.zero & size;
    final nowWall = DateTime.now();
    final cands = <LabelCandidate>[];
    final geos = <String, LatLng>{};
    final obstacles = <Rect>[...?widget.avoid?.call(size)];
    for (final b in widget.blockers) {
      final o = camera.latLngToScreenOffset(b);
      if (onScreen.inflate(24).contains(o)) obstacles.add(Rect.fromCenter(center: o, width: 84, height: 26));
    }
    final puck = widget.puck;
    if (puck != null) {
      final o = camera.latLngToScreenOffset(puck);
      if (onScreen.inflate(40).contains(o)) obstacles.add(Rect.fromCircle(center: o, radius: 17 * 1.5));
    }
    for (final c in scene.clusters) {
      obstacles.add(Rect.fromCircle(center: c.at, radius: clusterBubbleRadiusFor(c.count) + 3));
    }
    final seen = <String>{};
    for (final it in scene.singles) {
      if (!seen.add(it.key)) continue;
      final isSel = it.selected;
      final onS = onScreen.contains(it.at);
      final int prio;
      if (isSel) {
        prio = LabelPriority.selected;
      } else if (it.heardLast) {
        prio = LabelPriority.heardLast;
      } else if (it.heard) {
        prio = LabelPriority.heard;
      } else if (it.lastSeen != null && nowWall.difference(it.lastSeen!).inMinutes < 60) {
        prio = LabelPriority.freshAdvert;
      } else {
        prio = LabelPriority.rest;
      }
      final wantsLabel = widget.showNames && onS && (isSel || prio <= LabelPriority.heard || zoom >= kLabelMinZoom);
      var text = it.name;
      if (isSel && widget.selectedDetail != null) {
        text = '$text\n${widget.selectedDetail}';
      } else if (it.snr != null) {
        text = '$text  ${it.snr}';
      }
      cands.add(LabelCandidate(
        id: it.key,
        text: text,
        anchor: it.at,
        markerRadius: it.radius,
        priority: prio,
        distance: (it.at - here).distance,
        label: wantsLabel,
        stale: it.freshness == RepeaterFreshness.stale,
      ));
      geos[it.key] = LatLng(it.lat, it.lon);
    }
    for (final t in widget.linkTags) {
      final pa = camera.latLngToScreenOffset(t.a), pb = camera.latLngToScreenOffset(t.b);
      if (!onScreen.inflate(60).contains(pa) && !onScreen.inflate(60).contains(pb)) {
        // A line that crosses the screen with both ends off it still gets a tag if its middle is in view.
        if (!onScreen.contains(Offset.lerp(pa, pb, 0.5)!)) continue;
      }
      cands.add(LabelCandidate(
        id: t.id,
        text: t.text,
        anchor: Offset.lerp(pa, pb, 0.5)!,
        markerRadius: 0,
        priority: LabelPriority.linkTag,
        distance: 0,
        slots: [for (final f in LinkTagInput.slotsAlong) Offset.lerp(pa, pb, f)!],
      ));
    }
    _visible = {for (final c in cands) c.id};
    final bounds = Rect.fromLTRB(
      widget.inset.left + 4,
      widget.inset.top + 4,
      size.width - widget.inset.right - 4,
      size.height - widget.inset.bottom - 4,
    );
    final style = LabelPainter.styleFor(fontSize);
    final pad = widget.pill ? const Size(12, 4) : const Size(6, 2);
    final placed = placeRepeaterLabels(
      candidates: cands,
      measure: (t) {
        final tp = LabelPainter.measureText(t, style, scaler, fontSize);
        return Size(tp.width + pad.width, tp.height + pad.height);
      },
      bounds: bounds,
      obstacles: obstacles,
      budget: labelBudgetForZoom(zoom),
    );
    final plan = [
      for (final p in placed)
        if (p.candidate.slots == null)
          _PlacedGeo(p, geos[p.candidate.id]!, p.rect.topLeft - p.candidate.anchor)
        else
          () {
            final tag = widget.linkTags.firstWhere((t) => t.id == p.candidate.id);
            final geo = tag.at(LinkTagInput.slotsAlong[p.slot]);
            return _PlacedGeo(p, geo, p.rect.topLeft - p.candidate.slots![p.slot]);
          }(),
    ];
    for (final g in plan) {
      _geo[g.placed.candidate.id] = g;
    }
    _geo.removeWhere((k, _) => !_visible.contains(k));
    return placed;
  }
}

/// A label ready to draw.
class DrawnLabel {
  final Rect rect;
  final String text;
  final double alpha;
  final bool stale, tag, selected;
  final Color? tagColor;
  const DrawnLabel({required this.rect, required this.text, required this.alpha, this.stale = false, this.tag = false, this.tagColor, this.selected = false});
}

/// LRU of laid-out text (1,000 entries; the least recently used goes first, never a wholesale clear).
class TextLru {
  final int capacity;
  TextLru([this.capacity = 1000]);
  final LinkedHashMap<String, TextPainter> _m = LinkedHashMap<String, TextPainter>();
  int hits = 0, misses = 0;
  int get length => _m.length;

  TextPainter get(String key, TextPainter Function() make) {
    final h = _m.remove(key);
    if (h != null) {
      hits++;
      _m[key] = h;
      return h;
    }
    misses++;
    final tp = make();
    _m[key] = tp;
    if (_m.length > capacity) _m.remove(_m.keys.first);
    return tp;
  }
}

class LabelPainter extends CustomPainter {
  final List<DrawnLabel> labels;
  final Color ink, halo, surface;
  final bool pill;
  final double fontSize;
  final TextScaler scaler;
  LabelPainter({required this.labels, required this.ink, required this.halo, required this.pill, required this.fontSize, required this.scaler, required this.surface});

  /// null = the system font (SF Pro on iOS). Tests that cannot load it set a stand-in.
  @visibleForTesting
  static String? fontFamily;

  static TextStyle styleFor(double size) => TextStyle(fontFamily: fontFamily, fontSize: size, fontWeight: FontWeight.w600, height: 1.15);

  static final TextLru cache = TextLru();

  /// Second-line size of the selected repeater's label.
  static const double detailSize = 12;

  /// Lays out [text]; a '\n' starts the second line (12 pt, 70% ink).
  static TextPainter measureText(String text, TextStyle style, TextScaler scaler, double fontSize, {Color? color, Paint? foreground}) {
    final key = '$text|$fontFamily|$fontSize|${color?.toARGB32()}|${foreground?.color.toARGB32()}|${scaler.scale(12)}';
    return cache.get(key, () {
      final nl = text.indexOf('\n');
      TextStyle line1 = style.copyWith(color: foreground == null ? color : null, foreground: foreground);
      final spans = <InlineSpan>[
        TextSpan(text: nl < 0 ? text : text.substring(0, nl), style: line1),
        if (nl >= 0)
          TextSpan(
            text: '\n${text.substring(nl + 1)}',
            style: line1.copyWith(
              fontSize: detailSize,
              fontWeight: FontWeight.w500,
              color: foreground == null && color != null ? color.withValues(alpha: color.a * 0.7) : null,
            ),
          ),
      ];
      return TextPainter(
        text: TextSpan(children: spans),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: nl < 0 ? 1 : 2,
        ellipsis: '…',
      )..layout(maxWidth: kLabelMaxWidth * math.min(scaler.scale(1), 1.3));
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final style = styleFor(fontSize);
    final padX = pill ? 6.0 : 3.0, padY = pill ? 2.0 : 1.0;
    for (final l in labels) {
      final a = l.alpha;
      final inkColor = (l.stale ? ink.withValues(alpha: 0.7) : ink).withValues(alpha: (l.stale ? 0.7 : 1.0) * a);
      final at = l.rect.topLeft + Offset(padX, padY);
      if (l.tag) {
        final rr = RRect.fromRectAndRadius(l.rect, const Radius.circular(8));
        canvas.drawRRect(rr, Paint()..color = halo.withValues(alpha: 0.88 * a));
        canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = (l.tagColor ?? ink).withValues(alpha: a),
        );
        measureText(l.text, style, scaler, fontSize, color: ink.withValues(alpha: a)).paint(canvas, at);
        continue;
      }
      if (pill) {
        canvas.drawRRect(RRect.fromRectAndRadius(l.rect, const Radius.circular(8)), Paint()..color = halo.withValues(alpha: 0.88 * a));
      } else {
        final stroke = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0
          ..strokeJoin = StrokeJoin.round
          ..color = halo.withValues(alpha: a);
        measureText(l.text, style, scaler, fontSize, foreground: stroke).paint(canvas, at);
      }
      measureText(l.text, style, scaler, fontSize, color: inkColor).paint(canvas, at);
    }
  }

  @override
  bool shouldRepaint(LabelPainter old) => true;
}

