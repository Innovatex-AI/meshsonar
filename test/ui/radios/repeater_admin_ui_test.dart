// Repeater admin screens against the fake repeater (measured behaviours): login, overview, health check, settings editor with
// review/confirm/read-back/undo, neighbours, regions, access, console; guest mode; large text, dark, phone and tablet sizes,
// semantics and tap targets.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/repeater_admin.dart';
import 'package:meshsonar/ui/radios/repeater_admin/admin_controller.dart';
import 'package:meshsonar/ui/radios/repeater_admin/admin_login_view.dart';

import 'admin_rig.dart';

Future<void> tapTab(WidgetTester tester, String name) async {
  await tester.ensureVisible(find.byKey(Key('tab-$name')));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(Key('tab-$name')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('login', () {
    adminTest('explains where the password goes, masks it, and a wrong password says so in plain words', (tester) async {
      final rig = await openAdmin(tester, login: false);
      expect(find.text(adminPasswordPromise), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const Key('admin-password'))).obscureText, isTrue);
      expect(tester.widget<FilledButton>(find.byKey(const Key('admin-login-go'))).onPressed, isNull, reason: 'nothing to send yet');
      expect(find.byKey(const Key('admin-remember')), findsNothing, reason: 'remembering is only offered when a secure store exists');
      await tester.enterText(find.byKey(const Key('admin-password')), 'wrongpass');
      await tester.pump();
      await tester.tap(find.byKey(const Key('admin-login-go')));
      await pumpUntilFound(tester, find.byKey(const Key('admin-login-error')));
      expect(find.textContaining('No answer'), findsOneWidget);
      expect(rig.controller.stage, AdminStage.login);
      await tester.tap(find.byKey(const Key('admin-password-show')));
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const Key('admin-password'))).obscureText, isFalse);
    });

    adminTest('a correct password opens the tabs and clears the field; the controller keeps no password in its state', (tester) async {
      final rig = await openAdmin(tester);
      expect(find.byKey(const Key('admin-tabs')), findsOneWidget);
      expect(find.byKey(const Key('admin-password')), findsNothing);
      expect(rig.controller.session.isAdmin, isTrue);
      expect(rig.controller.session.debugState().toString(), isNot(contains('secret')));
      expect(rig.controller.session.log.map((e) => e.toString()).join(), isNot(contains('secret')));
    });

    adminTest('the radio disconnecting during use goes back to login with the reason', (tester) async {
      final rig = await openAdmin(tester);
      rig.radio.drop();
      await tester.runAsync(() => rig.controller.loadNeighbours());
      await tester.pump();
      expect(rig.controller.stage, AdminStage.login);
      expect(find.byKey(const Key('admin-login-error')), findsOneWidget);
      expect(find.textContaining('radio disconnected'), findsOneWidget);
    });
  });

  group('overview', () {
    adminTest('shows name, firmware, battery, uptime, noise, airtime, packets, errors and a right clock', (tester) async {
      await openAdmin(tester);
      expect(find.byKey(const Key('card-identity')), findsOneWidget);
      expect(find.text('INNO-OB-2'), findsWidgets);
      expect(find.byKey(const Key('v-firmware')), findsOneWidget);
      expect(find.text('Heltec V4.3 OLED'), findsOneWidget);
      expect(find.text('3.86 V'), findsOneWidget);
      expect(find.text('1 d 17 h'), findsOneWidget);
      expect(find.text('-108 dBm'), findsOneWidget);
      expect(find.textContaining('1165 received'), findsOneWidget);
      expect(find.textContaining('193 bad packets'), findsOneWidget);
      expect(find.text('Right (within 2 s)'), findsOneWidget);
      expect(find.byKey(const Key('sync-clock')), findsNothing);
      expect(find.textContaining('Last advert you heard'), findsOneWidget);
    });

    adminTest('a clock that is behind offers Sync clock behind a confirm, and fixes it', (tester) async {
      final rig = await openAdmin(tester, setup: (r) => r.clockOffsetSecs = -400);
      expect(find.byKey(const Key('sync-clock')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-clock')));
      await frames(tester);
      expect(find.text('Set the repeater\'s clock?'), findsOneWidget);
      expect(rig.rep.clockOffsetSecs, -400, reason: 'nothing sent before the confirm');
      await tester.tap(find.byKey(const Key('sync-clock-confirm')));
      await pumpUntil(tester, () => rig.rep.clockOffsetSecs.abs() < 5);
      expect(rig.rep.clockOffsetSecs.abs(), lessThan(5));
    });

    adminTest('a clock that is ahead says it cannot be set back', (tester) async {
      await openAdmin(tester, setup: (r) => r.clockOffsetSecs = 900);
      expect(find.byKey(const Key('sync-clock')), findsNothing);
      expect(find.textContaining('never sets its clock backwards'), findsWidgets);
    });

    adminTest('health check: plain-language findings with severity and a suggested fix, never auto-applied', (tester) async {
      final rig = await openAdmin(tester, setup: (r) {
        r.prefs['radio'] = '869.618,62.5,7,5';
        r.prefs['flood.advert.interval'] = '0';
        r.neighbours.clear();
        r.voltageV = 3.5;
      });
      await tester.ensureVisible(find.byKey(const Key('run-health')));
      await tester.tap(find.byKey(const Key('run-health')));
      await pumpUntil(tester, () => !rig.controller.checkingHealth && rig.controller.findings.isNotEmpty);
      await tester.pump();
      expect(find.byKey(const Key('finding-radio-preset')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('finding-radio-preset')));
      expect(find.textContaining('Radio differs from the region preset'), findsOneWidget);
      expect(find.textContaining('What to do:'), findsWidgets);
      expect(find.byKey(const Key('finding-advert')), findsOneWidget);
      expect(find.byKey(const Key('finding-neighbours')), findsOneWidget);
      expect(find.byKey(const Key('finding-battery')), findsOneWidget);
      expect(find.text('Suggestions are never applied for you.'), findsOneWidget);
      expect(rig.rep.received.where((c) => c.startsWith('set ')), isEmpty);
    });

    adminTest('advert buttons confirm first and say what the airtime cost is', (tester) async {
      final rig = await openAdmin(tester);
      await tester.ensureVisible(find.byKey(const Key('advert-flood')));
      await tester.tap(find.byKey(const Key('advert-flood')));
      await frames(tester);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('0.35 s each')), findsOneWidget);
      expect(rig.rep.adverts, isEmpty);
      await tester.tap(find.byKey(const Key('advert-confirm')));
      await pumpUntil(tester, () => rig.rep.adverts.isNotEmpty);
      expect(rig.rep.adverts, ['flood']);
    });

    adminTest('"Using airtime" is shown while a request is in flight and gone after', (tester) async {
      final rig = await openAdmin(tester);
      expect(rig.controller.usingAirtime, isFalse);
      double width() => tester.getSize(find.byKey(const Key('airtime-chip'))).width;
      expect(width(), 0, reason: 'idle: no room taken');
      rig.rep.inRange = false; // nobody answers: the request stays in flight until its timeout
      late Future<Object?> pending;
      await tester.runAsync(() async {
        pending = rig.controller.session.readStatus().then<Object?>((_) => null, onError: (Object e) => e);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.controller.usingAirtime, isTrue);
      expect(width(), greaterThan(20));
      final err = await tester.runAsync(() => pending);
      expect(err, isA<AdminException>());
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.controller.usingAirtime, isFalse);
      expect(width(), 0);
    });
  });

  group('settings editor', () {
    Future<void> openSetting(WidgetTester tester, String key) async {
      await tapTab(tester, 'settings');
      await pumpUntilFound(tester, find.byKey(Key('setting-$key')));
      await pumpUntil(tester, () => find.byKey(const Key('settings-progress')).evaluate().isEmpty);
      await tester.ensureVisible(find.byKey(Key('setting-$key')));
      await tester.tap(find.byKey(Key('setting-$key')));
      await frames(tester);
    }

    adminTest('rename: edit -> review (current -> new, consequence) -> apply -> Verified -> Undo puts it back', (tester) async {
      final rig = await openAdmin(tester);
      await openSetting(tester, 'name');
      await tester.enterText(find.byKey(const Key('editor-text')), 'Hilltop 2');
      await tester.pump();
      expect(find.byKey(const Key('editor-bytes')), findsOneWidget);
      await tester.tap(find.byKey(const Key('editor-review')));
      await pumpUntilFound(tester, find.byKey(const Key('review-change')));
      expect(find.text('INNO-OB-2'), findsWidgets);
      expect(find.byKey(const Key('review-new')), findsOneWidget);
      expect(find.textContaining('Renames the repeater from "INNO-OB-2" to "Hilltop 2"'), findsOneWidget);
      expect(find.byKey(const Key('review-effect')), findsOneWidget);
      expect(rig.rep.name, 'INNO-OB-2', reason: 'review sends nothing');
      await tester.tap(find.byKey(const Key('review-apply')));
      await pumpUntilFound(tester, find.byKey(const Key('result-verified')));
      expect(rig.rep.name, 'Hilltop 2');
      await tester.tap(find.byKey(const Key('result-undo')));
      await pumpUntilFound(tester, find.byKey(const Key('review-apply')));
      expect(find.text('Hilltop 2'), findsWidgets);
      await tester.tap(find.byKey(const Key('review-apply')));
      await pumpUntilFound(tester, find.byKey(const Key('result-verified')));
      expect(rig.rep.name, 'INNO-OB-2');
    });

    adminTest('invalid input is refused in the editor and nothing is sent', (tester) async {
      final rig = await openAdmin(tester);
      await openSetting(tester, 'name');
      await tester.enterText(find.byKey(const Key('editor-text')), 'Bad:Name');
      await tester.tap(find.byKey(const Key('editor-review')));
      await pumpUntilFound(tester, find.byKey(const Key('editor-error')));
      expect(find.textContaining('not allowed'), findsOneWidget);
      expect(rig.rep.received.where((c) => c.startsWith('set')), isEmpty);
    });

    adminTest('a lost write reply: Verified from the read-back, and the screen says the write was sent once', (tester) async {
      final rig = await openAdmin(tester);
      await openSetting(tester, 'tx');
      await tester.enterText(find.byKey(const Key('editor-text')), '20');
      await tester.tap(find.byKey(const Key('editor-review')));
      await pumpUntilFound(tester, find.byKey(const Key('review-apply')));
      rig.rep.dropOncePrefix = 'set tx';
      await tester.tap(find.byKey(const Key('review-apply')));
      await pumpUntilFound(tester, find.byKey(const Key('result-verified')));
      expect(rig.rep.received.where((c) => c.startsWith('set tx')).length, 1);
    });

    adminTest('cannot read it back: "Could not verify" with a Check again button; never left blank', (tester) async {
      final rig = await openAdmin(tester);
      await openSetting(tester, 'tx');
      await tester.enterText(find.byKey(const Key('editor-text')), '20');
      await tester.tap(find.byKey(const Key('editor-review')));
      await pumpUntilFound(tester, find.byKey(const Key('review-apply')));
      rig.rep.dropAllReplies = true;
      await tester.tap(find.byKey(const Key('review-apply')));
      await pumpUntilFound(tester, find.byKey(const Key('result-unverified')), rounds: 400);
      expect(find.byKey(const Key('result-recheck')), findsOneWidget);
      rig.rep.dropAllReplies = false;
      await tester.tap(find.byKey(const Key('result-recheck')));
      await pumpUntilFound(tester, find.byKey(const Key('result-verified')));
    });

    adminTest('the write never arrived: "Not applied", offers Try again, nothing resent', (tester) async {
      final rig = await openAdmin(tester);
      await openSetting(tester, 'tx');
      await tester.enterText(find.byKey(const Key('editor-text')), '20');
      await tester.tap(find.byKey(const Key('editor-review')));
      await pumpUntilFound(tester, find.byKey(const Key('review-apply')));
      rig.rep.ignoreOncePrefix = 'set tx';
      await tester.tap(find.byKey(const Key('review-apply')));
      await pumpUntilFound(tester, find.byKey(const Key('result-notApplied')), rounds: 300);
      expect(find.byKey(const Key('result-retry')), findsOneWidget);
      expect(rig.rep.received.where((c) => c.startsWith('set tx')), isEmpty);
    });

    adminTest('radio parameters: loud warning, region preset compare and fill-in, typed RADIO, reboot note after', (tester) async {
      final rig = await openAdmin(tester, setup: (r) => r.prefs['radio'] = '869.618,250,8,5');
      await tapTab(tester, 'settings');
      await pumpUntilFound(tester, find.byKey(const Key('radio-compare')));
      expect(find.textContaining('Differs from the region preset'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('setting-radio')));
      await tester.tap(find.byKey(const Key('setting-radio')));
      await frames(tester);
      expect(find.byKey(const Key('radio-warning')), findsOneWidget);
      expect(find.textContaining('take this repeater off the air'), findsWidgets);
      expect(find.byKey(const Key('radio-preset-line')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('radio-use-preset')));
      await tester.tap(find.byKey(const Key('radio-use-preset')));
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const Key('radio-field-0'))).controller!.text, '910.525');
      await tester.ensureVisible(find.byKey(const Key('editor-review')));
      await tester.tap(find.byKey(const Key('editor-review')));
      await pumpUntilFound(tester, find.byKey(const Key('review-typed')));
      expect(find.text('To go on, type RADIO'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('review-apply'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('review-typed')), 'RAD');
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(const Key('review-apply'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('review-typed')), 'RADIO');
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('review-apply')));
      await tester.tap(find.byKey(const Key('review-apply')));
      await pumpUntilFound(tester, find.byKey(const Key('result-verified')));
      expect(find.byKey(const Key('result-reboot')), findsOneWidget);
      expect(rig.rep.rebootCount, 0);
      await tester.tap(find.byKey(const Key('result-done')));
      await frames(tester);
      expect(find.byKey(const Key('reboot-banner')), findsOneWidget);
    });

    adminTest('repeat OFF needs the typed words REPEAT OFF', (tester) async {
      final rig = await openAdmin(tester);
      await openSetting(tester, 'repeat');
      await tester.tap(find.byKey(const Key('editor-toggle')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('editor-review')));
      await pumpUntilFound(tester, find.byKey(const Key('review-typed')));
      expect(find.textContaining('STOP repeating'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('review-apply'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('review-typed')), 'REPEAT OFF');
      await tester.pump();
      await tester.tap(find.byKey(const Key('review-apply')));
      await pumpUntilFound(tester, find.byKey(const Key('result-verified')));
      expect(rig.rep.prefs['repeat'], 'off');
    });

    adminTest('observer uplink is read only: slots shown, credentials never', (tester) async {
      final rig = await openAdmin(tester, setup: (r) {
        r.isObserver = true;
        r.firmware = 'v1.17.1.5-observer-7403067 (Build: 4 Oct 2026)';
      });
      await tapTab(tester, 'settings');
      await pumpUntilFound(tester, find.byKey(const Key('load-uplink')));
      await tester.ensureVisible(find.byKey(const Key('load-uplink')));
      await tester.tap(find.byKey(const Key('load-uplink')));
      await pumpUntilFound(tester, find.text('Slot 5: custom'), rounds: 400);
      expect(find.text('Slot 5: custom'), findsOneWidget);
      expect(rig.rep.received.any((c) => c.contains('password') || c.contains('token')), isFalse);
      expect(find.textContaining('secret'), findsNothing);
    });
  });

  group('neighbours', () {
    adminTest('table rows with SNR, last heard and names resolved from contacts', (tester) async {
      await openAdmin(tester);
      await tapTab(tester, 'neighbours');
      await pumpUntilFound(tester, find.byKey(const Key('neighbour-1bcee248')));
      expect(find.text('Hilltop North'), findsOneWidget);
      expect(find.text('Water Tower'), findsOneWidget);
      expect(find.text('Unknown repeater'), findsOneWidget);
      expect(find.text('7.8 dB'), findsOneWidget);
      expect(find.text('Heard 20 h ago'), findsOneWidget);
    });

    adminTest('empty list has an honest explanation', (tester) async {
      await openAdmin(tester, setup: (r) => r.neighbours.clear());
      await tapTab(tester, 'neighbours');
      await pumpUntilFound(tester, find.byKey(const Key('neighbours-empty')));
      expect(find.textContaining('does not hear any other repeater'), findsOneWidget);
    });

    adminTest('Look for neighbours confirms first', (tester) async {
      final rig = await openAdmin(tester);
      await tapTab(tester, 'neighbours');
      await pumpUntilFound(tester, find.byKey(const Key('discover-neighbours')));
      await tester.tap(find.byKey(const Key('discover-neighbours')));
      await frames(tester);
      expect(rig.rep.received.where((c) => c.startsWith('discover')), isEmpty);
      await tester.tap(find.byKey(const Key('discover-confirm')));
      await pumpUntil(tester, () => rig.rep.received.any((c) => c == 'discover.neighbors'));
      expect(rig.rep.received.where((c) => c == 'discover.neighbors').length, 1);
    });
  });

  group('regions', () {
    adminTest('tree, default, flood switch with confirm and read-back; deny-all needs DENY ALL', (tester) async {
      final rig = await openAdmin(tester);
      await tapTab(tester, 'regions');
      await pumpUntilFound(tester, find.byKey(const Key('region-cmh')));
      expect(find.byKey(const Key('v-default-region')), findsOneWidget);
      expect(find.text('cmh'), findsWidgets);
      await tester.tap(find.byKey(const Key('flood-cmh')));
      await frames(tester);
      expect(rig.rep.regions.firstWhere((r) => r.name == 'cmh').floodAllowed, isTrue, reason: 'asked first');
      await tester.tap(find.byKey(const Key('flood-confirm')));
      await pumpUntil(tester, () => rig.rep.received.contains('region get cmh'));
      expect(rig.rep.received, containsAllInOrder(['region denyf cmh', 'region save']));
      await pumpUntil(tester, () => !rig.controller.loadingRegions && !rig.controller.usingAirtime);
      await frames(tester);
      await tester.tap(find.byKey(const Key('flood-*')));
      await frames(tester);
      expect(find.text('Type DENY ALL to go on'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('confirm-ok'))).onPressed, isNull);
    });
  });

  group('access', () {
    adminTest('list with roles, the warning that a password change does not remove admins, no remove for your own radio', (tester) async {
      final rig = await openAdmin(tester, setup: (r) => r.acl['a9b1acd3a408${'11' * 26}'] = 3);
      await tapTab(tester, 'access');
      await pumpUntilFound(tester, find.byKey(const Key('acl-a9b1acd3a408')));
      expect(find.byKey(const Key('acl-warning')), findsOneWidget);
      expect(find.textContaining('does not remove them'), findsOneWidget);
      final mine = rig.radio.keyHex.substring(0, 12);
      expect(find.byKey(Key('acl-$mine')), findsOneWidget);
      expect(find.text('Your radio'), findsOneWidget);
      expect(find.byKey(Key('remove-$mine')), findsNothing);
      expect(find.byKey(const Key('remove-a9b1acd3a408')), findsOneWidget);
      await tester.tap(find.byKey(const Key('remove-a9b1acd3a408')));
      await frames(tester);
      expect(rig.rep.acl.length, 2);
      await tester.tap(find.byKey(const Key('remove-confirm')));
      await pumpUntil(tester, () => rig.rep.acl.length == 1);
      expect(rig.rep.received.where((c) => c.startsWith('setperm')), ['setperm a9b1acd3a408 0']);
    });

    adminTest('guest password: masked entry twice, differing entries refused, set, verified, never displayed', (tester) async {
      final rig = await openAdmin(tester);
      await tapTab(tester, 'access');
      await pumpUntilFound(tester, find.byKey(const Key('set-guest-password')));
      await tester.ensureVisible(find.byKey(const Key('set-guest-password')));
      await tester.tap(find.byKey(const Key('set-guest-password')));
      await frames(tester);
      expect(tester.widget<TextField>(find.byKey(const Key('editor-secret'))).obscureText, isTrue);
      await tester.enterText(find.byKey(const Key('editor-secret')), 'hunter22');
      await tester.enterText(find.byKey(const Key('editor-secret-repeat')), 'hunter23');
      await tester.tap(find.byKey(const Key('editor-review')));
      await tester.pump();
      expect(find.text('The two entries are different.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('editor-secret-repeat')), 'hunter22');
      await tester.tap(find.byKey(const Key('editor-review')));
      await pumpUntilFound(tester, find.byKey(const Key('review-apply')));
      expect(find.textContaining('hunter22'), findsNothing);
      await tester.tap(find.byKey(const Key('review-apply')));
      await pumpUntilFound(tester, find.byKey(const Key('result-verified')));
      expect(rig.rep.guestPassword, 'hunter22');
      expect(find.textContaining('hunter22'), findsNothing);
      expect(find.byKey(const Key('result-undo')), findsNothing, reason: 'the old password was never shown, so it cannot be put back');
    });

    adminTest('admin password change needs CHANGE PASSWORD typed', (tester) async {
      final rig = await openAdmin(tester);
      await tapTab(tester, 'access');
      await pumpUntilFound(tester, find.byKey(const Key('set-admin-password')));
      await tester.ensureVisible(find.byKey(const Key('set-admin-password')));
      await tester.tap(find.byKey(const Key('set-admin-password')));
      await frames(tester);
      await tester.enterText(find.byKey(const Key('editor-secret')), 'newpass99');
      await tester.enterText(find.byKey(const Key('editor-secret-repeat')), 'newpass99');
      await tester.tap(find.byKey(const Key('editor-review')));
      await pumpUntilFound(tester, find.byKey(const Key('review-typed')));
      expect(tester.widget<Text>(find.byKey(const Key('review-consequence'))).data, contains('only way back is a cable'));
      expect(tester.widget<FilledButton>(find.byKey(const Key('review-apply'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('review-typed')), 'CHANGE PASSWORD');
      await tester.pump();
      await tester.tap(find.byKey(const Key('review-apply')));
      await pumpUntilFound(tester, find.byKey(const Key('result-verified')));
      expect(rig.rep.adminPassword, 'newpass99');
      expect(find.textContaining('newpass99'), findsNothing);
      expect(find.textContaining('Test it with a fresh login'), findsOneWidget);
    });
  });

  group('console', () {
    adminTest('a read runs, a dangerous or unknown command is refused with the reason and never sent, a write opens the review', (tester) async {
      final rig = await openAdmin(tester);
      await tapTab(tester, 'console');
      await tester.enterText(find.byKey(const Key('console-input')), 'get radio');
      await tester.tap(find.byKey(const Key('console-send')));
      await pumpUntilFound(tester, find.textContaining('910.5250244'));
      expect(find.textContaining('910.5250244'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('console-input')), 'rebootnow');
      await tester.tap(find.byKey(const Key('console-send')));
      await pumpUntilFound(tester, find.textContaining('Not sent'));
      expect(find.textContaining('would reboot it'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('console-input')), 'get guest.password');
      await tester.tap(find.byKey(const Key('console-send')));
      await pumpUntilFound(tester, find.textContaining('never reads or shows passwords'));
      expect(rig.rep.rebootCount, 0);
      expect(rig.rep.received.last, 'get radio');
      expect(rig.rep.received.where((c) => c.startsWith('reboot') || c.contains('password')), isEmpty);
      await tester.enterText(find.byKey(const Key('console-input')), 'set name From Console');
      await tester.tap(find.byKey(const Key('console-send')));
      await pumpUntilFound(tester, find.byKey(const Key('review-apply')));
      expect(rig.rep.name, 'INNO-OB-2');
      await tester.tap(find.byKey(const Key('review-back')));
      await frames(tester);
      expect(rig.rep.name, 'INNO-OB-2');
    });

    adminTest('typed passwords are masked in the history', (tester) async {
      await openAdmin(tester);
      await tapTab(tester, 'console');
      await tester.enterText(find.byKey(const Key('console-input')), 'password hunter22');
      await tester.tap(find.byKey(const Key('console-send')));
      await pumpUntilFound(tester, find.textContaining('Not sent'));
      expect(find.textContaining('hunter22'), findsNothing);
      expect(find.text('> password ••••'), findsOneWidget);
    });
  });

  group('guest login', () {
    adminTest('status works; settings, access and console say they need the admin password', (tester) async {
      await openAdmin(tester, password: 'guest');
      expect(find.byKey(const Key('guest-note')), findsOneWidget);
      expect(find.text('3.86 V'), findsOneWidget);
      expect(find.byKey(const Key('card-adverts')), findsNothing);
      await tapTab(tester, 'settings');
      expect(find.byKey(const Key('settings-guest')), findsOneWidget);
      await tapTab(tester, 'access');
      expect(find.byKey(const Key('access-guest')), findsOneWidget);
      await tapTab(tester, 'console');
      expect(find.byKey(const Key('console-guest')), findsOneWidget);
    });
  });

  group('layout, accessibility', () {
    for (final cfg in [
      (name: 'iPhone', w: 390.0, h: 6000.0, dark: false, scale: 1.0),
      (name: 'iPhone dark', w: 390.0, h: 6000.0, dark: true, scale: 1.0),
      (name: 'iPad', w: 820.0, h: 6000.0, dark: false, scale: 1.0),
      (name: 'iPhone text 2.5x', w: 390.0, h: 6000.0, dark: false, scale: 2.5),
      (name: 'iPad dark text 2.5x', w: 820.0, h: 6000.0, dark: true, scale: 2.5),
    ]) {
      adminTest('every tab renders without overflow: ${cfg.name}', (tester) async {
        final rig = await openAdmin(tester, w: cfg.w, h: cfg.h, dark: cfg.dark, textScale: cfg.scale, setup: (r) => r.acl['a9b1acd3a408${'11' * 26}'] = 3);
        for (final tab in ['overview', 'settings', 'neighbours', 'regions', 'access', 'console']) {
          await tapTab(tester, tab);
          await settle(tester, ms: 80);
          await pumpUntil(tester, () => !rig.controller.loadingSettings && !rig.controller.loadingNeighbours && !rig.controller.loadingRegions && !rig.controller.loadingAcl, rounds: 400);
          await tester.pump();
          expect(tester.takeException(), isNull, reason: '$tab at ${cfg.name}');
        }
      });
    }

    adminTest('tap targets are at least 48 x 48 and the key actions are labelled for VoiceOver', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = await openAdmin(tester, setup: (r) => r.clockOffsetSecs = -400);
      for (final k in ['run-health', 'advert-flood', 'advert-local', 'sync-clock', 'overview-refresh']) {
        await tester.ensureVisible(find.byKey(Key(k)));
        final s = tester.getSize(find.byKey(Key(k)));
        expect(s.width, greaterThanOrEqualTo(48), reason: k);
        expect(s.height, greaterThanOrEqualTo(48), reason: k);
      }
      expect(find.bySemanticsLabel(RegExp('Battery: 3.86 V')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Radio idle|Using airtime')), findsOneWidget);
      await tapTab(tester, 'settings');
      await pumpUntilFound(tester, find.byKey(const Key('setting-name')));
      await pumpUntil(tester, () => !rig.controller.loadingSettings);
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp('Name: INNO-OB-2')), findsOneWidget);
      final node = tester.getSemantics(find.byKey(const Key('setting-name')));
      expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
      handle.dispose();
    });
  });
}
