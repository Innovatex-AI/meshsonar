// The Chat badge counts exactly what the Chats list shows (Andy, Nov 8 2026, build 52: "unread message banner shows 17,
// I have no unread"). Cause: the list shows only the radio on screen, the badge counted every radio this phone had ever
// used. Also pinned here: blocked contacts, muted and system conversations never count; the figure comes from the messages
// (a stale stored counter cannot inflate it); outgoing messages never count; "Mark all as read" clears the radio on screen.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';

import '../ui/chat/chat_kit.dart';

const radioB = 'bb00000000000000000000000000000000000000000000000000000000000002';

void main() {
  late ChatKit kit;
  setUp(() => kit = ChatKit());
  tearDown(() => kit.dispose());

  void dmFromBob(String text, {String radio = radioA}) => kit.service
      .handleInbound(InboundDirectText(radioId: radio, senderPrefix: bobKey.substring(0, 12), timestamp: kit.clockMs ~/ 1000, text: text));

  test('unread on ANOTHER radio is not in the badge of the radio on screen (the 17-unread bug)', () async {
    final ch = await kit.channel(1, 'Ohio');
    kit.incoming(ch, 'Dave', 'on A');
    // 17 unread DMs that arrived through a different radio (an older radio or the iPad's)
    for (var i = 0; i < 17; i++) {
      dmFromBob('on B $i', radio: radioB);
    }
    expect(kit.service.unreadMessages(), 1, reason: 'only the radio whose list is on screen');
    expect(kit.service.unreadBadge(), 1);
    expect(kit.controller.conversationRows().map((r) => r.unread).fold<int>(0, (a, b) => a + b), 1,
        reason: 'badge == sum of what the list shows');
    // switching the list to radio B shows its 17
    kit.store.db.putSetting('last_radio_id', radioB);
    expect(kit.service.unreadMessages(), 17);
  });

  test('blocked contacts, muted and system conversations never count; outgoing never counts', () async {
    kit.bob();
    dmFromBob('one');
    dmFromBob('two');
    expect(kit.service.unreadMessages(), 2);
    final bob = kit.store.contacts.get(radioA, bobKey)!;
    kit.store.contacts.upsert(bob.copyWith(blocked: true));
    expect(kit.service.unreadMessages(), 0, reason: 'messages from before the block stay out of the badge');
    expect(kit.service.unreadBadge(), 0);

    final ch = await kit.channel(2, 'Quiet');
    kit.incoming(ch, 'Eve', 'x');
    kit.service.setNotifyMode(radioA, ch.convKey, NotifyMode.muted);
    expect(kit.service.unreadMessages(), 0);
  });

  test('a stale stored counter cannot inflate the badge or the row', () async {
    final ch = await kit.channel(1, 'Ohio');
    kit.incoming(ch, 'Dave', 'hi');
    kit.service.markRead(ch.convKey);
    // simulate drift from an older build: the denormalised counter says 9, no message is unread
    kit.store.db.raw.execute('UPDATE conversations SET unread = 9 WHERE conv_key = ?', [ch.convKey]);
    expect(kit.service.unreadMessages(), 0);
    expect(kit.service.unreadBadge(), 0);
    expect(kit.controller.conversationRows().single.unread, 0);
  });

  test('Mark all as read clears every conversation of the radio on screen and leaves other radios alone', () async {
    final a = await kit.channel(1, 'Ohio');
    final b = await kit.channel(2, 'Dayton');
    kit.incoming(a, 'Dave', 'a1');
    kit.incoming(b, 'Eve', 'b1');
    kit.incoming(b, 'Eve', 'b2');
    dmFromBob('other radio', radio: radioB);
    kit.service.markUnread(radioA, a.convKey);
    expect(kit.service.unreadMessages(), 3);
    kit.service.markAllRead();
    expect(kit.service.unreadMessages(), 0);
    expect(kit.service.unreadBadge(), 0);
    expect(kit.controller.conversationRows().every((r) => r.unread == 0 && !r.markedUnread), isTrue);
    kit.store.db.putSetting('last_radio_id', radioB);
    expect(kit.service.unreadMessages(), 1, reason: 'the other radio keeps its unread');
  });
}
