// Screenshot flow for Contacts and direct messages on the real app with the simulated radio (scripts/verify_contacts_sim.sh
// runs it and grabs a simulator screenshot at every "SCREEN <name>" line). Debug builds only: it reaches into the simulated
// radio to play the mesh (a new node appearing, a reply arriving).
// Build 77: the run always ends with VERIFY_DONE (chat_harness.dart runHarness); a throw prints STEPFAIL first, and a frame
// whose subject moved prints NOTE and is shot at its replacement.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/ui/app.dart';

import 'chat_harness.dart';
import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('contacts and DMs', (t) async {
    await runHarness('contacts_visual', () async {
      await app.main();
      if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
        for (var i = 0; i < 4; i++) {
          await t.tap(find.byKey(const Key('onboarding-next')));
          await pumpFor(t, const Duration(milliseconds: 600));
        }
      }
      // Build 77 (round 5 O1): the intro ends on "What MeshSonar collects"; Keep sharing closes it.
      if (await waitFor(t, find.byKey(const Key('telemetry-keep')), timeout: const Duration(seconds: 6))) {
        await t.tap(find.byKey(const Key('telemetry-keep')));
        await pumpFor(t, const Duration(seconds: 1));
      }
      expect(await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))), isTrue, reason: 'the shell');
      final keep = find.byKey(const Key('telemetry-keep'));
      if (await waitFor(t, keep, timeout: const Duration(seconds: 4))) {
        await t.tap(keep);
        await pumpFor(t, const Duration(seconds: 1));
      }

      final state = AppScope.of(t.element(find.byType(Scaffold).first));
      final scanner = state.services.simulatorScanner as SimulatedRadioScanner;
      final list = find.byKey(const Key('contacts-list'));

      // Contacts before any radio: the honest first-run state. Chat opens on Chats; Contacts is the second segment.
      await openChatSegment(t, 'contacts');
      expect(await waitFor(t, find.byKey(const Key('contacts-no-radio')), timeout: const Duration(seconds: 5)), isTrue, reason: 'contacts without a radio');
      await shot(t, 'contacts-no-radio');

      // Connect the simulated radio; close the antenna sheet (decision 4: the first connect still opens it).
      expect(await state.connectSimulator(), isTrue, reason: 'simulated radio connects');
      await pumpFor(t, const Duration(seconds: 3));
      await closeAntennaSheet(t);
      while (find.byType(BottomSheet).evaluate().isNotEmpty) {
        await t.tapAt(const Offset(2, 2));
        await pumpFor(t, const Duration(seconds: 1));
      }
      await openChatSegment(t, 'contacts');
      expect(await waitFor(t, list), isTrue, reason: 'contacts list');
      await pumpFor(t, const Duration(seconds: 3));
      await shot(t, 'contacts-list');

      // The radio adds every node it hears: offer to ask first. Say yes.
      final yes = find.byKey(const Key('ask-yes'));
      if (await waitFor(t, yes, timeout: const Duration(seconds: 6))) {
        await t.ensureVisible(yes);
        await pumpFor(t, const Duration(milliseconds: 400));
        await shot(t, 'contacts-ask-first');
        await t.tap(yes);
        await pumpFor(t, const Duration(seconds: 2));
      } else {
        note('contacts-ask-first: the ask-first card was not offered');
      }

      // Nodes appear on the air: they wait under New nodes nearby, the radio does not fill up.
      final radio = scanner.lastTransport!;
      radio.injectNewAdvert('Maple Ridge RPT', type: 2, lat: 39.76, lon: -84.19);
      radio.injectNewAdvert('Sam W8SAM');
      radio.injectNewAdvert('Weather Node', type: 4);
      await pumpFor(t, const Duration(seconds: 2));
      final nearbyRow = find.byKey(const Key('nearby-row'));
      if (await waitFor(t, nearbyRow, timeout: const Duration(seconds: 5))) {
        await t.ensureVisible(nearbyRow);
        await pumpFor(t, const Duration(milliseconds: 400));
      } else {
        note('contacts-nearby: no New nodes nearby row on the Contacts list');
      }
      await shot(t, 'contacts-nearby');

      // Add one. Build 77: the Nearby row opens More > Radio, where each new node has its Add button; Sam (a person) is
      // added so the Contacts list shows him afterwards.
      if (nearbyRow.evaluate().isNotEmpty) {
        await t.tap(nearbyRow);
        await pumpFor(t, const Duration(seconds: 2));
        final rowKey = find.ancestor(
            of: find.text('Sam W8SAM'),
            matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> && RegExp(r'^nearby-[0-9a-f]{8}$').hasMatch((w.key as ValueKey<String>).value)));
        var add = keyPrefix('nearby-add-');
        if (rowKey.evaluate().isNotEmpty) {
          final id = (t.widget(rowKey.first).key! as ValueKey<String>).value.substring('nearby-'.length);
          add = find.byKey(Key('nearby-add-$id'));
        } else {
          note('contacts-after-add: Sam W8SAM not listed as nearby; the first nearby node is added');
        }
        final within = find.byKey(const Key('more-radio-list')).evaluate().isNotEmpty ? find.byKey(const Key('more-radio-list')) : find.byType(Scrollable).first;
        if (await scrollToFind(t, add, within, wait: const Duration(seconds: 8))) {
          await t.tap(add.first);
          await pumpFor(t, const Duration(seconds: 2));
        } else {
          note('contacts-after-add: no Add button for a nearby node');
        }
        await popToRoots(t);
        await openChatSegment(t, 'contacts');
        expect(await waitFor(t, list), isTrue, reason: 'contacts list after the add');
        await shot(t, 'contacts-after-add');
      }

      // Build 77: the Contacts list holds people only; the filter chips are gone and repeaters, rooms and sensors are in
      // More > Radio. The repeaters frame is shot there, at the first repeater row.
      note('contacts-filter-repeaters: no filter chips since the people-only Contacts list; shot is More > Radio at its first node row');
      await openTab(t, 'More');
      if (find.byKey(const Key('more-list')).hitTestable().evaluate().isEmpty) await openTab(t, 'More');
      expect(await tapFirstOf(t, ['more-radio']), isTrue, reason: 'More > Radio row');
      expect(await waitFor(t, find.byKey(const Key('more-radio-list')), timeout: const Duration(seconds: 8)), isTrue, reason: 'More > Radio list');
      final netRow = keyPrefix('network-row-');
      expect(await scrollToFind(t, netRow, find.byKey(const Key('more-radio-list'))), isTrue, reason: 'a repeater row in More > Radio');
      await shot(t, 'contacts-filter-repeaters');
      await popToRoots(t);

      // Search with no match, then clear.
      await openChatSegment(t, 'contacts');
      final search = find.byKey(const Key('contacts-search'));
      await t.ensureVisible(search);
      await pumpFor(t, const Duration(milliseconds: 400));
      await t.tap(search);
      await t.enterText(search, 'zzz');
      await pumpFor(t, const Duration(seconds: 1));
      await hideKeyboard(t);
      expect(find.byKey(const Key('contacts-no-match')), findsOneWidget, reason: 'no contact matches zzz');
      await shot(t, 'contacts-no-match');
      // Build 77: the clear action is the "Clear search" button in the no-match view (contacts-clear-search).
      await t.tap(find.byKey(const Key('contacts-clear-search')));
      await pumpFor(t, const Duration(milliseconds: 800));
      expect(find.byKey(const Key('contacts-no-match')), findsNothing, reason: 'the list is back after clearing the search');
      expect(list, findsOneWidget, reason: 'the list is back after clearing the search');

      // A direct message. Build 77: a tap on a contact row opens the profile; its Message button opens the conversation.
      final ann = find.text('Ann KE8ANN');
      await t.scrollUntilVisible(ann, 200, scrollable: find.descendant(of: list, matching: find.byType(Scrollable)).first);
      final annTile = find.ancestor(
          of: ann.first,
          matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> && RegExp(r'^contact-[0-9a-f]{8}$').hasMatch((w.key as ValueKey<String>).value)));
      expect(annTile, findsWidgets, reason: 'Ann KE8ANN row');
      final annId = (t.widget(annTile.first).key! as ValueKey<String>).value.substring('contact-'.length);
      await t.tap(find.byKey(Key('contact-message-$annId')));
      await pumpFor(t, const Duration(seconds: 2));
      expect(await waitFor(t, find.byKey(const Key('composer-field')), timeout: const Duration(seconds: 5)), isTrue, reason: 'the conversation with Ann');
      await shot(t, 'dm-empty');
      await t.tap(find.byKey(const Key('composer-field')));
      await t.enterText(find.byKey(const Key('composer-field')), 'Morning Ann, are you on the hill today?');
      await pumpFor(t, const Duration(milliseconds: 500));
      await t.tap(find.byKey(const Key('composer-send')));
      await pumpFor(t, const Duration(milliseconds: 300));
      // Build 77 (round 3): the first send raises the alerts pre-prompt; Not now.
      if (!await answerAlertsPrePrompt(t)) note('dm-sending: no alerts pre-prompt after the first send');
      await shot(t, 'dm-sending');
      await pumpFor(t, const Duration(seconds: 6));
      await shot(t, 'dm-delivered');
      radio.injectDirectMessage('Ann KE8ANN', 'Yes! Up there by 10. Bring the long antenna.');
      await pumpFor(t, const Duration(seconds: 8));
      await shot(t, 'dm-reply');
      // A person taps the field first; after a reply arrived the test's text input connection is stale otherwise.
      await t.tap(find.byKey(const Key('composer-field')));
      await pumpFor(t, const Duration(milliseconds: 500));
      await t.enterText(find.byKey(const Key('composer-field')), 'On it.');
      await pumpFor(t, const Duration(milliseconds: 300));
      await t.tap(find.byKey(const Key('composer-send')));
      await pumpFor(t, const Duration(seconds: 6));
      // Build 77 (round 3): route modes are gone; this frame is the second message sent by the known route.
      await hideKeyboard(t);
      await shot(t, 'dm-direct');

      // Message details of the last message, then the contact.
      await t.longPress(find.text('On it.').last);
      await pumpFor(t, const Duration(seconds: 1));
      final details = find.byKey(const Key('act-details'));
      expect(await waitFor(t, details, timeout: const Duration(seconds: 4)), isTrue, reason: 'Full details in the message menu');
      await t.tap(details);
      await pumpFor(t, const Duration(seconds: 1));
      expect(await waitFor(t, find.byKey(const Key('message-details')), timeout: const Duration(seconds: 5)), isTrue, reason: 'the message details sheet');
      await shot(t, 'dm-message-details');
      if (!await tapFirstOf(t, ['details-done'], wait: const Duration(seconds: 1))) await closeRouteHolding(t, 'message-details');
      // Build 77: the contact opens from the conversation's title (the old dm-contact-info button is gone).
      expect(await tapFirstOf(t, ['conv-title']), isTrue, reason: 'conversation title');
      final profile = find.byKey(const Key('contact-profile'));
      expect(await waitFor(t, profile, timeout: const Duration(seconds: 8)), isTrue, reason: 'Ann\'s profile');
      await shot(t, 'contact-detail');
      await t.drag(profile, const Offset(0, -500));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'contact-detail-2');
      await t.drag(profile, const Offset(0, -700));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'contact-detail-3');
      await t.tap(find.byKey(const Key('contact-back')));
      await pumpFor(t, const Duration(seconds: 1));
      await t.pageBack();
      await pumpFor(t, const Duration(seconds: 1));
      expect(await waitFor(t, list, timeout: const Duration(seconds: 5)), isTrue, reason: 'back on the Contacts list');
      await shot(t, 'back-to-contacts');

      // A repeater's details: More > Radio (build 77: repeaters are not in Contacts).
      note('repeater-detail: opened from More > Radio (no Repeaters filter on Contacts)');
      await openTab(t, 'More');
      if (find.byKey(const Key('more-list')).hitTestable().evaluate().isEmpty) await openTab(t, 'More');
      expect(await tapFirstOf(t, ['more-radio']), isTrue, reason: 'More > Radio row');
      expect(await scrollToFind(t, netRow, find.byKey(const Key('more-radio-list'))), isTrue, reason: 'a repeater row in More > Radio');
      await t.tap(netRow.first);
      await pumpFor(t, const Duration(seconds: 2));
      expect(await waitFor(t, profile, timeout: const Duration(seconds: 8)), isTrue, reason: 'the repeater page');
      await shot(t, 'repeater-detail');
      await popToRoots(t);

      // The add flow. Build 77: Add contact is the person-plus button in the bar while Contacts is selected.
      await openChatSegment(t, 'contacts');
      expect(await tapFirstOf(t, ['chat-add-contact']), isTrue, reason: 'Add contact in the bar');
      expect(await waitFor(t, find.byKey(const Key('add-contact')), timeout: const Duration(seconds: 5)), isTrue, reason: 'the Add contact screen');
      await shot(t, 'add-contact');
      expect(await tapFirstOf(t, ['add-mine']), isTrue, reason: 'Show my QR code');
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'add-my-contact');
      await t.pageBack();
      await pumpFor(t, const Duration(seconds: 1));
      expect(await tapFirstOf(t, ['add-paste-tile']), isTrue, reason: 'Paste a link or key');
      expect(await waitFor(t, find.byKey(const Key('add-text')), timeout: const Duration(seconds: 4)), isTrue, reason: 'the paste field');
      await t.enterText(find.byKey(const Key('add-text')), 'meshcore://contact/add?name=Pat+N8PAT&public_key=${'ab' * 32}&type=1');
      await pumpFor(t, const Duration(milliseconds: 500));
      await shot(t, 'add-paste');
      await hideKeyboard(t);
      await popToRoots(t);

      // The radio's list and the contacts settings: the two rows at the foot of the Contacts list.
      await openChatSegment(t, 'contacts');
      final usage = find.byKey(const Key('contacts-usage'));
      if (await scrollToFind(t, usage, list, wait: const Duration(seconds: 8))) {
        await t.tap(usage);
        await pumpFor(t, const Duration(seconds: 2));
        expect(await waitFor(t, find.byKey(const Key('radio-list-sheet')), timeout: const Duration(seconds: 5)), isTrue, reason: 'the radio list sheet');
        await shot(t, 'radio-list');
        await closeRouteHolding(t, 'radio-list-sheet');
      } else {
        note('radio-list: no "n of m on your radio" row (the radio did not report its count)');
      }
      // Build 77: the settings sheet opens from "Manage contacts" (contacts-manage); contacts-settings is the sheet itself.
      final manage = find.byKey(const Key('contacts-manage'));
      expect(await scrollToFind(t, manage, list, wait: const Duration(seconds: 8)), isTrue, reason: 'Manage contacts row');
      await t.tap(manage);
      await pumpFor(t, const Duration(seconds: 2));
      expect(await waitFor(t, find.byKey(const Key('contacts-settings')), timeout: const Duration(seconds: 5)), isTrue, reason: 'the contacts settings sheet');
      await shot(t, 'contacts-settings');
      await closeRouteHolding(t, 'contacts-settings');

      // The radio goes away: the book is still there, with the honest banner.
      await state.disconnect();
      await pumpFor(t, const Duration(seconds: 3));
      await popToRoots(t);
      await openChatSegment(t, 'contacts');
      await shot(t, 'contacts-offline');
    });
  }, timeout: const Timeout(Duration(minutes: 15)));
}
