// Which colour set the app draws signal strength in. Pure Dart so Settings can persist it; the actual hex values live in
// lib/ui/theme.dart (MeshSonarColors) and are written down in docs/FEATURES.md and the infra colour-palettes note, which
// the website copies.
enum ColourPalette {
  /// Red -> yellow -> green for coverage, your pings and the older network steps (Nov 8 2026; no blue since build 51).
  standard('standard', 'Standard'),

  /// Safe for deuteranopia, protanopia and tritanopia: blue to yellow to orange, never red against green.
  colourBlind('colour_blind', 'Colour-blind safe');

  /// The value stored in settings.json and used by the website (`?palette=`).
  final String id;
  final String label;
  const ColourPalette(this.id, this.label);

  /// The retired High contrast palette's id (removed Nov 8 2026, unified map plan M0: Andy wants Standard + one
  /// colour-blind-safe option only). A settings file that still says it loads as [colourBlind], the nearest choice (it was
  /// colour-blind safe too), and is saved back as `colour_blind` the next time settings are written.
  static const String retiredHighContrastId = 'high_contrast';

  /// Unknown or missing values (an older settings file, a newer app's choice) fall back to [standard]; the retired
  /// `high_contrast` maps to [colourBlind].
  static ColourPalette parse(Object? v) => v == retiredHighContrastId
      ? ColourPalette.colourBlind
      : ColourPalette.values.firstWhere((p) => p.id == v, orElse: () => ColourPalette.standard);
}
