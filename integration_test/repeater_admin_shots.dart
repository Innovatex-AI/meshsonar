// Screenshots of the repeater admin and room screens on a simulator, driven by the fake repeater (measured behaviours).
// Not part of the release: run with `flutter test integration_test/repeater_admin_shots.dart -d <simulator udid>` and grab a
// screenshot at every "SCREEN <name>" line (the script in HANDOFF does this).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';
import 'package:meshsonar/radio/room_session.dart';
import 'package:meshsonar/ui/radios/repeater_admin/repeater_admin_screen.dart';
import 'package:meshsonar/ui/radios/rooms/room_screen.dart';

import '../test/support/repeater_admin_fake.dart';
import '../test/ui/radios/admin_rig.dart' show app, makeRig, repKey;
import 'screens.dart';

Future<void> tapTab(WidgetTester t, String name) async {
  await t.tap(find.byKey(Key('tab-$name')));
  await pumpFor(t, const Duration(milliseconds: 600));
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
      await t.enterText(find.byKey(const Key('admin-password')), 'secret');
      await t.pump();
      await t.tap(find.byKey(const Key('admin-login-go')));
      await waitFor(t, find.byKey(const Key('card-status')));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'admin-overview-$d');
      await t.ensureVisible(find.byKey(const Key('run-health')));
      await t.tap(find.byKey(const Key('run-health')));
      await waitFor(t, find.byKey(const Key('finding-clock')), timeout: const Duration(seconds: 40));
      await pumpFor(t, const Duration(seconds: 1));
      await t.ensureVisible(find.byKey(const Key('finding-advert')));
      await shot(t, 'admin-health-$d');
      await tapTab(t, 'settings');
      await waitFor(t, find.byKey(const Key('setting-name')));
      await pumpFor(t, const Duration(seconds: 40));
      await shot(t, 'admin-settings-$d');
      await t.ensureVisible(find.byKey(const Key('setting-name')));
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
      await t.ensureVisible(find.byKey(const Key('setting-radio')));
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

  testWidgets('room', (t) async {
    final room = FakeAdminRepeater(key: repKey(), name: 'Valley Room', role: 'room', adminPassword: 'adminpw', guestPassword: 'roompw');
    room.roomPosts.addAll([
      (authorHex: 'cd' * 32, text: 'Net tonight at 8, 146.52 and the mesh', ts: 1793480000),
      (authorHex: 'ef' * 32, text: 'I can hear the hill repeater from the truck', ts: 1793480600),
    ]);
    final radio = AdminFakeTransport({room.keyHex: room});
    final link = MeshCoreCompanionLink(radio, claimReplyTimeout: const Duration(milliseconds: 500), messagePollInterval: const Duration(milliseconds: 100));
    final info = await link.start();
    final session = LinkRadioSession(link, info: info);
    final c = RoomController(room: RoomSession(radio: session, keyHex: room.keyHex, name: room.name), title: 'Valley Room', nameForPrefix: (p) => p == 'cdcdcdcd' ? 'Hill Walker' : null);
    await t.pumpWidget(app(RoomScreen(controller: c)));
    await shot(t, 'room-login');
    await t.enterText(find.byKey(const Key('room-password')), 'roompw');
    await t.pump();
    await t.tap(find.byKey(const Key('room-login-go')));
    await waitFor(t, find.text('Net tonight at 8, 146.52 and the mesh'));
    await t.enterText(find.byKey(const Key('room-compose')), 'Copy that, 73');
    await t.tap(find.byKey(const Key('room-send')));
    await waitFor(t, find.text('Copy that, 73'));
    await shot(t, 'room-conversation');
    await t.pumpWidget(const SizedBox());
    await link.close();
    // ignore: avoid_print
    print('VERIFY_DONE');
  });
}
