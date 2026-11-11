// One message bubble (chat plan 4.2): grouped runs (outer radius 18, inner 6), the time line under the LAST bubble of a run,
// the five delivery states as glyph + word, the tap-to-open info strip (no timer), links and @mentions, a red failed
// bubble with its own tap target, and the per-bubble context menu.
//
// Performance: [MessageBubble.signature] names everything the bubble paints. The conversation keeps the last widget per
// message and hands the SAME instance back while the signature is unchanged, so a delivery change on one message rebuilds
// that bubble only (test/ui/chat/conversation_perf_test.dart).
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../app/photo_controller.dart';
import '../../chat/bubble_grouping.dart';
import '../../chat/delivery_state.dart';
import '../../chat/message_info.dart';
import '../../chat/models.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/avatar_style.dart';
import '../design/tokens.dart';
import '../../core/photo_api.dart' show photoIdOf;
import 'message_format.dart';
import 'message_menu.dart';
import 'photo_widgets.dart';

const double kBubbleAvatar = 28;

AppSymbol symbolFor(DeliveryGlyph g) => switch (g) {
      DeliveryGlyph.clock => AppSymbols.clock,
      DeliveryGlyph.checkmark => AppSymbols.checkmark,
      DeliveryGlyph.antenna => AppSymbols.antenna,
      DeliveryGlyph.checkmarkCircleFill => AppSymbols.checkmarkCircleFill,
      DeliveryGlyph.exclamationCircleFill => AppSymbols.exclamationCircleFill,
    };

class MessageBubble extends StatefulWidget {
  /// Counts `build` calls of bubbles (the performance test reads and resets it). Not used in production paths.
  static int debugBuilds = 0;

  final BubbleSlot slot;

  /// Own messages only.
  final DeliveryUi? delivery;

  /// Show the status line (word + glyph) under this bubble. The conversation decides: the last own message of a run, plus
  /// any Queued or Failed bubble.
  final bool showStatus;
  final String? selfName;
  final bool radioConnected;

  /// Channels and rooms show a 28 pt avatar beside the last bubble of an incoming run.
  final bool avatars;
  final bool wide;

  /// The info strip is open for this message.
  final bool expanded;
  final MessageInfo? info;
  final bool highlighted;
  final String separatorText;

  final void Function(String url)? onUrl;
  final void Function(String link)? onMeshLink;
  final void Function(String id)? onTap;
  final void Function(String id)? onFailedTap;
  final void Function(String id, MessageMenuEntry entry)? onMenu;

  /// Long-press fallback (no context menu): the conversation opens the action sheet.
  final void Function(String id)? onLongPress;
  final void Function(String id)? onDetails;

  /// The info card shown under the bubble while its long-press menu is open (CR4); built only then. Null = bubble only.
  final Widget Function()? infoCard;

  /// A hop of the message's path has a known position: the menu offers "Route on map".
  final bool hasMap;

  /// Resend a channel message no repeater relayed (shown when [delivery] says it can be resent, CR2).
  final void Function(String id)? onResend;

  /// Photo messages: with a controller, MeshSonar photo links draw as thumbnails (null = plain links, as in previews).
  final PhotoController? photos;

  /// A loaded thumbnail was tapped: open the viewer.
  final void Function(String url)? onPhoto;

  const MessageBubble({
    super.key,
    required this.slot,
    this.delivery,
    this.showStatus = false,
    this.selfName,
    this.radioConnected = true,
    this.avatars = false,
    this.wide = false,
    this.expanded = false,
    this.info,
    this.highlighted = false,
    this.separatorText = '',
    this.onUrl,
    this.onMeshLink,
    this.onTap,
    this.onFailedTap,
    this.onMenu,
    this.onLongPress,
    this.onDetails,
    this.infoCard,
    this.hasMap = false,
    this.onResend,
    this.photos,
    this.onPhoto,
  });

  /// A lone bubble (previews, the System traffic list): no grouping, no status line, no menu.
  MessageBubble.single({super.key, required ChatMessage message, bool showSender = false, this.radioConnected = true})
      : slot = BubbleSlot(message: message, joinsOlder: false, joinsNewer: false, separatorAbove: false, showSender: showSender),
        delivery = null,
        showStatus = false,
        selfName = null,
        avatars = false,
        wide = false,
        expanded = false,
        info = null,
        highlighted = false,
        separatorText = '',
        onUrl = null,
        onMeshLink = null,
        onTap = null,
        onFailedTap = null,
        onMenu = null,
        onLongPress = null,
        onDetails = null,
        infoCard = null,
        hasMap = false,
        onResend = null,
        photos = null,
        onPhoto = null;

  ChatMessage get message => slot.message;

  /// Everything that changes what this bubble paints.
  String get signature {
    final m = slot.message;
    return [
      m.id, m.state.name, m.attempt, m.repeatsHeard, hasMap, m.ackMs, m.failReason?.name, m.text.length, m.snr, m.rssi, m.pathLen, m.route?.name, //
      slot.joinsOlder, slot.joinsNewer, slot.separatorAbove, slot.showSender, //
      delivery?.word, delivery?.detail, showStatus, radioConnected, avatars, wide, expanded, info?.sentence, highlighted, separatorText, selfName,
      photos != null, photos?.autoLoad, //
    ].join('|');
  }

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

  List<InlineSpan> _spans(String text, Color link, Color mention, Color mentionMe) {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
    final out = <InlineSpan>[];
    for (final p in splitMessage(text)) {
      switch (p.kind) {
        case PartKind.text:
          out.add(TextSpan(text: p.text));
        case PartKind.url:
        case PartKind.photo:
        case PartKind.meshLink:
          final r = TapGestureRecognizer()
            ..onTap = () {
              if (p.kind != PartKind.meshLink) {
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

  BorderRadius _radius(bool mine) {
    const outer = Radius.circular(18);
    const inner = Radius.circular(6);
    final s = widget.slot;
    // "Older" is above, "newer" below. The square-ish corners face the side the bubble hugs.
    final upper = s.joinsOlder ? inner : outer;
    final lower = s.joinsNewer ? inner : outer;
    return mine
        ? BorderRadius.only(topLeft: outer, bottomLeft: outer, topRight: upper, bottomRight: lower)
        : BorderRadius.only(topRight: outer, bottomRight: outer, topLeft: upper, bottomLeft: lower);
  }

  String _spoken(String time) {
    final m = widget.message;
    final who = m.isOutgoing ? 'You' : (m.senderName ?? 'Message');
    final tail = m.isOutgoing ? (widget.delivery?.detail ?? '') : '';
    final photos = widget.photos == null ? const <String>[] : photoLinksOf(m.text);
    final body = photos.isEmpty ? m.text : [if (photos.length == 1) 'Photo' else '${photos.length} photos', textWithoutPhotos(m.text)].where((e) => e.isNotEmpty).join('. ');
    final sb = StringBuffer('$who, $body');
    if (tail.isNotEmpty) sb.write(', ${tail[0].toLowerCase()}${tail.substring(1)}');
    sb.write(', $time');
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    MessageBubble.debugBuilds++;
    final w = widget;
    final s = w.slot;
    final m = s.message;
    final c = AppColors.of(context);
    final mine = m.isOutgoing;
    final failed = w.delivery?.stage == DeliveryStage.failed;
    final bg = mine ? c.bubbleOut : c.surfaceHigh;
    final fg = mine ? c.bubbleOutText : c.textPrimary;
    final base = AppType.body.copyWith(color: fg);
    final time = timeLabel(context, m.tsLocalMs);
    final maxW = (MediaQuery.sizeOf(context).width * (w.wide ? 0.6 : 0.78)).clamp(0.0, 560.0);
    final style = avatarStyle(m.senderPrefix ?? m.senderName ?? 'x', c);

    final photoLinks = w.photos == null ? const <String>[] : photoLinksOf(m.text);
    final rest = photoLinks.isEmpty ? m.text : textWithoutPhotos(m.text);
    final linkColors = (mine ? c.bubbleOutText : c.accent, mine ? c.bubbleOutText : c.accent, mine ? c.bubbleOutText : c.warning);
    final Widget content = photoLinks.isEmpty
        ? Text.rich(TextSpan(style: base, children: _spans(m.text, linkColors.$1, linkColors.$2, linkColors.$3)))
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final u in photoLinks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: PhotoThumb(
                    key: ValueKey('thumb-${m.id}-$u'),
                    url: u,
                    source: w.photos!.source,
                    autoLoad: w.photos!.autoLoad,
                    maxWidth: maxW - 8,
                    onOpen: w.onPhoto,
                  ),
                ),
              if (rest.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
                  child: Text.rich(TextSpan(style: base, children: _spans(rest, linkColors.$1, linkColors.$2, linkColors.$3))),
                ),
            ],
          );

    final body = Container(
      key: Key('bubble-${m.id}'),
      constraints: BoxConstraints(maxWidth: maxW, minHeight: Hit.of(context)),
      padding: photoLinks.isEmpty ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10) : const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: w.highlighted ? Color.alphaBlend(c.accent.withValues(alpha: 0.35), bg) : bg,
        // Increase Contrast: a hairline edge on every bubble (the fill alone may be too close to the page colour).
        border: failed ? Border.all(color: c.danger, width: 1.5) : ((MediaQuery.maybeHighContrastOf(context) ?? false) ? Border.all(color: c.textMuted, width: 1) : null),
        borderRadius: _radius(mine),
      ),
      child: content,
    );

    final tappable = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => failed ? w.onFailedTap?.call(m.id) : w.onTap?.call(m.id),
      child: body,
    );
    final menuEntries = MessageMenu.entries(m,
        hasMap: w.hasMap, canResend: (w.delivery?.canResend ?? false) && w.onResend != null, photos: w.photos != null, isOwnPhoto: (u) => w.photos?.isOwn(photoIdOf(u) ?? '') ?? false);
    final Widget withMenu = (MessageMenu.apple(context) && MessageMenu.useContextMenu)
        ? CupertinoContextMenu.builder(
            enableHapticFeedback: true,
            actions: [
              for (final e in menuEntries)
                Builder(
                  builder: (menuContext) => CupertinoContextMenuAction(
                    key: Key('menu-${MessageMenu.keyName(e.id)}-${m.id}'),
                    isDestructiveAction: e.destructive,
                    trailingIcon: e.symbol.apple,
                    onPressed: () {
                      // Act once the menu has finished closing: opening a screen or sheet while the menu still flies the
                      // bubble back into the list breaks the bubble's render tree (Path on map, Full details).
                      final menu = ModalRoute.of(menuContext);
                      Navigator.of(context, rootNavigator: true).pop();
                      if (menu != null) {
                        menu.completed.then((_) => w.onMenu?.call(m.id, e));
                      } else {
                        w.onMenu?.call(m.id, e);
                      }
                    },
                    child: Text(e.label),
                  ),
                ),
            ],
            // The same builder draws the bubble in the list and in the open menu (a PopupRoute): only the open menu adds the card.
            builder: (context, animation) {
              final bubble = ConstrainedBox(constraints: BoxConstraints(maxWidth: maxW), child: body);
              final card = w.infoCard;
              if (card == null || animation.value < CupertinoContextMenu.animationOpensAt || ModalRoute.of(context) is! PopupRoute) return bubble;
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [bubble, const SizedBox(height: Gap.s), card()],
                ),
              );
            },
          )
        : GestureDetector(behavior: HitTestBehavior.opaque, onLongPress: () => w.onLongPress?.call(m.id), child: tappable);
    // The context menu builder child has no tap handler of its own; the outer detector carries the tap.
    final bubbleCore = (MessageMenu.apple(context) && MessageMenu.useContextMenu)
        ? GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => failed ? w.onFailedTap?.call(m.id) : w.onTap?.call(m.id), child: withMenu)
        : withMenu;

    final links = MessageMenu.linksOf(m, photos: w.photos != null);
    final actions = <CustomSemanticsAction, VoidCallback>{
      const CustomSemanticsAction(label: 'Copy'): () => w.onMenu?.call(m.id, const MessageMenuEntry(MessageMenuId.copy, 'Copy', AppSymbols.docOnDoc)),
      const CustomSemanticsAction(label: 'Details'): () => w.onDetails?.call(m.id),
      if (failed) const CustomSemanticsAction(label: 'Try Again'): () => w.onMenu?.call(m.id, const MessageMenuEntry(MessageMenuId.retry, 'Try Again', AppSymbols.arrowUpCircleFill)),
      if (m.isPending) const CustomSemanticsAction(label: 'Cancel sending'): () => w.onMenu?.call(m.id, const MessageMenuEntry(MessageMenuId.cancel, 'Cancel sending', AppSymbols.xmarkCircleFill)),
      if (!m.isPending) const CustomSemanticsAction(label: 'Delete'): () => w.onMenu?.call(m.id, const MessageMenuEntry(MessageMenuId.delete, 'Delete', AppSymbols.trash, destructive: true)),
    };

    final bubbleSemantics = Semantics(
      container: true,
      label: _spoken(time),
      value: w.expanded ? w.info?.sentence : null,
      hint: w.expanded ? 'Double tap to close the details line' : 'Double tap for how it travelled',
      onTap: () => failed ? w.onFailedTap?.call(m.id) : w.onTap?.call(m.id),
      customSemanticsActions: actions,
      // Each link is its own focus node over the bubble (VoiceOver can reach and open it); the visible text is excluded so the
      // sentence above is read once.
      child: Stack(children: [
        ExcludeSemantics(child: bubbleCore),
        for (final l in links)
          Positioned.fill(
            child: Semantics(
              link: true,
              label: 'Link, $l',
              onTap: () => l.toLowerCase().startsWith('meshcore://') ? w.onMeshLink?.call(l) : w.onUrl?.call(l),
              child: const SizedBox.expand(),
            ),
          ),
        for (final u in photoLinks)
          Positioned.fill(
            child: Semantics(
              button: true,
              label: 'Photo. Double tap to open',
              onTap: () => w.onPhoto?.call(u),
              child: const SizedBox.expand(),
            ),
          ),
      ]),
    );

    final failedGlyph = failed
        ? Semantics(
            button: true,
            container: true,
            excludeSemantics: true,
            label: 'Not delivered. Choose what to do',
            onTap: () => w.onFailedTap?.call(m.id),
            child: GestureDetector(
              key: Key('failed-glyph-${m.id}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => w.onFailedTap?.call(m.id),
              child: SizedBox(width: Hit.of(context), height: Hit.of(context), child: Center(child: AppSymbolIcon(AppSymbols.exclamationCircleFill, size: 24, color: c.danger))),
            ),
          )
        : null;

    final showAvatar = w.avatars && !mine;
    // The sender's name sits right above the first bubble of their run, and their avatar sits beside that name and bubble,
    // top-aligned, so the two always read together (iOS group chats). Later bubbles of the run keep the avatar's column empty.
    final senderLabel = (s.showSender && m.senderName != null)
        ? Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 2),
            child: Text(m.senderName!, key: Key('sender-${m.id}'), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppType.footnote.copyWith(color: c.textMuted)),
          )
        : null;
    final row = Row(
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showAvatar) ...[
          SizedBox(
            width: kBubbleAvatar,
            height: kBubbleAvatar,
            child: s.firstOfRun ? ExcludeSemantics(child: _Initials(key: Key('avatar-${m.id}'), name: m.senderName ?? '?', fill: style.fill, ink: style.initials)) : null,
          ),
          const SizedBox(width: 6),
        ],
        ?failedGlyph,
        Flexible(
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [?senderLabel, bubbleSemantics],
          ),
        ),
      ],
    );

    final showMeta = s.lastOfRun || w.showStatus;
    final meta = showMeta ? _metaLine(context, c, time, mine, failed) : null;

    return Padding(
      padding: EdgeInsets.fromLTRB(Layout.screenMargin, s.joinsOlder ? 2 : 8, Layout.screenMargin, 0),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (s.separatorAbove) _Separator(text: w.separatorText),
          row,
          if (meta != null) Padding(padding: EdgeInsets.only(top: 2, left: showAvatar ? kBubbleAvatar + 6 + 4 : 4, right: 4), child: meta),
          if (w.expanded && w.info != null) _InfoStrip(info: w.info!, mine: mine, onDetails: w.onDetails == null ? null : () => w.onDetails!(m.id)),
        ],
      ),
    );
  }

  Widget _metaLine(BuildContext context, AppColors c, String time, bool mine, bool failed) {
    final d = widget.delivery;
    final m = widget.message;
    final muted = AppType.caption.copyWith(color: c.textMuted);
    if (mine && d != null && widget.showStatus) {
      final color = failed
          ? c.danger
          : ((d.stage == DeliveryStage.delivered || d.stage == DeliveryStage.likely) ? c.accent : (d.canResend ? c.warning : c.textMuted));
      final status = ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppSymbolIcon(symbolFor(d.glyph), size: 13, color: color),
            const SizedBox(width: 4),
            Flexible(child: Text('${d.word} · $time', key: Key('status-${m.id}'), style: muted.copyWith(color: color), maxLines: 2, overflow: TextOverflow.ellipsis)),
          ],
        ),
      );
      final resend = widget.onResend;
      if (!d.canResend || resend == null) return status;
      // Nobody relayed it: one tap sends it again (official app: resend when no repeats were heard; here it is offered by itself).
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: status),
        const SizedBox(width: Gap.s),
        CupertinoButton(
          key: Key('resend-${m.id}'),
          padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
          minimumSize: Size(Hit.min, Hit.of(context) * 0.75),
          onPressed: () => resend(m.id),
          child: Text('Resend', style: AppType.caption.copyWith(color: c.accent, fontWeight: FontWeight.w600)),
        ),
      ]);
    }
    // Incoming time line (and the quiet time of an own message that needs no status): the weak-signal anomaly rides along.
    final snr = m.snr;
    final weak = !mine && snr != null && signalBars(snr) == 0;
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(time, key: Key('time-${m.id}'), style: muted)),
          if (weak) ...[
            const SizedBox(width: 6),
            SignalBars(bars: 0, color: c.warning),
            const SizedBox(width: 4),
            Text('Weak', style: muted.copyWith(color: c.warning)),
          ],
        ],
      ),
    );
  }
}

/// The 3-bar signal glyph: shape plus a word elsewhere, never colour alone.
class SignalBars extends StatelessWidget {
  final int bars;
  final Color color;
  final double height;
  const SignalBars({super.key, required this.bars, required this.color, this.height = 11});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: height * 1.2,
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 1.5),
            Expanded(
              child: Container(
                height: height * (0.4 + 0.3 * i),
                decoration: BoxDecoration(color: i < bars ? color : color.withValues(alpha: 0.28), borderRadius: BorderRadius.circular(1)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Initials extends StatelessWidget {
  final String name;
  final Color fill, ink;
  const _Initials({super.key, required this.name, required this.fill, required this.ink});
  @override
  Widget build(BuildContext context) {
    final t = name.trim();
    final ch = t.isEmpty ? '?' : String.fromCharCode(t.runes.first).toUpperCase();
    return Container(
      decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(ch, style: AppType.footnote.copyWith(fontWeight: FontWeight.w600, color: ink)),
    );
  }
}

class _Separator extends StatelessWidget {
  final String text;
  const _Separator({required this.text});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      header: true,
      label: text,
      child: ExcludeSemantics(
        child: Container(
          key: const Key('time-separator'),
          width: double.infinity,
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          alignment: Alignment.center,
          child: Text(text, style: AppType.caption.copyWith(color: c.textMuted, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

/// The line that opens under a tapped bubble: route chips, then SNR / RSSI with a word and bars. Stays until tapped again.
class _InfoStrip extends StatelessWidget {
  final MessageInfo info;
  final bool mine;
  final VoidCallback? onDetails;
  const _InfoStrip({required this.info, required this.mine, this.onDetails});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final muted = AppType.footnote.copyWith(color: c.textMuted);
    final reduce = Motion.reduced(context);
    return AnimatedSize(
      duration: reduce ? Duration.zero : Motion.listInsert,
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
        child: Column(
          key: const Key('info-strip'),
          crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: mine ? WrapAlignment.end : WrapAlignment.start,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: [
                Text(info.routeWord, style: muted.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary)),
                for (var i = 0; i < info.chips.length; i++) ...[
                  if (i == 0) Text('·', style: muted) else Text('›', style: muted),
                  _Chip(text: info.chips[i]),
                ],
              ],
            ),
            if (info.signalText != null || info.signalWord != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (info.signalBars != null) ...[SignalBars(bars: info.signalBars!, color: info.signalBars == 0 ? c.warning : c.ok), const SizedBox(width: 6)],
                  Flexible(child: Text([?info.signalText, ?info.signalWord].join(' · '), style: muted)),
                ]),
              ),
            if (onDetails != null)
              CupertinoButton(
                key: const Key('strip-details'),
                padding: EdgeInsets.zero,
                minimumSize: Size.square(Hit.of(context)),
                onPressed: onDetails,
                child: Text('Details', style: AppType.footnote.copyWith(color: c.accent, fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  const _Chip({required this.text});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Text(text, style: AppType.footnote.copyWith(color: c.textPrimary)),
    );
  }
}
