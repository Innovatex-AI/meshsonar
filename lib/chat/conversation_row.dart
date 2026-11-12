// ConversationRow: the pure-Dart row model of the Chats list (chat redesign plan 4.1, WP2). Everything the list draws is
// decided here, once per change, from plain data; the widget only paints it. No Flutter imports.
//
//   * sources: conversation summaries (those with history), the joined channels (always listed, even with no messages yet),
//     contacts (for the avatar kind), the last message of each conversation (delivery glyph, channel sender prefix) and
//     drafts (a conversation with a draft is listed even before its first message);
//   * order: pinned first, then newest first (title, then key, break ties so the order never shuffles); the System group
//     (the wardrive channel) always last;
//   * badge: unread MESSAGES of unmuted, non-system conversations (D19), summed by [unreadMessageTotal].
import 'models.dart';

/// What the avatar and its small type badge show.
enum RowKind { person, repeater, sensor, room, publicChannel, hashtagChannel, privateChannel, system }

/// The delivery state of the last message when it is the person's own (glyphs: plan 4.2 table). Channels never reach
/// [delivered] (they have no receipts).
enum RowDelivery { none, queued, sent, heard, delivered, likely, failed }

/// The last message of a conversation, as far as the list cares.
class LastMessageInfo {
  final Direction direction;
  final MessageState state;
  final String? senderName;
  const LastMessageInfo({required this.direction, required this.state, this.senderName});
}

class ConversationRow {
  final String key;
  final ConvKind convKind;
  final RowKind kind;
  final String title;

  /// Key the avatar colour is derived from (the contact's public key, or the channel's local id).
  final String avatarSeed;
  final int? lastTsMs;

  /// Last message text, or the draft text when [hasDraft].
  final String preview;

  /// Who said the last incoming message in a channel or room ("Maya"); null for DMs and own messages.
  final String? previewSender;
  final bool hasDraft;
  final RowDelivery delivery;
  final int unread;

  /// Unread because the person chose "Mark unread" (shows as one unread; [unread] is then at least 1).
  final bool markedUnread;
  final bool muted;
  final bool pinned;
  final bool isSystem;

  /// A channel that only lives on the phone (evicted from the radio).
  final bool offRadio;
  final bool hasHistory;
  final int? channelId;
  final String? contactKey;

  const ConversationRow({
    required this.key,
    required this.convKind,
    required this.kind,
    required this.title,
    required this.avatarSeed,
    this.lastTsMs,
    this.preview = '',
    this.previewSender,
    this.hasDraft = false,
    this.delivery = RowDelivery.none,
    this.unread = 0,
    this.markedUnread = false,
    this.muted = false,
    this.pinned = false,
    this.isSystem = false,
    this.offRadio = false,
    this.hasHistory = false,
    this.channelId,
    this.contactKey,
  });

  bool get isChannel => convKind == ConvKind.channel;

  /// Counts toward the tab badge.
  bool get countsForBadge => !muted && !isSystem && unread > 0;
}

RowDelivery deliveryFor(LastMessageInfo? last, {required bool isChannel}) {
  if (last == null || last.direction != Direction.outgoing) return RowDelivery.none;
  switch (last.state) {
    case MessageState.queued:
    case MessageState.sending:
    case MessageState.retrying:
      return RowDelivery.queued;
    case MessageState.sent:
      return RowDelivery.sent;
    case MessageState.heard:
      return RowDelivery.heard;
    case MessageState.acked:
      // Channels have no delivery receipts: the most they can show is Heard.
      return isChannel ? RowDelivery.heard : RowDelivery.delivered;
    case MessageState.likelyDelivered:
      return isChannel ? RowDelivery.sent : RowDelivery.likely;
    case MessageState.failed:
      return RowDelivery.failed;
    case MessageState.received:
      return RowDelivery.none;
  }
}

RowKind _kindOfContact(ContactType t) => switch (t) {
      ContactType.companion => RowKind.person,
      ContactType.repeater => RowKind.repeater,
      ContactType.room => RowKind.room,
      ContactType.sensor => RowKind.sensor,
    };

RowKind _kindOfChannel(Channel c) => switch (c.kind) {
      ChannelKind.public => RowKind.publicChannel,
      ChannelKind.hashtag => RowKind.hashtagChannel,
      ChannelKind.private => RowKind.privateChannel,
      ChannelKind.system => RowKind.system,
    };

/// Builds the Chats list. [summaries] must include system conversations if they should appear in the System group.
List<ConversationRow> buildConversationRows({
  required Iterable<ConversationSummary> summaries,
  required Iterable<Channel> channels,
  required Iterable<Contact> contacts,
  required Map<String, LastMessageInfo> lastMessages,
  required Map<String, String> drafts,
  required int nowMs,
}) {
  final byChannel = {for (final c in channels) if (c.id != null) c.convKey: c};
  final byPrefix = <String, Contact>{for (final c in contacts) c.prefix: c};
  final seen = <String>{};
  final rows = <ConversationRow>[];

  ConversationRow make({required String key, required ConvKind convKind, ConversationSummary? s, Channel? ch, Contact? contact}) {
    final last = lastMessages[key];
    final draft = (drafts[key] ?? '').trim();
    final hasDraft = draft.isNotEmpty;
    final isChannel = convKind == ConvKind.channel;
    final kind = ch != null
        ? _kindOfChannel(ch)
        : contact != null
            ? _kindOfContact(contact.type)
            : (convKind == ConvKind.room ? RowKind.room : RowKind.person);
    final muted = s?.isMutedAt(nowMs) ?? false;
    final title = ch?.name ?? contact?.displayName ?? s?.title ?? key;
    final lastText = s?.lastPreview;
    String? sender;
    if (!hasDraft && lastText != null && (isChannel || convKind == ConvKind.room) && last != null && last.direction == Direction.incoming) {
      final n = last.senderName;
      if (n != null && n.isNotEmpty) sender = n;
    }
    return ConversationRow(
      key: key,
      convKind: convKind,
      kind: kind,
      title: title,
      avatarSeed: ch != null ? '${ch.id}' : (contact?.publicKey ?? ConvKey.body(key)),
      lastTsMs: s?.lastTsMs,
      preview: hasDraft ? draft : (lastText ?? ''),
      previewSender: sender,
      hasDraft: hasDraft,
      delivery: hasDraft ? RowDelivery.none : deliveryFor(last, isChannel: isChannel),
      unread: (s?.unread ?? 0) > 0 ? s!.unread : ((s?.markedUnread ?? false) ? 1 : 0),
      markedUnread: s?.markedUnread ?? false,
      muted: muted,
      pinned: s?.pinned ?? false,
      isSystem: kind == RowKind.system || (s?.isSystem ?? false),
      offRadio: ch != null && ch.slot == null,
      hasHistory: s?.lastTsMs != null,
      channelId: ch?.id,
      contactKey: contact?.publicKey,
    );
  }

  for (final s in summaries) {
    final isEmpty = s.lastTsMs == null;
    final hasDraft = (drafts[s.key] ?? '').trim().isNotEmpty;
    final ch = s.kind == ConvKind.channel ? byChannel[s.key] : null;
    // A conversation with no messages, no draft and no pin is noise unless it is a joined channel (added below).
    if (isEmpty && !hasDraft && !s.pinned && ch == null) continue;
    final contact = s.kind == ConvKind.channel ? null : byPrefix[ConvKey.body(s.key)];
    seen.add(s.key);
    rows.add(make(key: s.key, convKind: s.kind, s: s, ch: ch, contact: contact));
  }
  for (final ch in channels) {
    if (ch.id == null) continue;
    final k = ch.convKey;
    if (seen.contains(k)) continue;
    seen.add(k);
    rows.add(make(key: k, convKind: ConvKind.channel, ch: ch));
  }
  // Drafts for DMs that have no conversation row yet.
  for (final e in drafts.entries) {
    if (seen.contains(e.key) || e.value.trim().isEmpty) continue;
    final kind = ConvKey.kindOf(e.key);
    if (kind == null || kind == ConvKind.channel) continue;
    seen.add(e.key);
    rows.add(make(key: e.key, convKind: kind, contact: byPrefix[ConvKey.body(e.key)]));
  }

  int cmp(ConversationRow a, ConversationRow b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final ta = a.lastTsMs ?? 0, tb = b.lastTsMs ?? 0;
    if (ta != tb) return tb.compareTo(ta);
    final t = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return t != 0 ? t : a.key.compareTo(b.key);
  }

  final normal = rows.where((r) => !r.isSystem).toList()..sort(cmp);
  final system = rows.where((r) => r.isSystem).toList()..sort(cmp);
  return [...normal, ...system];
}

/// How every unread badge prints [n]: the number, capped at "99+" (tab badge, row pills, mini bars).
String unreadCountLabel(int n) => n > 99 ? '99+' : '$n';

/// The Chat tab badge: unread messages, muted and system conversations excluded (D19).
int unreadMessageTotal(Iterable<ConversationRow> rows) {
  var n = 0;
  for (final r in rows) {
    if (r.countsForBadge) n += r.unread;
  }
  return n;
}
