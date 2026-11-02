// The translucent tab bar material (plan WP1, chat D44/D49): the content behind the bar is blurred (sigma 20) under a
// surface tint at 80%, with a hairline on top. Opaque when Reduce Transparency / Increase Contrast is on, or when the
// platform cannot say (Android, desktop, tests): see Blur.opaque in ui/design/tokens.dart.
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

class BlurBar extends StatelessWidget {
  final Widget child;
  const BlurBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final opaque = Blur.opaque(context);
    final bar = DecoratedBox(
      key: Key(opaque ? 'blur-bar-opaque' : 'blur-bar-blurred'),
      decoration: BoxDecoration(
        color: opaque ? cs.surface : cs.surface.withValues(alpha: Blur.backgroundOpacity),
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      child: child,
    );
    if (opaque) return bar;
    return ClipRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: Blur.sigma, sigmaY: Blur.sigma), child: bar));
  }
}
