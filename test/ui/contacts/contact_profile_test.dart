// Contact profile (chat WP6a): what each kind of contact shows, the Edit sheet, block with Undo, remove with the
// conversation, Route / Share / coming sheets, and layouts at 393 / 375 / 1024 pt, AX3 and dark. Replaces contact_detail_test.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/chat/qr_widgets.dart' show QrView;
import 'package:meshsonar/ui/contacts/contact_profile_screen.dart';
import 'package:meshsonar/ui/contacts/contacts_controller.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../chat/contact_support.dart';
import '../../chat/support.dart';
import 'contacts_ui_support.dart';

Widget fakeMap(BuildContext c, double lat, double lon) => SizedBox(height: 120, key: const Key('fake-map'), child: Text('map $lat $lon'));

final shared = <String>[];
final files = <String>[];

Future<void> pumpProfile(WidgetTester tester, ContactsRig rig, String key,
    {Brightness b = Brightness.light, Widget Function(BuildContext, Contact)? claim}) async {
  await tester.pumpWidget(MaterialApp(
    key: UniqueKey(),
    theme: meshSonarTheme(b),
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const Key('open'),
            onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
              builder: (_) => ContactProfileScreen(
                controller: rig.controller,
                publicKey: key,
                mapBuilder: fakeMap,
                shareText: (text, {subject}) async => shared.add(text),
                shareFile: (name, text) async => files.add(name),
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
  await tester.scrollUntilVisible(f, 200, scrollable: find.descendant(of: find.byKey(const Key('contact-profile')), matching: find.byType(Scrollable)).first);
  await tester.pump();
}

void main() {
  late ContactsRig rig;
  final clip = <String>[];

  void tw(String name, Future<void> Function(WidgetTester) body) {
    testWidgetsT(name, (tester) async {
      rig = ContactsRig();
      await body(tester);
    });
  }

  setUp(() {
    shared.clear();
    files.clear();
    clip.clear();
    AppFlags.chatRedesign.value = false;
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clip.add((call.arguments as Map)['text'] as String);
      return null;
    });
  });
  tearDown(() {
    AppFlags.chatRedesign.value = false;
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    rig.dispose();
  });

  Contact c(String k) => rig.store.contacts.get(radioA, k)!;
  Future<void> openEdit(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('contact-edit')));
    await tester.pumpAndSettle();
  }

  group('who it shows', () {
    tw('person with a saved route: header lines, Message and Route tiles, route and hop on the route sheet', (tester) async {
      setScreen(tester);
      rig.port.radioAdd(radioContact(1, name: 'Ann KE8ANN', path: true));
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      await pumpProfile(tester, rig, keyN(1));
      expect(find.text('Ann KE8ANN'), findsOneWidget);
      expect(find.text('Person · Via 1 repeater'), findsOneWidget);
      expect(find.textContaining('Heard'), findsOneWidget);
      expect(find.byKey(const Key('tile-message')), findsOneWidget);
      expect(find.byKey(const Key('tile-route')), findsOneWidget);
      expect(find.byKey(const Key('tile-ping')), findsNothing, reason: 'no dead buttons with the flag off');
      expect(find.byKey(const Key('tile-stats')), findsNothing);
      expect(find.text('On your radio'), findsOneWidget);
      expect(find.text('Danger zone'), findsNothing);
      await tester.tap(find.byKey(const Key('tile-message')));
      expect(rig.opened.single.publicKey, keyN(1));
      await tester.tap(find.byKey(const Key('tile-route')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('route-sheet-hops')), findsOneWidget);
      expect(find.text('01'), findsOneWidget);
    });

    tw('person without a route: says so', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      expect(find.text('Person · No route yet'), findsOneWidget);
      expect(find.byKey(const Key('contact-last-delivery')), findsNothing);
    });

    tw('flood-only contact reads Searching', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      rig.chat.contacts.setForceFlood(keyN(1), true);
      await pumpProfile(tester, rig, keyN(1));
      expect(find.text('Person · Searching'), findsOneWidget);
    });

    tw('last delivery comes from the newest acknowledged message', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      final conv = ConvKey.dm(keyN(1).substring(0, 12));
      rig.store.messages.insert(ChatMessage(
          id: 'm1', radioId: radioA, convKind: ConvKind.dm, convKey: conv, direction: Direction.outgoing, tsSender: 1, tsLocalMs: rig.clock.ms - 120000, text: 'hi', state: MessageState.acked, ackMs: 1800, dedupeKey: 'd1'));
      await pumpProfile(tester, rig, keyN(1));
      expect(find.text('2 min ago · 1.8 s'), findsOneWidget);
    });

    tw('repeater: Dashboard tile opens admin, Claim shown, no Message', (tester) async {
      setScreen(tester);
      await rig.withContacts(5);
      await pumpProfile(tester, rig, keyN(5));
      expect(find.text('Repeater · No route yet'), findsOneWidget);
      expect(find.byKey(const Key('tile-message')), findsNothing);
      expect(find.byKey(const Key('fake-claim')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tile-dashboard')));
      expect(rig.adminOpened.single.publicKey, keyN(5));
      rig.dispose();
      rig = ContactsRig(admin: false);
      await rig.withContacts(5);
      await pumpProfile(tester, rig, keyN(5));
      expect(find.byKey(const Key('tile-dashboard')), findsNothing);
    });

    tw('room: no Open room until room login exists; Administer room row is there', (tester) async {
      setScreen(tester);
      await rig.withContacts(7);
      await pumpProfile(tester, rig, keyN(7));
      expect(find.byKey(const Key('tile-openRoom')), findsNothing);
      await scrollTo(tester, find.byKey(const Key('contact-admin')));
      expect(find.byKey(const Key('contact-admin')), findsOneWidget);
    });

    tw('room with room support: Open room opens the conversation', (tester) async {
      setScreen(tester);
      final withRooms = ContactsRig(canOpenRooms: true);
      addTearDown(withRooms.dispose);
      await withRooms.withContacts(7);
      await pumpProfile(tester, withRooms, keyN(7));
      expect(find.text('Open room'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tile-openRoom')));
      expect(withRooms.opened.single.publicKey, keyN(7));
    });

    tw('sensor: only Route with the flag off; Telemetry, Ping, Route with it on', (tester) async {
      setScreen(tester);
      rig.port.radioAdd(radioContact(9, type: ContactType.sensor));
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      await pumpProfile(tester, rig, keyN(9));
      expect(find.byKey(const Key('tile-route')), findsOneWidget);
      expect(find.byKey(const Key('tile-telemetry')), findsNothing);
      AppFlags.chatRedesign.value = true;
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tile-telemetry')), findsOneWidget);
      expect(find.byKey(const Key('tile-ping')), findsOneWidget);
    });

    tw('no conversation hook wired: no dead Message tile', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      final bare = ContactsController(chat: rig.chat, nowMs: rig.clock.call);
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: ContactProfileScreen(controller: bare, publicKey: keyN(1), mapBuilder: fakeMap)));
      expect(find.byKey(const Key('tile-message')), findsNothing);
      bare.dispose();
    });

    tw('not on the radio: says so and "Put on radio now" works (and says why when it cannot)', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      rig.store.contacts.setOnRadio(radioA, keyN(1), false);
      rig.port.table.remove(keyN(1));
      rig.chat.contacts.setFavourite(keyN(1), true);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await pumpProfile(tester, rig, keyN(1));
      expect(find.text('Saved on your phone only'), findsOneWidget);
      rig.port.isConnected = false;
      await scrollTo(tester, find.byKey(const Key('contact-put-on-radio')));
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

    tw('blocked contact says Blocked; the Edit sheet offers Unblock', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      rig.chat.contacts.setBlocked(keyN(1), true);
      await pumpProfile(tester, rig, keyN(1));
      expect(find.byKey(const Key('contact-blocked')), findsOneWidget);
      await openEdit(tester);
      expect(find.text('Unblock contact'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contact-block')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).blocked, isFalse);
    });

    tw('position: static map when advertised, "Not shared" when not; hold copies coordinates', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('fake-map')));
      expect(find.byKey(const Key('contact-coords')), findsOneWidget);
      await tester.longPress(find.byKey(const Key('contact-location')));
      await tester.pumpAndSettle();
      expect(clip.single, contains('39.001'));
      await tester.tap(find.byKey(const Key('contact-back')));
      await tester.pumpAndSettle();
      rig.store.contacts.upsert(c(keyN(1)).copyWith(lat: null, lon: null));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('contact-no-position')));
      expect(find.byKey(const Key('fake-map')), findsNothing);
    });

    tw('notes are read-only here and shown', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      rig.chat.contacts.setNotes(keyN(1), 'blue car, ham since 1998');
      await pumpProfile(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-notes')));
      expect(find.text('blue car, ham since 1998'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('flag on: tiles that wait for WP7 / WP8', () {
    tw('person gets Ping and Stats; each opens a labelled "coming" sheet', (tester) async {
      setScreen(tester);
      AppFlags.chatRedesign.value = true;
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      expect(find.byKey(const Key('tile-ping')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tile-ping')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('coming-soon-title')), findsOneWidget);
      expect(find.byKey(const Key('coming-soon-body')), findsOneWidget);
    });

    tw('radio away: Ping is dimmed with the reason, and a tap says why instead of doing nothing', (tester) async {
      setScreen(tester);
      AppFlags.chatRedesign.value = true;
      await rig.withContacts(1);
      rig.port.isConnected = false;
      rig.chat.contacts.detach();
      await pumpProfile(tester, rig, keyN(1));
      expect(find.byKey(const Key('tile-reason')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tile-ping')));
      await tester.pumpAndSettle();
      expect(find.text('Connect your radio to use this.'), findsWidgets);
      expect(find.byKey(const Key('coming-soon-title')), findsNothing);
    });
  });

  group('route, share, mute, copy', () {
    tw('Always search switch and Reset route (confirm first)', (tester) async {
      setScreen(tester);
      rig.port.radioAdd(radioContact(1, path: true));
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      await pumpProfile(tester, rig, keyN(1));
      await tester.tap(find.byKey(const Key('contact-route-row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('contact-force-flood')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).forceFlood, isTrue);
      await tester.tap(find.byKey(const Key('contact-reset-route')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).hasPath, isTrue, reason: 'nothing happens until confirmed');
      await tester.tap(find.byKey(const Key('reset-route-confirm')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(c(keyN(1)).hasPath, isFalse);
      expect(rig.port.resets, [keyN(1)]);
    });

    tw('Reset route is inert with no saved route', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await tester.tap(find.byKey(const Key('tile-route')));
      await tester.pumpAndSettle();
      expect(find.text('No route saved'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contact-reset-route')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reset-route-confirm')), findsNothing);
    });

    tw('a route learned while open appears at once', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      expect(find.text('Person · No route yet'), findsOneWidget);
      rig.store.contacts.setPath(radioA, keyN(1), Uint8List.fromList([0xab, 0xcd]), 2);
      rig.chat.contacts.onChanged();
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.text('Person · Via 2 repeaters'), findsOneWidget);
    });

    tw('tapping the public key copies all 64 characters', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-key-row')));
      expect(find.text('01010101…01010101'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contact-key-row')));
      await tester.pumpAndSettle();
      expect(clip.single, keyN(1));
      expect(find.text('Key copied'), findsOneWidget);
    });

    tw('Mute switch mutes the conversation and shows it', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-mute')));
      await tester.tap(find.byKey(const Key('contact-mute')));
      await tester.pumpAndSettle();
      final conv = rig.chat.conversation(ConvKey.dm(keyN(1).substring(0, 12)))!;
      expect(conv.notifyMode, NotifyMode.muted);
      expect(tester.widget<Switch>(find.byKey(const Key('contact-mute'))).value, isTrue);
    });

    tw('share sheet: QR carries the link; Copy link, Share, Export file, Copy key', (tester) async {
      setScreen(tester, h: 1000);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await tester.tap(find.byKey(const Key('contact-share-nav')));
      await tester.pumpAndSettle();
      final qr = tester.widget<QrView>(find.byType(QrView));
      expect(qr.data, startsWith('meshcore://contact/add?'));
      expect(qr.data, contains(keyN(1)));
      await tester.tap(find.byKey(const Key('qr-copy-link')));
      await tester.pumpAndSettle();
      expect(clip.last, qr.data);
      await tester.tap(find.byKey(const Key('share-copy-key')));
      await tester.pumpAndSettle();
      expect(clip.last, keyN(1));
      await tester.tap(find.byKey(const Key('qr-share-link')));
      expect(shared.single, qr.data);
      await tester.tap(find.byKey(const Key('share-export-file')));
      expect(files.single, endsWith('.meshcore.txt'));
    });

    tw('"Share contact" row opens the same sheet; Send to radios nearby tells both honest outcomes and is absent when the radio is away', (tester) async {
      setScreen(tester, h: 1000);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await scrollTo(tester, find.byKey(const Key('contact-share')));
      await tester.tap(find.byKey(const Key('contact-share')));
      await tester.pumpAndSettle();
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
    });
  });

  group('edit sheet', () {
    tw('rename, notes and favourite are saved on Done only', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await openEdit(tester);
      await tester.enterText(find.byKey(const Key('rename-field')), 'Mum');
      await tester.enterText(find.byKey(const Key('edit-notes')), 'blue car');
      await tester.tap(find.byKey(const Key('edit-favourite')));
      await tester.pump();
      expect(c(keyN(1)).customName, isNull, reason: 'nothing saved before Done');
      await tester.tap(find.byKey(const Key('edit-done')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).customName, 'Mum');
      expect(c(keyN(1)).notes, 'blue car');
      expect(c(keyN(1)).favourite, isTrue);
      expect(find.text('Mum'), findsOneWidget);
    });

    tw('"Use advertised name" resets the custom name', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      rig.chat.contacts.rename(keyN(1), 'Mum');
      await pumpProfile(tester, rig, keyN(1));
      await openEdit(tester);
      await tester.tap(find.byKey(const Key('rename-reset')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('edit-done')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).customName, isNull);
    });

    tw('Cancel with nothing changed closes at once', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await openEdit(tester);
      await tester.tap(find.byKey(const Key('edit-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit-done')), findsNothing);
      expect(find.byKey(const Key('edit-discard')), findsNothing);
    });

    tw('Cancel with changes asks (action sheet); Keep editing keeps the text, Discard drops it', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await openEdit(tester);
      await tester.enterText(find.byKey(const Key('rename-field')), 'Nope');
      await tester.tap(find.byKey(const Key('edit-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit-discard')), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-keep-editing')));
      await tester.pumpAndSettle();
      expect(find.text('Nope'), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-cancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('edit-discard')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit-done')), findsNothing);
      expect(c(keyN(1)).customName, isNull);
    });

    tw('Keep on my radio: off takes it off the radio, on puts it back; dimmed when the radio is away', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await openEdit(tester);
      await tester.tap(find.byKey(const Key('edit-keep-on-radio')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('edit-done')));
      await tester.pumpAndSettle();
      expect(rig.port.table.containsKey(keyN(1)), isFalse);
      expect(c(keyN(1)).onRadio, isFalse);
      rig.chat.contacts.detach();
      await tester.pumpAndSettle();
      await openEdit(tester);
      expect(find.text('Connect your radio to change this.'), findsOneWidget);
    });

    tw('Block asks first, says so, and Undo reverses it', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await openEdit(tester);
      await tester.tap(find.byKey(const Key('contact-block')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).blocked, isFalse, reason: 'confirmation first');
      await tester.tap(find.byKey(const Key('block-confirm')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).blocked, isTrue);
      expect(find.textContaining('is blocked'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).blocked, isFalse);
    });

    tw('Remove (conversation kept): both options offered when messages exist; Undo restores the contact', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      rig.chat.contacts.rename(keyN(1), 'Mum');
      rig.chat.contacts.setFavourite(keyN(1), true);
      final conv = ConvKey.dm(keyN(1).substring(0, 12));
      rig.store.messages.insert(ChatMessage(
          id: 'm1', radioId: radioA, convKind: ConvKind.dm, convKey: conv, direction: Direction.incoming, tsSender: 1, tsLocalMs: 1, text: 'hi', state: MessageState.received, dedupeKey: 'd1'));
      await pumpProfile(tester, rig, keyN(1));
      await openEdit(tester);
      await tester.tap(find.byKey(const Key('contact-remove')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('remove-delete-messages')), findsOneWidget);
      expect(find.textContaining('from this phone and from your radio'), findsOneWidget);
      await tester.tap(find.byKey(const Key('remove-confirm')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(rig.store.contacts.get(radioA, keyN(1)), isNull);
      expect(rig.port.table.containsKey(keyN(1)), isFalse);
      expect(rig.store.messages.page(conv).messages, hasLength(1));
      expect(find.byKey(const Key('contact-profile')), findsNothing, reason: 'popped back');
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      final back = rig.store.contacts.get(radioA, keyN(1))!;
      expect(back.customName, 'Mum');
      expect(back.favourite, isTrue);
    });

    tw('Remove and delete the conversation too (no Undo offered: the messages are gone)', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      final conv = ConvKey.dm(keyN(1).substring(0, 12));
      rig.store.messages.insert(ChatMessage(
          id: 'm1', radioId: radioA, convKind: ConvKind.dm, convKey: conv, direction: Direction.incoming, tsSender: 1, tsLocalMs: 1, text: 'hi', state: MessageState.received, dedupeKey: 'd1'));
      await pumpProfile(tester, rig, keyN(1));
      await openEdit(tester);
      await tester.tap(find.byKey(const Key('contact-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remove-delete-messages')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(rig.store.contacts.get(radioA, keyN(1)), isNull);
      expect(rig.store.messages.page(conv).messages, isEmpty);
      expect(find.text('Undo'), findsNothing);
    });

    tw('Remove with no conversation offers just the one choice', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await openEdit(tester);
      await tester.tap(find.byKey(const Key('contact-remove')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('remove-confirm')), findsOneWidget);
      expect(find.byKey(const Key('remove-delete-messages')), findsNothing);
      await tester.tap(find.byKey(const Key('remove-cancel')));
      await tester.pumpAndSettle();
      expect(rig.store.contacts.get(radioA, keyN(1)), isNotNull, reason: 'cancel keeps everything');
    });

    tw('removed from elsewhere while open: friendly state, then it leaves', (tester) async {
      setScreen(tester);
      await rig.withContacts(1);
      await pumpProfile(tester, rig, keyN(1));
      await rig.chat.contacts.remove(keyN(1));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contact-profile')), findsNothing);
      expect(find.byKey(const Key('open')), findsOneWidget);
    });
  });

  group('looks right everywhere', () {
    final configs = <String, ({double w, double h, double scale, Brightness b})>{
      'iPhone 17 Pro 393': (w: 393, h: 852, scale: 1.0, b: Brightness.light),
      'iPhone SE 375': (w: 375, h: 667, scale: 1.0, b: Brightness.light),
      'iPad 1024': (w: 1024, h: 768, scale: 1.0, b: Brightness.light),
      'AX3 text 2.35': (w: 393, h: 852, scale: 2.35, b: Brightness.light),
      'dark': (w: 393, h: 852, scale: 1.0, b: Brightness.dark),
    };
    for (final e in configs.entries) {
      tw('person with route and flag on, ${e.key}: no overflow, accessible, targets >= 44', (tester) async {
        setScreen(tester, w: e.value.w, h: e.value.h, scale: e.value.scale);
        AppFlags.chatRedesign.value = true;
        rig.port.radioAdd(radioContact(1, name: 'Maya Chen with a rather long display name', path: true));
        rig.chat.contacts.attach(rig.port);
        await rig.chat.contacts.syncNow();
        await pumpProfile(tester, rig, keyN(1), b: e.value.b);
        expect(tester.takeException(), isNull);
        final tiles = ['message', 'ping', 'route', 'stats'];
        await scrollTo(tester, find.byKey(const Key('tile-stats')));
        for (final t in tiles) {
          expect(tester.getSize(find.byKey(Key('tile-$t'))).height, greaterThanOrEqualTo(72), reason: t);
          expect(tester.getSize(find.byKey(Key('tile-$t'))).width, greaterThanOrEqualTo(72), reason: t);
        }
        final ys = {for (final t in tiles) tester.getTopLeft(find.byKey(Key('tile-$t'))).dy};
        if (e.value.scale >= 1.5) {
          expect(ys.length, 2, reason: 'AX text wraps the tiles into a 2 x 2 grid');
        } else {
          expect(ys.length, 1, reason: 'four tiles in one row, also at 375 pt');
        }
        await expectAccessible(tester);
        await scrollTo(tester, find.byKey(const Key('contact-share')));
        expect(tester.takeException(), isNull);
        await expectAccessible(tester);
      });
    }

    tw('three tiles on a repeater fit one row at 375 pt', (tester) async {
      setScreen(tester, w: 375, h: 667);
      AppFlags.chatRedesign.value = true;
      await rig.withContacts(5);
      await pumpProfile(tester, rig, keyN(5));
      final ys = {for (final t in ['dashboard', 'ping', 'route']) tester.getTopLeft(find.byKey(Key('tile-$t'))).dy};
      expect(ys.length, 1);
    });
  });

  group('goldens (layout only: the test font draws no real glyphs; SF Pro is checked on the simulator)', () {
    final types = <String, ContactType>{'person': ContactType.companion, 'repeater': ContactType.repeater, 'room': ContactType.room, 'sensor': ContactType.sensor};
    for (final e in types.entries) {
      for (final b in Brightness.values) {
        tw('profile ${e.key} ${b.name}', (tester) async {
          setScreen(tester, w: 393, h: 852);
          AppFlags.chatRedesign.value = true;
          final withRooms = ContactsRig(canOpenRooms: true);
          addTearDown(withRooms.dispose);
          withRooms.port.radioAdd(radioContact(1, type: e.value, name: 'Maya Chen', path: true));
          withRooms.chat.contacts.attach(withRooms.port);
          await withRooms.chat.contacts.syncNow();
          await pumpProfile(tester, withRooms, keyN(1), b: b);
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/profile_${e.key}_${b.name}.png'));
        });
      }
    }
  });
}
