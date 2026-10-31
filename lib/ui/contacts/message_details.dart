// Message details for one message: who, when, how it travelled, every try and why it failed. Plain language, no raw
// milliseconds. Agent 2A's conversation screen calls [showMessageDetails] from a message's long-press menu ("Details").
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_service.dart';
import '../../chat/db/outbox_repository.dart';
import '../../chat/delivery_text.dart';
import '../../chat/models.dart';
import '../theme.dart';

/// Opens the details of one message (bottom sheet on phones, dialog on wide screens).
Future<void> showMessageDetails(BuildContext context, {required ChatService chat, required String messageId}) async {
  final wide = MediaQuery.sizeOf(context).width >= 700;
  Widget body(BuildContext c) => MessageDetails(chat: chat, messageId: messageId);
  if (wide) {
    await showDialog<void>(
      context: context,
      builder: (c) => Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640), child: body(c))),
    );
  } else {
    await showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (c) => SafeArea(child: body(c)));
  }
}

String _clock(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

String _day(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${_clock(ms)}';
}

String _secs(int ms) {
  if (ms < 950) return '$ms ms';
  final s = ms / 1000;
  return s < 10 ? '${s.toStringAsFixed(1)} s' : '${s.round()} s';
}

/// SNR in plain words (LoRa SF7-SF8 decodes down to about -7 dB).
String snrWord(double snr) => snr >= 5 ? 'strong' : (snr >= -2 ? 'ok' : 'weak');

class MessageDetails extends StatefulWidget {
  final ChatService chat;
  final String messageId;
  const MessageDetails({super.key, required this.chat, required this.messageId});

  @override
  State<MessageDetails> createState() => _MessageDetailsState();
}

class _MessageDetailsState extends State<MessageDetails> {
  @override
  void initState() {
    super.initState();
    widget.chat.events.listen((e) {
      if (mounted && e.messageId == widget.messageId) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = widget.chat.store.messages.get(widget.messageId);
    if (m == null) {
      return const Padding(padding: EdgeInsets.all(Gap.xl), child: Text('This message is gone.', key: Key('details-gone')));
    }
    final store = widget.chat.store;
    final isDm = m.convKind == ConvKind.dm || m.convKind == ConvKind.room;
    final contact = isDm ? store.contacts.byPrefix(m.radioId, ConvKey.body(m.convKey)) : null;
    final who = m.isOutgoing ? (isDm ? 'To ${contact?.displayName ?? 'unknown contact'}' : 'Sent by you') : 'From ${m.senderName ?? contact?.displayName ?? 'unknown sender'}';
    final attempts = m.isOutgoing && isDm ? store.outbox.attemptsFor(m.id) : const <DeliveryAttempt>[];
    final rows = <(String, String)>[
      (m.isOutgoing ? 'Sent at' : 'Received at', _day(m.tsLocalMs)),
      if (!m.isOutgoing) ('Their clock said', _day(m.tsSender * 1000)),
      if (m.isOutgoing) ('Status', deliveryLabel(m)),
      ..._travel(m),
      ('Size', '${utf8.encode(m.text).length} bytes'),
      if (m.convKind == ConvKind.channel && m.isOutgoing) ('Repeats', m.repeatsHeard == 0 ? 'Not heard repeated yet' : 'Heard by ${m.repeatsHeard} ${m.repeatsHeard == 1 ? 'repeater' : 'repeaters'}'),
    ];
    return ListView(
      key: const Key('message-details'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
      children: [
        Semantics(header: true, child: Text(who, style: t.textTheme.titleMedium)),
        const SizedBox(height: Gap.s),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Gap.m),
          decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.small)),
          child: Text(m.text, key: const Key('details-text')),
        ),
        const SizedBox(height: Gap.m),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Wrap(spacing: Gap.s, children: [
              Text('${r.$1}:', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              Text(r.$2, style: t.textTheme.bodyMedium, key: Key('details-${r.$1}')),
            ]),
          ),
        if (attempts.isNotEmpty) ...[
          const SizedBox(height: Gap.m),
          Semantics(header: true, child: Text('Tries', style: t.textTheme.titleSmall)),
          for (var i = 0; i < attempts.length; i++) _attempt(context, m, attempts[i], i + 1),
        ],
        if (m.state == MessageState.failed) ...[
          const SizedBox(height: Gap.m),
          Container(
            key: const Key('details-failure'),
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(color: t.colorScheme.errorContainer, borderRadius: BorderRadius.circular(Corners.small)),
            child: Text(describeFailure(m, attempts), style: TextStyle(color: t.colorScheme.onErrorContainer)),
          ),
        ],
        const SizedBox(height: Gap.m),
        Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
          if (m.state == MessageState.failed)
            FilledButton.icon(
              key: const Key('details-retry'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
              onPressed: () {
                widget.chat.retryFailed(m.id);
                Navigator.of(context).maybePop();
              },
            ),
          OutlinedButton.icon(
            key: const Key('details-copy'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy text'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: m.text));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Text copied')));
              }
            },
          ),
        ]),
      ],
    );
  }

  List<(String, String)> _travel(ChatMessage m) {
    if (m.isOutgoing) {
      if (m.route == null) return const [];
      return [('Route', m.route == Route.flood ? 'Flooded through the mesh' : 'Sent along a saved route')];
    }
    final hops = m.pathLen;
    return [
      ('Came', hops == null ? 'Direct, no repeater in between' : (hops == 0 ? 'Directly from them' : '$hops ${hops == 1 ? 'hop' : 'hops'} through repeaters')),
      if (m.snr != null) ('Signal', '${m.snr!.toStringAsFixed(1)} dB, ${snrWord(m.snr!)}'),
    ];
  }

  Widget _attempt(BuildContext context, ChatMessage m, DeliveryAttempt a, int n) {
    final t = Theme.of(context);
    final acked = m.state == MessageState.acked && a.expectedAck != null && a.expectedAck == m.expectedAck;
    final line = StringBuffer('Try $n, ${a.route == Route.flood ? 'flooded' : 'direct'}, ${_clock(a.sentAtMs)}');
    if (acked && m.ackMs != null) line.write(', acknowledged after ${_secs(m.ackMs!)}');
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(acked ? Icons.check_circle_rounded : Icons.send_rounded, size: 18, color: acked ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(line.toString(), key: Key('details-try-$n'))),
      ]),
    );
  }
}
