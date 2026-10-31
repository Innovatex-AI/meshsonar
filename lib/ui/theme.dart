// MeshSonar design system: colours, type, shapes and the map palette.
//
// Direction: an in-car instrument, not a web dashboard. Deep "sonar water" navy in dark mode (the default at night),
// a cool chart-paper grey in light mode, one strong sonar-teal accent, and a warm beacon amber reserved for
// repeaters, so "you", "your pings" and "the towers" never share a colour. Numbers are set in Barlow Semi Condensed
// with tabular figures, big enough to read at arm's length; everything else is Barlow (a road-signage grotesque).
//
// Screens read the extra colours with `MeshSonarColors.of(context)`.
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../core/colour_palette.dart';
import '../core/network_coverage.dart' show CoverageLevel;

/// Spacing scale (logical px). Use these instead of ad-hoc numbers.
abstract final class Gap {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
}

/// Corner radii: big things are rounder than small things.
abstract final class Corners {
  static const double card = 20;
  static const double button = 18;
  static const double chip = 14;
  static const double small = 10;
}

const String _body = 'Barlow';
const String _numeric = 'BarlowSemiCondensed';

// ---------------------------------------------------------------- palette
class _Palette {
  final Color bg, surface, surfaceHigh, surfaceHighest, outline, outlineVariant, text, textMuted;
  final Color accent, onAccent, accentContainer, onAccentContainer;
  final Color danger, onDanger, dangerContainer, onDangerContainer;
  final Color beacon, onBeacon;
  final Color mapBg, mapGrid;
  final List<double> tileMatrix;
  const _Palette({
    required this.bg,
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceHighest,
    required this.outline,
    required this.outlineVariant,
    required this.text,
    required this.textMuted,
    required this.accent,
    required this.onAccent,
    required this.accentContainer,
    required this.onAccentContainer,
    required this.danger,
    required this.onDanger,
    required this.dangerContainer,
    required this.onDangerContainer,
    required this.beacon,
    required this.onBeacon,
    required this.mapBg,
    required this.mapGrid,
    required this.tileMatrix,
  });
}

// Tile colour matrices. OSM's standard tiles are light; these remap each pixel's luminance onto the palette, so the
// base map reads as a quiet chart under bright data. (Prototyped on real Westerville tiles.)
const List<double> _darkTiles = [
  -0.2412, -0.8114, -0.0819, 0, 302.29, //
  -0.2948, -0.9917, -0.1001, 0, 380.57, //
  -0.3156, -1.0618, -0.1072, 0, 416.57, //
  0, 0, 0, 1, 0,
];
const List<double> _lightTiles = [
  0.2446, 0.8227, 0.0831, 0, -51.33, //
  0.2131, 0.7168, 0.0724, 0, -10.56, //
  0.1964, 0.6607, 0.0667, 0, 10.44, //
  0, 0, 0, 1, 0,
];

const _dark = _Palette(
  bg: Color(0xFF0A1620),
  surface: Color(0xFF0F1E2A),
  surfaceHigh: Color(0xFF152836),
  surfaceHighest: Color(0xFF1D3343),
  outline: Color(0xFF5D7A8A),
  outlineVariant: Color(0xFF263E4E),
  text: Color(0xFFE8F1F4),
  textMuted: Color(0xFF9FB6C2),
  accent: Color(0xFF3EE0CF),
  onAccent: Color(0xFF00201C),
  accentContainer: Color(0xFF0E4B47),
  onAccentContainer: Color(0xFFA8F5EB),
  danger: Color(0xFFFF6B5B),
  onDanger: Color(0xFF2D0500),
  dangerContainer: Color(0xFF5A1A12),
  onDangerContainer: Color(0xFFFFDAD3),
  beacon: Color(0xFFFFB547),
  onBeacon: Color(0xFF2A1700),
  mapBg: Color(0xFF0D1B26),
  mapGrid: Color(0xFF3EE0CF),
  tileMatrix: _darkTiles,
);

const _light = _Palette(
  bg: Color(0xFFF1F5F6),
  surface: Color(0xFFFFFFFF),
  surfaceHigh: Color(0xFFE7EEF0),
  surfaceHighest: Color(0xFFDCE6E9),
  outline: Color(0xFF6B8290),
  outlineVariant: Color(0xFFC6D4DA),
  text: Color(0xFF0C1E28),
  textMuted: Color(0xFF4A6270),
  accent: Color(0xFF00796E),
  onAccent: Color(0xFFFFFFFF),
  accentContainer: Color(0xFFB9EEE6),
  onAccentContainer: Color(0xFF00201C),
  danger: Color(0xFFC62F22),
  onDanger: Color(0xFFFFFFFF),
  dangerContainer: Color(0xFFFFDAD4),
  onDangerContainer: Color(0xFF410001),
  beacon: Color(0xFFB86E00),
  onBeacon: Color(0xFFFFFFFF),
  mapBg: Color(0xFFE9EFF1),
  mapGrid: Color(0xFF00796E),
  tileMatrix: _lightTiles,
);

// ------------------------------------------------------- strength palettes
// The colours that mean "how strong was the signal", per ColourPalette and brightness. Hex values are copied to the
// website from docs/FEATURES.md ("Colour palettes") and meshsonar-infra/docs/planning/colour-palettes-2026-10-31.md;
// test/ui/palette_test.dart pins them and checks colour-blind separation. Grey (silent) and purple (heardUnknown) are
// part of each set so they stay distinguishable from the steps.
class _Strength {
  /// Network coverage steps (CoverageLevel.strong/good/fair/weak).
  final Color strong, good, fair, weak;

  /// Your pings' SNR gradient: equally spaced stops from -10 dB to +10 dB.
  final List<Color> stops;
  final Color silent, heardUnknown;

  /// Link lines and their casing; [linkDashed] false = solid.
  final Color link, linkCasing;
  final bool linkDashed;
  const _Strength({
    required this.strong,
    required this.good,
    required this.fair,
    required this.weak,
    required this.stops,
    required this.silent,
    required this.heardUnknown,
    required this.link,
    required this.linkCasing,
    required this.linkDashed,
  });
}

const _linkOrange = Color(0xFFFF6D00);

const _standardDark = _Strength(
  strong: Color(0xFF79BE69),
  good: Color(0xFF6AAEE0),
  fair: Color(0xFFE2B04A),
  weak: Color(0xFFF07B6B),
  stops: [Color(0xFF3B8FD6), Color(0xFF3EE0CF), Color(0xFF8CF58A)],
  silent: Color(0xFF8D99A6),
  heardUnknown: Color(0xFFB59AE0),
  link: _linkOrange,
  linkCasing: Color(0x8C000000),
  linkDashed: false,
);
const _standardLight = _Strength(
  strong: Color(0xFF2F7A3B),
  good: Color(0xFF2A6B9C),
  fair: Color(0xFFB07D16),
  weak: Color(0xFFB23B2E),
  stops: [Color(0xFF2468B8), Color(0xFF00897B), Color(0xFF2E9E3A)],
  silent: Color(0xFF8795A1),
  heardUnknown: Color(0xFF8A63C9),
  link: _linkOrange,
  linkCasing: Color(0x8C000000),
  linkDashed: false,
);
const _colourBlindDark = _Strength(
  strong: Color(0xFF2B8CE0),
  good: Color(0xFF8EDBFF),
  fair: Color(0xFFEDDD55),
  weak: Color(0xFFD25637),
  stops: [Color(0xFFD25637), Color(0xFFEDDD55), Color(0xFF8EDBFF), Color(0xFF2B8CE0)],
  silent: Color(0xFF8D99A6),
  heardUnknown: Color(0xFFB356A4),
  link: Color(0xFFF4F7F9),
  linkCasing: Color(0xD90D1B26),
  linkDashed: true,
);
const _colourBlindLight = _Strength(
  strong: Color(0xFF0A4FA0),
  good: Color(0xFF1E88C8),
  fair: Color(0xFF9C7F06),
  weak: Color(0xFF762608),
  stops: [Color(0xFF762608), Color(0xFF9C7F06), Color(0xFF004E66), Color(0xFF0A4FA0)],
  silent: Color(0xFF8795A1),
  heardUnknown: Color(0xFF8E5A8A),
  link: Color(0xFF0C1E28),
  linkCasing: Color(0xD9FFFFFF),
  linkDashed: true,
);
const _highContrastDark = _Strength(
  strong: Color(0xFF86CAFE),
  good: Color(0xFFBDE8F2),
  fair: Color(0xFFFEE405),
  weak: Color(0xFFFE831A),
  stops: [Color(0xFFFE831A), Color(0xFFFEE405), Color(0xFFBDE8F2), Color(0xFF86CAFE)],
  silent: Color(0xFFA3AEBA),
  heardUnknown: Color(0xFFD68BD0),
  link: Color(0xFFF4F7F9),
  linkCasing: Color(0xD90D1B26),
  linkDashed: true,
);
const _highContrastLight = _Strength(
  strong: Color(0xFF001365),
  good: Color(0xFF0A58C4),
  fair: Color(0xFF8B640C),
  weak: Color(0xFF7F2606),
  stops: [Color(0xFF7F2606), Color(0xFF8B640C), Color(0xFF004E66), Color(0xFF001365)],
  silent: Color(0xFF5F6C78),
  heardUnknown: Color(0xFF6E5C91),
  link: Color(0xFF0C1E28),
  linkCasing: Color(0xD9FFFFFF),
  linkDashed: true,
);

_Strength _strengthFor(ColourPalette p, Brightness b) {
  final dark = b == Brightness.dark;
  return switch (p) {
    ColourPalette.standard => dark ? _standardDark : _standardLight,
    ColourPalette.colourBlind => dark ? _colourBlindDark : _colourBlindLight,
    ColourPalette.highContrast => dark ? _highContrastDark : _highContrastLight,
  };
}

/// Colours beyond the Material scheme: signal quality, repeaters, and the map. The strength colours follow the chosen
/// [ColourPalette] (Settings > Units & display > Colour palette); call sites read them from here and never hardcode a hex.
@immutable
class MeshSonarColors extends ThemeExtension<MeshSonarColors> {
  /// Which palette these strength colours belong to.
  final ColourPalette palette;

  /// Repeaters ("beacons") everywhere in the app.
  final Color beacon;
  final Color onBeacon;

  /// Your pings' SNR scale for pings that were heard: equally spaced stops from -10 dB (first) to +10 dB (last).
  final List<Color> snrStops;

  /// Network coverage steps (CoverageLevel.strong/good/fair/weak): SNR >= +5, 0 to +5, -5 to 0, below -5 dB.
  final Color levelStrong, levelGood, levelFair, levelWeak;

  /// A ping that heard nothing: grey (mapped, no signal).
  final Color silent;

  /// A ping that was heard but whose signal strength is unknown.
  final Color heardUnknown;

  /// Link lines (a tapped repeater or cell), their casing, and whether they are dashed. Orange and solid in the standard
  /// palette; achromatic and dashed in the accessible palettes so they never blur into orange/yellow strength colours.
  final Color linkLine, linkLineCasing;
  final bool linkLineDashed;

  /// Map canvas under the tiles (what you see offline).
  final Color mapBackground;

  /// Range rings and grid on the map.
  final Color mapGrid;

  /// Applied to OSM tiles so the base map sits quietly under the data.
  final List<double> tileMatrix;

  /// Secondary text.
  final Color textMuted;

  const MeshSonarColors({
    this.palette = ColourPalette.standard,
    required this.beacon,
    required this.onBeacon,
    required this.snrStops,
    required this.levelStrong,
    required this.levelGood,
    required this.levelFair,
    required this.levelWeak,
    required this.silent,
    required this.heardUnknown,
    required this.linkLine,
    required this.linkLineCasing,
    required this.linkLineDashed,
    required this.mapBackground,
    required this.mapGrid,
    required this.tileMatrix,
    required this.textMuted,
  });

  /// Weakest, a middle and strongest anchor of the SNR scale (charts and gradients that want three colours).
  Color get snrWeak => snrStops.first;
  Color get snrMid => snrStops[1];
  Color get snrStrong => snrStops.last;

  static MeshSonarColors of(BuildContext context) =>
      Theme.of(context).extension<MeshSonarColors>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  static final MeshSonarColors dark = forPalette(ColourPalette.standard, Brightness.dark);
  static final MeshSonarColors light = forPalette(ColourPalette.standard, Brightness.light);

  /// The colours for [palette] on the dark or light theme.
  static MeshSonarColors forPalette(ColourPalette palette, Brightness b) =>
      _fromPalette(b == Brightness.dark ? _dark : _light, _strengthFor(palette, b), palette);

  static MeshSonarColors _fromPalette(_Palette p, _Strength st, ColourPalette palette) => MeshSonarColors(
    palette: palette,
    beacon: p.beacon,
    onBeacon: p.onBeacon,
    snrStops: st.stops,
    levelStrong: st.strong,
    levelGood: st.good,
    levelFair: st.fair,
    levelWeak: st.weak,
    silent: st.silent,
    heardUnknown: st.heardUnknown,
    linkLine: st.link,
    linkLineCasing: st.linkCasing,
    linkLineDashed: st.linkDashed,
    mapBackground: p.mapBg,
    mapGrid: p.mapGrid,
    tileMatrix: p.tileMatrix,
    textMuted: p.textMuted,
  );

  /// The colour of a network coverage step; [CoverageLevel.none] is [silent] and [CoverageLevel.unknown] is [heardUnknown].
  Color levelColor(CoverageLevel level) => switch (level) {
    CoverageLevel.strong => levelStrong,
    CoverageLevel.good => levelGood,
    CoverageLevel.fair => levelFair,
    CoverageLevel.weak => levelWeak,
    CoverageLevel.unknown => heardUnknown,
    CoverageLevel.none => silent,
  };

  /// The SNR scale at [t] (0 = -10 dB or weaker, 1 = +10 dB or stronger).
  Color snrAt(double t) {
    final x = t.clamp(0.0, 1.0) * (snrStops.length - 1);
    final i = x.floor().clamp(0, snrStops.length - 2);
    return Color.lerp(snrStops[i], snrStops[i + 1], x - i)!;
  }

  /// Colour for a ping result: [heard] false → [silent] (grey); heard with unknown SNR → [heardUnknown]; else the SNR scale.
  Color forPing({required bool heard, double? snr}) {
    if (!heard) return silent;
    if (snr == null) return heardUnknown;
    return snrAt((snr.clamp(-10.0, 10.0) + 10) / 20);
  }

  @override
  MeshSonarColors copyWith({Color? beacon, Color? silent}) => MeshSonarColors(
    palette: palette,
    beacon: beacon ?? this.beacon,
    onBeacon: onBeacon,
    snrStops: snrStops,
    levelStrong: levelStrong,
    levelGood: levelGood,
    levelFair: levelFair,
    levelWeak: levelWeak,
    silent: silent ?? this.silent,
    heardUnknown: heardUnknown,
    linkLine: linkLine,
    linkLineCasing: linkLineCasing,
    linkLineDashed: linkLineDashed,
    mapBackground: mapBackground,
    mapGrid: mapGrid,
    tileMatrix: tileMatrix,
    textMuted: textMuted,
  );

  @override
  MeshSonarColors lerp(MeshSonarColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    final n = t < 0.5 ? snrStops.length : other.snrStops.length;
    List<Color> stops() {
      Color at(List<Color> c, int i) => c[(i * (c.length - 1) / (n - 1)).round()];
      return [for (var i = 0; i < n; i++) l(at(snrStops, i), at(other.snrStops, i))];
    }
    return MeshSonarColors(
      palette: t < 0.5 ? palette : other.palette,
      beacon: l(beacon, other.beacon),
      onBeacon: l(onBeacon, other.onBeacon),
      snrStops: stops(),
      levelStrong: l(levelStrong, other.levelStrong),
      levelGood: l(levelGood, other.levelGood),
      levelFair: l(levelFair, other.levelFair),
      levelWeak: l(levelWeak, other.levelWeak),
      silent: l(silent, other.silent),
      heardUnknown: l(heardUnknown, other.heardUnknown),
      linkLine: l(linkLine, other.linkLine),
      linkLineCasing: l(linkLineCasing, other.linkLineCasing),
      linkLineDashed: t < 0.5 ? linkLineDashed : other.linkLineDashed,
      mapBackground: l(mapBackground, other.mapBackground),
      mapGrid: l(mapGrid, other.mapGrid),
      tileMatrix: t < 0.5 ? tileMatrix : other.tileMatrix,
      textMuted: l(textMuted, other.textMuted),
    );
  }
}

/// Big readable numbers (stats, countdowns). Tabular figures so digits don't jitter as they change.
TextStyle numberStyle(BuildContext context, {double size = 30, Color? color, FontWeight weight = FontWeight.w700}) =>
    TextStyle(
      fontFamily: _numeric,
      fontSize: size,
      height: 1.0,
      fontWeight: weight,
      color: color ?? Theme.of(context).colorScheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

ThemeData meshSonarTheme(Brightness b, {ColourPalette palette = ColourPalette.standard}) {
  final p = b == Brightness.dark ? _dark : _light;
  final mc = MeshSonarColors.forPalette(palette, b);
  final scheme = ColorScheme(
    brightness: b,
    primary: p.accent,
    onPrimary: p.onAccent,
    primaryContainer: p.accentContainer,
    onPrimaryContainer: p.onAccentContainer,
    secondary: p.beacon,
    onSecondary: p.onBeacon,
    secondaryContainer: Color.alphaBlend(p.beacon.withValues(alpha: 0.22), p.surface),
    onSecondaryContainer: p.text,
    tertiary: mc.snrWeak,
    onTertiary: p.bg,
    error: p.danger,
    onError: p.onDanger,
    errorContainer: p.dangerContainer,
    onErrorContainer: p.onDangerContainer,
    surface: p.surface,
    onSurface: p.text,
    onSurfaceVariant: p.textMuted,
    surfaceDim: p.bg,
    surfaceBright: p.surfaceHigh,
    surfaceContainerLowest: p.bg,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surfaceHigh,
    surfaceContainerHighest: p.surfaceHighest,
    outline: p.outline,
    outlineVariant: p.outlineVariant,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: p.text,
    onInverseSurface: p.bg,
    inversePrimary: p.accentContainer,
  );

  final base = ThemeData(useMaterial3: true, brightness: b, fontFamily: _body, colorScheme: scheme);
  final tt = base.textTheme;
  TextStyle? num(TextStyle? s, double size) =>
      s?.copyWith(fontFamily: _numeric, fontSize: size, fontWeight: FontWeight.w700, height: 1.05, letterSpacing: 0);
  final text = tt
      .copyWith(
        displayLarge: num(tt.displayLarge, 56),
        displayMedium: num(tt.displayMedium, 44),
        displaySmall: num(tt.displaySmall, 36),
        headlineLarge: num(tt.headlineLarge, 32),
        headlineMedium: num(tt.headlineMedium, 28),
        headlineSmall: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: 24),
        titleLarge: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 22),
        titleMedium: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 17),
        titleSmall: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
        bodyLarge: tt.bodyLarge?.copyWith(fontSize: 17, height: 1.35),
        bodyMedium: tt.bodyMedium?.copyWith(fontSize: 15, height: 1.35),
        bodySmall: tt.bodySmall?.copyWith(fontSize: 13, color: p.textMuted),
        labelLarge: tt.labelLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 15, letterSpacing: 0.1),
        labelMedium: tt.labelMedium?.copyWith(fontWeight: FontWeight.w500, fontSize: 13, color: p.textMuted),
        labelSmall: tt.labelSmall?.copyWith(fontWeight: FontWeight.w500, fontSize: 12, color: p.textMuted),
      )
      .apply(bodyColor: p.text, displayColor: p.text);

  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Corners.button));
  const buttonText = TextStyle(fontFamily: _body, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 0.1);

  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    textTheme: text,
    visualDensity: VisualDensity.standard,
    extensions: [mc],
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Corners.card),
        side: BorderSide(color: p.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 56),
        textStyle: buttonText,
        shape: buttonShape,
        disabledBackgroundColor: p.surfaceHighest,
        disabledForegroundColor: p.textMuted,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        textStyle: buttonText.copyWith(fontSize: 16),
        shape: buttonShape,
        foregroundColor: p.text,
        side: BorderSide(color: p.outline, width: 1.5),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        textStyle: buttonText.copyWith(fontSize: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Corners.small)),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.surfaceHigh,
      foregroundColor: p.text,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Corners.chip)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.surfaceHigh,
      side: BorderSide(color: p.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Corners.chip)),
      labelStyle: text.labelLarge,
      padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: Gap.s - 2),
    ),
    listTileTheme: ListTileThemeData(
      minVerticalPadding: 10,
      iconColor: p.textMuted,
      titleTextStyle: text.titleMedium,
      subtitleTextStyle: text.bodyMedium?.copyWith(color: p.textMuted),
    ),
    dividerTheme: DividerThemeData(color: p.outlineVariant, thickness: 1, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.accentContainer,
      height: 72,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontFamily: _body,
          fontSize: 14,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? p.text : p.textMuted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(size: 26, color: s.contains(WidgetState.selected) ? p.onAccentContainer : p.textMuted),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      // Float above the thumb zone so a message never covers Start/Stop or Ping now on the Drive screen.
      insetPadding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 160), // clear of the Antenna/Log row and the big buttons
      backgroundColor: p.text,
      contentTextStyle: TextStyle(fontFamily: _body, color: p.bg, fontSize: 16, fontWeight: FontWeight.w500),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Corners.chip)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(Corners.small), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Corners.small),
        borderSide: BorderSide(color: p.accent, width: 2),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.onAccent : p.outline),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.surfaceHighest,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent, linearTrackColor: p.surfaceHighest),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Corners.card)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Corners.card))),
    ),
  );
}

/// Follows the phone's light/dark setting. On desktop builds `MESHSONAR_THEME=dark|light` forces one (used for
/// screenshots and demos); phones always follow the system.
ThemeMode meshSonarThemeMode() {
  try {
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      final v = Platform.environment['MESHSONAR_THEME'];
      if (v == 'dark') return ThemeMode.dark;
      if (v == 'light') return ThemeMode.light;
    }
  } catch (_) {}
  return ThemeMode.system;
}
