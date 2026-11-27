// Map-specific tokens (Drive plan 3.2 and 6.3). Repeater freshness colours are deliberately palette-independent
// (Okabe-Ito derived) and differ from the signal ramp; the tower glyph plus white ring is the repeater signature.
import 'package:flutter/material.dart';

import '../theme.dart' show ColourLanguage;

abstract final class MapTokens {
  /// Ink for map text and glyphs, and the halo behind it.
  static Color mapInk(Brightness b) => b == Brightness.dark ? const Color(0xFFF4F6F8) : const Color(0xFF1B1F24);
  static Color mapHalo(Brightness b) => b == Brightness.dark ? const Color(0xFF12161B) : const Color(0xFFFFFFFF);

  /// Fresh (heard <= 24 h): the repeater colour at full strength (build 77 colour language: a neutral slate, never amber).
  static Color repeaterFresh(Brightness b) => ColourLanguage.of(b).repeater;

  /// Recent (<= 7 d): the same repeater colour, faded toward the map (15 % toward the land colour in light, 30 % toward the chart colour in dark), solid so it
  /// keeps 3:1 against the map and a 4.5:1 cluster count (build 77: freshness is not a warning, so it is no longer amber).
  static Color repeaterAging(Brightness b) => b == Brightness.dark ? const Color(0xFF8A98A1) : const Color(0xFF596C77);

  /// Stale (> 7 d or never): hollow, dashed ring. Light `#6B7280`, dark `#9CA3AF`.
  static Color repeaterStale(Brightness b) => b == Brightness.dark ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280);

  /// The credit pill (build 77, Round 1 decision 5): a small dark pill on a dark map, a light one on a light map, whatever the
  /// app theme (a Light map in a dark-theme app gets the light pill). [creditInk] is its text and (i).
  static Color creditPill({required bool darkMap}) => darkMap ? const Color(0xD912161B) : const Color(0xE6FFFFFF);
  static Color creditInk({required bool darkMap}) => darkMap ? const Color(0xFFE6EAEE) : const Color(0xFF1B1F24);

  /// Land colour of the light base map the contrast table is computed against.
  static const Color landLight = Color(0xFFF2EFE9);
}
