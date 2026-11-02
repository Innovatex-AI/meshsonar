// Map-specific tokens (Drive plan 3.2 and 6.3). Repeater freshness colours are deliberately palette-independent
// (Okabe-Ito derived) and differ from the signal ramp; the tower glyph plus white ring is the repeater signature.
import 'package:flutter/material.dart';

abstract final class MapTokens {
  /// Ink for map text and glyphs, and the halo behind it.
  static Color mapInk(Brightness b) => b == Brightness.dark ? const Color(0xFFF4F6F8) : const Color(0xFF1B1F24);
  static Color mapHalo(Brightness b) => b == Brightness.dark ? const Color(0xFF12161B) : const Color(0xFFFFFFFF);

  /// Fresh (advert <= 24 h): solid fill. Light `#0072B2` with white glyph, dark `#56B4E9` with `#12161B`.
  static Color repeaterFresh(Brightness b) => b == Brightness.dark ? const Color(0xFF56B4E9) : const Color(0xFF0072B2);

  /// Recent (<= 7 d): 35% tint, 2 pt ring. Light `#B35C00`, dark `#F0A92E`.
  static Color repeaterAging(Brightness b) => b == Brightness.dark ? const Color(0xFFF0A92E) : const Color(0xFFB35C00);

  /// Stale (> 7 d or never): hollow, dashed ring. Light `#6B7280`, dark `#9CA3AF`.
  static Color repeaterStale(Brightness b) => b == Brightness.dark ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280);

  /// Glyph colour on the fresh / recent / stale fill: white in light, `#12161B` in dark.
  static Color repeaterGlyph(Brightness b) => b == Brightness.dark ? const Color(0xFF12161B) : const Color(0xFFFFFFFF);

  /// Land colour of the light base map and the dark chart colour the contrast table is computed against.
  static const Color landLight = Color(0xFFF2EFE9);
  static const Color chartDark = Color(0xFF2B2F36);
}
