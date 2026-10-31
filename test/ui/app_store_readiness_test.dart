// App Store readiness: the privacy policy is reachable in the app, account / data deletion is in the app (guideline
// 5.1.1(v)), the Simulator never shares anything, and the iOS project files match what the app really does.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/account_delete_hook.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/server_url.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/ui/about_screen.dart';
import 'package:meshsonar/ui/settings/delete_my_data.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

final t0 = DateTime.utc(2026, 10, 16, 18);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ms_store_ui_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
  const canDelete = SiteConfig(region: region, capabilities: {'driverDelete'});

  Future<DiskHarness> open(WidgetTester tester, {bool key = true, SiteConfig? caps, bool autoKey = false}) async {
    useTallScreen(tester);
    final h = DiskHarness(tmp);
    if (key) h.approveKey();
    h.tele.siteConfigResult = caps;
    h.settings.autoKeyOn = autoKey;
    await h.pumpDiskApp(tester);
    await openSettingsTab(tester);
    return h;
  }

  group('privacy policy in the app', () {
    test('the policy URL is the live apex page', () {
      expect(privacyPolicyUrl, 'https://meshsonar.com/privacy');
    });

    testWidgets('Settings > Privacy & data sharing opens it', (tester) async {
      final h = await open(tester);
      await showSetting(tester, 'privacy-policy');
      await tester.tap(find.byKey(const Key('privacy-policy')));
      await tester.pumpAndSettle();
      expect(h.openedUrls.map((u) => u.toString()), contains(privacyPolicyUrl));
    });

    testWidgets('About opens it', (tester) async {
      final h = DiskHarness(tmp);
      useTallScreen(tester);
      await h.pumpDiskApp(tester);
      await openSettingsTab(tester);
      await showSetting(tester, 'about');
      await tester.tap(find.byKey(const Key('about')));
      await tester.pumpAndSettle();
      expect(find.byType(AboutScreen), findsOneWidget);
      await tester.tap(find.byKey(const Key('about-privacy-policy')));
      await tester.pumpAndSettle();
      expect(h.openedUrls.map((u) => u.toString()), contains(privacyPolicyUrl));
    });

    testWidgets('the driver-key request form (where data is first given) links to it', (tester) async {
      final h = await open(tester, key: false);
      await showSetting(tester, 'key-privacy-policy');
      await tester.tap(find.byKey(const Key('key-privacy-policy')));
      await tester.pumpAndSettle();
      expect(h.openedUrls.map((u) => u.toString()), contains(privacyPolicyUrl));
    });
  });

  group('delete my data and account', () {
    Future<void> openScreen(WidgetTester tester) async {
      await showSetting(tester, 'delete-my-data');
      await tester.tap(find.byKey(const Key('delete-my-data')));
      await tester.pumpAndSettle();
    }

    Future<void> see(WidgetTester tester, String key) => tester.scrollUntilVisible(find.byKey(Key(key)), 200,
        scrollable: find.descendant(of: find.byKey(const Key('delete-my-data-screen')), matching: find.byType(Scrollable)).first);

    testWidgets('"Delete my account" opens the website page that deletes it', (tester) async {
      final h = await open(tester);
      await openScreen(tester);
      await see(tester, 'delete-account-website');
      expect(find.text(deleteAccountText), findsOneWidget);
      await tester.tap(find.byKey(const Key('delete-account-website')));
      await tester.pumpAndSettle();
      expect(h.openedUrls.single.path, '/me/privacy');
    });

    group('in-app account deletion (server advertises driverDelete)', () {
      Future<DiskHarness> openIn(WidgetTester tester, {bool key = true, bool drives = false}) async {
        final h = await open(tester, key: key, caps: canDelete, autoKey: key);
        if (drives) {
          for (final id in ['d1', 'd2']) {
            h.store.seed(DriveSession(id: id, startedAt: t0, endedAt: t0.add(const Duration(minutes: 5))),
                [DrivePing(id: '$id-p1', ts: t0, lat: 40.1, lon: -82.9)]);
          }
          await h.state.refreshSessions();
        }
        await openScreen(tester);
        await settleIo(tester, until: () => h.state.serverCanDeleteAccount);
        return h;
      }

      Future<void> confirmAccountDelete(WidgetTester tester) async {
        await tester.tap(find.byKey(const Key('delete-account-dialog-confirm')));
        await tester.pumpAndSettle();
        // the key is forgotten, then the caches and (optionally) the drives go: real file IO outside the fake clock
        await settleIo(tester, until: () => find.byKey(const Key('delete-account-result')).evaluate().isNotEmpty);
      }

      testWidgets('the button deletes in the app: confirm dialog in destructive words, then the key is gone and not re-created', (tester) async {
        final h = await openIn(tester);
        await see(tester, 'delete-account-in-app');
        expect(find.text(deleteAccountInAppText), findsOneWidget);
        await see(tester, 'delete-account-website');
        expect(find.byKey(const Key('delete-account-website')), findsOneWidget, reason: 'only the secondary website link');
        await see(tester, 'delete-account-in-app');
        await tester.tap(find.byKey(const Key('delete-account-in-app')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('delete-account-dialog')), findsOneWidget);
        expect(find.textContaining('permanently deletes your driver key and all your uploaded drives and shared data'), findsOneWidget);
        expect(find.textContaining('cannot be undone'), findsWidgets);
        expect(h.tele.deletedDrivers, isEmpty, reason: 'nothing is sent before the person confirms');
        await confirmAccountDelete(tester);
        expect(h.tele.deletedDrivers, ['secretkey-abcdef-1234']);
        expect(h.state.hasKey, isFalse);
        expect(h.state.settings.autoKey, isFalse);
        await see(tester, 'delete-account-result');
        expect(find.textContaining('The server deleted your driver key'), findsOneWidget);
        expect(find.textContaining('Create my key'), findsWidgets);
        expect(find.byKey(const Key('delete-account-in-app')), findsNothing, reason: 'there is no account left to delete');
        expect(await h.state.ensureKey(), isFalse);
        expect(h.tele.requestCalls, 0);
      });

      testWidgets('cancel deletes nothing', (tester) async {
        final h = await openIn(tester);
        await see(tester, 'delete-account-in-app');
        await tester.tap(find.byKey(const Key('delete-account-in-app')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('delete-account-dialog-cancel')));
        await tester.pumpAndSettle();
        expect(h.tele.deletedDrivers, isEmpty);
        expect(h.state.hasKey, isTrue);
      });

      testWidgets('local drives stay by default', (tester) async {
        final h = await openIn(tester, drives: true);
        await see(tester, 'delete-account-in-app');
        await tester.tap(find.byKey(const Key('delete-account-in-app')));
        await tester.pumpAndSettle();
        expect(find.text('Also delete the 2 drives saved on this phone'), findsOneWidget);
        await confirmAccountDelete(tester);
        expect(h.state.hasKey, isFalse);
        expect(h.store.sessionsById.keys, unorderedEquals(['d1', 'd2']));
      });

      testWidgets('the checkbox deletes the drives on this phone too', (tester) async {
        final h = await openIn(tester, drives: true);
        await see(tester, 'delete-account-in-app');
        await tester.tap(find.byKey(const Key('delete-account-in-app')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('delete-account-local-drives')));
        await tester.pumpAndSettle();
        await confirmAccountDelete(tester);
        expect(h.state.hasKey, isFalse);
        expect(h.store.sessionsById, isEmpty);
      });

      testWidgets('offline: a plain message, the key and everything stay, nothing is queued; the retry then works', (tester) async {
        final h = await openIn(tester);
        h.tele.driverDeleteError = const CmatException('network error: offline');
        await see(tester, 'delete-account-in-app');
        await tester.tap(find.byKey(const Key('delete-account-in-app')));
        await tester.pumpAndSettle();
        await confirmAccountDelete(tester);
        await see(tester, 'delete-account-result');
        expect(find.text(accountDeleteOfflineText), findsOneWidget);
        expect(find.text('Not finished'), findsWidgets);
        expect(h.state.hasKey, isTrue);
        expect(h.state.settings.autoKey, isTrue);
        h.tele.driverDeleteError = null;
        await see(tester, 'delete-account-in-app');
        await tester.tap(find.byKey(const Key('delete-account-in-app')));
        await tester.pumpAndSettle();
        await confirmAccountDelete(tester);
        expect(h.state.hasKey, isFalse);
        expect(h.tele.deletedDrivers, hasLength(1));
      });

      testWidgets('a server error keeps everything and shows it; the button is usable again', (tester) async {
        final h = await openIn(tester);
        h.tele.driverDeleteError = const CmatException('database down', status: 503);
        await see(tester, 'delete-account-in-app');
        await tester.tap(find.byKey(const Key('delete-account-in-app')));
        await tester.pumpAndSettle();
        await confirmAccountDelete(tester);
        await see(tester, 'delete-account-result');
        expect(find.textContaining('Nothing was deleted'), findsOneWidget);
        expect(h.state.hasKey, isTrue);
        final btn = tester.widget<FilledButton>(find.byKey(const Key('delete-account-in-app')));
        expect(btn.onPressed, isNotNull);
      });

      testWidgets('no driver key: says there is no account here and offers no delete button', (tester) async {
        await openIn(tester, key: false);
        await see(tester, 'delete-account-nokey');
        expect(find.byKey(const Key('delete-account-in-app')), findsNothing);
      });
    });

    testWidgets('a server without the capability keeps the website hand-off (no in-app delete button)', (tester) async {
      final h = await open(tester, caps: const SiteConfig(region: region, capabilities: {'driveContextErase'}));
      await openScreen(tester);
      await settleIo(tester, until: () => h.state.uploadSiteConfig != null);
      await see(tester, 'delete-account-website');
      expect(find.byKey(const Key('delete-account-in-app')), findsNothing);
      expect(h.state.serverCanDeleteAccount, isFalse);
    });

    testWidgets('delete all drives asks first, then removes every drive on the phone', (tester) async {
      final h = await open(tester);
      for (final id in ['d1', 'd2']) {
        h.store.seed(DriveSession(id: id, startedAt: t0, endedAt: t0.add(const Duration(minutes: 5))),
            [DrivePing(id: '$id-p1', ts: t0, lat: 40.1, lon: -82.9)]);
      }
      await h.state.refreshSessions();
      await openScreen(tester);
      await see(tester, 'delete-all-drives');
      await tester.tap(find.byKey(const Key('delete-all-drives')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-drives-dialog')), findsOneWidget);
      expect(find.textContaining('Deletes 2 drives'), findsOneWidget);
      await tester.tap(find.byKey(const Key('delete-drives-dialog-confirm')));
      await tester.pumpAndSettle();
      expect(h.store.sessionsById, isEmpty);
      expect(find.byKey(const Key('delete-drives-result')), findsOneWidget);
    });

    testWidgets('remove the driver key from this phone', (tester) async {
      final h = await open(tester);
      expect(h.state.hasKey, isTrue);
      await openScreen(tester);
      await see(tester, 'delete-remove-key');
      await tester.tap(find.byKey(const Key('delete-remove-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-key-dialog-confirm')));
      await tester.pumpAndSettle();
      expect(h.state.hasKey, isFalse);
      expect(find.byKey(const Key('delete-remove-key')), findsNothing);
    });

    testWidgets('large text and small windows: the in-app delete section lays out without overflow', (tester) async {
      final h = await open(tester, caps: canDelete);
      await openScreen(tester);
      await settleIo(tester, until: () => h.state.serverCanDeleteAccount);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.reset);
      for (final size in const [Size(1024, 1366), Size(375, 667)]) {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = size * 2;
        await tester.pumpAndSettle();
        await see(tester, 'delete-account-in-app');
        expect(tester.takeException(), isNull, reason: '$size');
        await tester.ensureVisible(find.byKey(const Key('delete-account-in-app')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('delete-account-in-app')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('delete-account-dialog')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'dialog at $size');
        await tester.tap(find.byKey(const Key('delete-account-dialog-cancel')));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('large text, portrait and landscape iPad windows: the screen lays out without overflow', (tester) async {
      await open(tester);
      await openScreen(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.reset);
      for (final size in const [Size(1024, 1366), Size(1366, 1024), Size(507, 1024), Size(375, 667)]) {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = size * 2;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size');
        await see(tester, 'delete-account-website');
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });
  });

  group('Simulator', () {
    test('a drive with the simulator firmware is flagged; a real radio is not', () {
      expect(const Companion(firmware: 'v1.18.0-sim').isSimulated, isTrue);
      expect(const Companion(firmware: 'v1.9.0').isSimulated, isFalse);
      expect(const Companion().isSimulated, isFalse);
      expect(Companion(firmware: SimulatedTransport().firmwareVersion).isSimulated, isTrue, reason: 'the real simulator must be flagged');
    });
  });

  group('iOS project files', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    test('export compliance is answered (HTTPS and BLE only: exempt)', () {
      expect(plist, contains('<key>ITSAppUsesNonExemptEncryption</key>\n\t<false/>'));
    });

    test('required device capabilities match what the app needs', () {
      final block = RegExp(r'UIRequiredDeviceCapabilities</key>\s*<array>(.*?)</array>', dotAll: true).firstMatch(plist)!.group(1)!;
      expect(block, contains('bluetooth-le'));
      expect(block, contains('location-services'));
    });

    test('no unused permission strings: no peripheral role, only the prompts the app triggers', () {
      expect(plist, isNot(contains('NSBluetoothPeripheralUsageDescription')));
      for (final k in ['NSBluetoothAlwaysUsageDescription', 'NSLocationWhenInUseUsageDescription', 'NSLocationAlwaysAndWhenInUseUsageDescription', 'NSMotionUsageDescription']) {
        expect(plist, contains(k));
      }
      for (final k in ['NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSContactsUsageDescription', 'NSPhotoLibraryUsageDescription', 'NSUserTrackingUsageDescription', 'NSLocalNetworkUsageDescription']) {
        expect(plist, isNot(contains(k)), reason: k);
      }
    });

    test('the Always string says background use is for recording a drive, not "never when not driving" nor region tracking', () {
      final m = RegExp(r'NSLocationAlwaysAndWhenInUseUsageDescription</key>\s*<string>(.*?)</string>', dotAll: true).firstMatch(plist)!.group(1)!;
      expect(m, contains('record a drive'));
      expect(m, contains('not used in the background when you are not recording'));
      expect(m, isNot(contains('which MeshSonar region')));
    });

    test('background modes are exactly location and bluetooth-central', () {
      final block = RegExp(r'UIBackgroundModes</key>\s*<array>(.*?)</array>', dotAll: true).firstMatch(plist)!.group(1)!;
      expect(RegExp(r'<string>(.*?)</string>').allMatches(block).map((m) => m.group(1)).toSet(), {'location', 'bluetooth-central'});
    });

    test('privacy manifest: no tracking, no tracking domains', () {
      final m = File('ios/Runner/PrivacyInfo.xcprivacy').readAsStringSync();
      expect(m, contains('<key>NSPrivacyTracking</key>\n\t<false/>'));
      expect(m, contains('<key>NSPrivacyTrackingDomains</key>\n\t<array/>'));
    });

    test('the 1024 marketing icon is an opaque RGB PNG, and every icon file in Contents.json exists', () {
      final dir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
      final png = File('$dir/Icon-App-1024x1024@1x.png').readAsBytesSync();
      expect(png.sublist(1, 4), [0x50, 0x4e, 0x47]);
      final colorType = png[25]; // IHDR colour type: 2 = RGB, 6 = RGBA
      expect(colorType, 2, reason: 'App Store rejects an icon with an alpha channel');
      final contents = File('$dir/Contents.json').readAsStringSync();
      for (final m in RegExp(r'"filename"\s*:\s*"([^"]+)"').allMatches(contents)) {
        expect(File('$dir/${m.group(1)}').existsSync(), isTrue, reason: m.group(1));
      }
    });

    test('the Bluetooth package is the BSD-licensed flutter_reactive_ble, not the paid-for-profit flutter_blue_plus', () {
      expect(thirdPartyNotices.any((n) => n.name == 'flutter_blue_plus'), isFalse);
      final n = thirdPartyNotices.firstWhere((n) => n.name == 'flutter_reactive_ble');
      expect(n.license, contains('BSD-3-Clause'));
    });
  });
}
