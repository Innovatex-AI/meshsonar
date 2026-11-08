import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/contact_port.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/contacts/contacts_view.dart';

import '../../chat/contact_support.dart';
import '../../chat/support.dart';
import 'contacts_ui_support.dart';
import '../../support/semantics_audit.dart';

/// A radio that sends a few contacts, then waits for [gate]: the list is "in progress" for as long as the test wants.
class SlowPort extends FakeRadioPort {
  final gate = Completer<void>();
  SlowPort() : super(capacity: 400);
  @override
  Future<ContactDownload> download({required int since, required void Function(Contact contact, int received, int total) onContact}) async {
    onContact(radioContact(1), 120, 350);
    await gate.future;
    return const ContactDownload(totalOnRadio: 350, cursor: 0);
  }
}

void advert(ContactsRig rig, int n, {String? name, int hops = 2, ContactType type = ContactType.repeater}) => rig.store.adverts.record(AdvertSeen(
    radioId: radioA, publicKey: keyN(100 + n), type: type, name: name ?? 'Hill $n', firstTsMs: rig.clock.ms - 600000, lastTsMs: rig.clock.ms - 300000, pathLen: hops, advertTs: 1760000000));

Future<ContactsRig> pumpView(WidgetTester tester, {int contacts = 0, bool link = true, double w = 390, double h = 844, double scale = 1, Brightness b = Brightness.light, void Function(ContactsRig)? before, void Function()? onConnect}) async {
  setScreen(tester, w: w, h: h, scale: scale);
  final rig = ContactsRig();
  addTearDown(rig.dispose);
  if (contacts > 0 || link) {
    await rig.withContacts(contacts, link: link);
  }
  before?.call(rig);
  await tester.pumpWidget(hostApp(ContactsView(controller: rig.controller, onConnect: (_) => onConnect?.call()), brightness: b));
  await tester.pump();
  return rig;
}

void main() {
  String k(int n) => keyN(n).substring(0, 8);
  Finder tile(int n) => find.byKey(Key('contact-${k(n)}'));

  group('states', () {
    testWidgetsT('(a) no radio ever: explains, one Connect radio button', (tester) async {
      var connects = 0;
      await pumpView(tester, contacts: 0, link: false, onConnect: () => connects++);
      expect(find.byKey(const Key('contacts-no-radio')), findsOneWidget);
      expect(find.text('Your contacts appear here'), findsOneWidget);
      await tester.tap(find.text('Connect radio'));
      expect(connects, 1);
    });

    testWidgetsT('(b) connected, nothing yet: empty state with Announce myself and Scan a QR code', (tester) async {
      await pumpView(tester, contacts: 0);
      expect(find.byKey(const Key('contacts-empty')), findsOneWidget);
      expect(find.text('No contacts yet'), findsOneWidget);
      expect(find.byKey(const Key('contacts-send-advert')), findsOneWidget);
      await tester.tap(find.byKey(const Key('contacts-scan-qr')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contacts-search')), findsNothing, reason: 'the Add contact screen opened');
    });

    testWidgetsT('(c) radio away: the saved list is still there and there is no Add/filter chrome', (tester) async {
      await pumpView(tester, contacts: 6, link: false);
      expect(tile(1), findsOneWidget);
      expect(find.byKey(const Key('contacts-add')), findsNothing);
      expect(find.byKey(const Key('contacts-filters')), findsNothing);
      expect(find.byKey(const Key('contacts-usage')), findsNothing);
    });

    testWidgetsT('(d) sync in progress: one banner with counts, the list stays usable', (tester) async {
      setScreen(tester);
      final rig = ContactsRig();
      addTearDown(rig.dispose);
      final slow = SlowPort();
      rig.chat.contacts.attach(slow);
      unawaited(rig.chat.contacts.syncNow());
      await tester.pumpWidget(hostApp(ContactsView(controller: rig.controller)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('banner-syncing')), findsOneWidget);
      expect(find.text('Loading contacts from your radio: 120 of 350'), findsOneWidget);
      expect(find.byKey(const Key('contacts-search')), findsOneWidget);
      slow.gate.complete();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('banner-syncing')), findsNothing);
    });

    testWidgetsT('(e) sync failed: plain sentence and Try again completes it', (tester) async {
      setScreen(tester);
      final rig = ContactsRig();
      addTearDown(rig.dispose);
      for (var i = 1; i <= 8; i++) {
        rig.port.radioAdd(radioContact(i));
      }
      rig.port.dropAfter = 3;
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      await tester.pumpWidget(hostApp(ContactsView(controller: rig.controller)));
      await tester.pump();
      expect(find.byKey(const Key('banner-failed')), findsOneWidget);
      expect(find.textContaining('What arrived is saved'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('banner-failed')), findsNothing);
      expect(rig.store.contacts.count(radioA), 8);
    });

    testWidgetsT('(f) radio list full: card with numbers, Free up space frees a slot and the card goes', (tester) async {
      setScreen(tester);
      final rig = ContactsRig();
      addTearDown(rig.dispose);
      rig.port.capacity = 4;
      for (var i = 1; i <= 4; i++) {
        rig.port.radioAdd(radioContact(i));
      }
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      rig.chat.contacts.radioFull();
      await tester.pumpWidget(hostApp(ContactsView(controller: rig.controller)));
      await tester.pump();
      expect(find.byKey(const Key('banner-full')), findsOneWidget);
      expect(find.textContaining('(4 of 4)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('banner-free')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('radio-list-sheet')), findsOneWidget);
      await tester.tap(find.byKey(Key('cleanup-${k(1)}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('radio-list-remove')));
      await tester.pumpAndSettle();
      expect(rig.port.table.length, 3);
      expect(rig.store.contacts.count(radioA), 4, reason: 'still on the phone');
      Navigator.of(tester.element(find.byKey(const Key('radio-list-sheet')))).pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('banner-full')), findsNothing);
    });

    testWidgetsT('(g) foot: "N of M on your radio · Manage" opens the radio list; Manage contacts opens settings', (tester) async {
      await pumpView(tester, contacts: 5);
      await tester.dragUntilVisible(find.byKey(const Key('contacts-usage')), find.byKey(const Key('contacts-list')), const Offset(0, -150));
      expect(find.text('5 of 100 on your radio · Manage'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contacts-usage')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('radio-list-sheet')), findsOneWidget);
      expect(find.text('5 of 100 used'), findsOneWidget);
    });

    testWidgetsT('(g2) Manage contacts row opens the contact settings, also while the radio is away', (tester) async {
      final rig = await pumpView(tester, contacts: 5, link: false);
      await tester.dragUntilVisible(find.byKey(const Key('contacts-manage')), find.byKey(const Key('contacts-list')), const Offset(0, -150));
      await tester.tap(find.byKey(const Key('contacts-manage')));
      await tester.pumpAndSettle();
      expect(rig.chat.contacts.connected, isFalse);
      expect(find.text('Connect your radio to change this.'), findsOneWidget);
    });

    testWidgetsT('(h) ask-first offer: "Ask me first" switches the radio and the card goes', (tester) async {
      final rig = await pumpView(tester, contacts: 3);
      expect(find.byKey(const Key('ask-first')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ask-yes')));
      await tester.pump();
      await tester.pump();
      expect(rig.port.policy.askBeforeAdding, isTrue);
      expect(rig.chat.contacts.policyPromptAnswer, 'ask');
      expect(find.byKey(const Key('ask-first')), findsNothing);
    });

    testWidgetsT('(h2) ask-first offer: "Keep automatic" leaves the radio alone and does not come back', (tester) async {
      final rig = await pumpView(tester, contacts: 3);
      await tester.tap(find.byKey(const Key('ask-keep')));
      await tester.pump();
      await tester.pump();
      expect(rig.port.policy.askBeforeAdding, isFalse);
      expect(find.byKey(const Key('ask-first')), findsNothing);
    });

    testWidgetsT('(i) search with no hits says so and Clear search restores the list', (tester) async {
      await pumpView(tester, contacts: 6);
      await tester.enterText(find.byKey(const Key('contacts-search')), 'zzz');
      await tester.pump();
      await tester.pump();
      expect(find.text('No contact matches \u201Czzz\u201D'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contacts-clear-search')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('contacts-no-match')), findsNothing);
      expect(tile(2), findsOneWidget);
    });

    testWidgetsT('(j) a notice from the manager appears as a toast', (tester) async {
      final rig = ContactsRig();
      addTearDown(rig.dispose);
      setScreen(tester);
      rig.port.capacity = 3;
      for (var i = 1; i <= 3; i++) {
        rig.port.radioAdd(radioContact(i));
      }
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      rig.store.contacts.upsert(radioContact(9));
      await tester.pumpWidget(hostApp(ContactsView(controller: rig.controller)));
      await tester.pump();
      await tester.runAsync(() => rig.chat.contacts.ensureOnRadio(keyN(9)));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('still in your contacts'), findsOneWidget);
    });
  });

  group('list behaviour', () {
    testWidgetsT('people only: repeaters and rooms are not listed; favourites section first, then letter headers; no filter chips', (tester) async {
      await pumpView(tester, contacts: 10, before: (rig) => rig.chat.contacts.setFavourite(keyN(4), true));
      expect(find.byKey(const Key('title-favourites')), findsOneWidget);
      expect(find.byKey(const Key('title-letter-N')), findsOneWidget);
      expect(tile(5), findsNothing, reason: 'repeater');
      expect(tile(7), findsNothing, reason: 'room');
      expect(find.byType(ChoiceChip), findsNothing);
      expect(tester.getTopLeft(tile(4)).dy, lessThan(tester.getTopLeft(tile(1)).dy));
      expect(find.text('Person · No route yet'), findsWidgets);
      expect(find.text('Search 7 contacts'), findsOneWidget);
    });

    testWidgetsT('search narrows by name', (tester) async {
      await pumpView(tester, contacts: 12);
      await tester.enterText(find.byKey(const Key('contacts-search')), 'Node 11');
      await tester.pump();
      await tester.pump();
      expect(tile(11), findsOneWidget);
      expect(tile(2), findsNothing);
    });

    testWidgetsT('tap = the Contact profile, always, even for a person who has messages', (tester) async {
      final rig = await pumpView(tester, contacts: 3);
      await tester.tap(tile(2));
      await tester.pumpAndSettle();
      expect(rig.opened, isEmpty);
      expect(find.byKey(const Key('contacts-search')), findsNothing);
      expect(find.text('Node 2'), findsWidgets);
    });

    testWidgetsT('swipe right: Message opens the conversation, Favourite toggles and moves the row', (tester) async {
      final rig = await pumpView(tester, contacts: 3);
      await tester.drag(tile(2), const Offset(300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('swipe-message-${k(2)}')));
      await tester.pumpAndSettle();
      expect(rig.opened.single.publicKey, keyN(2));
      await tester.drag(tile(2), const Offset(300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('swipe-favourite-${k(2)}')));
      await tester.pumpAndSettle();
      expect(rig.store.contacts.get(radioA, keyN(2))!.favourite, isTrue);
      expect(find.byKey(const Key('title-favourites')), findsOneWidget);
    });

    testWidgetsT('swipe left: Ping while connected opens its sheet; offline it says to connect (no dead button)', (tester) async {
      await pumpView(tester, contacts: 3);
      await tester.drag(tile(2), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('swipe-ping-${k(2)}')));
      await tester.pumpAndSettle();
      // WP7's ping: the first time ever it says it uses airtime, then the result sheet (test/ui/tools/ping_result_sheet_test).
      expect(find.text('Ping uses radio airtime'), findsOneWidget);
    });

    testWidgetsT('swipe left: Ping offline explains', (tester) async {
      await pumpView(tester, contacts: 3, link: false);
      await tester.drag(tile(2), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('swipe-ping-${k(2)}')));
      await tester.pumpAndSettle();
      expect(find.text('Connect your radio to use this.'), findsOneWidget);
    });

    testWidgetsT('swipe left: Remove asks in an action sheet, then removes with Undo', (tester) async {
      final rig = await pumpView(tester, contacts: 3);
      await tester.drag(tile(2), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('swipe-remove-${k(2)}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('remove-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('remove-cancel')));
      await tester.pumpAndSettle();
      expect(rig.store.contacts.get(radioA, keyN(2)), isNotNull);
      await tester.drag(tile(2), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('swipe-remove-${k(2)}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remove-confirm')));
      await tester.pumpAndSettle();
      expect(rig.store.contacts.get(radioA, keyN(2)), isNull);
      expect(tile(2), findsNothing);
      expect(find.text('Undo'), findsOneWidget);
    });

    testWidgetsT('pull to refresh does a full read of the radio', (tester) async {
      final rig = await pumpView(tester, contacts: 8);
      final before = rig.port.downloads.length;
      await tester.fling(find.byKey(const Key('contacts-list')), const Offset(0, 400), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(rig.port.downloads.length, before + 1);
      expect(rig.port.downloads.last, 0);
    });
  });

  group('New nodes nearby', () {
    testWidgetsT('ONE collapsed row; See all opens a sheet; Ignore removes; Add puts it on the radio', (tester) async {
      final rig = await pumpView(tester, contacts: 3, before: (rig) {
        for (var i = 1; i <= 5; i++) {
          advert(rig, i);
        }
      });
      expect(find.text('New nodes nearby (5)'), findsOneWidget);
      expect(find.byKey(Key('nearby-${keyN(101).substring(0, 8)}')), findsNothing, reason: 'collapsed');
      await tester.tap(find.byKey(const Key('nearby-row')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('nearby-${keyN(101).substring(0, 8)}')), findsOneWidget);
      expect(find.textContaining('heard 5 min ago, via 2 repeaters'), findsWidgets);
      await tester.tap(find.byKey(Key('nearby-ignore-${keyN(101).substring(0, 8)}')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(Key('nearby-${keyN(101).substring(0, 8)}')), findsNothing);
      await tester.tap(find.byKey(Key('nearby-add-${keyN(102).substring(0, 8)}')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(rig.port.table.containsKey(keyN(102)), isTrue);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgetsT('semantics: a new node row reads name, type and how it was heard', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpView(tester, contacts: 1, before: (rig) => advert(rig, 1, name: 'Hilltop'));
      await tester.tap(find.byKey(const Key('nearby-row')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('New node Hilltop, Repeater, heard 5 min ago, via 2 repeaters')), findsOneWidget);
      handle.dispose();
    });
  });

  group('accessibility and layout matrix', () {
    final sizes = [(w: 393.0, h: 852.0), (w: 375.0, h: 667.0), (w: 744.0, h: 1133.0), ipadSize];
    for (final size in sizes) {
      for (final scale in [1.0, 2.0, 3.1]) {
        for (final dark in [false, true]) {
          testWidgetsT('everything at once: ${size.w.toInt()}x${size.h.toInt()} text x$scale ${dark ? 'dark' : 'light'}', (tester) async {
            final rig = await pumpView(tester, contacts: 14, w: size.w, h: size.h, scale: scale, b: dark ? Brightness.dark : Brightness.light, before: (rig) {
              for (var i = 1; i <= 4; i++) {
                advert(rig, i);
              }
              rig.chat.contacts.radioFull();
              rig.chat.contacts.setFavourite(keyN(2), true);
            });
            expect(tester.takeException(), isNull);
            await tester.drag(find.byKey(const Key('contacts-list')), const Offset(0, -600));
            await tester.pump();
            expect(tester.takeException(), isNull);
            await tester.drag(find.byKey(const Key('contacts-list')), const Offset(0, 600));
            await tester.pump();
            final sem = tester.ensureSemantics();
            await tester.pump();
            if (scale < 2.0) expectHeader(tester); // sticky letter headers are below the fold at large text
            sem.dispose();
            await expectAccessibleIos(tester);
            expect(rig.chat.contacts.state.tableFull, isTrue);
          });
        }
      }
    }

    testWidgetsT('VoiceOver: a tile reads name, type, route, heard; rows expose Message/Favourite/Ping/Remove actions', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpView(tester, contacts: 4);
      expect(find.bySemanticsLabel(RegExp(r'^Node 1, Person, No route yet, ')), findsOneWidget);
      final data = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Node 1, Person')));
      expect(data.getSemanticsData().customSemanticsActionIds, isNotEmpty);
      handle.dispose();
    });
  });
}
