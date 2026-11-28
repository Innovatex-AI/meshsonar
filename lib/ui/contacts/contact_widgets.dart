// Small pieces every Contacts screen shares: the avatar, the type words and icons, the "heard 5 min ago" text.
import 'package:flutter/material.dart';

import '../../chat/models.dart';
import '../../core/time_format.dart' as tf;
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
/// (the route the radio holds), "No route yet". The radio decides direct or flood for each message (build 77).
String routeCaption(Contact c) {
  if (!c.hasPath) return 'No route yet';
  final n = c.pathHops ?? 0;
  if (n == 0) return 'Direct';
  return 'Via $n ${n == 1 ? 'repeater' : 'repeaters'}';
}

/// "Heard just now", "Heard 5 min ago", "Heard 3 h ago", "Heard 12 d ago", "Not heard yet" (the one app time formatter).
String heardText(int? ms, int nowMs) {
  if (ms == null || ms <= 0) return 'Not heard yet';
  return 'Heard ${tf.relativeTime(DateTime.fromMillisecondsSinceEpoch(ms), now: DateTime.fromMillisecondsSinceEpoch(nowMs))}';
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
