// The Chats list row (plan 4.1): 52 pt avatar with a type badge, title and time, a fixed two-line preview slot (so the list
// can use a prototype extent), delivery glyph before the person's own last text, "Draft:" prefix, pin and mute marks, and
// the unread pill. Pure painting: [ConversationRow] (lib/chat/conversation_row.dart) decides everything it shows.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../chat/conversation_row.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/avatar_style.dart';
import '../design/tokens.dart';

const double kRowMinHeight = 72;
const double kAvatarSize = 52;
const double kAvatarBadge = 20;

/// Left inset of the hairline between rows: row padding + avatar + gap.
const double kRowDividerInset = 16 + kAvatarSize + 12;

String _initials(ConversationRow r) {
  final name = r.title.replaceAll('#', '').trim();
  if (name.isEmpty) return '?';
  final words = name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  String first(String w) => w.characters.first.toUpperCase();
  if (r.kind == RowKind.person && words.length > 1) return first(words.first) + first(words.last);
  return first(words.first);
}

AppSymbol? badgeFor(RowKind k) => switch (k) {
      RowKind.person => null,
      RowKind.repeater => AppSymbols.antenna,
      RowKind.room => AppSymbols.bubbles,
      RowKind.sensor => AppSymbols.thermometer,
      RowKind.publicChannel => AppSymbols.globe,
      RowKind.hashtagChannel => AppSymbols.numberSign,
      RowKind.privateChannel => AppSymbols.lockFill,
      RowKind.system => AppSymbols.waveform,
    };

/// Avatar: circle for people, repeaters and sensors; rounded square for channels, rooms and System.
class ConversationAvatar extends StatelessWidget {
  final ConversationRow row;
  final double size;
  const ConversationAvatar({super.key, required this.row, this.size = kAvatarSize});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final style = avatarStyle(row.avatarSeed, c);
    final squared = row.isChannel || row.kind == RowKind.room || row.kind == RowKind.system;
    final repeater = row.kind == RowKind.repeater;
    final fill = row.kind == RowKind.system ? c.surfaceHigh : (repeater ? c.warning : style.fill);
    final ink = row.kind == RowKind.system ? c.textMuted : Colors.white;
    final badge = badgeFor(row.kind);
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                shape: squared ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: squared ? BorderRadius.circular(size * 0.28) : null,
              ),
              child: row.kind == RowKind.system
                  ? AppSymbolIcon(AppSymbols.waveform, size: 24, color: ink)
                  : Text(
                      _initials(row),
                      maxLines: 1,
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(color: ink, fontSize: size * 0.38, fontWeight: FontWeight.w600),
                    ),
            ),
            if (badge != null && row.kind != RowKind.system)
              Positioned(
                right: -3,
                bottom: -3,
                child: Container(
                  width: kAvatarBadge,
                  height: kAvatarBadge,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.surfaceHigh,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.bg, width: 2),
                  ),
                  child: AppSymbolIcon(badge, size: 11, color: repeater ? c.warning : c.textPrimary, scaleWithText: false),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

AppSymbol? deliverySymbol(RowDelivery d) => switch (d) {
      RowDelivery.none => null,
      RowDelivery.queued => AppSymbols.clock,
      RowDelivery.sent => AppSymbols.checkmark,
      RowDelivery.heard => AppSymbols.antenna,
      RowDelivery.delivered => AppSymbols.checkmarkCircleFill,
      RowDelivery.failed => AppSymbols.exclamationCircleFill,
    };

String deliveryWord(RowDelivery d) => switch (d) {
      RowDelivery.none => '',
      RowDelivery.queued => 'Waiting to send',
      RowDelivery.sent => 'Sent',
      RowDelivery.heard => 'Heard by a repeater',
      RowDelivery.delivered => 'Delivered',
      RowDelivery.failed => 'Not delivered',
    };

/// What the preview slot says when a conversation has no text yet.
String emptyPreview(ConversationRow r) {
  if (r.offRadio && !r.hasHistory) return 'Not on your radio right now';
  if (r.kind == RowKind.room) return 'No posts yet';
  return 'No messages yet';
}

/// One line of the screen-reader label: title, state flags, delivery word, last message.
String rowSemantics(ConversationRow r, String stamp) {
  final b = StringBuffer(r.title);
  if (r.kind == RowKind.room) b.write(', room');
  if (r.unread > 0) b.write(', ${r.unread} unread');
  if (r.pinned) b.write(', pinned');
  if (r.muted) b.write(', muted');
  if (r.offRadio) b.write(', not on the radio');
  if (stamp.isNotEmpty) b.write(', $stamp');
  b.write('. ');
  if (r.hasDraft) {
    b.write('Draft: ${r.preview}');
  } else {
    final w = deliveryWord(r.delivery);
    if (w.isNotEmpty) b.write('$w. ');
    if (r.previewSender != null) b.write('${r.previewSender}: ');
    b.write(r.preview.isEmpty ? emptyPreview(r) : r.preview);
  }
  return b.toString();
}

class ConversationTile extends StatefulWidget {
  final ConversationRow row;
  final String stamp;
  final VoidCallback? onTap;
  final bool selected;

  /// Extra screen-reader actions (Pin, Mute, Delete).
  final Map<CustomSemanticsAction, VoidCallback> actions;
  const ConversationTile({super.key, required this.row, required this.stamp, this.onTap, this.selected = false, this.actions = const {}});

  @override
  State<ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<ConversationTile> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final c = AppColors.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final unread = r.unread > 0;
    final titleStyle = AppType.headline.copyWith(color: c.textPrimary);
    final subStyle = AppType.subhead.copyWith(color: c.textMuted);
    final stampStyle = AppType.subhead.copyWith(color: unread && !r.muted ? c.accent : c.textMuted, fontFeatures: AppType.tabular);
    final previewHeight = scaler.scale(15) * 1.27 * 2;
    final stampBelow = scaler.scale(17) > 17 * 1.5;
    final sym = deliverySymbol(r.delivery);
    final text = r.preview.isEmpty ? emptyPreview(r) : r.preview;

    final spans = <InlineSpan>[
      if (r.hasDraft) TextSpan(text: 'Draft: ', style: subStyle.copyWith(color: c.accent, fontWeight: FontWeight.w600)),
      if (sym != null)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: AppSymbolIcon(sym, size: 14, color: r.delivery == RowDelivery.failed ? c.danger : (r.delivery == RowDelivery.delivered ? c.accent : c.textMuted)),
          ),
        ),
      if (r.previewSender != null) TextSpan(text: '${r.previewSender}: ', style: subStyle.copyWith(color: c.textPrimary)),
      TextSpan(text: text, style: r.offRadio && r.preview.isEmpty ? subStyle.copyWith(color: c.warning) : subStyle),
    ];

    final trailing = <Widget>[
      if (r.pinned) AppSymbolIcon(AppSymbols.pinFill, size: 14, color: c.textMuted, scaleWithText: false),
      if (r.muted) AppSymbolIcon(AppSymbols.bellSlash, size: 14, color: c.textMuted, scaleWithText: false),
      if (unread) _UnreadPill(count: r.unread, muted: r.muted),
    ];

    return Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      label: rowSemantics(r, widget.stamp),
      onTap: widget.onTap,
      customSemanticsActions: widget.actions,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          child: Container(
            color: widget.selected
                ? c.accent.withValues(alpha: 0.14)
                : (_down ? c.textMuted.withValues(alpha: 0.14) : Colors.transparent),
            constraints: const BoxConstraints(minHeight: kRowMinHeight),
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConversationAvatar(row: r),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (stampBelow) ...[
                        // Large text: the time goes under the name, like Messages does, instead of squeezing it.
                        Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                        Text(widget.stamp, maxLines: 1, overflow: TextOverflow.ellipsis, style: stampStyle),
                      ] else
                        Row(
                          children: [
                            Expanded(
                              child: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                            ),
                            const SizedBox(width: Gap.s),
                            Text(widget.stamp, maxLines: 1, style: stampStyle),
                          ],
                        ),
                      const SizedBox(height: 2),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: previewHeight,
                              child: Text.rich(TextSpan(children: spans), maxLines: 2, overflow: TextOverflow.ellipsis, style: subStyle),
                            ),
                          ),
                          if (trailing.isNotEmpty) ...[
                            const SizedBox(width: Gap.s),
                            Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: trailing),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnreadPill extends StatelessWidget {
  final int count;
  final bool muted;
  const _UnreadPill({required this.count, required this.muted});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final label = count > 99 ? '99+' : '$count';
    return Container(
      key: const Key('unread-pill'),
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: muted ? c.textMuted : c.bubbleOut, borderRadius: BorderRadius.circular(11)),
      // A badge stays compact: its number stops growing at 1.5x.
      child: Text(
        label,
        maxLines: 1,
        textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.5),
        style: AppType.num(13).copyWith(color: Colors.white),
      ),
    );
  }
}

/// Hairline between rows, inset to the text column.
class RowDivider extends StatelessWidget {
  const RowDivider({super.key});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: kRowDividerInset),
      child: SizedBox(height: 0.5, child: ColoredBox(color: c.outline.withValues(alpha: 0.35))),
    );
  }
}
