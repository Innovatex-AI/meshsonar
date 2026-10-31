// The Contacts half of the Chat tab as the app builds it (ContactsTab over the real ChatController): list -> direct message
// with the route strip -> contact details, and how the strip follows the radio.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/contacts/contact_detail_screen.dart';
import 'package:meshsonar/ui/contacts/contacts_tab.dart';

import '../../chat/contact_support.dart';
import '../chat/chat_kit.dart' as kitlib;
import 'contacts_ui_support.dart' show expectAccessible;

void main() {
  late kitlib.ChatKit kit;
  late FakeRadioPort port;

  Future<void> boot(WidgetTester tester, {bool linked = true, double w = 390, double h = 844, double scale = 1.0, Brightness b = Brightness.light}) async {
    kitlib.setSize(tester, w: w, h: h, scale: scale);
    port = FakeRadioPort(capacity: 100)..radioId = kitlib.radioA;
    port.radioAdd(radioContact(1, name: 'Ann'));
    port.radioAdd(radioContact(2, name: 'Tower', type: ContactType.repeater));
    kit.service.contacts.attach(port);
    await kit.service.contacts.syncNow();
    if (!linked) {
      port.isConnected = false;
    }
    await tester.pumpWidget(kitlib.host(Scaffold(body: ContactsTab(chat: kit.controller)), brightness: b));
    await tester.pump();
  }

  setUp(() => kit = kitlib.ChatKit());
  tearDown(() => kit.dispose());

  testWidgets('tapping a person opens the conversation with the route strip; the strip opens the details', (tester) async {
    await boot(tester);
    expect(find.text('Ann'), findsOneWidget);
    await tester.tap(find.text('Ann'));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationScreen), findsOneWidget);
    expect(find.byKey(const Key('dm-route-header')), findsOneWidget);
    expect(find.textContaining('No saved route yet'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dm-route-header')));
    await tester.pumpAndSettle();
    expect(find.byType(ContactDetailScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dm-contact-info')));
    await tester.pumpAndSettle();
    expect(find.byType(ContactDetailScreen), findsOneWidget);
  });

  testWidgets('a message written in the conversation goes out through the chat service', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Ann'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('composer-field')), 'hello Ann');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();
    await kit.service.pump();
    await tester.pump();
    expect(kit.sink.directs.single.text, 'hello Ann');
    expect(find.text('hello Ann'), findsOneWidget);
  });

  testWidgets('the strip follows the radio: a learned route shows hops and when they were last heard', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Ann'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No saved route yet'), findsOneWidget);
    port.radioAdd(radioContact(1, name: 'Ann', path: true));
    await kit.service.contacts.pathUpdated(keyN(1));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Direct, 1 hop'), findsOneWidget);
    expect(find.textContaining('No saved route yet'), findsNothing);
  });

  testWidgets('radio away: the strip says messages wait', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Ann'));
    await tester.pumpAndSettle();
    kit.service.contacts.detach();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Messages wait here and send when it is back'), findsOneWidget);
  });

  testWidgets('"always flood" is said on the strip', (tester) async {
    await boot(tester);
    kit.service.contacts.setForceFlood(keyN(1), true);
    await tester.tap(find.text('Ann'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Always sent by flood'), findsOneWidget);
  });

  testWidgets('a repeater opens its details, not a conversation (it has no inbox)', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Tower'));
    await tester.pumpAndSettle();
    expect(find.byType(ContactDetailScreen), findsOneWidget);
    expect(find.byType(ConversationScreen), findsNothing);
  });

  for (final (w, h, scale, dark) in [(390.0, 844.0, 1.0, false), (390.0, 844.0, 2.5, true), (834.0, 1194.0, 1.0, false)]) {
    testWidgets('conversation with the strip at ${w.toInt()}x${h.toInt()} x$scale ${dark ? 'dark' : 'light'}: no overflow, accessible', (tester) async {
      await boot(tester, w: w, h: h, scale: scale, b: dark ? Brightness.dark : Brightness.light);
      await tester.dragUntilVisible(find.text('Ann'), find.byKey(const Key('contacts-list')), const Offset(0, -120));
      await tester.pump();
      await tester.tap(find.text('Ann'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectAccessible(tester);
    });
  }
}
