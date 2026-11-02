// Typography (D46): the system font only. On iOS `fontFamily: null` resolves to SF Pro (Text below 20 pt, Display from
// 20 pt); on Android it is Roboto. No SF font file is ever bundled, embedded or written into a generated file: the two
// OFL Barlow TTFs below are plain assets used ONLY by the PDF export ([AppType.documentRegular] / [documentBold]).
//
// Sizes follow the iOS text styles and scale with `MediaQuery.textScalerOf`; Apple's per-size tracking table is applied
// as `letterSpacing`. Every numeric style carries tabular figures (digits keep one width, so a changing number never
// shifts its neighbours).
import 'package:flutter/material.dart';

abstract final class AppType {
  /// PDF export only (D46). Never use these for UI text.
  static const String documentRegular = 'assets/fonts/Barlow-Regular.ttf';
  static const String documentBold = 'assets/fonts/Barlow-SemiBold.ttf';

  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  /// Apple's tracking (points) by font size: 34 +0.37, 22 +0.35, 17 -0.41, 16 -0.32, 15 -0.24, 13 -0.08, 12 0.
  static final Map<double, double> trackingTable = {
    34: 0.37,
    22: 0.35,
    17: -0.41,
    16: -0.32,
    15: -0.24,
    13: -0.08,
    12: 0,
    11: 0.06,
  };

  /// Tracking for [size]: the table value for an exact size, else linear between the neighbouring entries, clamped.
  static double tracking(double size) {
    final keys = trackingTable.keys.toList()..sort();
    if (size <= keys.first) return trackingTable[keys.first]!;
    if (size >= keys.last) return trackingTable[keys.last]!;
    for (var i = 0; i < keys.length - 1; i++) {
      final a = keys[i], b = keys[i + 1];
      if (size >= a && size <= b) {
        final t = (size - a) / (b - a);
        return trackingTable[a]! + (trackingTable[b]! - trackingTable[a]!) * t;
      }
    }
    return 0;
  }

  static TextStyle _s(double size, FontWeight w, {double? height, bool numeric = false}) => TextStyle(
    fontSize: size,
    fontWeight: w,
    letterSpacing: tracking(size),
    height: height,
    fontFeatures: numeric ? tabular : null,
  );

  // ---- the iOS text styles (pt at default size)
  static final TextStyle largeTitle = _s(34, FontWeight.w700);
  static final TextStyle title2 = _s(22, FontWeight.w600);
  static final TextStyle headline = _s(17, FontWeight.w600);
  static final TextStyle body = _s(17, FontWeight.w400, height: 1.3);
  static final TextStyle callout = _s(16, FontWeight.w400);
  static final TextStyle subhead = _s(15, FontWeight.w400);
  static final TextStyle footnote = _s(13, FontWeight.w400);
  static final TextStyle caption = _s(12, FontWeight.w400);

  /// Smallest size allowed anywhere (HIG).
  static final TextStyle floor = _s(11, FontWeight.w400);

  /// Drive HUD hero number: 34 pt semibold, tabular (spike S4). Cap its text scale at [heroMaxScale] where it is used.
  static final TextStyle hero = _s(34, FontWeight.w600, numeric: true);
  static const double heroMaxScale = 1.3;

  /// A number in running UI: tabular figures at [size] / [weight].
  static TextStyle num(double size, {FontWeight weight = FontWeight.w600}) => _s(size, weight, numeric: true);

  /// Keys, CLI and fixed-width values (SF Mono on Apple platforms through the platform fallback list).
  static const TextStyle mono = TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: ['Courier', 'monospace'],
    fontSize: 13,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Adds the tracking table to every style of a Material [TextTheme] by its own font size (keeps colours and weights).
  static TextTheme withTracking(TextTheme t) {
    TextStyle? f(TextStyle? s) => s == null || s.fontSize == null ? s : s.copyWith(letterSpacing: tracking(s.fontSize!));
    return t.copyWith(
      displayLarge: f(t.displayLarge),
      displayMedium: f(t.displayMedium),
      displaySmall: f(t.displaySmall),
      headlineLarge: f(t.headlineLarge),
      headlineMedium: f(t.headlineMedium),
      headlineSmall: f(t.headlineSmall),
      titleLarge: f(t.titleLarge),
      titleMedium: f(t.titleMedium),
      titleSmall: f(t.titleSmall),
      bodyLarge: f(t.bodyLarge),
      bodyMedium: f(t.bodyMedium),
      bodySmall: f(t.bodySmall),
      labelLarge: f(t.labelLarge),
      labelMedium: f(t.labelMedium),
      labelSmall: f(t.labelSmall),
    );
  }
}
