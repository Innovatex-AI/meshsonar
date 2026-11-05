// Message details (chat plan 4.4): a sheet with the hop diagram, the grouped facts (status, route, repeaters, signal, round
// trip, size, times), every try with its outcome, and Try Again / Copy / Delete. Plain language, no raw milliseconds.
// Opened from the bubble menu, the info strip and the failed-bubble sheet through [showMessageDetails].
import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_service.dart';
import '../../chat/db/outbox_repository.dart';
import '../../chat/delivery_state.dart';
import '../../chat/delivery_text.dart';
import '../../chat/events.dart';
import '../../chat/message_info.dart';
import '../../chat/models.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import '../chat/message_menu.dart' show confirmDeleteMessage;

/// Opens the details of one message as a sheet (detents 0.5 / 0.92; on an iPad it is the centred form sheet of showAppSheet).
Future<void> showMessageDetails(BuildContext context, {required ChatService chat, required String messageId}) async {
  await showAppSheet<void>(
    context,
    detents: const [0.5, 0.92],
    builder: (c, scroll) => MessageDetails(chat: chat, messageId: messageId, scroll: scroll),
  );
}

String _day(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

String _clock(int ms) => _day(ms).substring(11);

String _secs(int ms) {
  if (ms < 950) return '$ms ms';
  final s = ms / 1000;
  return s < 10 ? '${s.toStringAsFixed(1)} s' : '${s.round()} s';
}

class MessageDetails extends StatefulWidget {
  final ChatService chat;
  final String messageId;
  final ScrollController? scroll;

  /// Test seam: the event stream to follow (default: the service's). The leak test counts listeners through it.
  final Stream<ChatEvent>? events;
  const MessageDetails({super.key, required this.chat, required this.messageId, this.scroll, this.events});

  @override
  State<MessageDetails> createState() => _MessageDetailsState();
}

class _MessageDetailsState extends State<MessageDetails> {
  StreamSubscription<ChatEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = (widget.events ?? widget.chat.events).listen((e) {
      if (mounted && e.messageId == widget.messageId) setState(() {});
    });
  }

  @override
  void dispose() {
    // Fix 7.2: the subscription used to outlive the sheet.
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = widget.chat.store.messages.get(widget.messageId);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Gap.xs, 0),
          child: Row(children: [
            const SizedBox(width: 64),
            Expanded(child: Semantics(header: true, child: Text('Message details', textAlign: TextAlign.center, style: AppType.headline.copyWith(color: c.textPrimary)))),
            SizedBox(
              width: 64,
              child: CupertinoButton(
                key: const Key('details-done'),
                padding: EdgeInsets.zero,
                minimumSize: Size.square(Hit.of(context)),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text('Done', style: AppType.body.copyWith(color: c.accent, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
        Expanded(child: m == null ? _gone(c) : _body(context, c, m)),
      ],
    );
  }

  Widget _gone(AppColors c) => ListView(controller: widget.scroll, padding: const EdgeInsets.all(Gap.xl), children: [
        Text('This message is gone.', key: const Key('details-gone'), style: AppType.body.copyWith(color: c.textMuted)),
      ]);

  Widget _body(BuildContext context, AppColors c, ChatMessage m) {
    final store = widget.chat.store;
    final isDm = m.convKind == ConvKind.dm || m.convKind == ConvKind.room;
    final contact = isDm ? store.contacts.byPrefix(m.radioId, ConvKey.body(m.convKey)) : null;
    final repeaters = store.contacts.list(m.radioId).where((x) => x.type == ContactType.repeater).toList();
    final who = m.isOutgoing ? (isDm ? 'To ${contact?.displayName ?? 'unknown contact'}' : 'Sent by you') : 'From ${m.senderName ?? contact?.displayName ?? 'unknown sender'}';
    final attempts = m.isOutgoing && isDm ? store.outbox.attemptsFor(m.id) : const <DeliveryAttempt>[];
    final maxAttempts = store.outbox.get(m.id)?.maxAttempts;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final d = deliveryUi(m, radioConnected: true, maxAttempts: maxAttempts, nowMs: nowMs);
    final info = messageInfo(m, repeaters: repeaters, peer: contact?.displayName ?? m.senderName, contact: contact);
    final rows = <(String, String)>[
      if (m.isOutgoing) ('Status', m.state == MessageState.acked ? 'Delivered ${_clock(m.tsLocalMs)}' : d.word),
      ('Route', info.routeWord + (m.isOutgoing && info.kind == TravelKind.viaRepeaters ? ' (saved)' : '')),
      if (info.hops.isNotEmpty || (!m.isOutgoing && (m.pathLen ?? 0) > 0)) ('Repeaters', info.hops.isNotEmpty ? info.hops.join(', ') : '${m.pathLen}'),
      if (!m.isOutgoing && (m.snr != null || m.rssi != null))
        ('Signal', [if (m.snr != null) 'SNR ${m.snr!.toStringAsFixed(1)} dB', if (m.rssi != null) 'RSSI ${m.rssi}', if (m.snr != null) signalWord(m.snr!)].join(' · ')),
      if (m.isOutgoing && m.ackMs != null) ('Round trip', _secs(m.ackMs!)),
      if (m.convKind == ConvKind.channel && m.isOutgoing) ('Heard by', m.repeatsHeard == 0 ? 'No repeater yet' : '${m.repeatsHeard} ${m.repeatsHeard == 1 ? 'repeater' : 'repeaters'}'),
      ('Size', '${utf8.encode(m.text).length} bytes'),
      (m.isOutgoing ? 'Sent' : 'Received', _day(m.tsLocalMs)),
      if (!m.isOutgoing) ('Their clock', _clock(m.tsSender * 1000)),
    ];

    return ListView(
      key: const Key('message-details'),
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, Gap.xl),
      children: [
        Semantics(header: true, child: Text(who, style: AppType.callout.copyWith(color: c.textMuted))),
        const SizedBox(height: Gap.xs),
        Text('“${m.text}”', key: const Key('details-text'), style: AppType.body.copyWith(color: c.textPrimary)),
        const SizedBox(height: Gap.m),
        if (info.chips.length > 1) _HopDiagram(info: info),
        if (info.chips.length > 1) const SizedBox(height: Gap.m),
        Container(
          decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.card)),
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              _Row(label: rows[i].$1, value: rows[i].$2),
              if (i < rows.length - 1) Padding(padding: const EdgeInsets.only(left: Gap.m), child: Container(height: 0.5, color: c.outline.withValues(alpha: 0.3))),
            ],
          ]),
        ),
        if (attempts.isNotEmpty) ...[
          const SizedBox(height: Gap.l),
          Semantics(header: true, child: Text('ATTEMPTS', style: AppType.footnote.copyWith(color: c.textMuted, fontWeight: FontWeight.w600))),
          const SizedBox(height: Gap.xs),
          for (var i = 0; i < attempts.length; i++) _attempt(c, describeAttempt(attempts[i], i + 1, m, last: i == attempts.length - 1), i + 1),
        ],
        if (m.state == MessageState.failed) ...[
          const SizedBox(height: Gap.m),
          Container(
            key: const Key('details-failure'),
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(border: Border.all(color: c.danger), borderRadius: BorderRadius.circular(Corners.small)),
            child: Text(describeFailure(m, attempts), style: AppType.callout.copyWith(color: c.textPrimary)),
          ),
        ],
        const SizedBox(height: Gap.l),
        Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
          if (m.state == MessageState.failed)
            CupertinoButton.filled(
              key: const Key('details-retry'),
              minimumSize: Size.square(Hit.of(context)),
              onPressed: () {
                widget.chat.retryFailed(m.id);
                Navigator.of(context).maybePop();
              },
              child: const Text('Try Again'),
            ),
          CupertinoButton(
            key: const Key('details-copy'),
            minimumSize: Size.square(Hit.of(context)),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: m.text));
              if (context.mounted) showAppToast(context, 'Text copied');
            },
            child: const Text('Copy'),
          ),
          if (!m.isPending)
            CupertinoButton(
              key: const Key('details-delete'),
              minimumSize: Size.square(Hit.of(context)),
              onPressed: () async {
                if (await confirmDeleteMessage(context)) {
                  widget.chat.deleteMessage(m.id);
                  if (context.mounted) Navigator.of(context).maybePop();
                }
              },
              child: Text('Delete', style: TextStyle(color: c.danger)),
            ),
        ]),
      ],
    );
  }

  Widget _attempt(AppColors c, ({String text, bool acked}) a, int n) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppSymbolIcon(a.acked ? AppSymbols.checkmarkCircleFill : AppSymbols.paperplaneFill, size: 16, color: a.acked ? c.accent : c.textMuted),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(a.text, key: Key('details-try-$n'), style: AppType.subhead.copyWith(color: c.textPrimary))),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  final String label, value;
  const _Row({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      constraints: BoxConstraints(minHeight: Hit.of(context)),
      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 104, child: Text(label, style: AppType.body.copyWith(color: c.textMuted))),
        Expanded(child: Text(value, key: Key('details-$label'), textAlign: TextAlign.end, style: AppType.body.copyWith(color: c.textPrimary))),
      ]),
    );
  }
}

/// Read-only chain of the route: "You ─ Ridge ─ Hill ─ Maya". Wraps instead of scrolling; a text alternative reads the route.
class _HopDiagram extends StatelessWidget {
  final MessageInfo info;
  const _HopDiagram({required this.info});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      label: 'Route: ${info.chips.join(', ')}',
      child: ExcludeSemantics(
        child: Wrap(
          key: const Key('hop-diagram'),
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < info.chips.length; i++) ...[
              if (i > 0) Text('─', style: AppType.body.copyWith(color: c.textMuted)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: c.surfaceHigh,
                  borderRadius: BorderRadius.circular(Corners.chip),
                  border: Border.all(color: i > 0 && i < info.chips.length - 1 ? c.beacon : c.outline.withValues(alpha: 0.4)),
                ),
                child: Text(info.chips[i], style: AppType.subhead.copyWith(color: c.textPrimary)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
