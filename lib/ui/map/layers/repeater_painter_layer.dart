// RepeaterPainterLayer (Drive plan 6.1): the ONE renderer for every repeater on the map. Heard / known repeaters of the
// drive (the [RepeaterBadge]s), the region roster and the global network all draw here, so a repeater is one badge and
// one label whichever lists know it (merge priority heard > roster > network; the source leaves claimed keys out of its
// lists, see [RepeaterMapSource.claimedKeys]). Singles are sprites from the atlas ([repeater_sprites.dart]) at a level
// of detail by zoom, clusters are neutral bubbles with a ring in the dominant freshness colour. The layer hit-tests
// itself and speaks for the nearest 20 badges to VoiceOver (WP9 finalises the traversal).
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter_map/flutter_map.dart';

import '../../../core/cluster_index.dart';
import '../../../core/repeater_points.dart' show RepeaterPoints;
import '../../design/tokens.dart' show AppColors;
import 'clustered_points_layer.dart' show clusterLod, clusterSemanticsLabel, visibleSlice;
import 'map_layer.dart';
import 'repeater_cluster_layer.dart' show repeaterHitFor;
import 'repeater_map_source.dart';
import 'repeater_sprites.dart';

/// Hit radius of a badge (44 pt target).
const double kRepeaterTapRadius = 22;

/// The nearest centre within this many points wins a tap before the priority order (plan 6.2).
const double kRepeaterNearestWins = 14;

/// Screen reader proxies: the nearest this many badges get a node.
const int kRepeaterProxyCount = 20;

/// One repeater of the drive as the painter needs it (heard this drive, or in the app's known list).
@immutable
class RepeaterBadge {
  final String key, name;
  final double lat, lon;
  final bool isRoom;
  final RepeaterFreshness freshness;

  /// Heard this drive (any phase): 28 pt with the tick.
  final bool heard;

  /// Heard on the latest ping (label priority).
  final bool heardLast;

  /// Last advert / last heard according to a list that knows it (label priority: advert in the last hour).
  final DateTime? lastSeen;

  /// "+4.5 dB" for a repeater heard lately, appended to its label.
  final String? snr;
  const RepeaterBadge({
    required this.key,
    required this.name,
    required this.lat,
    required this.lon,
    this.isRoom = false,
    this.freshness = RepeaterFreshness.stale,
    this.heard = false,
    this.heardLast = false,
    this.lastSeen,
    this.snr,
  });
}

/// A list the scene draws from, with its viewport slice.
class RepeaterSceneSource {
  final String layerId;
  final RepeaterPoints points;
  final ClusterIndex index;
  final ClusterSlice slice;
  RepeaterSceneSource(this.layerId, this.points, this.index, this.slice);
}

/// One drawn repeater.
class RepeaterItem {
  final String key, name;
  final bool room;
  final RepeaterFreshness freshness;
  final double lat, lon;
  final Offset at;
  final SpriteVariant variant;
  final bool heard, heardLast, selected;
  final DateTime? lastSeen;
  final String? snr;

  /// Index into the scene's sources, or -1 for a badge.
  final int sourceIndex;
  final int pointIndex;
  final RepeaterBadge? badge;
  const RepeaterItem({
    required this.key,
    required this.name,
    required this.room,
    required this.freshness,
    required this.lat,
    required this.lon,
    required this.at,
    required this.variant,
    required this.heard,
    required this.heardLast,
    required this.selected,
    required this.lastSeen,
    required this.snr,
    required this.sourceIndex,
    required this.pointIndex,
    required this.badge,
  });

  double get radius => variant.radius;
}

class RepeaterClusterItem {
  final Offset at;
  final int count;
  final RepeaterFreshness freshness;
  final int level, id;
  const RepeaterClusterItem(this.at, this.count, this.freshness, this.level, this.id);
}

/// Everything visible, built once per camera change and shared by the painter and the labels.
class RepeaterScene {
  final List<RepeaterSceneSource> sources;
  final List<RepeaterItem> singles;
  final List<RepeaterClusterItem> clusters;
  const RepeaterScene(this.sources, this.singles, this.clusters);
  static const RepeaterScene empty = RepeaterScene([], [], []);
}

RepeaterFreshness _freshnessOfBand(String layerId, int band) =>
    layerId == kRosterLayerId ? freshnessOfRosterBand(band) : freshnessOfAdvertBand(band);

/// Merges the lists into what is on screen. Order of [sources] is the draw order underneath the badges (network first,
/// roster after it); [badges] draw on top; the selected item is last of all. [selectedPoint] gives the selected
/// point's index per source (or -1).
RepeaterScene buildRepeaterScene({
  required MapCamera camera,
  required List<RepeaterSceneSource> sources,
  required List<RepeaterBadge> badges,
  required String? selectedKey,
  List<int>? selectedPoint,
  double margin = 40,
}) {
  final scale = worldPixels(camera.zoom);
  final o = camera.pixelOrigin;
  final zoom = camera.zoom;
  final size = camera.size;
  final view = (Offset.zero & size).inflate(margin);
  final singles = <RepeaterItem>[];
  final clusters = <RepeaterClusterItem>[];
  RepeaterItem? selected;
  void add(RepeaterItem it) {
    if (it.selected) {
      selected = it;
    } else {
      singles.add(it);
    }
  }

  for (var s = 0; s < sources.length; s++) {
    final src = sources[s];
    final slice = src.slice;
    final pts = src.points;
    for (var k = 0; k < slice.length; k++) {
      final at = Offset(slice.x[k] * scale - o.dx, slice.y[k] * scale - o.dy);
      final n = slice.count[k];
      final f = _freshnessOfBand(src.layerId, slice.band[k]);
      if (n > 1) {
        clusters.add(RepeaterClusterItem(at, n, f, slice.level, slice.cluster[k]));
        continue;
      }
      final pi = slice.point[k];
      if (pi < 0) continue;
      final sel = selectedPoint != null && selectedPoint[s] == pi;
      add(RepeaterItem(
        key: pts.key[pi],
        name: pts.name[pi],
        room: pts.isRoom(pi),
        freshness: f,
        lat: pts.lat[pi],
        lon: pts.lon[pi],
        at: at,
        variant: spriteVariantFor(zoom, selected: sel),
        heard: false,
        heardLast: false,
        selected: sel,
        lastSeen: pts.lastSeen(pi),
        snr: null,
        sourceIndex: s,
        pointIndex: pi,
        badge: null,
      ));
    }
  }
  for (final b in badges) {
    final at = Offset(mercatorX(b.lon) * scale - o.dx, mercatorY(b.lat) * scale - o.dy);
    if (!view.contains(at)) continue;
    final sel = b.key == selectedKey;
    add(RepeaterItem(
      key: b.key,
      name: b.name,
      room: b.isRoom,
      freshness: b.freshness,
      lat: b.lat,
      lon: b.lon,
      at: at,
      variant: spriteVariantFor(zoom, heard: b.heard, selected: sel),
      heard: b.heard,
      heardLast: b.heardLast,
      selected: sel,
      lastSeen: b.lastSeen,
      snr: b.snr,
      sourceIndex: -1,
      pointIndex: -1,
      badge: b,
    ));
  }
  if (selected != null) singles.add(selected!);
  // One repeater can arrive from two lists (roster and network) or as a badge too: draw it once, the top-most copy wins
  // (the semantics tree and hit tests key on the repeater key).
  final seen = <String>{};
  final unique = <RepeaterItem>[];
  for (var i = singles.length - 1; i >= 0; i--) {
    if (seen.add(singles[i].key)) unique.add(singles[i]);
  }
  return RepeaterScene(sources, unique.reversed.toList(growable: false), clusters);
}

/// What a tap or a VoiceOver activation picked.
class RepeaterPick {
  final RepeaterItem? item;
  final RepeaterClusterItem? cluster;
  final ClusterTap? tap;
  final String? layerId;
  const RepeaterPick({this.item, this.cluster, this.tap, this.layerId});
}

class RepeaterPainterLayer extends StatefulWidget {
  /// Roster first, then network (priority order; drawn in reverse so the roster is above the network).
  final List<(RepeaterMapSource source, String layerId)> sources;
  final List<RepeaterBadge> badges;
  final String? selectedKey;

  /// A tap on a single or a cluster of a list.
  final ValueChanged<MapHit>? onHit;

  /// A tap on a badge of the drive.
  final ValueChanged<RepeaterBadge>? onBadgeTap;

  const RepeaterPainterLayer({super.key, required this.sources, this.badges = const [], this.selectedKey, this.onHit, this.onBadgeTap});

  static const ValueKey<String> paintKey = ValueKey('repeater-painter-paint');

  @override
  State<RepeaterPainterLayer> createState() => _RepeaterPainterLayerState();
}

class _RepeaterPainterLayerState extends State<RepeaterPainterLayer> {
  RepeaterPoints? _selSrc;
  String? _selKey;
  int _selIdx = -1;

  int _selectedIndex(RepeaterPoints pts) {
    final key = widget.selectedKey;
    if (key == null) return -1;
    if (!identical(_selSrc, pts) || _selKey != key) {
      _selSrc = pts;
      _selKey = key;
      _selIdx = pts.indexOf(key);
    }
    return _selIdx;
  }

  @override
  Widget build(BuildContext context) {
    final sources = [for (final (s, _) in widget.sources) s];
    return ListenableBuilder(
      listenable: Listenable.merge([...sources, RepeaterSprites.instance]),
      builder: (context, _) {
        final camera = MapCamera.of(context);
        final colors = AppColors.of(context);
        final theme = RepeaterSpriteTheme(
          brightness: Theme.of(context).brightness,
          accent: colors.accent,
          ok: colors.ok,
          highContrast: MediaQuery.highContrastOf(context),
        );
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final atlas = RepeaterSprites.instance.atlasFor(RepeaterSpriteKey(theme, dpr));
        final scene = <RepeaterSceneSource>[];
        final sel = <int>[];
        // Network under roster: reverse of the priority order.
        for (final (source, layerId) in widget.sources.reversed) {
          final index = source.indexOf(layerId);
          if (index == null || index.indexedCount == 0) continue;
          final pts = source.pointsOf(layerId);
          scene.add(RepeaterSceneSource(layerId, pts, index, visibleSlice(index, camera)));
          sel.add(_selectedIndex(pts));
        }
        final built = buildRepeaterScene(
          camera: camera,
          sources: scene,
          badges: widget.badges,
          selectedKey: widget.selectedKey,
          selectedPoint: sel,
        );
        if (built.singles.isEmpty && built.clusters.isEmpty) return const SizedBox.shrink();
        final painter = RepeaterPainter(
          scene: built,
          camera: camera,
          theme: theme,
          atlas: atlas,
          onPick: _onPick,
        );
        return MobileLayerTransformer(
          child: GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            onTapUp: (d) {
              final pick = painter.pickAt(d.localPosition);
              if (pick != null) _onPick(pick);
            },
            child: CustomPaint(key: RepeaterPainterLayer.paintKey, painter: painter, size: camera.size, isComplex: true),
          ),
        );
      },
    );
  }

  void _onPick(RepeaterPick p) {
    final item = p.item;
    if (item != null && item.badge != null) {
      widget.onBadgeTap?.call(item.badge!);
      return;
    }
    final tap = p.tap;
    if (tap == null || p.layerId == null) return;
    for (final (source, layerId) in widget.sources) {
      if (layerId == p.layerId) {
        widget.onHit?.call(repeaterHitFor(source, layerId, tap));
        return;
      }
    }
  }
}

class RepeaterPainter extends CustomPainter {
  final RepeaterScene scene;
  final MapCamera camera;
  final RepeaterSpriteTheme theme;
  final RepeaterSpriteAtlas? atlas;
  final ValueChanged<RepeaterPick>? onPick;

  RepeaterPainter({required this.scene, required this.camera, required this.theme, required this.atlas, this.onPick});

  /// Painted on the last frame (tests, profiling).
  int debugSprites = 0, debugClusters = 0;
  bool debugUsedAtlas = false;

  @override
  void paint(Canvas canvas, Size size) {
    final singles = scene.singles;
    debugSprites = singles.length;
    debugClusters = scene.clusters.length;
    final a = atlas;
    debugUsedAtlas = a != null;
    if (singles.isNotEmpty) {
      if (a != null) {
        final c = Float32List(singles.length * 2);
        final idx = List<int>.filled(singles.length, 0);
        for (var i = 0; i < singles.length; i++) {
          final it = singles[i];
          c[i * 2] = it.at.dx;
          c[i * 2 + 1] = it.at.dy;
          idx[i] = RepeaterSpriteSpec(it.freshness, it.room, it.variant).index;
        }
        a.draw(canvas, c, idx, singles.length);
      } else {
        for (final it in singles) {
          paintRepeaterSprite(canvas, it.at, RepeaterSpriteSpec(it.freshness, it.room, it.variant), theme);
        }
      }
    }
    for (final c in scene.clusters) {
      _paintCluster(canvas, c);
    }
  }

  void _paintCluster(Canvas canvas, RepeaterClusterItem c) {
    // The definition's cluster: a plain count bubble (`symbols.cluster`: fill, 2 pt stroke, count in the text colour).
    final sym = theme.symbol;
    final tp = clusterCountPainter(clusterLabel(c.count), sym.clusterText);
    final rad = math.max(clusterBubbleRadiusFor(c.count), tp.width / 2 + 6);
    canvas.drawCircle(c.at, rad, Paint()..color = sym.clusterFill);
    canvas.drawCircle(
      c.at,
      rad - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = sym.clusterStroke,
    );
    tp.paint(canvas, c.at - Offset(tp.width / 2, tp.height / 2));
  }

  /// The pick at [local]: the nearest centre within 14 pt wins, else priority badge > roster > network.
  RepeaterPick? pickAt(Offset local) {
    final cand = <(double, int, RepeaterPick)>[]; // distance, priority, pick
    // Items: topmost (last painted) first so overlapping badges resolve to the one on top.
    for (var i = scene.singles.length - 1; i >= 0; i--) {
      final it = scene.singles[i];
      final d = (it.at - local).distance;
      if (d > math.max(kRepeaterTapRadius, it.radius)) continue;
      final prio = it.badge != null ? 0 : 1 + (scene.sources.length - 1 - it.sourceIndex);
      final tap = it.badge != null ? null : _singleTap(it);
      cand.add((d, prio, RepeaterPick(item: it, tap: tap, layerId: it.badge != null ? null : scene.sources[it.sourceIndex].layerId)));
    }
    for (final c in scene.clusters) {
      final d = (c.at - local).distance;
      final r = math.max(kRepeaterTapRadius, clusterBubbleRadiusFor(c.count));
      if (d > r) continue;
      final src = _clusterSource(c);
      final tap = src.$1.index.hitTest(
        (camera.pixelOrigin.dx + c.at.dx) / worldPixels(camera.zoom),
        (camera.pixelOrigin.dy + c.at.dy) / worldPixels(camera.zoom),
        camera.zoom,
        radiusPx: 1,
      );
      if (tap == null) continue;
      final lod = clusterLod(tap, src.$1.index, camera.zoom);
      if (lod == null) continue;
      cand.add((d, 1 + (scene.sources.length - 1 - src.$2), RepeaterPick(cluster: c, tap: lod, layerId: src.$1.layerId)));
    }
    if (cand.isEmpty) return null;
    cand.sort((a, b) => a.$1.compareTo(b.$1));
    if (cand.first.$1 <= kRepeaterNearestWins) return cand.first.$3;
    cand.sort((a, b) {
      final p = a.$2.compareTo(b.$2);
      return p != 0 ? p : a.$1.compareTo(b.$1);
    });
    return cand.first.$3;
  }

  (RepeaterSceneSource, int) _clusterSource(RepeaterClusterItem c) {
    // The cluster belongs to the source whose slice holds it; sources are few (<= 2).
    for (var s = 0; s < scene.sources.length; s++) {
      final slice = scene.sources[s].slice;
      for (var k = 0; k < slice.length; k++) {
        if (slice.count[k] > 1 && slice.cluster[k] == c.id && slice.level == c.level) return (scene.sources[s], s);
      }
    }
    return (scene.sources.first, 0);
  }

  ClusterTap _singleTap(RepeaterItem it) {
    final id = -(it.pointIndex + 1);
    final bounds = GeoBounds(south: it.lat, west: it.lon, north: it.lat, east: it.lon);
    final src = scene.sources[it.sourceIndex];
    var tap = ClusterTap(id: id, count: 1, point: it.pointIndex, lat: it.lat, lon: it.lon, bounds: bounds);
    // Co-located stack (several repeaters on one tower): let the same hit test report them.
    final hit = src.index.hitTest(
      (camera.pixelOrigin.dx + it.at.dx) / worldPixels(camera.zoom),
      (camera.pixelOrigin.dy + it.at.dy) / worldPixels(camera.zoom),
      camera.zoom,
      radiusPx: 2,
    );
    if (hit != null && hit.point == it.pointIndex) tap = hit;
    return clusterLod(tap, src.index, camera.zoom) ?? tap;
  }

  @override
  bool? hitTest(Offset position) => pickAt(position) != null;

  /// Clusters read out their count; the nearest [kRepeaterProxyCount] repeaters get a node each.
  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final out = <CustomPainterSemantics>[];
    for (final c in scene.clusters) {
      final rect = Rect.fromCircle(center: c.at, radius: clusterBubbleRadiusFor(c.count) + 2);
      if (!rect.overlaps(Offset.zero & size)) continue;
      out.add(CustomPainterSemantics(
        key: ValueKey('cluster-${c.level}-${c.id}'),
        rect: rect,
        properties: SemanticsProperties(label: clusterSemanticsLabel(c.count), textDirection: TextDirection.ltr, button: true),
      ));
    }
    final here = size.center(Offset.zero);
    final near = [
      for (final it in scene.singles)
        if ((Offset.zero & size).contains(it.at)) it,
    ]..sort((a, b) => (a.at - here).distanceSquared.compareTo((b.at - here).distanceSquared));
    for (final it in near.take(kRepeaterProxyCount)) {
      out.add(CustomPainterSemantics(
        key: ValueKey('repeater-${it.key}'),
        rect: Rect.fromCircle(center: it.at, radius: math.max(22, it.radius)),
        properties: SemanticsProperties(
          label: repeaterSemanticsLabel(it),
          hint: 'Shows repeater details',
          textDirection: TextDirection.ltr,
          button: true,
          selected: it.selected,
          onTap: onPick == null
              ? null
              : () => onPick!(
                  RepeaterPick(item: it, tap: it.badge == null ? _singleTap(it) : null, layerId: it.badge == null ? scene.sources[it.sourceIndex].layerId : null),
                ),
        ),
      ));
    }
    return out;
  };

  @override
  bool shouldRebuildSemantics(RepeaterPainter oldDelegate) => !identical(oldDelegate.scene, scene);

  @override
  bool shouldRepaint(RepeaterPainter oldDelegate) =>
      !identical(oldDelegate.scene, scene) || oldDelegate.camera != camera || oldDelegate.theme != theme || !identical(oldDelegate.atlas, atlas);
}

/// "Repeater Alpha Tower, room server, advertised in the last 24 hours, heard this drive".
String repeaterSemanticsLabel(RepeaterItem it) {
  final name = it.name.isEmpty ? it.key.substring(0, math.min(4, it.key.length)) : it.name;
  return [
    it.room ? 'Room server $name' : 'Repeater $name',
    freshnessWord(it.freshness),
    if (it.heard) 'heard this drive',
  ].join(', ');
}

/// Radius of a cluster bubble: 36-44 pt across (plan 6.5).
double clusterBubbleRadiusFor(int count) => clusterRadiusPx(count).clamp(18.0, 22.0);

final Map<String, TextPainter> _countCache = {};

/// Laid-out count text (15 pt semibold), cached by text and colour.
TextPainter clusterCountPainter(String text, Color ink) {
  final key = '$text|${ink.toARGB32()}';
  final hit = _countCache[key];
  if (hit != null) return hit;
  if (_countCache.length > 256) _countCache.clear();
  return _countCache[key] = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: ink, fontSize: 15, fontWeight: FontWeight.w600, height: 1, fontFeatures: const [ui.FontFeature.tabularFigures()]),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
}
