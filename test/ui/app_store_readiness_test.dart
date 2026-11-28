// App Store readiness: the privacy policy is reachable in the app, account / data deletion is in the app (guideline
// 5.1.1(v)), the Simulator never shares anything, and the iOS project files match what the app really does.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  Future<DiskHarness> open(WidgetTester tester, {bool key = true}) async {
    useTallScreen(tester);
    final h = DiskHarness(tmp);
    if (key) h.approveKey();
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
      // Build 76: the form is on its own page behind "Create my key".
      await showSetting(tester, 'key-create');
      await tester.tap(find.byKey(const Key('key-create')));
      await tester.pumpAndSettle();
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

    Future<void> see(WidgetTester tester, String key) async {
      await tester.scrollUntilVisible(find.byKey(Key(key)), 200,
          scrollable: find.descendant(of: find.byKey(const Key('delete-my-data-screen')), matching: find.byType(Scrollable)).first);
      // Mid-screen, clear of the tab bar the list scrolls under (where it lands depends on the length of the text above).
      await Scrollable.ensureVisible(tester.element(find.byKey(Key(key))), alignment: 0.5);
      await tester.pumpAndSettle();
    }

    testWidgets('"Delete my account" opens the website page that deletes it', (tester) async {
      final h = await open(tester);
      await openScreen(tester);
      await see(tester, 'delete-account-website');
      // Build 76: one line on the page, the full text one tap away.
      expect(find.text(deleteAccountShort), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('delete-account-details')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-account-details')));
      await tester.pumpAndSettle();
      expect(find.text(deleteAccountText), findsOneWidget);
      await see(tester, 'delete-account-website');
      await tester.tap(find.byKey(const Key('delete-account-website')));
      await tester.pumpAndSettle();
      expect(h.openedUrls.single.path, '/me/privacy');
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

    testWidgets('delete all drives with no drives on the phone: says so, no dialog with a red button', (tester) async {
      await open(tester);
      await openScreen(tester);
      await see(tester, 'delete-all-drives');
      await tester.tap(find.byKey(const Key('delete-all-drives')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-drives-dialog')), findsNothing);
      expect(tester.widget<Text>(find.byKey(const Key('delete-drives-result'))).data, 'There are no drives on this phone.');
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
      for (final k in ['NSBluetoothAlwaysUsageDescription', 'NSLocationWhenInUseUsageDescription', 'NSLocationAlwaysAndWhenInUseUsageDescription', 'NSMotionUsageDescription', 'NSCameraUsageDescription', 'NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription']) {
        expect(plist, contains(k));
      }
      for (final k in ['NSMicrophoneUsageDescription', 'NSContactsUsageDescription', 'NSUserTrackingUsageDescription']) {
        expect(plist, isNot(contains(k)), reason: k);
      }
    });

    test('MeshSonar radio over Wi-Fi (build 78): Local Network string, Bonjour type, plain HTTP to local addresses only', () {
      final m = RegExp(r'NSLocalNetworkUsageDescription</key>\s*<string>(.*?)</string>', dotAll: true).firstMatch(plist)!.group(1)!;
      expect(m, 'MeshSonar talks to your MeshSonar radio on your Wi-Fi.');
      final bonjour = RegExp(r'NSBonjourServices</key>\s*<array>(.*?)</array>', dotAll: true).firstMatch(plist)!.group(1)!;
      expect(bonjour.trim(), '<string>_meshsonar._tcp</string>');
      expect(plist, matches(RegExp(r'NSAppTransportSecurity</key>\s*<dict>\s*<key>NSAllowsLocalNetworking</key>\s*<true/>\s*</dict>')));
      expect(plist, isNot(contains('NSAllowsArbitraryLoads')));
    });

    test('the camera string names its two uses: a photo for a chat, and Scan QR code (nothing from a scan is recorded)', () {
      final m = RegExp(r'NSCameraUsageDescription</key>\s*<string>(.*?)</string>', dotAll: true).firstMatch(plist)!.group(1)!;
      expect(m, contains('Take a photo to share in a chat'));
      expect(m, contains('uploaded'), reason: 'photos leave the phone; the string must say so');
      expect(m, contains('Scan QR code'));
      expect(m, contains('nothing from a scan is recorded'));
    });

    test('the photo library strings are plain: pick a photo for a chat, save a photo from a chat', () {
      String v(String k) => RegExp('$k</key>\\s*<string>(.*?)</string>', dotAll: true).firstMatch(plist)!.group(1)!;
      expect(v('NSPhotoLibraryUsageDescription'), startsWith('Pick a photo to share in a chat.'));
      expect(v('NSPhotoLibraryUsageDescription'), contains('uploaded'), reason: 'photos leave the phone; the string must say so');
      expect(v('NSPhotoLibraryAddUsageDescription'), 'Save a photo from a chat to your Photos.');
    });

    test('the Always string says background use is for recording a drive, not "never when not driving" nor region tracking', () {
      final m = RegExp(r'NSLocationAlwaysAndWhenInUseUsageDescription</key>\s*<string>(.*?)</string>', dotAll: true).firstMatch(plist)!.group(1)!;
      expect(m, contains('record a drive'));
      expect(m, contains('not used in the background when you are not recording'));
      expect(m, isNot(contains('which MeshSonar region')));
    });

    test('universal links: the entitlement names meshsonar.com and every Runner build config points at it', () {
      final ent = File('ios/Runner/Runner.entitlements').readAsStringSync();
      expect(ent, contains('com.apple.developer.associated-domains'));
      expect(ent, contains('applinks:meshsonar.com'));
      // AZ-3.5: region subdomains (cmh.meshsonar.com/nodes/...) open the app too; the site serves the AASA file on every host.
      expect(ent, contains('applinks:*.meshsonar.com'));
      final pbx = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      expect('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'.allMatches(pbx).length, 3, reason: 'Debug, Release and Profile of Runner');
      expect(plist, contains('<key>FlutterDeepLinkingEnabled</key>\n\t<false/>'), reason: 'app_links, not Flutter, receives the links');
    });

    test('the Always string covers the always-on phone observer; Bluetooth and When-in-use strings match what the app does', () {
      String v(String k) => RegExp('$k</key>\\s*<string>(.*?)</string>', dotAll: true).firstMatch(plist)!.group(1)!;
      expect(v('NSLocationAlwaysAndWhenInUseUsageDescription'), contains('Share with MeshSonar'));
      expect(v('NSLocationAlwaysAndWhenInUseUsageDescription'), contains('5 km'));
      expect(v('NSBluetoothAlwaysUsageDescription'), allOf(contains('chat'), contains('background')));
      // Observer everywhere (0.38): App Review reads the Bluetooth string; it says the phone observes while connected.
      expect(v('NSBluetoothAlwaysUsageDescription'), allOf(contains('observer'), contains('public packets')));
      // Only what is verified is claimed: a locked-screen drive keeps recording; background delivery of incoming messages is not promised.
      expect(v('NSBluetoothAlwaysUsageDescription'), contains('A drive keeps recording in the background while the screen is locked.'));
      expect(v('NSBluetoothAlwaysUsageDescription'), isNot(contains('incoming messages')));
      expect(plist, isNot(contains('Home observer')));
      expect(v('NSLocationWhenInUseUsageDescription'), allOf(contains('region'), contains('map')));
    });

    test('privacy manifest declares what the app collects: photos (uploaded), coarse and precise location, all linked, none for tracking', () {
      final m = File('ios/Runner/PrivacyInfo.xcprivacy').readAsStringSync();
      for (final type in ['PhotosorVideos', 'CoarseLocation', 'PreciseLocation', 'UserID', 'OtherUserContent']) {
        final block = RegExp('<string>NSPrivacyCollectedDataType$type</string>(.*?)</dict>', dotAll: true).firstMatch(m);
        expect(block, isNotNull, reason: '$type must be declared');
        expect(block!.group(1), contains('NSPrivacyCollectedDataTypeLinked</key>\n\t\t\t<true/>'), reason: '$type is linked to the driver key');
        expect(block.group(1), contains('NSPrivacyCollectedDataTypeTracking</key>\n\t\t\t<false/>'), reason: '$type is not used for tracking');
        expect(block.group(1), contains('NSPrivacyCollectedDataTypePurposeAppFunctionality'));
      }
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
