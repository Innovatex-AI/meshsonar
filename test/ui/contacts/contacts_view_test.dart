import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/contact_port.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/contacts/contacts_view.dart';

import '../../chat/contact_support.dart';
import '../../chat/support.dart';
import 'contacts_ui_support.dart';

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
  group('states', () {
    testWidgetsT('(a) no radio ever: explains, one Connect radio button', (tester) async {
      var connects = 0;
      await pumpView(tester, contacts: 0, link: false, onConnect: () => connects++);
      expect(find.byKey(const Key('contacts-no-radio')), findsOneWidget);
      expect(find.text('Your contacts appear here'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contacts-connect')));
      expect(connects, 1);
    });

    testWidgetsT('(b) connected, nothing yet: says how contacts arrive and offers Add contact', (tester) async {
      await pumpView(tester, contacts: 0);
      expect(find.byKey(const Key('contacts-empty')), findsOneWidget);
      expect(find.text('No contacts yet'), findsOneWidget);
      expect(find.textContaining('New nodes nearby'), findsOneWidget);
      expect(find.byKey(const Key('contacts-add')), findsOneWidget);
    });

    testWidgetsT('(c) radio away: banner says the phone copy is shown, Connect radio works, the list is still there', (tester) async {
      var connects = 0;
      await pumpView(tester, contacts: 6, link: false, onConnect: () => connects++);
      expect(find.byKey(const Key('banner-offline')), findsOneWidget);
      expect(find.textContaining('Messages wait and send when it is back'), findsOneWidget);
      expect(find.byKey(Key('contact-${keyN(1).substring(0, 8)}')), findsOneWidget);
      await tester.tap(find.byKey(const Key('banner-connect')));
      expect(connects, 1);
    });

    testWidgetsT('(d) sync in progress: progress with counts, the list stays usable', (tester) async {
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
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
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
      await tester.tap(find.byKey(const Key('banner-retry')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('banner-failed')), findsNothing);
      expect(rig.store.contacts.count(radioA), 8);
    });

    testWidgetsT('(f) radio list full: banner with numbers, Free up space frees a slot and the banner goes', (tester) async {
      setScreen(tester);
      final rig = ContactsRig();
      addTearDown(rig.dispose);
      rig.port.capacity = 4;
      for (var i = 1; i <= 4; i++) {
        rig.port.radioAdd(radioContact(i));
      }
      await rig.chat.contacts.syncNow(); // not attached yet: no-op
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
      expect(find.textContaining('does not'), findsWidgets);
      await tester.tap(find.byKey(Key('cleanup-${keyN(1).substring(0, 8)}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('radio-list-remove')));
      await tester.pumpAndSettle();
      expect(rig.port.table.length, 3);
      expect(rig.store.contacts.count(radioA), 4, reason: 'still on the phone');
      Navigator.of(tester.element(find.byKey(const Key('radio-list-sheet')))).pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('banner-full')), findsNothing);
    });

    testWidgetsT('(g) usage line opens the radio list; offline the sheet says to connect', (tester) async {
      await pumpView(tester, contacts: 5);
      expect(find.text('On your radio: 5 of 100 contacts'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contacts-usage')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('radio-list-sheet')), findsOneWidget);
      expect(find.text('5 of 100 used'), findsOneWidget);
    });

    testWidgetsT('(g2) radio list sheet while the radio is away', (tester) async {
      final rig = await pumpView(tester, contacts: 5, link: false);
      expect(find.byKey(const Key('contacts-usage')), findsNothing);
      await tester.tap(find.byKey(const Key('contacts-settings')));
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
      expect(find.text("No contact matches 'zzz'"), findsOneWidget);
      await tester.tap(find.byKey(const Key('contacts-clear-filters')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('contacts-no-match')), findsNothing);
      expect(find.byKey(Key('contact-${keyN(2).substring(0, 8)}')), findsOneWidget);
    });

    testWidgetsT('(j) a notice from the manager (a slot was freed for a DM) appears as a snackbar', (tester) async {
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
    testWidgetsT('sections: favourites first, then the rest alphabetically; unread badge and last message show', (tester) async {
      final rig = await pumpView(tester, contacts: 6, before: (rig) {
        rig.chat.contacts.setFavourite(keyN(4), true);
        rig.store.messages.insert(ChatMessage(
            id: 'x', radioId: radioA, convKind: ConvKind.dm, convKey: ConvKey.dm(keyN(2).substring(0, 12)), direction: Direction.incoming,
            tsSender: 1, tsLocalMs: rig.clock.ms, text: 'see you at the hill', state: MessageState.received, dedupeKey: 'k'));
        rig.store.messages.markConversationRead(ConvKey.dm(keyN(2).substring(0, 12)));
      });
      expect(find.byKey(const Key('title-favourites')), findsOneWidget);
      expect(find.byKey(const Key('title-all')), findsOneWidget);
      final fav = tester.getTopLeft(find.byKey(Key('contact-${keyN(4).substring(0, 8)}'))).dy;
      final other = tester.getTopLeft(find.byKey(Key('contact-${keyN(1).substring(0, 8)}'))).dy;
      expect(fav, lessThan(other));
      expect(rig.opened, isEmpty);
    });

    testWidgetsT('filters: repeaters only; favourites; people; recent', (tester) async {
      await pumpView(tester, contacts: 10, before: (rig) => rig.chat.contacts.setFavourite(keyN(3), true));
      await tester.ensureVisible(find.byKey(const Key('filter-repeaters')));
      await tester.tap(find.byKey(const Key('filter-repeaters')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(Key('contact-${keyN(5).substring(0, 8)}')), findsOneWidget);
      expect(find.byKey(Key('contact-${keyN(1).substring(0, 8)}')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('filter-favourites')));
      await tester.tap(find.byKey(const Key('filter-favourites')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(Key('contact-${keyN(3).substring(0, 8)}')), findsOneWidget);
      expect(find.byKey(Key('contact-${keyN(5).substring(0, 8)}')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('filter-recent')));
      await tester.tap(find.byKey(const Key('filter-recent')));
      await tester.pump();
      await tester.pump();
      expect(find.text('No contacts in Recent'), findsOneWidget);
    });

    testWidgetsT('search narrows by name', (tester) async {
      await pumpView(tester, contacts: 12);
      await tester.enterText(find.byKey(const Key('contacts-search')), 'Node 11');
      await tester.pump();
      await tester.pump();
      expect(find.byKey(Key('contact-${keyN(11).substring(0, 8)}')), findsOneWidget);
      expect(find.byKey(Key('contact-${keyN(2).substring(0, 8)}')), findsNothing);
    });

    testWidgetsT('tapping a person opens the conversation; the info button opens the details', (tester) async {
      final rig = await pumpView(tester, contacts: 3);
      await tester.tap(find.byKey(Key('contact-${keyN(2).substring(0, 8)}')));
      await tester.pumpAndSettle();
      expect(rig.opened.single.publicKey, keyN(2));
      expect(find.byKey(const Key('contacts-search')), findsOneWidget, reason: 'the hook was called, nothing was pushed');
      await tester.tap(find.byKey(Key('contact-details-${keyN(2).substring(0, 8)}')));
      await tester.pumpAndSettle();
      expect(find.text('Node 2'), findsWidgets);
      expect(find.byKey(const Key('contacts-search')), findsNothing);
    });

    testWidgetsT('a repeater has no conversation: tapping it opens the details', (tester) async {
      final rig = await pumpView(tester, contacts: 5);
      await tester.dragUntilVisible(find.byKey(Key('contact-${keyN(5).substring(0, 8)}')), find.byKey(const Key('contacts-list')), const Offset(0, -120));
      await tester.tap(find.byKey(Key('contact-${keyN(5).substring(0, 8)}')));
      await tester.pumpAndSettle();
      expect(rig.opened, isEmpty);
      expect(find.byKey(const Key('contacts-search')), findsNothing);
      expect(find.byKey(Key('contact-details-${keyN(5).substring(0, 8)}')), findsNothing);
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
    testWidgetsT('three shown, See all expands; Ignore removes the row; Add puts it on the radio and the row leaves', (tester) async {
      final rig = await pumpView(tester, contacts: 3, before: (rig) {
        for (var i = 1; i <= 5; i++) {
          advert(rig, i);
        }
      });
      expect(find.byKey(const Key('nearby-title')), findsOneWidget);
      expect(find.byKey(Key('nearby-${keyN(101).substring(0, 8)}')), findsOneWidget);
      expect(find.byKey(Key('nearby-${keyN(104).substring(0, 8)}')), findsNothing);
      expect(find.textContaining('heard 5 min ago, 2 hops'), findsWidgets);
      await tester.scrollUntilVisible(find.byKey(const Key('nearby-more')), 200, scrollable: find.descendant(of: find.byKey(const Key('contacts-list')), matching: find.byType(Scrollable)).first);
      await tester.tap(find.byKey(const Key('nearby-more')));
      await tester.pump();
      expect(find.byKey(Key('nearby-${keyN(105).substring(0, 8)}')), findsOneWidget);
      await tester.tap(find.byKey(Key('nearby-ignore-${keyN(101).substring(0, 8)}')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(Key('nearby-${keyN(101).substring(0, 8)}')), findsNothing);
      await tester.runAsync(() async {});
      await tester.tap(find.byKey(Key('nearby-add-${keyN(102).substring(0, 8)}')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(rig.port.table.containsKey(keyN(102)), isTrue);
      expect(find.byKey(Key('nearby-${keyN(102).substring(0, 8)}')), findsNothing);
      expect(find.byKey(Key('contact-${keyN(102).substring(0, 8)}')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgetsT('semantics: a new node row reads name, type and how it was heard', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpView(tester, contacts: 1, before: (rig) => advert(rig, 1, name: 'Hilltop'));
      expect(find.bySemanticsLabel(RegExp('New node Hilltop, Repeater, heard 5 min ago, 2 hops')), findsOneWidget);
      handle.dispose();
    });
  });

  group('accessibility and layout matrix', () {
    for (final size in [phoneSize, ipadSize]) {
      for (final scale in [1.0, 2.5]) {
        for (final dark in [false, true]) {
          testWidgetsT('everything at once: ${size.w.toInt()}x${size.h.toInt()} text x$scale ${dark ? 'dark' : 'light'}', (tester) async {
            final rig = await pumpView(tester, contacts: 14, w: size.w, h: size.h, scale: scale, b: dark ? Brightness.dark : Brightness.light, before: (rig) {
              for (var i = 1; i <= 4; i++) {
                advert(rig, i);
              }
              rig.chat.contacts.radioFull();
              rig.chat.contacts.setFavourite(keyN(2), true);
              rig.store.messages.insert(ChatMessage(
                  id: 'x', radioId: radioA, convKind: ConvKind.dm, convKey: ConvKey.dm(keyN(3).substring(0, 12)), direction: Direction.incoming,
                  tsSender: 1, tsLocalMs: rig.clock.ms, text: 'a fairly long message preview that has to wrap at large text sizes', state: MessageState.received, dedupeKey: 'k'));
            });
            expect(tester.takeException(), isNull);
            await tester.drag(find.byKey(const Key('contacts-list')), const Offset(0, -600));
            await tester.pump();
            expect(tester.takeException(), isNull);
            await tester.drag(find.byKey(const Key('contacts-list')), const Offset(0, 600));
            await tester.pump();
            await expectAccessible(tester);
            expect(rig.chat.contacts.state.tableFull, isTrue);
          });
        }
      }
    }

    testWidgetsT('VoiceOver: a tile reads "name, type, status, N unread"; key buttons are labelled', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpView(tester, contacts: 4, before: (rig) {
        rig.store.messages.insert(ChatMessage(
            id: 'x', radioId: radioA, convKind: ConvKind.dm, convKey: ConvKey.dm(keyN(2).substring(0, 12)), direction: Direction.incoming,
            tsSender: 1, tsLocalMs: rig.clock.ms, text: 'hello there', state: MessageState.received, dedupeKey: 'k'));
      });
      expect(find.bySemanticsLabel('Node 2, Person, hello there, 1 unread'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Node 1, Person, Heard')), findsOneWidget);
      expect(find.byTooltip('Contact settings'), findsOneWidget);
      expect(find.bySemanticsLabel('Add contact'), findsWidgets);
      handle.dispose();
    });

    testWidgetsT('big text hides the route chip instead of overflowing; normal text shows route words', (tester) async {
      await pumpView(tester, contacts: 3);
      expect(find.textContaining('no route yet'), findsWidgets);
    });
  });
}
