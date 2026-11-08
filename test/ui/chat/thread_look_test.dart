// The conversation (thread) screen's look (Andy, Nov 8: "the messaging screens are ugly"): seen on the iPhone 17 simulator with
// integration_test/chat_thread_look_test.dart, pinned here.
//  * every Text had Flutter's debug fallback style (yellow double underline): CupertinoPageScaffold gives no Material text style;
//  * bubbles stretched to full width (a Container with `alignment` fills its constraints);
//  * the avatar sat beside the LAST bubble of a run and the name above the FIRST, so they drifted apart;
//  * sender names were coloured, and the header avatar used another colour seed than the Chats list.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/message_menu.dart';
import 'package:meshsonar/ui/design/avatar_style.dart';
import 'package:meshsonar/ui/design/tokens.dart';

import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  setUp(() {
    kit = ChatKit();
    MessageMenu.useContextMenu = false;
  });
  tearDown(() => kit.dispose());

  Future<Channel> thread(WidgetTester tester) async {
    setSize(tester);
    final ch = await kit.channel(1, 'Ohio', kind: ChannelKind.hashtag);
    kit.incoming(ch, 'Sam', 'Copy. Mobile on 33 heading east, listening on the hilltop repeater the whole way.');
    kit.incoming(ch, 'Sam', 'ok');
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    return ch;
  }

  List<ChatMessage> msgs(Channel ch) => kit.service.page(ch.convKey).messages.reversed.toList(); // oldest first

  testWidgets('message text never gets the debug fallback style (no yellow underline)', (tester) async {
    final ch = await thread(tester);
    for (final m in msgs(ch)) {
      final ctx = tester.element(find.byKey(Key('bubble-${m.id}')));
      final style = DefaultTextStyle.of(ctx).style;
      expect(style.decoration, anyOf(isNull, TextDecoration.none), reason: 'bubble ${m.text}');
    }
    final sender = tester.element(find.byKey(Key('sender-${msgs(ch).first.id}')));
    expect(DefaultTextStyle.of(sender).style.decoration, anyOf(isNull, TextDecoration.none));
  });

  testWidgets('a bubble hugs its text: "ok" is short, a long message is wide', (tester) async {
    final ch = await thread(tester);
    final m = msgs(ch);
    final short = tester.getSize(find.byKey(Key('bubble-${m[1].id}'))).width;
    final long = tester.getSize(find.byKey(Key('bubble-${m[0].id}'))).width;
    expect(short, lessThan(100));
    expect(long, greaterThan(200));
  });

  testWidgets('the avatar sits beside the first bubble of a run, top-aligned with the grey sender name', (tester) async {
    final ch = await thread(tester);
    final m = msgs(ch);
    expect(find.byKey(Key('avatar-${m[0].id}')), findsOneWidget);
    expect(find.byKey(Key('avatar-${m[1].id}')), findsNothing, reason: 'one avatar per run, on its first bubble');
    final avatarTop = tester.getTopLeft(find.byKey(Key('avatar-${m[0].id}'))).dy;
    final nameTop = tester.getTopLeft(find.byKey(Key('sender-${m[0].id}'))).dy;
    expect((avatarTop - nameTop).abs(), lessThan(4));
    final name = tester.widget<Text>(find.byKey(Key('sender-${m[0].id}')));
    final c = AppColors.of(tester.element(find.byKey(Key('sender-${m[0].id}'))));
    expect(name.style?.color, c.textMuted, reason: 'quiet grey names; the colour is in the avatar');
  });

  testWidgets('the header avatar has the same colour as the conversation\'s row in the Chats list', (tester) async {
    final ch = await thread(tester);
    final c = AppColors.of(tester.element(find.byType(ConversationScreen)));
    final want = avatarStyle('${ch.id}', c).fill; // the Chats list row's seed (conversation_row.dart avatarSeed)
    final boxes = tester.widgetList<Container>(find.byType(Container)).where((w) => w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color == want);
    expect(boxes, isNotEmpty);
  });
}
