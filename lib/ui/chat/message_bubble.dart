// One message bubble: sender name (channels and rooms), tappable links, mentions, time, and for your own messages the
// delivery chip with Retry / Cancel. Used by the conversation screen and by search results.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../chat/models.dart';
import '../theme.dart';
import 'message_format.dart';

class MessageBubble extends StatefulWidget {
  final ChatMessage message;

  /// Show the sender's name above the text (first message of a run in a channel or room).
  final bool showSender;
  final String? selfName;
  final bool radioConnected;
  final int? dueInMs;
  final void Function(String url)? onUrl;
  final void Function(String link)? onMeshLink;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;

  const MessageBubble({
    super.key,
    required this.message,
    this.showSender = false,
    this.selfName,
    this.radioConnected = true,
    this.dueInMs,
    this.onUrl,
    this.onMeshLink,
    this.onRetry,
    this.onCancel,
    this.onLongPress,
    this.onTap,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  final List<TapGestureRecognizer> _taps = [];

  @override
  void dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  List<InlineSpan> _spans(TextStyle base, Color link, Color mention, Color mentionMe) {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
    final out = <InlineSpan>[];
    for (final p in splitMessage(widget.message.text)) {
      switch (p.kind) {
        case PartKind.text:
          out.add(TextSpan(text: p.text));
        case PartKind.url:
        case PartKind.meshLink:
          final r = TapGestureRecognizer()
            ..onTap = () {
              if (p.kind == PartKind.url) {
                widget.onUrl?.call(p.text);
              } else {
                widget.onMeshLink?.call(p.text);
              }
            };
          _taps.add(r);
          out.add(TextSpan(text: p.text, style: TextStyle(color: link, decoration: TextDecoration.underline, decorationColor: link), recognizer: r));
        case PartKind.mention:
          final me = mentionsMe(p.text, widget.selfName);
          out.add(TextSpan(text: mentionLabel(p.text), style: TextStyle(fontWeight: FontWeight.w700, color: me ? mentionMe : mention)));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final mine = m.isOutgoing;
    final bg = mine ? cs.primaryContainer : cs.surfaceContainerHighest;
    final fg = mine ? cs.onPrimaryContainer : cs.onSurface;
    final base = (t.textTheme.bodyLarge ?? const TextStyle()).copyWith(color: fg);
    final linkColor = mine ? cs.onPrimaryContainer : cs.primary;
    final del = mine ? deliveryOf(m, dueInMs: widget.dueInMs, radioConnected: widget.radioConnected) : null;
    final sender = m.senderName;
    final time = timeLabel(context, m.tsLocalMs);

    final semantic = StringBuffer();
    semantic.write(mine ? 'You' : (sender ?? 'Message'));
    semantic.write(', $time. ${m.text}');
    if (del != null) semantic.write('. ${del.detail}');

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
      decoration: BoxDecoration(
        color: bg,
        border: del?.failed == true ? Border.all(color: cs.error, width: 1.5) : null,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(Corners.card),
          topRight: const Radius.circular(Corners.card),
          bottomLeft: Radius.circular(mine ? Corners.card : 6),
          bottomRight: Radius.circular(mine ? 6 : Corners.card),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showSender && !mine && sender != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(sender, style: t.textTheme.labelLarge?.copyWith(color: cs.primary, fontWeight: FontWeight.w700)),
            ),
          Text.rich(TextSpan(style: base, children: _spans(base, linkColor, cs.primary, cs.tertiary))),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: Text(time, style: t.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.75))),
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 2),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Semantics(
            container: true,
            label: semantic.toString(),
            onLongPressHint: 'Message actions',
            child: ExcludeSemantics(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: widget.onLongPress,
                onTap: widget.onTap,
                child: bubble,
              ),
            ),
          ),
          if (del != null && del.label.isNotEmpty) _status(context, del),
        ],
      ),
    );
  }

  Widget _status(BuildContext context, DeliveryView del) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final color = del.failed ? cs.error : cs.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 2, right: 4),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Gap.s,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(del.icon, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(child: Text(del.label, key: const Key('delivery-label'), style: t.textTheme.labelMedium?.copyWith(color: color))),
          ]),
          if (del.failed && widget.onRetry != null)
            TextButton(key: const Key('msg-retry'), style: _smallBtn, onPressed: widget.onRetry, child: const Text('Retry')),
          if ((del.failed || del.pending) && widget.onCancel != null)
            TextButton(key: const Key('msg-cancel'), style: _smallBtn, onPressed: widget.onCancel, child: Text(del.failed ? 'Delete' : 'Cancel')),
        ],
      ),
    );
  }

  static final ButtonStyle _smallBtn = TextButton.styleFrom(minimumSize: const Size(48, 48), padding: const EdgeInsets.symmetric(horizontal: Gap.s));
}
