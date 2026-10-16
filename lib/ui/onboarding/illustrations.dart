// Illustrations for the first-run intro, drawn with Flutter (no image files).
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Brand colours shared with the app icon and the iOS launch screen.
class Brand {
  static const Color deep = Color(0xFF062A2C); // icon / launch background
  static const Color teal = Color(0xFF0E4D4F);
  static const Color glow = Color(0xFF3EE0CF); // sonar arcs (theme accent, dark)
  static const Color ping = Color(0xFFFFB547); // repeaters / beacon (theme beacon, dark)
}

/// Concentric sonar arcs sweeping out from a ping, with repeaters lighting up. Animates gently.
class SonarIllustration extends StatefulWidget {
  final double size;
  final bool animate;
  const SonarIllustration({super.key, this.size = 220, this.animate = true});
  @override
  State<SonarIllustration> createState() => _SonarIllustrationState();
}

final bool _inFlutterTest = () {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}();

class _SonarIllustrationState extends State<SonarIllustration> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

  @override
  void initState() {
    super.initState();
    // Widget tests use pumpAndSettle, which never settles with a repeating animation.
    if (widget.animate && !_inFlutterTest) {
      _c.repeat();
    } else {
      _c.value = 0.55;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(painter: SonarPainter(_c.value)),
      ),
    );
  }
}

class SonarPainter extends CustomPainter {
  final double t; // 0..1 sweep phase
  SonarPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width * 0.5, size.height * 0.74);
    final r = size.width * 0.5;
    // Soft disc
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(colors: [Brand.glow.withValues(alpha: 0.18), Brand.glow.withValues(alpha: 0.0)])
            .createShader(Rect.fromCircle(center: c, radius: r)),
    );
    // Static arcs
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = size.width * 0.028;
    for (var i = 1; i <= 3; i++) {
      final rr = r * (0.2 + 0.2 * i);
      arc.color = Brand.glow.withValues(alpha: 0.35 + 0.2 * (3 - i) / 2);
      canvas.drawArc(Rect.fromCircle(center: c, radius: rr), math.pi * 1.18, math.pi * 0.64, false, arc);
    }
    // Moving wave
    final wr = r * (0.2 + 0.8 * t);
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: wr),
      math.pi * 1.12,
      math.pi * 0.76,
      false,
      arc
        ..color = Brand.glow.withValues(alpha: (1 - t).clamp(0, 1) * 0.9)
        ..strokeWidth = size.width * 0.02,
    );
    // Repeaters: light up when the wave passes them
    final reps = [const Offset(-0.78, -0.62), const Offset(0.0, -1.0), const Offset(0.78, -0.62)];
    for (final o in reps) {
      final p = c + Offset(o.dx * r, o.dy * r);
      final d = (p - c).distance / r;
      final lit = t > d - 0.15 && t < d + 0.35;
      _tower(canvas, p, size.width * 0.07, lit ? Brand.ping : Colors.white.withValues(alpha: 0.55));
    }
    // The ping (the car)
    canvas.drawCircle(c, size.width * 0.06, Paint()..color = Brand.ping);
    canvas.drawCircle(c, size.width * 0.06 + 4, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Brand.ping.withValues(alpha: 0.4));
  }

  void _tower(Canvas canvas, Offset p, double s, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = s * 0.22
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(p + Offset(0, -s * 0.2), p + Offset(-s * 0.55, s), paint);
    canvas.drawLine(p + Offset(0, -s * 0.2), p + Offset(s * 0.55, s), paint);
    canvas.drawCircle(p + Offset(0, -s * 0.45), s * 0.28, Paint()..color = color);
  }

  @override
  bool shouldRepaint(SonarPainter old) => old.t != t;
}

/// A round badge holding an icon, with a soft glow ring.
class GlowIcon extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color color;
  const GlowIcon(this.icon, {super.key, this.size = 72, this.color = Brand.glow});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size * 1.6,
      height: size * 1.6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 2),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.25), blurRadius: 30, spreadRadius: 2)],
      ),
      child: Icon(icon, size: size, color: color),
    );
  }
}

/// Radio and phone linked by Bluetooth.
class RadioLinkIllustration extends StatelessWidget {
  const RadioLinkIllustration({super.key});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const GlowIcon(Icons.router, size: 52),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.bluetooth, color: Brand.ping, size: 30),
            const SizedBox(height: 6),
            Row(children: [
              for (var i = 0; i < 5; i++)
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(color: Brand.glow.withValues(alpha: 0.3 + i * 0.14), shape: BoxShape.circle),
                ),
            ]),
          ]),
        ),
        const GlowIcon(Icons.phone_iphone, size: 52),
      ],
    );
  }
}

/// Phone → driver key → community map.
class KeyCloudIllustration extends StatelessWidget {
  const KeyCloudIllustration({super.key});
  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GlowIcon(Icons.phone_iphone, size: 34),
        _Dots(),
        GlowIcon(Icons.vpn_key, size: 46, color: Brand.ping),
        _Dots(),
        GlowIcon(Icons.public, size: 34),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 2.5),
              decoration: BoxDecoration(color: Brand.glow.withValues(alpha: 0.35 + i * 0.2), shape: BoxShape.circle),
            ),
        ]),
      );
}
