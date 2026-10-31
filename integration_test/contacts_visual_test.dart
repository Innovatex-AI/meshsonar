// Screenshot flow for Contacts and direct messages on the real app with the simulated radio (scripts/verify_contacts_sim.sh
// runs it and grabs a simulator screenshot at every "SCREEN <name>" line). Debug builds only: it reaches into the simulated
// radio to play the mesh (a new node appearing, a reply arriving).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/ui/app.dart';

import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('contacts and DMs', (t) async {
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      for (var i = 0; i < 4; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(milliseconds: 600));
      }
    }
    expect(await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))), isTrue);
    final keep = find.byKey(const Key('telemetry-keep'));
    if (await waitFor(t, keep, timeout: const Duration(seconds: 4))) {
      await t.tap(keep);
      await pumpFor(t, const Duration(seconds: 1));
    }

    final state = AppScope.of(t.element(find.byType(Scaffold).first));
    final scanner = state.services.simulatorScanner as SimulatedRadioScanner;

    // Chat before any radio: the honest first-run state.
    await openShellTab(t, 'Chat');
    await shot(t, 'contacts-no-radio');

    // Connect the simulated radio; close the antenna sheet.
    expect(await state.connectSimulator(), isTrue);
    await pumpFor(t, const Duration(seconds: 3));
    while (find.byType(BottomSheet).evaluate().isNotEmpty) {
      await t.tapAt(const Offset(2, 2));
      await pumpFor(t, const Duration(seconds: 1));
    }
    await openShellTab(t, 'Chat');
    expect(await waitFor(t, find.byKey(const Key('contacts-list'))), isTrue, reason: 'contacts list');
    await pumpFor(t, const Duration(seconds: 3));
    await shot(t, 'contacts-list');

    // The radio adds every node it hears: offer to ask first. Say yes.
    final yes = find.byKey(const Key('ask-yes'));
    if (await waitFor(t, yes, timeout: const Duration(seconds: 6))) {
      await shot(t, 'contacts-ask-first');
      await t.tap(yes);
      await pumpFor(t, const Duration(seconds: 2));
    }

    // Nodes appear on the air: they wait under New nodes nearby, the radio does not fill up.
    final radio = scanner.lastTransport!;
    radio.injectNewAdvert('Maple Ridge RPT', type: 2, lat: 39.76, lon: -84.19);
    radio.injectNewAdvert('Sam W8SAM');
    radio.injectNewAdvert('Weather Node', type: 4);
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'contacts-nearby');

    // Add one.
    final add = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('nearby-add-'));
    if (add.evaluate().isNotEmpty) {
      await t.tap(add.first);
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'contacts-after-add');
    }

    // Filters and search.
    await t.tap(find.text('Repeaters').first);
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'contacts-filter-repeaters');
    await t.tap(find.text('All').first);
    await pumpFor(t, const Duration(milliseconds: 500));
    await t.enterText(find.byKey(const Key('contacts-search')), 'zzz');
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'contacts-no-match');
    await t.enterText(find.byKey(const Key('contacts-search')), '');
    await pumpFor(t, const Duration(milliseconds: 500));

    // A direct message: flood first, delivered, route learned, then direct.
    final ann = find.textContaining('Ann KE8ANN').first;
    await t.tap(ann);
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'dm-empty');
    await t.enterText(find.byKey(const Key('composer-field')), 'Morning Ann, are you on the hill today?');
    await pumpFor(t, const Duration(milliseconds: 500));
    await t.tap(find.byKey(const Key('composer-send')));
    await pumpFor(t, const Duration(milliseconds: 800));
    await shot(t, 'dm-sending');
    await pumpFor(t, const Duration(seconds: 6));
    await shot(t, 'dm-delivered');
    radio.injectDirectMessage('Ann KE8ANN', 'Yes! Up there by 10. Bring the long antenna.');
    await pumpFor(t, const Duration(seconds: 8));
    await shot(t, 'dm-reply');
    await t.enterText(find.byKey(const Key('composer-field')), 'On it.');
    await pumpFor(t, const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('composer-send')));
    await pumpFor(t, const Duration(seconds: 6));
    await shot(t, 'dm-direct');

    // Message details of the last message, then the contact.
    await t.longPress(find.text('On it.').first);
    await pumpFor(t, const Duration(seconds: 1));
    final details = find.byKey(const Key('act-details'));
    if (details.evaluate().isNotEmpty) {
      await t.tap(details);
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'dm-message-details');
      await t.tapAt(const Offset(10, 10));
      await pumpFor(t, const Duration(seconds: 1));
    }
    await t.tap(find.byKey(const Key('dm-contact-info')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'contact-detail');
    final listView = find.byType(Scrollable).first;
    await t.drag(listView, const Offset(0, -500));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'contact-detail-2');
    await t.drag(listView, const Offset(0, -700));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'contact-detail-3');
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));

    // A repeater's details, the add flow, the radio list and the settings sheet.
    await t.tap(find.text('Repeaters').first);
    await pumpFor(t, const Duration(seconds: 1));
    final rep = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('contact-') && !(w.key as ValueKey<String>).value.startsWith('contact-details'));
    if (rep.evaluate().isNotEmpty) {
      await t.tap(rep.first);
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'repeater-detail');
      await t.pageBack();
      await pumpFor(t, const Duration(seconds: 1));
    }
    await t.tap(find.text('All').first);
    await pumpFor(t, const Duration(milliseconds: 500));
    await t.tap(find.byKey(const Key('contacts-add')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'add-contact');
    await t.tap(find.byKey(const Key('add-mine')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'add-my-contact');
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));
    await t.tap(find.byKey(const Key('add-paste-tile')));
    await pumpFor(t, const Duration(seconds: 1));
    await t.enterText(find.byKey(const Key('add-text')), 'meshcore://contact/add?name=Pat+N8PAT&public_key=${'ab' * 32}&type=1');
    await pumpFor(t, const Duration(milliseconds: 500));
    await shot(t, 'add-paste');
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));
    final usage = find.byKey(const Key('contacts-usage'));
    if (usage.evaluate().isNotEmpty) {
      await t.tap(usage);
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'radio-list');
      await t.tapAt(const Offset(10, 10));
      await pumpFor(t, const Duration(seconds: 1));
    }
    await t.tap(find.byKey(const Key('contacts-settings')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'contacts-settings');
    await t.tapAt(const Offset(10, 10));
    await pumpFor(t, const Duration(seconds: 1));

    // The radio goes away: the book is still there, with the honest banner.
    await state.disconnect();
    await pumpFor(t, const Duration(seconds: 3));
    await openShellTab(t, 'Chat');
    await shot(t, 'contacts-offline');
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
