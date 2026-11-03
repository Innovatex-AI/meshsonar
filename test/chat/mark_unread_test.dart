import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';

import '../ui/chat/chat_kit.dart';

void main() {
  late ChatKit kit;
  setUp(() => kit = ChatKit());
  tearDown(() => kit.dispose());

  test('Mark unread counts as one in the list and both badges; markRead and incoming reading clear it', () async {
    final ch = await kit.channel(1, 'Ohio');
    kit.incoming(ch, 'Dave', 'hi');
    kit.service.markRead(ch.convKey);
    expect(kit.service.unreadMessages(), 0);
    expect(kit.service.unreadBadge(), 0);

    kit.service.markUnread(radioA, ch.convKey);
    expect(kit.service.conversation(ch.convKey)!.markedUnread, isTrue);
    expect(kit.service.unreadMessages(), 1);
    expect(kit.service.unreadBadge(), 1);
    expect(kit.controller.conversationRows().single.unread, 1);

    kit.service.markRead(ch.convKey);
    expect(kit.service.conversation(ch.convKey)!.markedUnread, isFalse);
    expect(kit.service.unreadMessages(), 0);
  });

  test('real unread wins over the manual mark; muted manual marks stay out of the badge', () async {
    final ch = await kit.channel(1, 'Ohio');
    kit.incoming(ch, 'Dave', 'a');
    kit.incoming(ch, 'Dave', 'b');
    kit.service.markUnread(radioA, ch.convKey);
    expect(kit.service.unreadMessages(), 2);
    kit.service.markRead(ch.convKey);
    kit.service.markUnread(radioA, ch.convKey);
    kit.service.setNotifyMode(radioA, ch.convKey, NotifyMode.muted);
    expect(kit.service.unreadMessages(), 0);
    expect(kit.controller.conversationRows().single.markedUnread, isTrue);
  });
}
