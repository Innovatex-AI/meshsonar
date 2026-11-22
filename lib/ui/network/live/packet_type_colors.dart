// The packet type palette (AZ-3.3), the same colours as the website's (meshcore-insights
// src/components/region/ui/chart-palette.ts PACKET_TYPE_COLOR over src/styles/region-ui.css --rc-pkt-*, PALETTE_HEX):
// ADVERT cat-1, GRP_TXT cat-2, TXT_MSG cat-3, ACK cat-4, RESPONSE cat-5, TRACE cat-6, PATH cat-7, REQ cat-8, anything
// else "Other". Light and dark values copied exactly, so a packet is the same colour on the site and in the app.
import 'package:flutter/material.dart';

import '../../../core/map_definition_v2.dart';
import '../../map/active_map_definition.dart';

const List<Color> _catLight = [
  Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A), Color(0xFFEDA100), //
  Color(0xFFE87BA4), Color(0xFF008300), Color(0xFF6250D6), Color(0xFFE34948),
];
const List<Color> _catDark = [
  Color(0xFF3987E5), Color(0xFFD95926), Color(0xFF199E70), Color(0xFFC98500), //
  Color(0xFFD55181), Color(0xFF008300), Color(0xFF9085E9), Color(0xFFE66767),
];
const Color _otherLight = Color(0xFF6F7780);
const Color _otherDark = Color(0xFF8A929B);

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
  final slot = packetTypeSlot(type);
  final dark = brightness == Brightness.dark;
  if (slot == null) return dark ? _otherDark : _otherLight;
  return (dark ? _catDark : _catLight)[slot];
}

Color packetTypeColor(BuildContext context, int type) => packetTypeColorFor(type, Theme.of(context).brightness);

/// The types the filter offers, in the palette's order, then "Other" types that are common enough to name.
const List<int> livePacketTypes = [4, 5, 2, 3, 1, 9, 8, 0, 6, 7, 10, 11];

/// The ghost-hop colour (unresolved hops): the palette's "Other" grey.
Color ghostColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? _otherDark : _otherLight;
