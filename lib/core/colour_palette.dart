// Which colour set the app draws signal strength in. Pure Dart so Settings can persist it; the actual hex values live in
// lib/ui/theme.dart (MeshSonarColors) and are written down in docs/FEATURES.md and the infra colour-palettes note, which
// the website copies.
enum ColourPalette {
  /// Blue / teal / green SNR scale for your pings; green / blue / amber / red for network coverage steps.
  standard('standard', 'Standard'),

  /// Safe for deuteranopia, protanopia and tritanopia: blue to yellow to orange, never red against green.
  colourBlind('colour_blind', 'Colour-blind safe'),

  /// Maximum separation between steps and against the map, still colour-blind safe.
  highContrast('high_contrast', 'High contrast');

  /// The value stored in settings.json and used by the website (`?palette=`).
  final String id;
  final String label;
  const ColourPalette(this.id, this.label);

  /// Unknown or missing values (an older settings file, a newer app's choice) fall back to [standard].
  static ColourPalette parse(Object? v) =>
      ColourPalette.values.firstWhere((p) => p.id == v, orElse: () => ColourPalette.standard);
}
