// Small pieces every Contacts screen shares: the avatar, the type words and icons, the "heard 5 min ago" text.
import 'package:flutter/material.dart';

import '../../chat/models.dart';

String contactTypeLabel(ContactType t) => switch (t) {
      ContactType.companion => 'Person',
      ContactType.repeater => 'Repeater',
      ContactType.room => 'Room',
      ContactType.sensor => 'Sensor',
    };

IconData contactTypeIcon(ContactType t) => switch (t) {
      ContactType.companion => Icons.person_rounded,
      ContactType.repeater => Icons.cell_tower_rounded,
      ContactType.room => Icons.forum_rounded,
      ContactType.sensor => Icons.sensors_rounded,
    };

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

/// First letter of the name on a coloured disc (colour from the key, so a contact keeps its colour); repeaters, rooms and
/// sensors show their type icon instead.
class ContactAvatar extends StatelessWidget {
  final Contact contact;
  final double size;
  const ContactAvatar(this.contact, {super.key, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final hue = (int.tryParse(contact.publicKey.substring(0, 4), radix: 16) ?? 0) % 360;
    final dark = t.brightness == Brightness.dark;
    final bg = HSLColor.fromAHSL(1, hue.toDouble(), 0.45, dark ? 0.30 : 0.82).toColor();
    final fg = HSLColor.fromAHSL(1, hue.toDouble(), 0.5, dark ? 0.85 : 0.25).toColor();
    final person = contact.type == ContactType.companion;
    final name = contact.displayName.trim();
    final letter = name.isEmpty ? '?' : String.fromCharCode(name.runes.first).toUpperCase();
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: size / 2,
        backgroundColor: bg,
        foregroundColor: fg,
        child: person ? Text(letter, style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w600)) : Icon(contactTypeIcon(contact.type), size: size * 0.5),
      ),
    );
  }
}
