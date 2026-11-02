// Screenshot flow for the contact profile (Chat WP6a) on the real app with the simulated radio:
//   FLOW_TEST=integration_test/contact_profile_visual_test.dart scripts/verify_sim.sh <worktree>
// Shoots a person (flag off, then on), the Edit / Share / Route sheets and a repeater.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/ui/app.dart';

import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('contact profile', (t) async {
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
    expect(await state.connectSimulator(), isTrue);
    await pumpFor(t, const Duration(seconds: 3));
    while (find.byType(BottomSheet).evaluate().isNotEmpty) {
      await t.tapAt(const Offset(2, 2));
      await pumpFor(t, const Duration(seconds: 1));
    }
    await openShellTab(t, 'Chat');
    expect(await waitFor(t, find.byKey(const Key('contacts-list'))), isTrue);
    await pumpFor(t, const Duration(seconds: 3));
    final yes = find.byKey(const Key('ask-yes'));
    if (await waitFor(t, yes, timeout: const Duration(seconds: 6))) {
      await t.tap(yes);
      await pumpFor(t, const Duration(seconds: 2));
    }

    Future<void> openContact(String name) async {
      final row = find.textContaining(name);
      await t.scrollUntilVisible(row, 200, scrollable: find.descendant(of: find.byKey(const Key('contacts-list')), matching: find.byType(Scrollable)).first);
      await t.tap(row.first);
      await pumpFor(t, const Duration(seconds: 2));
      final info = find.byKey(const Key('dm-contact-info'));
      if (info.evaluate().isNotEmpty) {
        await t.tap(info);
        await pumpFor(t, const Duration(seconds: 2));
      }
    }

    Future<void> back() async {
      await t.tap(find.byKey(const Key('contact-back')));
      await pumpFor(t, const Duration(seconds: 1));
    }

    await openContact('Ann KE8ANN');
    await shot(t, 'profile-person-flag-off');
    AppFlags.chatRedesign = true;
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'profile-person');
    await t.drag(find.byKey(const Key('contact-profile')), const Offset(0, -500));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'profile-person-2');
    await t.drag(find.byKey(const Key('contact-profile')), const Offset(0, -900));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'profile-person-3');
    await t.drag(find.byKey(const Key('contact-profile')), const Offset(0, 2000));
    await pumpFor(t, const Duration(milliseconds: 600));
    await t.tap(find.byKey(const Key('contact-edit')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'profile-edit');
    await t.tap(find.byKey(const Key('edit-cancel')));
    await pumpFor(t, const Duration(seconds: 1));
    await t.tap(find.byKey(const Key('contact-share-nav')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'profile-share');
    await t.tapAt(const Offset(10, 60));
    await pumpFor(t, const Duration(seconds: 1));
    await t.tap(find.byKey(const Key('tile-route')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'profile-route');
    await t.tapAt(const Offset(10, 60));
    await pumpFor(t, const Duration(seconds: 1));
    await t.tap(find.byKey(const Key('tile-ping')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'profile-ping-coming');
    await t.tapAt(const Offset(10, 60));
    await pumpFor(t, const Duration(seconds: 1));
    await back();
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));
    await t.ensureVisible(find.byKey(const Key('filter-repeaters')));
    await t.tap(find.byKey(const Key('filter-repeaters')));
    await pumpFor(t, const Duration(seconds: 1));
    final first = find.descendant(of: find.byKey(const Key('contacts-list')), matching: find.byType(InkWell));
    if (first.evaluate().isNotEmpty) {
      await t.tap(first.first);
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'profile-repeater');
    }
    AppFlags.chatRedesign = false;
  });
}
