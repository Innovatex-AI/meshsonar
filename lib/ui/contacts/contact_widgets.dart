// Small pieces every Contacts screen shares: the avatar, the type words and icons, the "heard 5 min ago" text.
import 'package:flutter/material.dart';

import '../../chat/models.dart';
import '../design/app_symbols.dart';
import '../design/avatar_style.dart';
import '../design/tokens.dart';

String contactTypeLabel(ContactType t) => switch (t) {
      ContactType.companion => 'Person',
      ContactType.repeater => 'Repeater',
      ContactType.room => 'Room',
      ContactType.sensor => 'Sensor',
    };

AppSymbol contactTypeSymbol(ContactType t) => switch (t) {
      ContactType.companion => AppSymbols.personFill,
      ContactType.repeater => AppSymbols.antenna,
      ContactType.room => AppSymbols.person2Fill,
      ContactType.sensor => AppSymbols.thermometer,
    };

/// How messages reach the contact, in the app-wide words (plan 2.1): "Direct" (no repeater between), "Via 2 repeaters"
/// (a saved route), "Searching" (every message goes to everyone nearby), "No route yet".
String routeCaption(Contact c) {
  if (c.forceFlood) return 'Searching';
  if (!c.hasPath) return 'No route yet';
  final n = c.pathHops ?? 0;
  if (n == 0) return 'Direct';
  return 'Via $n ${n == 1 ? 'repeater' : 'repeaters'}';
}

/// "just now", "5 min ago", "3 h ago", "yesterday", "12 days ago", "never heard".
String heardText(int? ms, int nowMs) {
  if (ms == null || ms <= 0) return 'Not heard yet';
  final d = nowMs - ms;
  if (d < 90 * 1000) return 'Heard just now';
  final min = d ~/ 60000;
  if (min < 60) return 'Heard $min min ago';
  final h = d ~/ 3600000;
  if (h < 24) return 'Heard $h h ago';
  final days = d ~/ 86400000;
  if (days == 1) return 'Heard yesterday';
  return 'Heard $days days ago';
}

/// Initials on a coloured disc (colour from the key via [avatarStyle], so a contact keeps its colour and the initials
/// always read at 4.5:1); repeaters, rooms and sensors show their type symbol instead.
class ContactAvatar extends StatelessWidget {
  final Contact contact;
  final double size;
  const ContactAvatar(this.contact, {super.key, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final style = avatarStyle(contact.publicKey, AppColors.of(context));
    final person = contact.type == ContactType.companion;
    final name = contact.displayName.trim();
    final letter = name.isEmpty ? '?' : String.fromCharCode(name.runes.first).toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: style.fill, shape: BoxShape.circle),
        child: person
            ? Text(letter, textScaler: TextScaler.noScaling, style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w600, color: style.initials))
            : AppSymbolIcon(contactTypeSymbol(contact.type), size: size * 0.5, color: style.initials, scaleWithText: false),
      ),
    );
  }
}
