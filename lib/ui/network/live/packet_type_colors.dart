// The packet type palette (AZ-3.3): one colour per type, the same on the site and in the app. Slot order ADVERT, GRP_TXT,
// TXT_MSG, ACK, RESPONSE, TRACE, PATH, REQ, anything else "Other".
import 'package:flutter/material.dart';

import '../../../core/map_definition_v2.dart';
import '../../map/active_map_definition.dart';
import '../../theme.dart' show ColourLanguage;

// Build 77 (Round 1 N4): the colours moved off the signal hues (no red, orange, amber, yellow or green next to coverage). The
// built-in list is the app's colour language (ui/theme.dart ColourLanguage.packetTypes), which the Map Definition's
// `packetTypes` carries from schemaMinor 10 (test/core/map_definition_v2_test.dart pins the two equal).
Color _builtIn(int? slot, Brightness b) {
  final l = ColourLanguage.of(b);
  return slot == null || slot >= l.packetTypes.length ? l.packetOther : l.packetTypes[slot];
}

/// The palette slot (0-based) of a packet type number; null = "Other".
int? packetTypeSlot(int type) => switch (type) {
      4 => 0, // ADVERT
      5 => 1, // GRP_TXT
      2 => 2, // TXT_MSG
      3 => 3, // ACK
      1 => 4, // RESPONSE
      9 => 5, // TRACE
      8 => 6, // PATH
      0 => 7, // REQ
      _ => null,
    };

/// The colour of packet type [type] for [brightness].
///
/// MAP slice 3: the colours come from the Map Definition's `packetTypes` (one list for Live, the feed, the packets table and the
/// charts on the site and in the app); the built-in list below is what that list said on Nov 22 2026 and is used when the
/// definition in use has none. A test pins the two equal.
Color packetTypeColorFor(int type, Brightness brightness) {
  final def = ActiveMapDefinition.current.packetTypes;
  if (def != null) {
    final c = def.of(type);
    return Color(brightness == Brightness.dark ? c.dark : c.light);
  }
  return _builtIn(packetTypeSlot(type), brightness);
}

Color packetTypeColor(BuildContext context, int type) => packetTypeColorFor(type, Theme.of(context).brightness);

/// The types the filter offers, in the palette's order, then "Other" types that are common enough to name.
const List<int> livePacketTypes = [4, 5, 2, 3, 1, 9, 8, 0, 6, 7, 10, 11];

/// The ghost-hop colour (unresolved hops): the palette's "Other" grey.
Color ghostColor(BuildContext context) => ColourLanguage.of(Theme.of(context).brightness).packetOther;
