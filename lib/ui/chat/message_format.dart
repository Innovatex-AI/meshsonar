// Small formatting helpers shared by the chat screens: delivery wording, days, times, links and mentions.
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../chat/models.dart';

/// What a person reads under an outgoing message. [dueInMs] is how long until the outbox tries it again (null if unknown).
class DeliveryView {
  final IconData icon;
  final String label;

  /// Longer sentence for screen readers and the details sheet.
  final String detail;
  final bool failed;
  final bool pending;
  const DeliveryView(this.icon, this.label, this.detail, {this.failed = false, this.pending = false});
}

DeliveryView deliveryOf(ChatMessage m, {int? dueInMs, required bool radioConnected}) {
  final isChannel = m.convKind == ConvKind.channel;
  switch (m.state) {
    case MessageState.queued:
      if (!radioConnected) {
        return const DeliveryView(Icons.schedule_rounded, 'Waiting for the radio', 'Waiting for the radio to connect. It will be sent when it does.', pending: true);
      }
      if (dueInMs != null && dueInMs > 800) {
        final s = (dueInMs / 1000).ceil();
        return DeliveryView(Icons.schedule_rounded, 'Queued, sending in $s s', 'Queued. The radio is busy, so this message goes out in about $s seconds.', pending: true);
      }
      return const DeliveryView(Icons.schedule_rounded, 'Queued', 'Queued, sending now.', pending: true);
    case MessageState.sending:
      return const DeliveryView(Icons.north_east_rounded, 'Sending', 'Sending to the radio.', pending: true);
    case MessageState.retrying:
      final s = dueInMs == null ? null : (dueInMs / 1000).ceil();
      return DeliveryView(Icons.refresh_rounded, s == null || s <= 0 ? 'Trying again' : 'Trying again in $s s',
          'No confirmation yet. Trying again (attempt ${m.attempt + 1}).',
          pending: true);
    case MessageState.sent:
      return isChannel
          ? const DeliveryView(Icons.check_rounded, 'Sent', 'Sent by the radio. No repeater has been heard repeating it yet.')
          : const DeliveryView(Icons.check_rounded, 'Sent, waiting for confirmation', 'Sent by the radio. Waiting for the other side to confirm.');
    case MessageState.heard:
      final n = m.repeatsHeard;
      final lbl = n <= 1 ? 'Heard by 1 repeater' : 'Heard by $n repeaters';
      return DeliveryView(Icons.cell_tower_rounded, lbl, '$lbl: it is on the air and was repeated.');
    case MessageState.acked:
      final ms = m.ackMs;
      return DeliveryView(Icons.done_all_rounded, 'Delivered', ms == null ? 'Delivered. The other side confirmed.' : 'Delivered. Confirmed after ${(ms / 1000).toStringAsFixed(1)} s.');
    case MessageState.failed:
      final why = m.failReason?.describe() ?? 'It could not be sent.';
      return DeliveryView(Icons.error_outline_rounded, 'Not sent', 'Not sent. $why', failed: true);
    case MessageState.received:
      return const DeliveryView(Icons.check_rounded, '', '');
  }
}

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
