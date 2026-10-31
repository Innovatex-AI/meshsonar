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
  final Color snrWeak, snrMid, snrStrong, silent, heardUnknown;
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
    required this.snrWeak,
    required this.snrMid,
    required this.snrStrong,
    required this.silent,
    required this.heardUnknown,
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
  snrWeak: Color(0xFF3B8FD6),
  snrMid: Color(0xFF3EE0CF),
  snrStrong: Color(0xFF8CF58A),
  silent: Color(0xFF8D99A6), // mapped, nothing heard: grey, never a coverage colour
  heardUnknown: Color(0xFFB59AE0), // heard, signal strength unknown: its own colour, never green
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
  snrWeak: Color(0xFF2468B8),
  snrMid: Color(0xFF00897B),
  snrStrong: Color(0xFF2E9E3A),
  silent: Color(0xFF8795A1),
  heardUnknown: Color(0xFF8A63C9),
  mapBg: Color(0xFFE9EFF1),
  mapGrid: Color(0xFF00796E),
  tileMatrix: _lightTiles,
);

/// Colours beyond the Material scheme: signal quality, repeaters, and the map.
@immutable
class MeshSonarColors extends ThemeExtension<MeshSonarColors> {
  /// Repeaters ("beacons") everywhere in the app.
  final Color beacon;
  final Color onBeacon;

  /// SNR scale for pings that were heard: weak (≤ -10 dB) → mid (0 dB) → strong (≥ +10 dB).
  final Color snrWeak, snrMid, snrStrong;

  /// A ping that heard nothing: grey (mapped, no signal).
  final Color silent;

  /// A ping that was heard but whose signal strength is unknown.
  final Color heardUnknown;

  /// Map canvas under the tiles (what you see offline).
  final Color mapBackground;

  /// Range rings and grid on the map.
  final Color mapGrid;

  /// Applied to OSM tiles so the base map sits quietly under the data.
  final List<double> tileMatrix;

  /// Secondary text.
  final Color textMuted;

  const MeshSonarColors({
    required this.beacon,
    required this.onBeacon,
    required this.snrWeak,
    required this.snrMid,
    required this.snrStrong,
    required this.silent,
    required this.heardUnknown,
    required this.mapBackground,
    required this.mapGrid,
    required this.tileMatrix,
    required this.textMuted,
  });

  static MeshSonarColors of(BuildContext context) =>
      Theme.of(context).extension<MeshSonarColors>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  static final MeshSonarColors dark = _fromPalette(_dark);
  static final MeshSonarColors light = _fromPalette(_light);

  static MeshSonarColors _fromPalette(_Palette p) => MeshSonarColors(
    beacon: p.beacon,
    onBeacon: p.onBeacon,
    snrWeak: p.snrWeak,
    snrMid: p.snrMid,
    snrStrong: p.snrStrong,
    silent: p.silent,
    heardUnknown: p.heardUnknown,
    mapBackground: p.mapBg,
    mapGrid: p.mapGrid,
    tileMatrix: p.tileMatrix,
    textMuted: p.textMuted,
  );

  /// Colour for a ping result: [heard] false → [silent] (grey); heard with unknown SNR → [heardUnknown]; else the SNR scale.
  Color forPing({required bool heard, double? snr}) {
    if (!heard) return silent;
    if (snr == null) return heardUnknown;
    final t = ((snr.clamp(-10.0, 10.0)) + 10) / 20; // 0..1
    return t < 0.5 ? Color.lerp(snrWeak, snrMid, t * 2)! : Color.lerp(snrMid, snrStrong, (t - 0.5) * 2)!;
  }

  @override
  MeshSonarColors copyWith({Color? beacon, Color? silent}) => MeshSonarColors(
    beacon: beacon ?? this.beacon,
    onBeacon: onBeacon,
    snrWeak: snrWeak,
    snrMid: snrMid,
    snrStrong: snrStrong,
    silent: silent ?? this.silent,
    heardUnknown: heardUnknown,
    mapBackground: mapBackground,
    mapGrid: mapGrid,
    tileMatrix: tileMatrix,
    textMuted: textMuted,
  );

  @override
  MeshSonarColors lerp(MeshSonarColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return MeshSonarColors(
      beacon: l(beacon, other.beacon),
      onBeacon: l(onBeacon, other.onBeacon),
      snrWeak: l(snrWeak, other.snrWeak),
      snrMid: l(snrMid, other.snrMid),
      snrStrong: l(snrStrong, other.snrStrong),
      silent: l(silent, other.silent),
      heardUnknown: l(heardUnknown, other.heardUnknown),
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

ThemeData meshSonarTheme(Brightness b) {
  final p = b == Brightness.dark ? _dark : _light;
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
    tertiary: p.snrWeak,
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
    extensions: [b == Brightness.dark ? MeshSonarColors.dark : MeshSonarColors.light],
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
