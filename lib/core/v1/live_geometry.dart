// What the live map draws for one packet (AZ-3.3): the propagation from the origin through the relays to each observer
// along each resolved path, said as honestly as the hops are known (contract 2.3, CS-162):
//   - a hop the server calls `unique` is placed at its node and its segments are SOLID;
//   - a `likely` hop is placed too, but every segment that touches it is DASHED;
//   - an `ambiguous` or `unknown` hop (or a unique one whose node has no position) is never placed: it is a GHOST hop.
//     The segment from the placed point before it to the placed point after it is drawn as a faint GHOST segment, with
//     one ghost mark per missing hop spaced evenly along it, never as a certain line. Ghost hops before the first placed
//     point or after the last one cannot be drawn and are counted in [LiveDrawing.unplaced].
//   - DIRECT packets (`direction: remaining`) carry the route still AHEAD of the observer: drawn from the observer out
//     through those hops as AHEAD segments (dashed), never as travelled lines.
// Positions come from the hop's own candidates when the server sent them, then from the app's node roster
// ([LivePositions.node]); observers from the observer list ([LivePositions.observer]).
//
// Pure Dart: no Flutter imports.
import 'live_api.dart';
import 'packet_models.dart';

/// A point on the map.
class GeoPoint {
  final double lat, lon;
  const GeoPoint(this.lat, this.lon);

  GeoPoint lerp(GeoPoint b, double t) => GeoPoint(lat + (b.lat - lat) * t, lon + (b.lon - lon) * t);

  @override
  bool operator ==(Object other) => other is GeoPoint && (other.lat - lat).abs() < 1e-9 && (other.lon - lon).abs() < 1e-9;
  @override
  int get hashCode => Object.hash((lat * 1e6).round(), (lon * 1e6).round());
  @override
  String toString() => '($lat, $lon)';
}

enum SegmentStyle { solid, dashed, ghost, ahead }

class LiveSegment {
  final GeoPoint a, b;
  final SegmentStyle style;

  /// Hops along this segment that could not be placed (ghost segments only).
  final int ghosts;

  /// Order along the path, from 0: the animation draws segment n after segment n-1.
  final int step;
  const LiveSegment(this.a, this.b, this.style, {this.ghosts = 0, this.step = 0});

  @override
  String toString() => 'LiveSegment($a -> $b, ${style.name}${ghosts > 0 ? ', $ghosts ghosts' : ''})';
}

enum MarkKind { origin, hop, likelyHop, ghost, observer }

class LiveMark {
  final GeoPoint point;
  final MarkKind kind;
  final String? label;

  /// Node key or observer id, for taps.
  final String? id;
  final int step;
  const LiveMark(this.point, this.kind, {this.label, this.id, this.step = 0});
}

class LiveDrawing {
  final List<LiveSegment> segments;
  final List<LiveMark> marks;

  /// Hops that could not be drawn at all (no placed point on one side).
  final int unplaced;

  /// Number of animation steps (the longest path's segment count).
  final int steps;
  const LiveDrawing({this.segments = const [], this.marks = const [], this.unplaced = 0, this.steps = 0});

  bool get isEmpty => segments.isEmpty && marks.isEmpty;

  /// Every point drawn (to fit the camera).
  List<GeoPoint> get points => [for (final s in segments) ...[s.a, s.b], for (final m in marks) m.point];
}

/// Where things are: node key (lowercase, 64 hex) and observer id to a point; null when unknown.
class LivePositions {
  final GeoPoint? Function(String key) node;
  final GeoPoint? Function(String observerId) observer;
  const LivePositions({required this.node, required this.observer});

  static GeoPoint? _none(String _) => null;
  static const LivePositions none = LivePositions(node: _none, observer: _none);
}

enum _Cert { certain, likely }

class _Placed {
  final GeoPoint p;
  final _Cert cert;
  const _Placed(this.p, this.cert);
}

GeoPoint? _hopPoint(LiveV2Packet pk, PacketHop h, LivePositions pos) {
  if (h.node == null) return null;
  final key = h.node!.key.toLowerCase();
  final c = h.position;
  if (c != null) return GeoPoint(c.lat, c.lon);
  final legacy = pk.legacyPositions[key];
  if (legacy != null) return GeoPoint(legacy.$1, legacy.$2);
  return key.isEmpty ? null : pos.node(key);
}

/// The drawing for [p]. Identical segments from several paths are drawn once (the strongest style wins).
LiveDrawing drawLivePacket(LiveV2Packet p, LivePositions pos) {
  final segs = <String, LiveSegment>{};
  final marks = <String, LiveMark>{};
  var unplaced = 0, steps = 0;

  void addSeg(LiveSegment s) {
    final k = '${s.a}|${s.b}';
    final k2 = '${s.b}|${s.a}';
    final old = segs[k] ?? segs[k2];
    if (old == null || s.style.index < old.style.index) {
      segs.remove(k2);
      segs[k] = s;
    }
  }

  void addMark(LiveMark m) {
    final k = '${m.point}';
    final old = marks[k];
    if (old == null || m.kind.index < old.kind.index) marks[k] = m;
  }

  GeoPoint? originPt;
  if (p.origin != null && p.origin!.key.isNotEmpty) originPt = pos.node(p.origin!.key.toLowerCase());
  if (originPt != null) addMark(LiveMark(originPt, MarkKind.origin, label: p.origin!.name, id: p.origin!.key));

  // Observations by path; an observation without a path id belongs to the first path.
  final obsByPath = <String, List<LiveObs>>{};
  for (final o in p.observations) {
    final pid = o.pathId ?? (p.paths.isEmpty ? '' : p.paths.first.id);
    (obsByPath[pid] ??= []).add(o);
  }
  final paths = p.paths.isEmpty && p.observations.isNotEmpty ? [const PacketPath(id: '')] : p.paths;

  for (final path in paths) {
    final observers = <(GeoPoint, LiveObs)>[
      for (final o in obsByPath[path.id] ?? const <LiveObs>[])
        if (pos.observer(o.observer.id) case final g?) (g, o)
    ];
    for (final (g, o) in observers) {
      addMark(LiveMark(g, MarkKind.observer, label: o.observer.name, id: o.observer.id));
    }
    final ahead = path.direction == 'remaining';
    // The sequence of points: a placed point, or null for a ghost hop.
    final seq = <_Placed?>[];
    if (ahead) {
      // The route still ahead starts where it was heard; with several observers the first placed one is the start.
      if (observers.isNotEmpty) seq.add(_Placed(observers.first.$1, _Cert.certain));
    } else if (originPt != null) {
      // No known origin: the path starts at its first hop (the origin is not a hop, so it is not counted as unplaced).
      seq.add(_Placed(originPt, _Cert.certain));
    }
    for (final h in path.hops) {
      final g = (h.confidence == HopConfidence.unique || h.confidence == HopConfidence.likely) ? _hopPoint(p, h, pos) : null;
      seq.add(g == null ? null : _Placed(g, h.confidence == HopConfidence.likely ? _Cert.likely : _Cert.certain));
      if (g != null) {
        addMark(LiveMark(g, h.confidence == HopConfidence.likely ? MarkKind.likelyHop : MarkKind.hop, label: h.node?.name ?? h.prefix, id: h.node?.key));
      }
    }

    // Walk the sequence once to the end of the hops, then fan out to each observer (travelled paths).
    var step = 0;
    _Placed? last;
    var pending = 0;
    void connect(_Placed b) {
      if (last == null) {
        unplaced += pending;
      } else if (pending > 0) {
        addSeg(LiveSegment(last!.p, b.p, SegmentStyle.ghost, ghosts: pending, step: step));
        for (var i = 1; i <= pending; i++) {
          addMark(LiveMark(last!.p.lerp(b.p, i / (pending + 1)), MarkKind.ghost, step: step));
        }
        step++;
      } else if (last!.p != b.p) {
        final style = ahead
            ? SegmentStyle.ahead
            : (last!.cert == _Cert.certain && b.cert == _Cert.certain ? SegmentStyle.solid : SegmentStyle.dashed);
        addSeg(LiveSegment(last!.p, b.p, style, step: step));
        step++;
      }
      last = b;
      pending = 0;
    }

    for (final e in seq) {
      if (e == null) {
        pending++;
      } else {
        connect(e);
      }
    }
    if (!ahead && observers.isNotEmpty) {
      if (last == null) {
        unplaced += pending; // ghosts before anything placed: no line can be drawn through them
        pending = 0;
      }
      final (l, lp, st) = (last, pending, step);
      var maxStep = st;
      for (final (g, _) in observers) {
        last = l;
        pending = lp;
        step = st;
        connect(_Placed(g, _Cert.certain));
        if (step > maxStep) maxStep = step;
      }
      step = maxStep;
    } else {
      unplaced += pending;
    }
    if (step > steps) steps = step;
  }
  return LiveDrawing(segments: segs.values.toList(), marks: marks.values.toList(), unplaced: unplaced, steps: steps);
}
