// Shared design tokens (WP0 of the Drive and Chat redesigns, D1). The colour palette itself stays in ../theme.dart;
// this file adds the semantic names, hit targets, motion and blur rules both programmes build on.
//
//   Gap / Corners        re-exported from theme.dart (spacing and radii)
//   Hit                  44 pt minimum target and `Hit.pad` (small visual, full-size hit area)
//   Motion               spring and fade durations, Reduce Motion aware
//   Blur                 translucent bar material, opaque under Reduce Transparency / Increase Contrast
//   AppColors            semantic colour names (accent, bubbleOut, danger, warning, ok, ...) per theme
import 'package:flutter/material.dart';

import '../../platform/accessibility_channel.dart';
import '../theme.dart';

export '../theme.dart' show Gap, Corners;

/// Hit targets. Visual controls may be smaller than [min] only when wrapped in [pad].
abstract final class Hit {
  /// Apple's minimum target. The existing code that already enforces 48 keeps 48.
  static const double min = 44;
  static const double minAndroid = 48;

  /// Wraps [child] so its tappable area is at least [size] x [size] while the visual stays as it is
  /// (segmented control 32 visual / 44 hit, send button 32 visual / 44 hit).
  static Widget pad({required Widget child, VoidCallback? onTap, double size = min, String? semanticsLabel}) {
    final padded = ConstrainedBox(
      constraints: BoxConstraints(minWidth: size, minHeight: size),
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    );
    if (onTap == null) return padded;
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: padded),
    );
  }
}

/// Motion rules: springs for sheets and menus, short fades for state, nothing looping.
abstract final class Motion {
  /// Sheets and menus: spring, damping ratio 0.85, about 300 ms.
  static const Duration sheet = Duration(milliseconds: 300);
  static const double sheetDamping = 0.85;
  static const Duration listInsert = Duration(milliseconds: 180);
  static const Duration crossFade = Duration(milliseconds: 150);
  static const Duration toastIn = Duration(milliseconds: 220);

  /// Reduce Motion: cross-fades only, no springs, no pulse.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [d] unless Reduce Motion is on, then a plain fade length.
  static Duration of(BuildContext context, Duration d) => reduced(context) ? crossFade : d;
}

/// The blurred bar material (nav bar, compose bar): sigma 20 over the background at 80%.
abstract final class Blur {
  static const double sigma = 20;
  static const double backgroundOpacity = 0.8;

  /// Spike S10: Flutter has no Reduce Transparency signal, so a native channel answers it
  /// (lib/platform/accessibility_channel.dart). Opaque when it reports ON, when it is ABSENT (unknown), or when Increase
  /// Contrast (`highContrast`) is on.
  static bool opaque(BuildContext context) =>
      (MediaQuery.maybeHighContrastOf(context) ?? false) || (AccessibilitySignals.reduceTransparency ?? true);
}

/// Extra layout constants shared by Chat and Drive.
abstract final class Layout {
  static const double screenMargin = 16;
  static const double screenMarginPad = 20;
  static const double sectionGap = 32;

  /// Sheets are a centred form-sheet on tablets.
  static const double sheetMaxWidth = 560;
}

/// Semantic colours for one theme. Names, not hexes: the hexes live in theme.dart palettes (plus the three chosen here,
/// [bubbleOut], [bubbleOutText] and [warning], which are checked by test/ui/design/tokens_contrast_test.dart).
class AppColors {
  final Brightness brightness;
  final Color bg, surface, surfaceHigh, outline, textPrimary, textMuted;
  final Color accent, onAccent;

  /// Own chat bubble fill and its text. Darker teal than [accent] so white text holds 4.5:1; the bright accent is
  /// never a text-bearing fill.
  final Color bubbleOut, bubbleOutText;
  final Color beacon;

  /// Destructive actions and Failed only.
  final Color danger;

  /// Near a limit, default password, stale path.
  final Color warning;

  /// Success checks (the strong-signal green of the active palette).
  final Color ok;

  const AppColors({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceHigh,
    required this.outline,
    required this.textPrimary,
    required this.textMuted,
    required this.accent,
    required this.onAccent,
    required this.bubbleOut,
    required this.bubbleOutText,
    required this.beacon,
    required this.danger,
    required this.warning,
    required this.ok,
  });

  static const Color _bubbleLight = Color(0xFF00685E);
  static const Color _bubbleDark = Color(0xFF0A5C54);
  static const Color _warningLight = Color(0xFFA14B00);
  static const Color _warningDark = Color(0xFFFFA14A);

  factory AppColors.fromTheme(ThemeData t) {
    final cs = t.colorScheme;
    final mc = t.extension<MeshSonarColors>();
    final dark = t.brightness == Brightness.dark;
    return AppColors(
      brightness: t.brightness,
      bg: cs.surfaceDim,
      surface: cs.surface,
      surfaceHigh: cs.surfaceContainerHigh,
      outline: cs.outline,
      textPrimary: cs.onSurface,
      textMuted: cs.onSurfaceVariant,
      accent: cs.primary,
      onAccent: cs.onPrimary,
      bubbleOut: dark ? _bubbleDark : _bubbleLight,
      bubbleOutText: Colors.white,
      beacon: mc?.beacon ?? cs.secondary,
      danger: cs.error,
      warning: dark ? _warningDark : _warningLight,
      ok: mc?.levelStrong ?? const Color(0xFF2E9E5B),
    );
  }

  static AppColors of(BuildContext context) => AppColors.fromTheme(Theme.of(context));
}
