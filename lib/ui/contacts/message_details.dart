// Message details (chat plan 4.4): a sheet with the hop diagram, the grouped facts (status, route, repeaters, signal, round
// trip, size, times), every try with its outcome, and Try Again / Copy / Delete. Plain language, no raw milliseconds.
// Opened from the bubble menu, the info strip and the failed-bubble sheet through [showMessageDetails].
//
// Build 77 (round 3): every try is listed with its number, the route the RADIO reported for it (direct / flood) and what
// became of it, read from the delivery engine ([ChatService.deliveryProgress]); a message still being tried has Cancel; a
// direct message has its message log (what the phone and the radio said to each other, no message text) to read and
// export; times follow the app's time setting (C-V3); a named repeater in the route opens its page (C-U8); a hop two
// repeaters share offers "Work out the likely route" (round 2 N-U3).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Material, MaterialPageRoute, MaterialType;
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../chat/chat_service.dart';
import '../../chat/db/outbox_repository.dart';
import '../../chat/message_log.dart';
import '../../core/time_format.dart' as tf;
import '../../chat/delivery_state.dart';
import '../../chat/delivery_text.dart';
import '../../chat/events.dart';
import '../../chat/hop_resolver.dart';
import '../../chat/message_info.dart';
import '../../chat/models.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import '../chat/hop_names.dart';
import '../chat/message_info_card.dart';
import '../chat/message_menu.dart' show deleteMessageWithUndo;

/// Opens the details of one message as a sheet (detents 0.5 / 0.92; on an iPad it is the centred form sheet of showAppSheet).
/// [onOpenContact]: a named repeater of the route that is on your radio opens through it (its profile); without it, and
/// for a repeater only the network knows, the Network tab's node page opens. [onManageRadioContacts]: the button of a
/// message that failed because the radio's contact list is full.
Future<void> showMessageDetails(BuildContext context,
    {required ChatService chat, required String messageId, void Function(Contact contact)? onOpenContact, VoidCallback? onManageRadioContacts}) async {
  await showAppSheet<void>(
    context,
    detents: const [0.5, 0.92],
    builder: (c, scroll) =>
        MessageDetails(chat: chat, messageId: messageId, scroll: scroll, onOpenContact: onOpenContact, onManageRadioContacts: onManageRadioContacts),
  );
}

// One time style (round 3 C-V3): the app's formatter, so the phone's 12/24-hour setting and Settings > Time zone apply.
// Build 76 hard-coded 24-hour local time and a raw yyyy-mm-dd date here.
String _day(int ms) => tf.dateTime(DateTime.fromMillisecondsSinceEpoch(ms), seconds: true);

String _clock(int ms) => tf.timeOfDay(DateTime.fromMillisecondsSinceEpoch(ms), seconds: true);

/// Shares the exported message log as a text file (the share sheet). Tests replace it.
Future<void> Function(String fileName, String text) shareMessageLog = _shareLogFile;

Future<void> _shareLogFile(String fileName, String text) async {
  await SharePlus.instance.share(ShareParams(files: [XFile.fromData(Uint8List.fromList(utf8.encode(text)), mimeType: 'text/plain')], fileNameOverrides: [fileName]));
}

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
  final void Function(Contact contact)? onOpenContact;
  final VoidCallback? onManageRadioContacts;
  const MessageDetails({super.key, required this.chat, required this.messageId, this.scroll, this.events, this.onOpenContact, this.onManageRadioContacts});

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
    final resolver = hopResolverFor(store, m.radioId, rosterOf(context));
    final who = m.isOutgoing ? (isDm ? 'To ${contact?.displayName ?? 'unknown contact'}' : 'Sent by you') : 'From ${m.senderName ?? contact?.displayName ?? 'unknown sender'}';
    // Every try, from the delivery engine: this send's tries, and those of earlier sends (before a Try Again).
    final progress = m.isOutgoing && isDm ? widget.chat.deliveryProgress(m.id) : null;
    final tries = progress?.tries ?? const <DeliveryAttempt>[];
    final earlier = progress?.earlierTries ?? const <DeliveryAttempt>[];
    final attempts = [...earlier, ...tries];
    final maxAttempts = progress?.tryCount;
    final canCancel = m.isOutgoing && (m.isPending || (progress?.active ?? false));
    final hasLog = m.isOutgoing && isDm && widget.chat.log.forMessage(m.id, limit: 1).isNotEmpty;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final d = deliveryUi(m, radioConnected: true, maxAttempts: maxAttempts, nowMs: nowMs);
    final info = messageInfo(m, resolver: resolver, peer: contact?.displayName ?? m.senderName, contact: contact);
    final isChannel = m.convKind == ConvKind.channel;
    final repeats = isChannel ? repeatViews(m, store.messages.repeatsFor(m.id), resolver) : const <RepeatView>[];
    final peer = m.isOutgoing ? (contact?.displayName ?? 'Them') : (m.senderName ?? contact?.displayName ?? 'Them');
    final mapNodes = <HopNode>[];
    if (isChannel && m.isOutgoing) {
      final seen = <String>{};
      for (final v in repeats) {
        for (final n in v.path) {
          if (seen.add(n.hash)) mapNodes.add(n);
        }
      }
    } else {
      mapNodes.addAll(info.nodes);
    }
    final canMap = mapNodes.any((n) => n.known && n.hasPosition);
    final rows = <(String, String)>[
      if (m.isOutgoing) ('Status', m.state == MessageState.acked ? 'Delivered ${_clock(m.tsLocalMs)}' : d.word),
      ('Route', info.routeWord + (m.isOutgoing && info.kind == TravelKind.viaRepeaters && !info.routeIsActual ? ' (saved)' : '')),
      if (info.nodes.isNotEmpty || (!m.isOutgoing && (m.pathLen ?? 0) > 0))
        ('Repeaters', info.nodes.isNotEmpty ? info.nodes.map((n) => n.description).join(', ') : '${m.pathLen}'),
      // Plain word first (D6); this is where the numbers live.
      if (!m.isOutgoing && (m.snr != null || m.rssi != null))
        ('Signal', [if (m.snr != null) signalWord(m.snr!), if (m.snr != null) 'SNR ${m.snr!.toStringAsFixed(1)} dB', if (m.rssi != null) 'RSSI ${m.rssi} dBm'].join(' · ')),
      if (!m.isOutgoing && m.airMs != null) ('Time on air', m.airMs! < 1000 ? '${m.airMs} ms' : '${(m.airMs! / 1000).toStringAsFixed(2)} s'),
      if (m.isOutgoing && m.ackMs != null) ('Round trip', _secs(m.ackMs!)),
      if (isChannel && m.isOutgoing) ('Heard by', m.repeatsHeard == 0 ? 'No repeater yet' : '${m.repeatsHeard} ${m.repeatsHeard == 1 ? 'repeater' : 'repeaters'}'),
      if (isChannel && !m.isOutgoing && repeats.length > 1) ('Arrived by', '${repeats.length} routes'),
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
        if (info.nodes.isNotEmpty)
          HopChain(
            first: m.isOutgoing ? 'You' : peer,
            nodes: info.nodes,
            last: m.isOutgoing ? peer : 'You',
            // C-U8: a named repeater opens its page.
            canOpen: (n) => hopTarget(store, m.radioId, rosterOf(context), n) != null,
            onHop: (n) => _openHop(m, n),
          )
        else if (info.chips.length > 1)
          _HopDiagram(info: info),
        if (info.nodes.any((n) => n.ambiguous))
          // Round 2 N-U3: which repeater was it? Path Inspector works it out from the whole route.
          CupertinoButton(
            key: const Key('details-likely-route'),
            padding: EdgeInsets.zero,
            minimumSize: Size.square(Hit.of(context)),
            onPressed: () {
              if (!openPathInspector(context, info.nodes)) showAppToast(context, 'Open Network, then Tools, then Path Inspector to work this out.');
            },
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AppSymbolIcon(AppSymbols.route, size: 18, color: c.accent),
              const SizedBox(width: Gap.xs),
              Flexible(child: Text('Work out the likely route', style: AppType.body.copyWith(color: c.accent))),
            ]),
          ),
        if (info.nodes.isNotEmpty || info.chips.length > 1) const SizedBox(height: Gap.m),
        if (canMap) ...[
          CupertinoButton(
            key: const Key('details-map'),
            padding: EdgeInsets.zero,
            minimumSize: Size.square(Hit.of(context)),
            onPressed: () => MessagePathMapScreen.open(context,
                title: isChannel && m.isOutgoing ? 'Repeaters that relayed it' : (m.isOutgoing ? 'Route it took' : 'How it reached you'),
                nodes: mapNodes,
                connect: !(isChannel && m.isOutgoing)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AppSymbolIcon(AppSymbols.map, size: 18, color: c.accent),
              const SizedBox(width: Gap.xs),
              Text('Route on map', style: AppType.body.copyWith(color: c.accent)),
            ]),
          ),
          const SizedBox(height: Gap.s),
        ],
        Container(
          decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.card)),
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              _Row(label: rows[i].$1, value: rows[i].$2),
              if (i < rows.length - 1) Padding(padding: const EdgeInsets.only(left: Gap.m), child: Container(height: 0.5, color: c.outline.withValues(alpha: 0.3))),
            ],
          ]),
        ),
        if (repeats.isNotEmpty) ...[
          const SizedBox(height: Gap.l),
          Semantics(
            header: true,
            child: Text(m.isOutgoing ? 'REPEATS (${repeats.length})' : 'ARRIVALS (${repeats.length})',
                key: const Key('details-repeats-header'), style: AppType.footnote.copyWith(color: c.textMuted, fontWeight: FontWeight.w600)),
          ),
          RepeatsList(message: m, repeats: repeats),
        ],
        if (attempts.isNotEmpty) ...[
          const SizedBox(height: Gap.l),
          Semantics(
            header: true,
            child: Text(
                // "TRIES (3 of 8)" while it is still going; the count alone once it is over.
                progress != null && progress.active && maxAttempts != null ? 'TRIES (${tries.length} of $maxAttempts)' : 'TRIES (${attempts.length})',
                key: const Key('details-tries-header'),
                style: AppType.footnote.copyWith(color: c.textMuted, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: Gap.xs),
          if (earlier.isNotEmpty) ...[
            Text('Earlier sends', key: const Key('details-earlier'), style: AppType.footnote.copyWith(color: c.textMuted)),
            for (var i = 0; i < earlier.length; i++) _attempt(c, describeAttempt(earlier[i], i + 1, m, last: false), i + 1),
            const SizedBox(height: Gap.s),
            Text('This send', style: AppType.footnote.copyWith(color: c.textMuted)),
          ],
          // One line per try: its number, direct or flood as the radio reported it, when, and what became of it.
          for (var i = 0; i < tries.length; i++) _attempt(c, describeAttempt(tries[i], i + 1, m, last: i == tries.length - 1), earlier.length + i + 1),
        ],
        if (m.state == MessageState.failed) ...[
          const SizedBox(height: Gap.m),
          Container(
            key: const Key('details-failure'),
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(border: Border.all(color: c.danger), borderRadius: BorderRadius.circular(Corners.small)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(describeFailure(m, attempts), style: AppType.callout.copyWith(color: c.textPrimary)),
              // D1: the list is full and the app removes nobody to make room: the person chooses who goes.
              if (m.failReason == FailReason.contactListFull && widget.onManageRadioContacts != null)
                CupertinoButton(
                  key: const Key('details-manage-radio'),
                  padding: EdgeInsets.zero,
                  minimumSize: Size.square(Hit.of(context)),
                  onPressed: () {
                    final go = widget.onManageRadioContacts!;
                    Navigator.of(context).maybePop().then((_) => go());
                  },
                  child: const Text('Manage radio contacts'),
                ),
            ]),
          ),
        ],
        if (hasLog) ...[
          const SizedBox(height: Gap.m),
          // What the phone and the radio said to each other while this message was being delivered. No message text.
          CupertinoButton(
            key: const Key('details-log'),
            padding: EdgeInsets.zero,
            minimumSize: Size.square(Hit.of(context)),
            onPressed: () => MessageLogScreen.open(context, chat: widget.chat, messageId: m.id),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AppSymbolIcon(AppSymbols.docOnDoc, size: 18, color: c.accent),
              const SizedBox(width: Gap.xs),
              Text('Message log', style: AppType.body.copyWith(color: c.accent)),
            ]),
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
          if (canCancel)
            CupertinoButton.filled(
              key: const Key('details-cancel'),
              minimumSize: Size.square(Hit.of(context)),
              onPressed: () {
                widget.chat.cancel(m.id);
                Navigator.of(context).maybePop();
              },
              child: const Text('Cancel sending'),
            ),
          CupertinoButton(
            key: const Key('details-copy'),
            minimumSize: Size.square(Hit.of(context)),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: m.text));
              if (context.mounted) showAppToast(context, 'Text copied');
            },
            child: const Text('Copy text'),
          ),
          if (!m.isPending && !canCancel)
            CupertinoButton(
              key: const Key('details-delete'),
              minimumSize: Size.square(Hit.of(context)),
              onPressed: () async {
                deleteMessageWithUndo(context, widget.chat, m.id);
                if (context.mounted) Navigator.of(context).maybePop();
              },
              child: Text('Delete', style: TextStyle(color: c.danger)),
            ),
        ]),
      ],
    );
  }

  void _openHop(ChatMessage m, HopNode n) {
    final opened = openHop(context, store: widget.chat.store, radioId: m.radioId, node: n, onContact: widget.onOpenContact == null
        ? null
        : (contact) {
            final go = widget.onOpenContact!;
            // The profile opens over the conversation, not over this sheet.
            Navigator.of(context).maybePop().then((_) => go(contact));
          });
    if (!opened) showAppToast(context, 'This repeater has no page to open here.');
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
                  // Neutral, not amber (build 77 colour language: amber is for warnings only).
                  border: Border.all(color: i > 0 && i < info.chips.length - 1 ? c.repeater : c.outline.withValues(alpha: 0.4)),
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


/// The message log of one message (round 3, defect M12): one line per command given to the radio and per reply code, one
/// per confirmation (its code and whether it matched a try), and each step of the message. Read it here; Export shares
/// it as a text file. It never holds message text, keys or passwords.
class MessageLogScreen extends StatelessWidget {
  final ChatService chat;
  final String messageId;
  const MessageLogScreen({super.key, required this.chat, required this.messageId});

  static Future<void> open(BuildContext context, {required ChatService chat, required String messageId}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MessageLogScreen(chat: chat, messageId: messageId)));

  /// The file a shared log goes out as.
  static String fileNameFor(String messageId) => 'meshsonar-message-log-${MessageLog.shortId(messageId)}.txt';

  Future<void> _export(BuildContext context) async {
    // An exported log is in UTC and says so (two people's logs then line up), whatever the Time zone setting.
    final text = chat.exportMessageLog(messageId: messageId);
    try {
      await shareMessageLog(fileNameFor(messageId), text);
    } catch (_) {
      if (context.mounted) showAppToast(context, 'The log could not be shared. Try again.', kind: AppToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final lines = chat.log.forMessage(messageId);
    return CupertinoPageScaffold(
      key: const Key('message-log-screen'),
      backgroundColor: c.bg,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: c.bg,
        middle: const Text('Message log'),
        trailing: CupertinoButton(
          key: const Key('message-log-export'),
          padding: EdgeInsets.zero,
          minimumSize: Size.square(Hit.of(context)),
          onPressed: lines.isEmpty ? null : () => _export(context),
          child: const Text('Export'),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: lines.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: Text('Nothing was logged for this message. The log keeps the newest messages only.',
                        key: const Key('message-log-empty'), textAlign: TextAlign.center, style: AppType.body.copyWith(color: c.textMuted)),
                  ),
                )
              : ListView.builder(
                  key: const Key('message-log-list'),
                  padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, Gap.xl),
                  itemCount: lines.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: Gap.m),
                        child: Text(
                            'What your phone and your radio said to each other while this message was being delivered. '
                            'It holds no message text, keys or passwords. > is a command to the radio, < its reply, = a step of the message.',
                            key: const Key('message-log-intro'),
                            style: AppType.footnote.copyWith(color: c.textMuted)),
                      );
                    }
                    final l = lines[i - 1];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('${MessageLog.lineTime(l.tsMs)}  ${l.text}', key: Key('message-log-line-${i - 1}'), style: AppType.footnote.copyWith(color: c.textPrimary)),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
