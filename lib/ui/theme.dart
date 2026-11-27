// MeshSonar design system: colours, type, shapes and the map palette.
//
// Direction: an in-car instrument, not a web dashboard. Deep "sonar water" navy in dark mode (the default at night),
// a cool chart-paper grey in light mode and one strong sonar-teal accent. Type is the system font (SF Pro on Apple
// platforms; see design/app_type.dart): numbers use tabular figures, big enough to read at arm's length.
//
// One meaning per colour (build 77, Round 1 N4 / Round 2 N-V3 / Round 5 S4 and decision 10):
//   teal            you, and anything selected (chips, segments, tonal buttons, the status strip, the tab bar)
//   amber           a warning, and nothing else: `MeshSonarColors.warning`
//   neutral slate   repeaters: `MeshSonarColors.repeater` (no longer amber)
//   signal ramp     signal strength only (Map Definition bands); percent heard has its own teal scale (`heardStops`)
// The tokens are on [MeshSonarColors] (values in [ColourLanguage]). `beacon` is the OLD amber, kept only so call sites
// that have not moved yet still compile: a repeater takes `repeater`, a warning takes `warning`.
//
// Screens read the extra colours with `MeshSonarColors.of(context)`.
import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../core/colour_palette.dart';
import '../core/map_definition.dart' show MapDefinition;
import '../core/network_coverage.dart' show CoverageLevel;
import 'design/app_type.dart';
import 'map/active_map_definition.dart';

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

  /// Chat bubbles: outer corner, and the corner joining a grouped run.
  static const double bubble = 18;
  static const double bubbleInner = 6;

  /// Quick-action tiles and channel avatars (rounded square).
  static const double tile = 16;
  static const double channelAvatar = 14;
}


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
/// The dark chart grading, public so the Dark base map can force it whatever the app theme is.
const List<double> kDarkTileMatrix = _darkTiles;
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

// ------------------------------------------------------- colour language
/// The build 77 colour language (Round 1 N4, Round 5 decision 10): the colours that are NOT signal strength and NOT the
/// teal accent, one meaning each. Read them through [MeshSonarColors] (`MeshSonarColors.of(context).repeater`, ...).
/// None of these is a Map Definition signal colour (test/lint/no_signal_colours_test.dart) and none is amber except
/// [warning].
@immutable
class ColourLanguage {
  /// Warnings only (near a limit, stale, degraded, unusual). The one amber in the app. Text-safe on surfaces (4.5:1).
  final Color warning;

  /// Text or icon on a solid [warning] fill.
  final Color onWarning;

  /// Repeaters wherever one is drawn as an icon, bar, rank number or chip: a neutral slate, never amber and never the
  /// accent teal. [onRepeater] is text or a glyph on a solid [repeater] fill. For a soft badge use [repeaterTint].
  final Color repeater, onRepeater;

  /// The soft fill behind a repeater icon (avatar circle, row badge): [repeater] at low strength, already blended for
  /// this theme's surface, so it needs no `withValues(alpha:)`.
  final Color repeaterTint;

  /// "No reply" (a ping nobody answered, a cell with no coverage): a neutral dark slate, so it no longer sits next to
  /// the red Edge band as a second red. Not a signal band.
  final Color noReply;

  /// The tapped-repeater / tapped-cell link line: white, drawn over [linkNeutralCasing] so it shows on any base map
  /// and is never a signal hue (the old line was orange, the Weak band's family).
  final Color linkNeutral, linkNeutralCasing;

  /// Friend pins (MeshTrack). Magenta, so a friend is never mistaken for your own position (teal). [onFriend] is the
  /// initials or glyph on the pin. (Close to the TXT_MSG packet orchid by hue; a pin with initials and a packet line
  /// are told apart by shape.)
  final Color friend, onFriend;

  /// Percent heard, low (first) to high (last): one teal hue, five steps. Use for heard %, "Best spot", heard per
  /// week and the hop mix tints. Never the signal ramp. 0 % itself is [noReply].
  final List<Color> heardStops;

  /// Packet types, moved off the Standard palette's signal hues (no red, orange, amber, yellow or green). Slot order
  /// is `packetTypeSlot`: ADVERT, GRP_TXT, TXT_MSG, ACK, RESPONSE, TRACE, PATH, REQ. [packetOther] is every other type.
  /// The colours a user sees today come from the Map Definition's `packetTypes` (shared with the website); these are
  /// the values that list should carry, and the built-in fallback for it.
  final List<Color> packetTypes;
  final Color packetOther;

  const ColourLanguage({
    required this.warning,
    required this.onWarning,
    required this.repeater,
    required this.onRepeater,
    required this.repeaterTint,
    required this.noReply,
    required this.linkNeutral,
    required this.linkNeutralCasing,
    required this.friend,
    required this.onFriend,
    required this.heardStops,
    required this.packetTypes,
    required this.packetOther,
  });

  static ColourLanguage of(Brightness b) => b == Brightness.dark ? dark : light;

  static const ColourLanguage dark = ColourLanguage(
    warning: Color(0xFFFFA14A),
    onWarning: Color(0xFF2A1700),
    repeater: Color(0xFFB4C6D0),
    onRepeater: Color(0xFF0C1E28),
    repeaterTint: Color(0xFF24394A),
    noReply: Color(0xFF35425D),
    linkNeutral: Color(0xFFFFFFFF),
    linkNeutralCasing: Color(0xD9081219),
    friend: Color(0xFFFF7AD9),
    onFriend: Color(0xFF3A0030),
    heardStops: [Color(0xFF1B5A56), Color(0xFF1F7C75), Color(0xFF27A096), Color(0xFF31C2B4), Color(0xFF3EE0CF)],
    packetTypes: [
      Color(0xFF3987E5), // ADVERT    blue
      Color(0xFF5CC8F0), // GRP_TXT   sky
      Color(0xFFE08AF0), // TXT_MSG   orchid
      Color(0xFF9FB3C8), // ACK       slate
      Color(0xFFD55181), // RESPONSE  pink
      Color(0xFFE6ECF2), // TRACE     near white
      Color(0xFF8478F0), // PATH      violet
      Color(0xFFB9AFA6), // REQ       stone
    ],
    packetOther: Color(0xFF8A929B),
  );

  static const ColourLanguage light = ColourLanguage(
    warning: Color(0xFFA14B00),
    onWarning: Color(0xFFFFFFFF),
    repeater: Color(0xFF3F5663),
    onRepeater: Color(0xFFFFFFFF),
    repeaterTint: Color(0xFFDDE5EA),
    noReply: Color(0xFF0E1B2B),
    linkNeutral: Color(0xFFFFFFFF),
    linkNeutralCasing: Color(0xD90C1E28),
    friend: Color(0xFFB4238F),
    onFriend: Color(0xFFFFFFFF),
    heardStops: [Color(0xFFBFE9E2), Color(0xFF86D3C8), Color(0xFF45B3A6), Color(0xFF14948A), Color(0xFF00796E)],
    packetTypes: [
      Color(0xFF2A78D6), // ADVERT    blue
      Color(0xFF0A86B0), // GRP_TXT   sky
      Color(0xFFA53FC4), // TXT_MSG   orchid
      Color(0xFF5A6F85), // ACK       slate
      Color(0xFFD9457F), // RESPONSE  pink
      Color(0xFF2B3A47), // TRACE     near black
      Color(0xFF5B49D6), // PATH      violet
      Color(0xFF625348), // REQ       stone
    ],
    packetOther: Color(0xFF6F7780),
  );
}

// ------------------------------------------------------- strength palettes
// The colours that mean "how strong was the signal", per ColourPalette and brightness. They come from the Map Definition
// (`palettes[].themes[theme]`, served by /api/map/definition, bundled copy = the M1 fixture); no hex is written here.
// test/lint/no_signal_colours_test.dart fails if any signal colour of the definition appears in lib/ outside the generated
// bundled copy.
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

/// The strength colours of [p] on [b], read from the Map Definition (plan unified-map-system §2.2, M2: no signal colour is
/// hand-copied into the app). One 5-band SNR scale everywhere (§2.5): the older 4-step network levels are the bands
/// Excellent / Good / Fair / Edge, the ping SNR ramp runs Edge -> Excellent over -10..+10 dB, a ping nobody answered is the
/// No-reply colour and a heard ping without an SNR is band 6 ("Heard, no direct signal"); link lines are the palette's link
/// style (orange and solid in Standard, achromatic and dashed in Colour-blind safe).
_Strength _strengthFor(ColourPalette p, Brightness b, MapDefinition def) {
  final s = def.signal(p.id, dark: b == Brightness.dark);
  Color band(int i) => Color(s.bands[i.clamp(0, s.bands.length - 1)]);
  return _Strength(
    strong: band(5),
    good: band(4),
    fair: band(3),
    weak: band(1),
    stops: [band(1), band(2), band(3), band(4), band(5)],
    silent: band(0),
    heardUnknown: band(6),
    link: Color(s.link.color),
    linkCasing: Color(s.link.casing).withValues(alpha: s.link.casingOpacity),
    linkDashed: s.link.dash != null,
  );
}

/// Colours beyond the Material scheme: signal quality, repeaters, and the map. The strength colours follow the chosen
/// [ColourPalette] (Settings > Units & display > Colour palette); call sites read them from here and never hardcode a hex.
@immutable
class MeshSonarColors extends ThemeExtension<MeshSonarColors> {
  /// Which palette these strength colours belong to.
  final ColourPalette palette;

  /// The OLD repeater amber. Build 77: amber means a warning only, so do not use this in new code. A repeater takes
  /// [repeater]; a warning takes [warning]. Kept, with its old value, until every call site has moved.
  final Color beacon;
  final Color onBeacon;

  /// The build 77 colour language for this theme (see [ColourLanguage]); the getters below are the usual way in.
  final ColourLanguage language;

  /// Your pings' SNR scale for pings that were heard: equally spaced stops from -10 dB (first) to +10 dB (last).
  final List<Color> snrStops;

  /// Network coverage steps (CoverageLevel.strong/good/fair/weak): SNR >= +5, 0 to +5, -5 to 0, below -5 dB.
  final Color levelStrong, levelGood, levelFair, levelWeak;

  /// A ping that heard nothing: the definition's No-reply colour (band 0).
  final Color silent;

  /// A ping that was heard but whose signal strength is unknown.
  final Color heardUnknown;

  /// Link lines (a tapped repeater or cell), their casing, and whether they are dashed. Orange and solid in the standard
  /// palette; achromatic and dashed in the accessible palettes so they never blur into orange/yellow strength colours.
  final Color linkLine, linkLineCasing;
  final bool linkLineDashed;

  /// Map canvas under the tiles (what you see offline).
  final Color mapBackground;

  /// The chart grid drawn on the map background.
  final Color mapGrid;

  /// Applied to OSM tiles so the base map sits quietly under the data.
  final List<double> tileMatrix;

  /// Secondary text.
  final Color textMuted;

  const MeshSonarColors({
    this.palette = ColourPalette.standard,
    required this.beacon,
    required this.onBeacon,
    required this.language,
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

  /// Warnings only: the one amber in the app. [onWarning] sits on a solid warning fill.
  Color get warning => language.warning;
  Color get onWarning => language.onWarning;

  /// Repeaters (icons, bars, rank numbers, chips): neutral slate, not amber. [repeaterTint] is the soft badge fill.
  Color get repeater => language.repeater;
  Color get onRepeater => language.onRepeater;
  Color get repeaterTint => language.repeaterTint;

  /// "No reply" as a neutral dark slate (not the red definition band [silent]).
  Color get noReply => language.noReply;

  /// The white link line and its dark casing (not the orange definition line [linkLine]).
  Color get linkNeutral => language.linkNeutral;
  Color get linkNeutralCasing => language.linkNeutralCasing;

  /// Friend pins: magenta, distinct from your own position (teal).
  Color get friend => language.friend;
  Color get onFriend => language.onFriend;

  /// Percent heard, low to high, in one teal hue; see [heardAt].
  List<Color> get heardStops => language.heardStops;

  /// The percent-heard teal at [fraction] (0 = lowest step, 1 = everything heard). Not a signal colour.
  Color heardAt(double fraction) {
    final s = heardStops;
    final x = (fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0)) * (s.length - 1);
    final i = x.floor().clamp(0, s.length - 2);
    return Color.lerp(s[i], s[i + 1], x - i)!;
  }

  /// The packet type colour for palette slot [slot] (`packetTypeSlot`); null or out of range = "Other". Off the signal
  /// hues, so a packet never reads as good / weak / bad next to coverage.
  Color packetType(int? slot) =>
      slot == null || slot < 0 || slot >= language.packetTypes.length ? language.packetOther : language.packetTypes[slot];

  /// Weakest, a middle and strongest anchor of the SNR scale (charts and gradients that want three colours).
  Color get snrWeak => snrStops.first;
  Color get snrMid => snrStops[snrStops.length ~/ 2];
  Color get snrStrong => snrStops.last;

  static MeshSonarColors of(BuildContext context) =>
      Theme.of(context).extension<MeshSonarColors>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  static final MeshSonarColors dark = forPalette(ColourPalette.standard, Brightness.dark);
  static final MeshSonarColors light = forPalette(ColourPalette.standard, Brightness.light);

  /// The colours for [palette] on the dark or light theme.
  static MeshSonarColors forPalette(ColourPalette palette, Brightness b, {MapDefinition? definition}) =>
      _fromPalette(b == Brightness.dark ? _dark : _light, _strengthFor(palette, b, definition ?? ActiveMapDefinition.current), palette);

  static MeshSonarColors _fromPalette(_Palette p, _Strength st, ColourPalette palette) => MeshSonarColors(
    palette: palette,
    beacon: p.beacon,
    onBeacon: p.onBeacon,
    language: identical(p, _dark) ? ColourLanguage.dark : ColourLanguage.light,
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
    language: language,
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
      language: t < 0.5 ? language : other.language,
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
      fontSize: size,
      height: 1.0,
      fontWeight: weight,
      color: color ?? Theme.of(context).colorScheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

ThemeData meshSonarTheme(Brightness b, {ColourPalette palette = ColourPalette.standard, MapDefinition? definition}) {
  final p = b == Brightness.dark ? _dark : _light;
  final mc = MeshSonarColors.forPalette(palette, b, definition: definition);
  final scheme = ColorScheme(
    brightness: b,
    primary: p.accent,
    onPrimary: p.onAccent,
    primaryContainer: p.accentContainer,
    onPrimaryContainer: p.onAccentContainer,
    // Build 77 (S4 / N-V3): the secondary container is what Material paints behind every SELECTED control (segments,
    // filter and choice chips), tonal buttons and the status strip. It used to be a blend of the amber, so selection
    // read as a warning. It is now the teal container; amber is only `MeshSonarColors.warning`.
    // `secondary` itself keeps the old amber until its last call sites have moved (it is not a selection colour).
    secondary: p.beacon,
    onSecondary: p.onBeacon,
    secondaryContainer: p.accentContainer,
    onSecondaryContainer: p.onAccentContainer,
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

  final base = ThemeData(useMaterial3: true, brightness: b, colorScheme: scheme);
  final tt = base.textTheme;
  TextStyle? num(TextStyle? s, double size) =>
      s?.copyWith(fontSize: size, fontWeight: FontWeight.w700, height: 1.05, fontFeatures: AppType.tabular);
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
  final tracked = AppType.withTracking(text);

  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Corners.button));
  const buttonText = TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 0.1);

  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    textTheme: tracked,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),
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
    // Selected segment = teal, stated here as well as through the scheme so it cannot drift (S4, D-16).
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.accentContainer : null,
        ),
        foregroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return null;
          return s.contains(WidgetState.selected) ? p.onAccentContainer : p.text;
        }),
        iconColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return null;
          return s.contains(WidgetState.selected) ? p.onAccentContainer : p.text;
        }),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.surfaceHigh,
      // Selected chip = teal on every tab (N-V3).
      selectedColor: p.accentContainer,
      secondarySelectedColor: p.accentContainer,
      checkmarkColor: p.onAccentContainer,
      secondaryLabelStyle: text.labelLarge?.copyWith(color: p.onAccentContainer),
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
      contentTextStyle: TextStyle(color: p.bg, fontSize: 16, fontWeight: FontWeight.w500),
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
