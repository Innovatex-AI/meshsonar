// Screenshots of the repeater admin and room screens on a simulator, driven by the fake repeater (measured behaviours).
// Not part of the release: run with `flutter test integration_test/repeater_admin_shots.dart -d <simulator udid>` and grab a
// screenshot at every "SCREEN <name>" line (the script in HANDOFF does this).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/ui/radios/repeater_admin/repeater_admin_screen.dart';

import '../test/ui/radios/admin_rig.dart' show app, makeRig;
import 'screens.dart';

Future<void> tapTab(WidgetTester t, String name) async {
  await t.tap(find.byKey(Key('tab-$name')));
  await pumpFor(t, const Duration(milliseconds: 600));
}

/// Lists are lazy: scroll the widget into the built range, then into view.
Future<void> reveal(WidgetTester t, Finder f) async {
  if (f.evaluate().isEmpty) {
    await t.scrollUntilVisible(f, 200, scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first, maxScrolls: 60);
  }
  await t.ensureVisible(f);
  await pumpFor(t, const Duration(milliseconds: 400));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final dark in [false, true]) {
    testWidgets('repeater admin ${dark ? 'dark' : 'light'}', (t) async {
      final rig = await makeRig(setup: (r) {
        r.clockOffsetSecs = -400;
        r.prefs['flood.advert.interval'] = '0';
        r.acl['a9b1acd3a408${'11' * 26}'] = 3;
      });
      await t.pumpWidget(app(RepeaterAdminScreen(controller: rig.controller, keyHex: rig.rep.keyHex, ownsController: false), dark: dark));
      await pumpFor(t, const Duration(milliseconds: 500));
      final d = dark ? 'dark' : 'light';
      await shot(t, 'admin-login-$d');
      unawaited(rig.controller.login('secret'));
      await waitFor(t, find.byKey(const Key('card-status')));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'admin-overview-$d');
      await reveal(t, find.byKey(const Key('run-health')));
      await t.tap(find.byKey(const Key('run-health')));
      await waitFor(t, find.byKey(const Key('finding-clock')), timeout: const Duration(seconds: 40));
      await pumpFor(t, const Duration(seconds: 1));
      await reveal(t, find.byKey(const Key('finding-advert')));
      await shot(t, 'admin-health-$d');
      await tapTab(t, 'settings');
      await waitFor(t, find.byKey(const Key('setting-name')));
      await pumpFor(t, const Duration(seconds: 6));
      await shot(t, 'admin-settings-$d');
      await reveal(t, find.byKey(const Key('setting-name')));
      await t.tap(find.byKey(const Key('setting-name')));
      await pumpFor(t, const Duration(milliseconds: 800));
      await t.enterText(find.byKey(const Key('editor-text')), 'Hilltop 2');
      await t.tap(find.byKey(const Key('editor-review')));
      await waitFor(t, find.byKey(const Key('review-apply')));
      await shot(t, 'admin-review-$d');
      await t.tap(find.byKey(const Key('review-apply')));
      await waitFor(t, find.byKey(const Key('result-verified')));
      await shot(t, 'admin-verified-$d');
      await t.tap(find.byKey(const Key('result-done')));
      await pumpFor(t, const Duration(milliseconds: 600));
      await reveal(t, find.byKey(const Key('setting-radio')));
      await t.tap(find.byKey(const Key('setting-radio')));
      await pumpFor(t, const Duration(milliseconds: 800));
      await shot(t, 'admin-radio-warning-$d');
      await t.tapAt(const Offset(10, 60));
      await pumpFor(t, const Duration(milliseconds: 600));
      await tapTab(t, 'neighbours');
      await waitFor(t, find.byKey(const Key('neighbour-1bcee248')));
      await shot(t, 'admin-neighbours-$d');
      await tapTab(t, 'access');
      await waitFor(t, find.byKey(const Key('acl-a9b1acd3a408')));
      await shot(t, 'admin-access-$d');
      await tapTab(t, 'console');
      await t.enterText(find.byKey(const Key('console-input')), 'get radio');
      await t.tap(find.byKey(const Key('console-send')));
      await pumpFor(t, const Duration(seconds: 2));
      await t.enterText(find.byKey(const Key('console-input')), 'rebootnow');
      await t.tap(find.byKey(const Key('console-send')));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'admin-console-$d');
      await t.pumpWidget(const SizedBox());
      await rig.link.close();
    });
  }
}
