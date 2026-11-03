// The Chats list row model (chat/conversation_row.dart): ordering, pin, System last, drafts, the own-last delivery glyph,
// muted conversations kept out of the badge, and 500 rows computed in one go.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/conversation_row.dart';
import 'package:meshsonar/chat/models.dart';

const radio = 'aa00000000000000000000000000000000000000000000000000000000000001';
const now = 1000000000000;

/// The first 12 hex characters (the conversation key) differ per index.
String keyOf(int i) => i.toRadixString(16).padLeft(12, '0').padRight(64, '0');

ConversationSummary dm(int i, {int? ts, int unread = 0, bool pinned = false, NotifyMode mode = NotifyMode.all, int? mutedUntil, String? preview}) => ConversationSummary(
      key: ConvKey.dm(keyOf(i)),
      kind: ConvKind.dm,
      radioId: radio,
      title: 'Person $i',
      lastPreview: preview ?? 'hello $i',
      lastTsMs: ts,
      unread: unread,
      pinned: pinned,
      notifyMode: mode,
      mutedUntilMs: mutedUntil,
    );

Contact person(int i, {ContactType type = ContactType.companion}) => Contact(radioId: radio, publicKey: keyOf(i), type: type, name: 'Person $i');

List<ConversationRow> build({
  List<ConversationSummary> summaries = const [],
  List<Channel> channels = const [],
  List<Contact> contacts = const [],
  Map<String, LastMessageInfo> last = const {},
  Map<String, String> drafts = const {},
}) =>
    buildConversationRows(summaries: summaries, channels: channels, contacts: contacts, lastMessages: last, drafts: drafts, nowMs: now);

void main() {
  test('pinned first, then newest first, ties broken by title so the order never shuffles', () {
    final rows = build(summaries: [
      dm(1, ts: 100),
      dm(2, ts: 300),
      dm(3, ts: 200, pinned: true),
      dm(4, ts: 300),
    ], contacts: [for (var i = 1; i <= 4; i++) person(i)]);
    expect(rows.map((r) => r.title), ['Person 3', 'Person 2', 'Person 4', 'Person 1']);
  });

  test('the System (wardrive) channel is always last, even when it is the newest', () {
    final ch = const Channel(id: 9, radioId: radio, slot: 0, name: '#wardriving', kind: ChannelKind.system);
    final sys = ConversationSummary(key: 'c:9', kind: ConvKind.channel, radioId: radio, title: '#wardriving', lastTsMs: 999, lastPreview: 'ping', isSystem: true);
    final rows = build(summaries: [sys, dm(1, ts: 5)], channels: [ch], contacts: [person(1)]);
    expect(rows.map((r) => r.title), ['Person 1', '#wardriving']);
    expect(rows.last.isSystem, isTrue);
    expect(rows.last.kind, RowKind.system);
  });

  test('joined channels are listed even with no messages; empty DMs are not', () {
    final ch = const Channel(id: 3, radioId: radio, slot: 1, name: 'Ohio', kind: ChannelKind.hashtag);
    final empty = ConversationSummary(key: ConvKey.dm(keyOf(7)), kind: ConvKind.dm, radioId: radio, title: 'Nobody');
    final rows = build(summaries: [empty], channels: [ch]);
    expect(rows.map((r) => r.title), ['Ohio']);
    expect(rows.single.kind, RowKind.hashtagChannel);
    expect(rows.single.hasHistory, isFalse);
  });

  test('a channel that only lives on the phone is flagged off-radio', () {
    final ch = const Channel(id: 3, radioId: radio, name: 'Old', kind: ChannelKind.private);
    expect(build(channels: [ch]).single.offRadio, isTrue);
  });

  test('a draft replaces the preview and lists a conversation that has no messages yet', () {
    final key = ConvKey.dm(keyOf(2));
    final rows = build(summaries: [dm(1, ts: 50)], contacts: [person(1), person(2)], drafts: {key: ' are you still there ', ConvKey.dm(keyOf(1)): ''});
    expect(rows.map((r) => r.key), contains(key));
    final d = rows.firstWhere((r) => r.key == key);
    expect(d.hasDraft, isTrue);
    expect(d.preview, 'are you still there');
    expect(d.title, 'Person 2');
    expect(rows.firstWhere((r) => r.title == 'Person 1').hasDraft, isFalse, reason: 'whitespace-only drafts do not count');
  });

  group('own last message glyph', () {
    RowDelivery of(MessageState s, {bool channel = false, Direction d = Direction.outgoing}) =>
        deliveryFor(LastMessageInfo(direction: d, state: s), isChannel: channel);

    test('maps every outgoing state', () {
      expect(of(MessageState.queued), RowDelivery.queued);
      expect(of(MessageState.sending), RowDelivery.queued);
      expect(of(MessageState.retrying), RowDelivery.queued);
      expect(of(MessageState.sent), RowDelivery.sent);
      expect(of(MessageState.heard), RowDelivery.heard);
      expect(of(MessageState.acked), RowDelivery.delivered);
      expect(of(MessageState.failed), RowDelivery.failed);
    });
    test('channels never show Delivered (no receipts): the cap is Heard', () {
      expect(of(MessageState.acked, channel: true), RowDelivery.heard);
    });
    test('incoming messages and no message show no glyph', () {
      expect(of(MessageState.received, d: Direction.incoming), RowDelivery.none);
      expect(deliveryFor(null, isChannel: false), RowDelivery.none);
    });
    test('a draft hides the glyph', () {
      final k = ConvKey.dm(keyOf(1));
      final rows = build(
        summaries: [dm(1, ts: 5)],
        contacts: [person(1)],
        last: {k: const LastMessageInfo(direction: Direction.outgoing, state: MessageState.acked)},
        drafts: {k: 'typing'},
      );
      expect(rows.single.delivery, RowDelivery.none);
    });
  });

  test('channels and rooms prefix the last incoming message with the sender; DMs and own messages do not', () {
    final ch = const Channel(id: 3, radioId: radio, slot: 1, name: 'Ohio', kind: ChannelKind.public);
    final summaries = [
      ConversationSummary(key: 'c:3', kind: ConvKind.channel, radioId: radio, title: 'Ohio', lastTsMs: 10, lastPreview: 'net at 8'),
      dm(1, ts: 5),
    ];
    final rows = build(
      summaries: summaries,
      channels: [ch],
      contacts: [person(1)],
      last: {
        'c:3': const LastMessageInfo(direction: Direction.incoming, state: MessageState.received, senderName: 'Dave'),
        ConvKey.dm(keyOf(1)): const LastMessageInfo(direction: Direction.incoming, state: MessageState.received, senderName: 'Person 1'),
      },
    );
    expect(rows.firstWhere((r) => r.isChannel).previewSender, 'Dave');
    expect(rows.firstWhere((r) => !r.isChannel).previewSender, isNull);
  });

  test('contact types pick the avatar kind', () {
    final rows = build(
      summaries: [
        for (var i = 1; i <= 4; i++) dm(i, ts: i),
        ConversationSummary(key: ConvKey.room(keyOf(5)), kind: ConvKind.room, radioId: radio, title: 'Room', lastTsMs: 9, lastPreview: 'hi'),
      ],
      contacts: [person(1), person(2, type: ContactType.repeater), person(3, type: ContactType.sensor), person(4, type: ContactType.room), person(5, type: ContactType.room)],
    );
    RowKind k(String t) => rows.firstWhere((r) => r.title == t).kind;
    expect(k('Person 1'), RowKind.person);
    expect(k('Person 2'), RowKind.repeater);
    expect(k('Person 3'), RowKind.sensor);
    expect(k('Person 4'), RowKind.room);
  });

  group('tab badge', () {
    test('sums unread MESSAGES, not conversations', () {
      final rows = build(summaries: [dm(1, ts: 1, unread: 3), dm(2, ts: 2, unread: 4)], contacts: [person(1), person(2)]);
      expect(unreadMessageTotal(rows), 7);
    });
    test('muted conversations are excluded, a mute that has run out counts again', () {
      final rows = build(
        summaries: [
          dm(1, ts: 1, unread: 3, mode: NotifyMode.muted), // until I unmute
          dm(2, ts: 2, unread: 4, mode: NotifyMode.muted, mutedUntil: now + 60000), // still muted
          dm(3, ts: 3, unread: 5, mode: NotifyMode.muted, mutedUntil: now - 1), // expired
          dm(4, ts: 4, unread: 1),
        ],
        contacts: [for (var i = 1; i <= 4; i++) person(i)],
      );
      expect(rows.firstWhere((r) => r.title == 'Person 1').muted, isTrue);
      expect(rows.firstWhere((r) => r.title == 'Person 3').muted, isFalse);
      expect(unreadMessageTotal(rows), 6);
    });
    test('System unread never counts', () {
      final ch = const Channel(id: 9, radioId: radio, slot: 0, name: '#wardriving', kind: ChannelKind.system);
      final sys = ConversationSummary(key: 'c:9', kind: ConvKind.channel, radioId: radio, title: '#wardriving', lastTsMs: 1, unread: 40, isSystem: true);
      expect(unreadMessageTotal(build(summaries: [sys], channels: [ch])), 0);
    });
  });

  test('500 rows: ordered, unique keys, computed quickly', () {
    final summaries = [
      for (var i = 0; i < 400; i++) dm(i, ts: 1000 + (i * 37) % 997, unread: i % 5, pinned: i % 50 == 0),
      for (var i = 0; i < 100; i++)
        ConversationSummary(key: 'c:$i', kind: ConvKind.channel, radioId: radio, title: 'Chan $i', lastTsMs: 2000 + i, lastPreview: 'm', unread: 1),
    ];
    final channels = [for (var i = 0; i < 100; i++) Channel(id: i, radioId: radio, slot: i % 8, name: 'Chan $i', kind: ChannelKind.private)];
    final sw = Stopwatch()..start();
    final rows = build(summaries: summaries, channels: channels, contacts: [for (var i = 0; i < 400; i++) person(i)]);
    sw.stop();
    expect(rows.length, 500);
    expect(rows.map((r) => r.key).toSet().length, 500);
    final pinnedCount = rows.where((r) => r.pinned).length;
    expect(pinnedCount, 8);
    expect(rows.take(pinnedCount).every((r) => r.pinned), isTrue, reason: 'pinned rows lead');
    for (var i = pinnedCount; i < rows.length - 1; i++) {
      expect((rows[i].lastTsMs ?? 0) >= (rows[i + 1].lastTsMs ?? 0), isTrue, reason: 'row $i is not older than the next');
    }
    expect(sw.elapsedMilliseconds, lessThan(500));
  });
}
