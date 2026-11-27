// The Contacts half of the Chat tab as the app builds it (ContactsTab over the real ChatController): list -> direct message
// with the route strip -> contact details, and how the strip follows the radio.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/ui/chat/channel_flows.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/contacts/contact_profile_screen.dart';
import 'package:meshsonar/ui/contacts/contacts_tab.dart';

import '../../chat/contact_support.dart';
import '../chat/chat_kit.dart' as kitlib;
import 'contacts_ui_support.dart' show expectAccessibleIos;

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

  /// Tap on a person opens the profile now; Message is the leading swipe action.
  Future<void> openChat(WidgetTester tester, String name, int n) async {
    await tester.drag(find.text(name), const Offset(300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('swipe-message-${keyN(n).substring(0, 8)}')));
    await tester.pumpAndSettle();
  }

  setUp(() => kit = kitlib.ChatKit());
  tearDown(() => kit.dispose());

  testWidgets('tapping a person opens the profile; Message (swipe) opens the conversation with the route text; the title block opens the profile', (tester) async {
    await boot(tester);
    expect(find.text('Ann'), findsOneWidget);
    await tester.tap(find.text('Ann'));
    await tester.pumpAndSettle();
    expect(find.byType(ContactProfileScreen), findsOneWidget, reason: 'tap = profile');
    await tester.tap(find.byKey(const Key('contact-back')));
    await tester.pumpAndSettle();
    await openChat(tester, 'Ann', 1);
    expect(find.byType(ConversationScreen), findsOneWidget);
    expect(find.byKey(const Key('dm-route-text')), findsOneWidget);
    expect(find.text('No route yet'), findsOneWidget);
    await tester.tap(find.byKey(const Key('conv-title')));
    await tester.pumpAndSettle();
    expect(find.byType(ContactProfileScreen), findsOneWidget);
  });

  testWidgets('a message written in the conversation goes out through the chat service', (tester) async {
    await boot(tester);
    await openChat(tester, 'Ann', 1);
    await tester.enterText(find.byKey(const Key('composer-field')), 'hello Ann');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();
    await kit.service.pump();
    await tester.pump();
    expect(kit.sink.directs.single.text, 'hello Ann');
    expect(find.text('hello Ann'), findsOneWidget);
  });

  testWidgets('the route text follows the radio: a learned route says Via N repeaters', (tester) async {
    await boot(tester);
    await openChat(tester, 'Ann', 1);
    expect(find.text('No route yet'), findsOneWidget);
    port.radioAdd(radioContact(1, name: 'Ann', path: true));
    await kit.service.contacts.pathUpdated(keyN(1));
    await tester.pump();
    await tester.pump();
    expect(find.text('Via 1 repeater'), findsOneWidget);
    expect(find.text('No route yet'), findsNothing);
  });

  testWidgets('radio away: the composer says messages wait', (tester) async {
    await boot(tester);
    await openChat(tester, 'Ann', 1);
    kit.service.contacts.detach();
    await tester.pump();
    await tester.pump();
    expect(find.text('Radio not connected. Sends when it connects.'), findsOneWidget);
  });

  testWidgets('the subtitle says the route the radio holds; build 76 "always search" left in storage is never said', (tester) async {
    await boot(tester);
    kit.store.db.raw.execute("UPDATE contacts SET path_mode = 'flood', force_flood = 1");
    await openChat(tester, 'Ann', 1);
    expect(find.text('Searching'), findsNothing);
    expect(find.text('No route yet'), findsOneWidget);
  });

  testWidgets('repeaters and rooms are not in Contacts (they live under Radio)', (tester) async {
    await boot(tester);
    port.radioAdd(radioContact(3, name: 'Lounge', type: ContactType.room));
    await kit.service.contacts.syncNow();
    await tester.pump();
    expect(find.text('Ann'), findsOneWidget);
    expect(find.text('Tower'), findsNothing);
    expect(find.text('Lounge'), findsNothing);
  });

  group('a tapped or scanned meshcore:// link', () {
    Future<BuildContext> hostCtx(WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(kitlib.host(Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }))));
      return ctx;
    }

    testWidgets('a contact link is added through the contact book', (tester) async {
      kitlib.setSize(tester);
      port = FakeRadioPort(capacity: 100);
      kit.service.contacts.attach(port);
      final ctx = await hostCtx(tester);
      await handleMeshLink(ctx, kit.controller, 'meshcore://contact/add?name=Sam+W8SAM&public_key=${keyN(9)}&type=1');
      await tester.pump();
      expect(find.textContaining('Added Sam W8SAM'), findsOneWidget);
      expect(kit.store.contacts.get(kitlib.radioA, keyN(9))!.onRadio, isTrue);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('an advert link is added too, and a second time says it is already there', (tester) async {
      kitlib.setSize(tester);
      port = FakeRadioPort(capacity: 100);
      kit.service.contacts.attach(port);
      final ctx = await hostCtx(tester);
      final raw = buildUnsignedAdvertPacket(List.filled(32, 0x44), type: 2, name: 'Ridge', timestamp: 1760000600);
      final link = 'meshcore://${raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      await handleMeshLink(ctx, kit.controller, link);
      await tester.pump();
      expect(find.textContaining('Added Ridge'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await handleMeshLink(ctx, kit.controller, link);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Already in Contacts: Ridge'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('before any radio was seen it says so instead of failing', (tester) async {
      kitlib.setSize(tester);
      final bare = kitlib.ChatKit(knownRadio: false);
      addTearDown(bare.dispose);
      final ctx = await hostCtx(tester);
      await handleMeshLink(ctx, bare.controller, 'meshcore://contact/add?name=Sam&public_key=${keyN(9)}&type=1');
      await tester.pump();
      expect(find.textContaining('Connect your radio once'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });
  });

  for (final (w, h, scale, dark) in [(390.0, 844.0, 1.0, false), (390.0, 844.0, 2.5, true), (834.0, 1194.0, 1.0, false)]) {
    testWidgets('conversation at ${w.toInt()}x${h.toInt()} x$scale ${dark ? 'dark' : 'light'}: no overflow, accessible', (tester) async {
      await boot(tester, w: w, h: h, scale: scale, b: dark ? Brightness.dark : Brightness.light);
      await tester.dragUntilVisible(find.text('Ann'), find.byKey(const Key('contacts-list')), const Offset(0, -120));
      await tester.pump();
      await openChat(tester, 'Ann', 1);
      final ex = tester.takeException();
      expect(ex, isNull, reason: ex is FlutterError ? ex.diagnostics.map((n) => n.toStringDeep()).join('\n') : '$ex');
      await expectAccessibleIos(tester);
    });
  }
}
