// Small formatting helpers shared by the chat screens: delivery wording, days, times, links and mentions.
import 'dart:convert';

import 'package:flutter/material.dart';


String two(int n) => n.toString().padLeft(2, '0');

DateTime dayOf(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime(d.year, d.month, d.day);
}

String dayLabel(BuildContext context, int ms, {DateTime? now}) {
  final today = dayOf((now ?? DateTime.now()).millisecondsSinceEpoch);
  final d = dayOf(ms);
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return MaterialLocalizations.of(context).formatMediumDate(d);
}

String timeLabel(BuildContext context, int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
}

/// The centred separator above a group: "Today 9:38", "Yesterday 21:02", "Mon 9:38" within a week, else "Oct 28, 9:38".
String separatorLabel(BuildContext context, int ms, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final diff = dayOf(n.millisecondsSinceEpoch).difference(dayOf(ms)).inDays;
  final t = timeLabel(context, ms);
  if (diff <= 0) return 'Today $t';
  if (diff == 1) return 'Yesterday $t';
  if (diff < 7) return '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][DateTime.fromMillisecondsSinceEpoch(ms).weekday - 1]} $t';
  return '${MaterialLocalizations.of(context).formatShortDate(DateTime.fromMillisecondsSinceEpoch(ms))}, $t';
}

/// Short stamp for list rows: time today, "Yesterday", weekday this week, else a date.
String listStamp(BuildContext context, int? ms, {DateTime? now}) {
  if (ms == null) return '';
  final n = now ?? DateTime.now();
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = dayOf(n.millisecondsSinceEpoch).difference(dayOf(ms)).inDays;
  if (diff <= 0) return timeLabel(context, ms);
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];
  return MaterialLocalizations.of(context).formatShortDate(d);
}

int utf8Len(String s) => utf8.encode(s).length;

/// Pieces of a message: plain text, a link, or a mention.
enum PartKind { text, url, meshLink, mention }

class TextPart {
  final PartKind kind;
  final String text;
  const TextPart(this.kind, this.text);
}

final RegExp _partRe = RegExp(r'(https?://[^\s<>"]+|meshcore://[^\s<>"]+|@\[[^\]\n]{1,40}\])', caseSensitive: false);

/// Splits [s] into text, links and `@[name]` mentions. Trailing punctuation is not part of a link.
List<TextPart> splitMessage(String s) {
  final out = <TextPart>[];
  var last = 0;
  for (final m in _partRe.allMatches(s)) {
    if (m.start > last) out.add(TextPart(PartKind.text, s.substring(last, m.start)));
    var t = m.group(0)!;
    var tail = '';
    if (!t.startsWith('@[')) {
      final trim = RegExp(r'[.,;:!?)\]]+$').firstMatch(t);
      if (trim != null) {
        tail = trim.group(0)!;
        t = t.substring(0, t.length - tail.length);
      }
    }
    final kind = t.startsWith('@[') ? PartKind.mention : (t.toLowerCase().startsWith('meshcore://') ? PartKind.meshLink : PartKind.url);
    out.add(TextPart(kind, t));
    if (tail.isNotEmpty) out.add(TextPart(PartKind.text, tail));
    last = m.end;
  }
  if (last < s.length) out.add(TextPart(PartKind.text, s.substring(last)));
  return out;
}

/// "@[Name]" -> "@Name" for display.
String mentionLabel(String raw) => '@${raw.substring(2, raw.length - 1)}';

bool mentionsMe(String text, String? me) => me != null && me.isNotEmpty && text.toLowerCase().contains('@[${me.toLowerCase()}]');
