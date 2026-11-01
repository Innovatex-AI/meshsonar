// The live "sonar" puck: the dot that moves with you, the rings a ping sends out, and the lines that come back from the
// repeaters that heard it. Three pieces:
//
//   PuckController  Owns the dot's motion (lib/core/puck_motion.dart) and the ping animation clock. The Drive map model
//                   feeds it every GPS fix and every ping event. It is DISPLAY ONLY; pings record the engine's own fix.
//   PuckLinksLayer  A flutter_map layer under the repeater markers: lines from the moving dot to each repeater that
//                   echoed the latest ping (orange link colour, never a signal strength), drawn out from the dot and
//                   faded a few seconds later.
//   PuckLayer       A flutter_map layer on top: accuracy disc, heading cone, ping rings and the dot. Owns the Ticker,
//                   which sleeps whenever nothing is moving.
//
// Both layers repaint on their own every frame without rebuilding the map: a GPS fix never touches the hex, cell or
// repeater layers (that rebuild was what made the old dot hop).
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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

class PuckController extends ChangeNotifier {
  final DateTime Function() clock;
  final PuckMotion motion;
  PuckController({DateTime Function()? clock, PuckConfig config = const PuckConfig()})
    : clock = clock ?? DateTime.now,
      motion = PuckMotion(config);

  /// Bumped when there is something to animate again; the ticker wakes on it.
  final ValueNotifier<int> wake = ValueNotifier<int>(0);

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

  /// A GPS fix arrived. Returns whether the dot accepted it (see PuckMotion's outlier gate).
  bool onFix(GeoFix f) {
    final ok = motion.add(f, clock());
    if (ok) {
      _pose ??= motion.poseAt(clock());
      _wake();
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
    _pose = null;
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

  /// Advance one frame: compute the pose and tell the layers to repaint. Returns true while another frame is needed.
  bool tick({bool reducedMotion = false}) {
    final now = clock();
    _pose = motion.poseAt(now, reducedMotion: reducedMotion) ?? _pose;
    notifyListeners();
    return !(_pose?.settled ?? true) || (!reducedMotion && animatingPing(now)) || (reducedMotion && _linksFading(now));
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

  @override
  void dispose() {
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

/// The dot, its accuracy disc, heading cone and ping rings. Owns the frame ticker.
class PuckLayer extends StatefulWidget {
  final PuckController puck;

  /// Shown, still, until the first live fix: the phone's last-known or idle position.
  final LatLng? fallback;

  /// Called after every frame with the dot's position, so the camera can follow it.
  final void Function(LatLng at)? onMoved;
  const PuckLayer({super.key, required this.puck, this.fallback, this.onMoved});

  @override
  State<PuckLayer> createState() => _PuckLayerState();
}

class _PuckLayerState extends State<PuckLayer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastPaint = Duration.zero;
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
    if (!mounted || _ticker.isActive) return;
    _lastPaint = Duration.zero;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    // 30 frames a second is plenty for a dot at driving speed, and halves the map's repaint work on 120 Hz iPads.
    if (_lastPaint != Duration.zero && elapsed - _lastPaint < const Duration(milliseconds: 30)) return;
    _lastPaint = elapsed;
    final more = widget.puck.tick(reducedMotion: _reduced);
    final p = widget.puck.pose;
    if (p != null) widget.onMoved?.call(LatLng(p.lat, p.lon));
    if (!more) _ticker.stop();
  }

  @override
  void dispose() {
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
                left: c.dx - 24,
                top: c.dy - 24,
                width: 48,
                height: 48,
                child: _Dot(key: const Key('map-position'), color: t.colorScheme.primary, ring: t.colorScheme.surface),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final Color ring;
  const _Dot({super.key, required this.color, required this.ring});
  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Your position',
      child: Center(
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: ring, width: 3),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 6)],
          ),
        ),
      ),
    );
  }
}

class _PuckPainter extends CustomPainter {
  final MapCamera camera;
  final LatLng at;
  final Offset center;
  final PuckPose? pose;
  final Color color, echoColor, silentColor;
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

    // Accuracy disc (only when it is bigger than the dot, so it reads as uncertainty).
    final acc = p?.accuracyM;
    if (acc != null) {
      final r = (acc * ppm).clamp(0.0, 140.0);
      if (r > 14) {
        canvas.drawCircle(center, r, Paint()..color = color.withValues(alpha: 0.10));
        canvas.drawCircle(
          center,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = color.withValues(alpha: 0.28),
        );
      }
    }

    // Heading cone: a wedge toward the direction of travel, measured on screen so map rotation is respected.
    final course = p?.courseDeg;
    if (course != null) {
      final r = course * math.pi / 180;
      const aheadM = 40.0;
      final tip = camera.latLngToScreenOffset(
        LatLng(
          at.latitude + math.cos(r) * aheadM / 111320.0,
          at.longitude + math.sin(r) * aheadM / (111320.0 * math.cos(at.latitude * math.pi / 180)),
        ),
      );
      final v = tip - center;
      if (v.distance > 1) {
        final ang = math.atan2(v.dy, v.dx);
        const len = 46.0, half = 0.46;
        final path = ui.Path()
          ..moveTo(center.dx, center.dy)
          ..lineTo(center.dx + math.cos(ang - half) * len, center.dy + math.sin(ang - half) * len)
          ..arcTo(Rect.fromCircle(center: center, radius: len), ang - half, half * 2, false)
          ..close();
        canvas.drawPath(
          path,
          Paint()
            ..shader = ui.Gradient.radial(center, len, [color.withValues(alpha: 0.55), color.withValues(alpha: 0)]),
        );
      }
    }

    if (reduced) return;

    // Rings sent while the ping waits for echoes.
    final s = sentSince;
    if (s != null) {
      for (final ring in waitingRings(s)) {
        final r = 14 + ring.grow * 120;
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
        14 + (1 - math.pow(1 - f, 2).toDouble()) * 70,
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
