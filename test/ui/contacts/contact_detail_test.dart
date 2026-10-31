
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/contacts/contact_detail_screen.dart';
import 'package:meshsonar/ui/contacts/contacts_controller.dart';
import 'package:meshsonar/ui/contacts/qr_view.dart';

import '../../chat/contact_support.dart';
import '../../chat/support.dart';
import 'contacts_ui_support.dart';

Widget fakeMap(BuildContext c, double lat, double lon) => SizedBox(height: 180, key: const Key('fake-map'), child: Text('map $lat $lon'));

final shared = <String>[];

Future<void> pumpDetail(WidgetTester tester, ContactsRig rig, String key,
    {Brightness b = Brightness.light, Widget Function(BuildContext, Contact)? claim}) async {
  await tester.pumpWidget(MaterialApp(
    key: UniqueKey(),
    theme: ThemeData(brightness: b, useMaterial3: true),
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const Key('open'),
            onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
              builder: (_) => ContactDetailScreen(
                controller: rig.controller,
                publicKey: key,
                mapBuilder: fakeMap,
                shareText: (text, {subject}) async => shared.add(text),
                claimBuilder: claim ?? (c, contact) => const SizedBox(key: Key('fake-claim'), height: 48, child: Text('Claim this repeater')),
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: find.descendant(of: find.byKey(const Key('contact-detail')), matching: find.byType(Scrollable)).first);
  await tester.pump();
}

void main() {
  late ContactsRig rig;
  final clip = <String>[];

  // The rig must be built INSIDE the test's fake-async zone, or the controller's microtasks never run under pump().
  void tw(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      rig = ContactsRig();
      await body(tester);
    });
  }

  setUp(() async {
    shared.clear();
    clip.clear();
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clip.add((call.arguments as Map)['text'] as String);
      return null;
    });
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    rig.dispose();
  });

  Contact c(String k) => rig.store.contacts.get(radioA, k)!;

  group('who it shows', () {
    tw('companion with a saved route: message, route sentence, hops, chips, status chip', (tester) async {
      setScreen(tester);
      rig.port.radioAdd(radioContact(1, name: 'Ann KE8ANN', path: true));
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      await pumpDetail(tester, rig, keyN(1));
      expect(find.text('Ann KE8ANN'), findsWidgets);
      expect(find.byKey(const Key('contact-message')), findsOneWidget);
      expect(find.byKey(const Key('contact-admin')), findsNothing);
      expect(find.byKey(const Key('fake-claim')), findsNothing);
      expect(find.text('On your radio'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contact-message')));
      expect(rig.opened.single.publicKey, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-route')));
      expect(find.textContaining('Direct, 1 hop'), findsOneWidget);
      expect(find.byKey(const Key('contact-hops')), findsOneWidget);
      expect(find.byKey(const Key('hop-01')), findsOneWidget);
    });

    tw('companion without a route: explains flood, reset is disabled with the reason', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-reset-route')));
      expect(find.textContaining('No saved route'), findsOneWidget);
      expect(find.text('Nothing to reset: no route is saved yet.'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('contact-reset-route'))).onPressed, isNull);
    });

    tw('repeater: Claim shown, Admin only when the host wires it', (tester) async {
      setScreen(tester);
      await rig.withContacts(5);
      await pumpDetail(tester, rig, keyN(5));
      expect(find.text('Repeater'), findsOneWidget);
      expect(find.byKey(const Key('contact-message')), findsNothing, reason: 'a repeater has no inbox');
      expect(find.byKey(const Key('fake-claim')), findsOneWidget);
      expect(find.byKey(const Key('contact-admin')), findsOneWidget);
      await tester.tap(find.byKey(const Key('contact-admin')));
      expect(rig.adminOpened.single.publicKey, keyN(5));
      rig.dispose();
      rig = ContactsRig(admin: false);
      await rig.withContacts(5);
      await pumpDetail(tester, rig, keyN(5));
      expect(find.byKey(const Key('contact-admin')), findsNothing);
    });

    tw('room: "Open room" opens the conversation', (tester) async {
      setScreen(tester);
      await rig.withContacts(7);
      await pumpDetail(tester, rig, keyN(7));
      expect(find.text('Open room'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contact-message')));
      expect(rig.opened.single.publicKey, keyN(7));
    });

    tw('sensor: no Message button, nothing dead', (tester) async {
      setScreen(tester);
      rig.port.radioAdd(radioContact(9, type: ContactType.sensor));
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      await pumpDetail(tester, rig, keyN(9));
      expect(find.byKey(const Key('contact-message')), findsNothing);
      expect(find.byKey(const Key('contact-admin')), findsNothing);
    });

    tw('no conversation hook wired: no dead Message button', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      final bare = ContactsController(chat: rig.chat, nowMs: rig.clock.call);
      await tester.pumpWidget(MaterialApp(home: ContactDetailScreen(controller: bare, publicKey: keyN(1), mapBuilder: fakeMap)));
      expect(find.byKey(const Key('contact-message')), findsNothing);
      bare.dispose();
    });

    tw('not on the radio: says so, explains, and "Put on radio now" works (and says why when it cannot)', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      rig.store.contacts.setOnRadio(radioA, keyN(1), false);
      rig.port.table.remove(keyN(1));
      rig.chat.contacts.setFavourite(keyN(1), true);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await pumpDetail(tester, rig, keyN(1));
      expect(find.text('Saved on your phone only'), findsOneWidget);
      expect(find.byKey(const Key('contact-put-on-radio')), findsOneWidget);
      rig.port.isConnected = false;
      await tester.tap(find.byKey(const Key('contact-put-on-radio')));
      await tester.pumpAndSettle();
      expect(find.textContaining('radio is not connected'), findsOneWidget);
      rig.port.isConnected = true;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.byKey(const Key('contact-put-on-radio')));
      await tester.pumpAndSettle();
      expect(rig.port.table.containsKey(keyN(1)), isTrue);
      expect(find.text('On your radio'), findsOneWidget);
    });

    tw('blocked contact shows the chip and Unblock', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      rig.chat.contacts.setBlocked(keyN(1), true);
      await pumpDetail(tester, rig, keyN(1));
      expect(find.text('Blocked'), findsOneWidget);
      await scrollTo(tester, find.byKey(const Key('contact-block')));
      expect(find.text('Unblock'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contact-block')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).blocked, isFalse);
    });

    tw('position: map when advertised, plain sentence when not', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('fake-map')));
      expect(find.byKey(const Key('fake-map')), findsOneWidget);
      expect(find.byKey(const Key('contact-coords')), findsOneWidget);
      await tester.tap(find.byKey(const Key('contact-copy-coords')));
      await tester.pumpAndSettle();
      expect(clip.single, contains('39.001'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      rig.store.contacts.upsert(c(keyN(1)).copyWith(lat: null, lon: null));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('contact-no-position')));
      expect(find.byKey(const Key('fake-map')), findsNothing);
    });
  });

  group('actions', () {
    tw('favourite star toggles and is labelled for VoiceOver', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      expect(find.byTooltip('Favourite'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contact-favourite')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).favourite, isTrue);
      expect(find.byTooltip('Remove favourite'), findsOneWidget);
    });

    tw('rename, then reset name', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-rename')));
      await tester.tap(find.byKey(const Key('contact-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rename-field')), 'Mum');
      await tester.tap(find.byKey(const Key('rename-save')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).customName, 'Mum');
      await tester.tap(find.byKey(const Key('contact-rename')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('rename-reset')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).customName, isNull);
    });

    tw('notes are saved when the field loses focus', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-notes')));
      await tester.enterText(find.byKey(const Key('contact-notes')), 'blue car, ham since 1998');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(c(keyN(1)).notes, 'blue car, ham since 1998');
    });

    tw('copy key puts all 64 characters on the clipboard', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-copy-key')));
      await tester.tap(find.byKey(const Key('contact-copy-key')));
      await tester.pumpAndSettle();
      expect(clip.single, keyN(1));
      expect(find.text('Key copied'), findsOneWidget);
    });

    tw('QR sheet carries the contact link; Copy link and Share work', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-show-qr')));
      await tester.tap(find.byKey(const Key('contact-show-qr')));
      await tester.pumpAndSettle();
      final qr = tester.widget<QrView>(find.byType(QrView));
      expect(qr.data, startsWith('meshcore://contact/add?'));
      expect(qr.data, contains(keyN(1)));
      await tester.tap(find.byKey(const Key('qr-copy-link')));
      await tester.pumpAndSettle();
      expect(clip.single, qr.data);
      await tester.tap(find.byKey(const Key('qr-share-link')));
      expect(shared.single, qr.data);
    });

    tw('Share contact sends the link', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-share')));
      await tester.tap(find.byKey(const Key('contact-share')));
      expect(shared.single, startsWith('meshcore://contact/add'));
    });

    tw('Send to radios nearby: both honest outcomes; absent when the radio is away', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-share-nearby')));
      await tester.tap(find.byKey(const Key('contact-share-nearby')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.textContaining('has no stored advert'), findsOneWidget);
      rig.port.hasAdvert = {keyN(1)};
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.byKey(const Key('contact-share-nearby')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.text('Sent. Only radios within direct range can hear it.'), findsOneWidget);
      rig.chat.contacts.detach();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('contact-share')));
      expect(find.byKey(const Key('contact-share-nearby')), findsNothing);
    });

    tw('always-flood switch and Reset route (phone and radio)', (tester) async {
      setScreen(tester);
      rig.port.radioAdd(radioContact(1, path: true));
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-force-flood')));
      await tester.tap(find.byKey(const Key('contact-force-flood')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).forceFlood, isTrue);
      await scrollTo(tester, find.byKey(const Key('contact-reset-route')));
      await tester.tap(find.byKey(const Key('contact-reset-route')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(c(keyN(1)).hasPath, isFalse);
      expect(rig.port.resets, [keyN(1)]);
      expect(find.text('Route forgotten. The next message floods and finds a new one.'), findsOneWidget);
    });

    tw('remove, keeping the messages', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      final conv = ConvKey.dm(keyN(1).substring(0, 12));
      rig.store.messages.insert(ChatMessage(
          id: 'm1', radioId: radioA, convKind: ConvKind.dm, convKey: conv, direction: Direction.incoming, tsSender: 1, tsLocalMs: 1, text: 'hi', state: MessageState.received, dedupeKey: 'd1'));
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-remove')));
      await tester.tap(find.byKey(const Key('contact-remove')));
      await tester.pumpAndSettle();
      expect(find.textContaining('from this phone and from your radio'), findsOneWidget);
      await tester.tap(find.byKey(const Key('remove-confirm')));
      await tester.pumpAndSettle();
      expect(rig.store.contacts.get(radioA, keyN(1)), isNull);
      expect(rig.port.table.containsKey(keyN(1)), isFalse);
      expect(rig.store.messages.page(conv).messages, hasLength(1));
      expect(find.byKey(const Key('contact-detail')), findsNothing, reason: 'popped back');
    });

    tw('remove and delete the messages too', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      final conv = ConvKey.dm(keyN(1).substring(0, 12));
      rig.store.messages.insert(ChatMessage(
          id: 'm1', radioId: radioA, convKind: ConvKind.dm, convKey: conv, direction: Direction.incoming, tsSender: 1, tsLocalMs: 1, text: 'hi', state: MessageState.received, dedupeKey: 'd1'));
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-remove')));
      await tester.tap(find.byKey(const Key('contact-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remove-delete-messages')));
      await tester.tap(find.byKey(const Key('remove-confirm')));
      await tester.pumpAndSettle();
      expect(rig.store.contacts.get(radioA, keyN(1)), isNull);
      expect(rig.store.messages.page(conv).messages, isEmpty);
    });

    tw('cancel keeps everything', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-remove')));
      await tester.tap(find.byKey(const Key('contact-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(rig.store.contacts.get(radioA, keyN(1)), isNotNull);
    });

    tw('removed from elsewhere while open: friendly state, then it leaves', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      await rig.chat.contacts.remove(keyN(1));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contact-detail')), findsNothing);
      expect(find.byKey(const Key('open')), findsOneWidget);
    });

    tw('a route learned while open appears at once', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpDetail(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-route')));
      expect(find.textContaining('No saved route'), findsOneWidget);
      rig.store.contacts.setPath(radioA, keyN(1), Uint8List.fromList([0xab, 0xcd]), 2);
      rig.chat.contacts.onChanged();
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.textContaining('Direct, 2 hops via ab then cd'), findsOneWidget);
    });
  });

  group('looks right everywhere', () {
    final configs = <String, ({double w, double h, double scale, Brightness b})>{
      'phone': (w: 390, h: 844, scale: 1.0, b: Brightness.light),
      'ipad': (w: 834, h: 1194, scale: 1.0, b: Brightness.light),
      'text 2.5': (w: 390, h: 844, scale: 2.5, b: Brightness.light),
      'dark': (w: 390, h: 844, scale: 1.0, b: Brightness.dark),
    };
    for (final e in configs.entries) {
      tw('repeater with route, ${e.key}: no overflow, accessible, labelled buttons', (tester) async {
        setScreen(tester, w: e.value.w, h: e.value.h, scale: e.value.scale);
        rig.port.radioAdd(radioContact(5, type: ContactType.repeater, name: 'Hilltop Repeater North Ridge', path: true));
        rig.chat.contacts.attach(rig.port);
        await rig.chat.contacts.syncNow();
        await pumpDetail(tester, rig, keyN(5), b: e.value.b);
        expect(tester.takeException(), isNull);
        final handle = tester.ensureSemantics();
        expect(find.bySemanticsLabel('Favourite'), findsWidgets);
        handle.dispose();
        await expectAccessible(tester);
        await scrollTo(tester, find.byKey(const Key('contact-remove')));
        expect(tester.takeException(), isNull);
        await expectAccessible(tester);
        final handle2 = tester.ensureSemantics();
        for (final k in ['contact-share', 'contact-block', 'contact-remove']) {
          expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48), reason: k);
        }
        handle2.dispose();
      });
    }
  });
}
