// The live "sonar" puck: the arrow that moves with you, the rings a ping sends out, and the lines that come back from the
// repeaters that heard it. Three pieces:
//
//   PuckController  Owns the motion (lib/core/puck_motion.dart), the direction (lib/core/heading.dart) and the ping animation
//                   clock. The Drive map model feeds it every GPS fix, compass reading and ping event. DISPLAY ONLY; pings
//                   record the engine's own fix.
//   PuckLinksLayer  A flutter_map layer under the repeater markers: lines from the moving dot to each repeater that echoed the
//                   latest ping (orange link colour, never a signal strength), drawn out from the dot and faded later.
//   PuckLayer       A flutter_map layer on top: accuracy disc, ping rings and the direction arrow. Owns the Ticker, which runs at
//                   the display's refresh rate (60 or 120 Hz) while anything moves and sleeps when nothing does.
//
// Direction: a navigation arrow (chevron), not a dot. It points along the course while the car moves (above ~1.5 m/s) and along
// the compass when stopped; the angle is eased along the shortest arc, so it never spins at north. Sonar rings are thin circles
// that pulse out of it on each ping, so the two never look alike. GPS weak (no fix for 2.5 s): the arrow dims, its ring grows
// and a "GPS weak" tag appears; after 5 s it stops coasting and holds.
//
// Both layers repaint on their own every frame without rebuilding the map: a GPS fix never touches the hex, cell or repeater
// layers (that rebuild was what made the old dot hop).
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/heading.dart';
import '../../core/puck_motion.dart';
import '../../radio/radio_api.dart';
import '../theme.dart';
import 'map_layers.dart';

/// How long a ping ring takes to expand and fade.
const Duration pingRingLife = Duration(milliseconds: 1600);

/// Gap between rings sent while the ping waits for echoes.
const Duration pingRingGap = Duration(milliseconds: 600);

/// Rings stop being sent after this long without an answer.
const Duration pingRingMax = Duration(seconds: 12);

/// Lines draw out from the dot over this long.
const Duration linkDrawIn = Duration(milliseconds: 700);

/// Fresh lines stay at full strength this long, then fade to the held look over [linkFade].
const Duration linkHold = Duration(seconds: 5);
const Duration linkFade = Duration(seconds: 4);

/// The strength of a held (older or faded) line.
const double linkHeldAlpha = 0.38;

/// Counters the health recorder reads (and resets) every sample.
class PuckStats {
  int frames = 0;
  int fixes = 0;
  int fixesRejected = 0;
  double maxFixGapS = 0;
  int weakFrames = 0;
  int compassReadings = 0;

  /// Longest wait between two frames of the running ticker (a stall of the UI isolate shows up here), in ms.
  double maxFrameGapMs = 0;

  Map<String, Object?> toJson(double windowS) => {
    'puck_updates_hz': windowS <= 0 ? 0 : double.parse((frames / windowS).toStringAsFixed(1)),
    'fixes': fixes,
    'fixes_rejected': fixesRejected,
    'max_fix_gap_s': double.parse(maxFixGapS.toStringAsFixed(1)),
    'weak_frames': weakFrames,
    'compass_readings': compassReadings,
    'max_frame_gap_ms': double.parse(maxFrameGapMs.toStringAsFixed(1)),
  };

  void reset() {
    frames = fixes = fixesRejected = weakFrames = compassReadings = 0;
    maxFixGapS = 0;
    maxFrameGapMs = 0;
  }
}

class PuckController extends ChangeNotifier {
  final DateTime Function() clock;
  final PuckMotion motion;
  final HeadingSmoother heading = HeadingSmoother();
  PuckController({DateTime Function()? clock, PuckConfig config = const PuckConfig()})
    : clock = clock ?? DateTime.now,
      motion = PuckMotion(config);

  /// Bumped when there is something to animate again; the ticker wakes on it.
  final ValueNotifier<int> wake = ValueNotifier<int>(0);

  /// Counters for the health recorder.
  final PuckStats stats = PuckStats();

  PuckPose? _pose;

  /// Where the dot is drawn now (updated by [tick]); null before the first accepted fix.
  PuckPose? get pose => _pose;

  DateTime? _sentAt;
  DateTime? _resolvedAt;
  bool _resolvedHeard = false;

  /// When the latest ping went out (rings start here); null when none yet this drive.
  DateTime? get sentAt => _sentAt;

  /// When the latest ping's echoes were counted; null while it still waits.
  DateTime? get resolvedAt => _resolvedAt;
  bool get resolvedHeard => _resolvedHeard;
  bool get waiting => _sentAt != null && (_resolvedAt == null || _resolvedAt!.isBefore(_sentAt!));

  // ---- direction ----
  double? _compassDeg;
  DateTime? _compassAt;
  double? _lastCourse;
  double? _headingDeg;
  DateTime? _lastTickAt;
  DateTime? _lastFixArrived;

  /// The heading the arrow points along on the map (degrees clockwise from north), eased; null when unknown.
  double? get headingDeg => _headingDeg;

  final HeadingSmoother _courseSmoother = HeadingSmoother(tau: 0.35);
  double? _mapHeading;

  /// Direction of travel for turning the map (heading-up): the smoothed GPS course, held when the car stops. Never the
  /// compass, so a parked car does not spin the map.
  double? get mapHeadingDeg => _mapHeading;

  /// True while the arrow follows the compass (the car is stopped) rather than the course.
  bool get headingFromCompass => (_pose?.courseDeg == null) && _compassFresh(clock());

  bool _compassFresh(DateTime now) => _compassDeg != null && _compassAt != null && now.difference(_compassAt!) < const Duration(seconds: 3);

  /// A compass reading (degrees clockwise from north). Used for the arrow only while no course is known.
  void onCompass(double deg) {
    _compassDeg = normalizeDeg(deg);
    _compassAt = clock();
    stats.compassReadings++;
    if (_pose?.courseDeg == null) _wake();
  }

  /// A GPS fix arrived. Returns whether the dot accepted it (see PuckMotion's outlier gate).
  bool onFix(GeoFix f) {
    final now = clock();
    final ok = motion.add(f, now);
    if (ok) {
      stats.fixes++;
      final last = _lastFixArrived;
      if (last != null) stats.maxFixGapS = math.max(stats.maxFixGapS, now.difference(last).inMicroseconds / 1e6);
      _lastFixArrived = now;
      _pose ??= motion.poseAt(now);
      _wake();
    } else {
      stats.fixesRejected++;
    }
    return ok;
  }

  /// A ping went out: rings start.
  void pingSent() {
    _sentAt = clock();
    _resolvedAt = null;
    _wake();
  }

  /// The ping's listen window closed: [heard] says whether any repeater echoed it.
  void pingResolved({required bool heard}) {
    _resolvedAt = clock();
    _resolvedHeard = heard;
    _sentAt ??= _resolvedAt;
    _wake();
  }

  /// Forget the drive (drive ended).
  void reset() {
    motion.reset();
    heading.reset();
    _courseSmoother.reset();
    _mapHeading = null;
    _pose = null;
    _headingDeg = null;
    _lastCourse = null;
    _lastTickAt = null;
    _lastFixArrived = null;
    _sentAt = _resolvedAt = null;
    _resolvedHeard = false;
    notifyListeners();
  }

  /// True while a ping animation is on screen.
  bool animatingPing([DateTime? now]) {
    now ??= clock();
    final s = _sentAt;
    if (s == null) return false;
    final r = _resolvedAt;
    if (r == null || r.isBefore(s)) return now.difference(s) < pingRingMax;
    return now.difference(r) < linkHold + linkFade + const Duration(milliseconds: 200);
  }

  /// Advance one frame: compute the pose and the heading and tell the layers to repaint. Returns true while another frame is
  /// needed.
  bool tick({bool reducedMotion = false}) {
    if (_disposed) return false;
    final now = clock();
    final p = motion.poseAt(now, reducedMotion: reducedMotion) ?? _pose;
    _pose = p;
    stats.frames++;
    if (p != null && p.weak) stats.weakFrames++;
    var dt = _lastTickAt == null ? 0.0 : now.difference(_lastTickAt!).inMicroseconds / 1e6;
    if (_lastTickAt != null) stats.maxFrameGapMs = math.max(stats.maxFrameGapMs, dt * 1000);
    if (dt < 0 || dt > 0.5) dt = 0.016;
    _lastTickAt = now;
    var headingBusy = false;
    if (p != null) {
      final course = p.courseDeg;
      double? target;
      if (course != null) {
        target = course;
        _lastCourse = course;
        _mapHeading = reducedMotion ? (_courseSmoother..set(course)).value : _courseSmoother.step(course, dt);
      } else if (_compassFresh(now)) {
        target = _compassDeg;
      } else {
        target = _lastCourse;
      }
      if (target != null) {
        final before = heading.value;
        _headingDeg = reducedMotion ? (heading..set(target)).value : heading.step(target, dt);
        headingBusy = before != null && shortestArc(before, target).abs() > 0.3;
      }
    }
    notifyListeners();
    return !(p?.settled ?? true) || headingBusy || (!reducedMotion && animatingPing(now)) || (reducedMotion && _linksFading(now));
  }

  /// The ticker went to sleep: the next gap is not a stall.
  void tickerStopped() => _lastTickAt = null;

  /// Seconds until the pose turns "weak" if no fix arrives; null when it already is, or there is no fix.
  Duration? get untilWeak {
    final p = _pose;
    if (p == null || p.weak) return null;
    final left = motion.config.weakAfter.inMicroseconds / 1e6 - p.fixAgeS;
    return Duration(milliseconds: (left * 1000).ceil() + 30);
  }

  bool _linksFading(DateTime now) {
    final r = _resolvedAt;
    return r != null && now.difference(r) < linkHold + linkFade;
  }

  void _wake() {
    wake.value++;
    // No ticker (hidden tab, tests without a frame): still let listeners know there is a new fix.
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    wake.dispose();
    super.dispose();
  }
}

/// Alpha of a fresh line [since] its ping resolved: full, then fading to [linkHeldAlpha].
double freshLinkAlpha(Duration since) {
  if (since <= linkHold) return 1;
  final f = ((since - linkHold).inMicroseconds / linkFade.inMicroseconds).clamp(0.0, 1.0);
  return 1 - (1 - linkHeldAlpha) * f;
}

/// How far along its line the draw-in is, 0..1, eased out.
double linkDrawProgress(Duration since) {
  final f = (since.inMicroseconds / linkDrawIn.inMicroseconds).clamp(0.0, 1.0);
  return 1 - math.pow(1 - f, 3).toDouble();
}

/// (radius fraction, alpha fraction) of every ping ring alive [since] the ping went out and still waiting for echoes.
List<({double grow, double fade})> waitingRings(Duration since) {
  final out = <({double grow, double fade})>[];
  if (since >= pingRingMax) return out;
  for (var k = 0; k < 4; k++) {
    final age = since - pingRingGap * k;
    if (age < Duration.zero || age >= pingRingLife) continue;
    final f = age.inMicroseconds / pingRingLife.inMicroseconds;
    out.add((grow: 1 - math.pow(1 - f, 2).toDouble(), fade: 1 - f));
  }
  return out;
}

class _Frame extends StatelessWidget {
  final PuckController puck;
  final Widget Function(BuildContext context, PuckPose? pose) builder;
  const _Frame({required this.puck, required this.builder});
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: puck, builder: (c, _) => builder(c, puck.pose));
}

/// Lines from the moving dot to each live heard repeater (those with a known position).
class PuckLinksLayer extends StatelessWidget {
  final PuckController puck;
  final List<HeardView> heard;

  /// Where the dot stands when there is no live pose yet (a drive map opened before the first fix).
  final LatLng? fallback;
  const PuckLinksLayer({super.key, required this.puck, required this.heard, this.fallback});

  @override
  Widget build(BuildContext context) {
    final ends = [
      for (final h in heard)
        if (h.live && h.ref != null) (LatLng(h.ref!.lat, h.ref!.lon), h.phase == HeardPhase.fresh),
    ];
    if (ends.isEmpty) return const SizedBox.shrink();
    final mc = MeshSonarColors.of(context);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final camera = MapCamera.of(context);
    return _Frame(
      puck: puck,
      builder: (context, pose) {
        final from = pose != null ? LatLng(pose.lat, pose.lon) : fallback;
        if (from == null) return const SizedBox.shrink();
        return IgnorePointer(
          child: CustomPaint(
            key: const Key('puck-links'),
            size: Size.infinite,
            painter: _LinksPainter(
              camera: camera,
              from: from,
              ends: ends,
              line: mc.linkLine,
              casing: mc.linkLineCasing,
              dashedStyle: mc.linkLineDashed,
              since: puck.resolvedAt == null ? null : puck.clock().difference(puck.resolvedAt!),
              reduced: reduced,
            ),
          ),
        );
      },
    );
  }
}

class _LinksPainter extends CustomPainter {
  final MapCamera camera;
  final LatLng from;
  final List<(LatLng, bool)> ends;
  final Color line, casing;
  final bool dashedStyle;
  final Duration? since;
  final bool reduced;
  _LinksPainter({
    required this.camera,
    required this.from,
    required this.ends,
    required this.line,
    required this.casing,
    required this.dashedStyle,
    required this.since,
    required this.reduced,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final a = camera.latLngToScreenOffset(from);
    for (final (end, fresh) in ends) {
      final b = camera.latLngToScreenOffset(end);
      var alpha = linkHeldAlpha;
      var progress = 1.0;
      if (fresh && since != null) {
        alpha = freshLinkAlpha(since!);
        progress = reduced ? 1 : linkDrawProgress(since!);
      }
      final dashed = dashedStyle || !fresh || alpha <= linkHeldAlpha + 0.02;
      final tip = Offset.lerp(a, b, progress)!;
      _stroke(canvas, a, tip, casing.withValues(alpha: casing.a * alpha), 5.5, dashed);
      _stroke(canvas, a, tip, line.withValues(alpha: alpha), 3, dashed);
      if (progress >= 1) {
        canvas.drawCircle(b, 3.5, Paint()..color = line.withValues(alpha: alpha));
        canvas.drawCircle(
          b,
          3.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.white.withValues(alpha: alpha),
        );
      }
    }
  }

  void _stroke(Canvas canvas, Offset a, Offset b, Color c, double w, bool dashed) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..color = c;
    if (!dashed) {
      canvas.drawLine(a, b, p);
      return;
    }
    final len = (b - a).distance;
    if (len < 1) return;
    final dir = (b - a) / len;
    const dash = 9.0, gap = 6.0;
    for (var d = 0.0; d < len; d += dash + gap) {
      canvas.drawLine(a + dir * d, a + dir * math.min(d + dash, len), p);
    }
  }

  @override
  bool shouldRepaint(_LinksPainter old) => true;
}

/// The puck: accuracy disc, ping rings and the direction arrow. Owns the frame ticker.
class PuckLayer extends StatefulWidget {
  final PuckController puck;

  /// Shown, still, until the first live fix: the phone's last-known or idle position.
  final LatLng? fallback;

  /// Called once per frame (after the pose is updated) with the dot's position and the seconds since the last frame, so the
  /// camera can follow it in the same frame.
  final void Function(LatLng at, double dtS)? onMoved;

  /// Called every frame the ticker runs (before [onMoved]); the health recorder counts frames here.
  final VoidCallback? onFrame;
  const PuckLayer({super.key, required this.puck, this.fallback, this.onMoved, this.onFrame});

  @override
  State<PuckLayer> createState() => _PuckLayerState();
}

class _PuckLayerState extends State<PuckLayer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  Timer? _weakTimer;
  Duration _last = Duration.zero;
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    widget.puck.wake.addListener(_start);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didUpdateWidget(PuckLayer old) {
    super.didUpdateWidget(old);
    if (old.puck != widget.puck) {
      old.puck.wake.removeListener(_start);
      widget.puck.wake.addListener(_start);
      _start();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  void _start() {
    if (!mounted) return;
    _weakTimer?.cancel();
    if (_ticker.isActive) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.016 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final more = widget.puck.tick(reducedMotion: _reduced);
    widget.onFrame?.call();
    final p = widget.puck.pose;
    if (p != null) widget.onMoved?.call(LatLng(p.lat, p.lon), dt);
    if (!more) {
      _ticker.stop();
      widget.puck.tickerStopped();
      // Asleep, but the dot must still go "weak" when the fixes stop: wake once for that.
      final due = widget.puck.untilWeak;
      if (due != null) _weakTimer = Timer(due, _start);
    }
  }

  @override
  void dispose() {
    _weakTimer?.cancel();
    widget.puck.wake.removeListener(_start);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final camera = MapCamera.of(context);
    final puck = widget.puck;
    return _Frame(
      puck: puck,
      builder: (context, pose) {
        final at = pose != null ? LatLng(pose.lat, pose.lon) : widget.fallback;
        if (at == null) return const SizedBox.shrink();
        final c = camera.latLngToScreenOffset(at);
        final now = puck.clock();
        final weak = pose?.weak ?? false;
        final heading = puck.headingDeg;
        return IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  key: const Key('puck-paint'),
                  painter: _PuckPainter(
                    camera: camera,
                    at: at,
                    center: c,
                    pose: pose,
                    color: t.colorScheme.primary,
                    weakColor: mc.beacon,
                    echoColor: mc.linkLine,
                    silentColor: mc.silent,
                    sentSince: puck.waiting && puck.sentAt != null ? now.difference(puck.sentAt!) : null,
                    resolvedSince: puck.resolvedAt == null ? null : now.difference(puck.resolvedAt!),
                    resolvedHeard: puck.resolvedHeard,
                    reduced: _reduced,
                  ),
                ),
              ),
              Positioned(
                left: c.dx - 28,
                top: c.dy - 28,
                width: 56,
                height: 56,
                child: _PuckMark(
                  key: const Key('map-position'),
                  color: t.colorScheme.primary,
                  outline: Colors.white,
                  // The arrow on the screen: the heading plus however much the map is turned.
                  angle: heading == null ? null : (heading + camera.rotation) * math.pi / 180,
                  weak: weak,
                  weakColor: mc.beacon,
                  fromCompass: puck.headingFromCompass,
                ),
              ),
              if (weak)
                Positioned(
                  left: c.dx - 40,
                  top: c.dy + 26,
                  width: 80,
                  child: Center(
                    child: DecoratedBox(
                      key: const Key('gps-weak-tag'),
                      decoration: BoxDecoration(
                        color: t.colorScheme.surface.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: mc.beacon, width: 1.2),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        child: Text('GPS weak', style: t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: 11)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The arrow (or a plain dot while the direction is unknown). 56 x 56 logical px, the arrow about 36 px tall: readable at arm's
/// length on a dash mount, white outline and a shadow so it stands out on a light or a dark map.
class _PuckMark extends StatelessWidget {
  final Color color;
  final Color outline;
  final Color weakColor;
  final double? angle;
  final bool weak;
  final bool fromCompass;
  const _PuckMark({super.key, required this.color, required this.outline, required this.weakColor, required this.angle, required this.weak, required this.fromCompass});

  @override
  Widget build(BuildContext context) {
    final fill = weak ? Color.lerp(color, Colors.grey, 0.55)! : color;
    final child = angle == null
        ? CustomPaint(size: const Size(56, 56), painter: _DotPainter(fill, outline))
        : Transform.rotate(
            key: const Key('map-heading-arrow'),
            angle: angle!,
            child: CustomPaint(size: const Size(56, 56), painter: _ArrowPainter(fill, outline, hollow: fromCompass)),
          );
    return Semantics(
      label: weak ? 'Your position, GPS signal weak' : 'Your position',
      child: Opacity(opacity: weak ? 0.75 : 1, child: child),
    );
  }
}

class _DotPainter extends CustomPainter {
  final Color fill, outline;
  _DotPainter(this.fill, this.outline);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawCircle(c + const Offset(0, 1.5), 12, Paint()..color = Colors.black.withValues(alpha: 0.30)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawCircle(c, 11, Paint()..color = outline);
    canvas.drawCircle(c, 8, Paint()..color = fill);
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.fill != fill || old.outline != outline;
}

/// A navigation chevron pointing up (rotated by the parent). [hollow]: the direction is from the compass, not the road, drawn
/// with a lighter centre so the two can be told apart.
class _ArrowPainter extends CustomPainter {
  final Color fill, outline;
  final bool hollow;
  _ArrowPainter(this.fill, this.outline, {required this.hollow});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final path = ui.Path()
      ..moveTo(c.dx, c.dy - 19)
      ..lineTo(c.dx + 14, c.dy + 16)
      ..lineTo(c.dx, c.dy + 8)
      ..lineTo(c.dx - 14, c.dy + 16)
      ..close();
    canvas.drawPath(path.shift(const Offset(0, 2)), Paint()..color = Colors.black.withValues(alpha: 0.32)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeJoin = StrokeJoin.round
        ..color = outline,
    );
    canvas.drawPath(path, Paint()..color = hollow ? Color.alphaBlend(Colors.white.withValues(alpha: 0.35), fill) : fill);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round
        ..color = fill,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.fill != fill || old.outline != outline || old.hollow != hollow;
}

class _PuckPainter extends CustomPainter {
  final MapCamera camera;
  final LatLng at;
  final Offset center;
  final PuckPose? pose;
  final Color color, weakColor, echoColor, silentColor;
  final Duration? sentSince; // while waiting for echoes
  final Duration? resolvedSince;
  final bool resolvedHeard;
  final bool reduced;
  _PuckPainter({
    required this.camera,
    required this.at,
    required this.center,
    required this.pose,
    required this.color,
    required this.weakColor,
    required this.echoColor,
    required this.silentColor,
    required this.sentSince,
    required this.resolvedSince,
    required this.resolvedHeard,
    required this.reduced,
  });

  /// Pixels per metre at the dot (the map's scale), measured on the screen so rotation and zoom are right.
  double _pxPerMetre() {
    final b = camera.latLngToScreenOffset(LatLng(at.latitude + 100 / 111320.0, at.longitude));
    return (b - center).distance / 100;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final ppm = _pxPerMetre();
    final p = pose;
    final weak = p?.weak ?? false;

    // Accuracy disc (only when it is bigger than the arrow, so it reads as uncertainty). Dashed amber while the signal is weak.
    final acc = p?.accuracyM;
    if (acc != null) {
      final r = (acc * ppm).clamp(0.0, 160.0);
      if (r > 20) {
        final base = weak ? weakColor : color;
        canvas.drawCircle(center, r, Paint()..color = base.withValues(alpha: weak ? 0.07 : 0.10));
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = weak ? 1.6 : 1
          ..color = base.withValues(alpha: weak ? 0.7 : 0.28);
        if (weak) {
          final n = (2 * math.pi * r / 12).clamp(16, 120).round();
          for (var i = 0; i < n; i++) {
            canvas.drawArc(Rect.fromCircle(center: center, radius: r), 2 * math.pi * i / n, math.pi / n, false, ring);
          }
        } else {
          canvas.drawCircle(center, r, ring);
        }
      }
    }

    if (reduced) return;

    // Rings sent while the ping waits for echoes.
    final s = sentSince;
    if (s != null) {
      for (final ring in waitingRings(s)) {
        final r = 20 + ring.grow * 120;
        canvas.drawCircle(
          center,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..color = color.withValues(alpha: 0.55 * ring.fade),
        );
      }
    }

    // The answer: one ring in the link colour when something echoed, a grey one when nothing did.
    final r = resolvedSince;
    if (r != null && r < pingRingLife) {
      final f = r.inMicroseconds / pingRingLife.inMicroseconds;
      final c = resolvedHeard ? echoColor : silentColor;
      canvas.drawCircle(
        center,
        20 + (1 - math.pow(1 - f, 2).toDouble()) * 70,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = c.withValues(alpha: 0.8 * (1 - f)),
      );
    }
  }

  @override
  bool shouldRepaint(_PuckPainter old) => true;
}
