// ID steps 2 and 3 inside the app: radio proof at connect, the "Is that you?" sheet, Keychain copy of the key, More > Devices
// and Account. Flag ON = the server advertises `capabilities.radioProof`; flag OFF (production at build 73) = the old flow runs and
// NOT ONE of the new calls is made, the Keychain is not touched, and the old Devices and key screens are what you get.
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/app/driver_key_vault.dart';
import 'package:meshsonar/chat/secret_store.dart' show InMemorySecretStore;
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/person_identity.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/account/devices_screen.dart';
import 'package:meshsonar/ui/account/person_devices_screen.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/widgets.dart' show ErrorBanner;

import '../support/proof_fakes.dart';
import 'claims_ui_test.dart' show ScriptedLink, k;
import 'fakes.dart';

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _on = SiteConfig(region: _region, capabilities: {'nodeClaims', 'radioProof'});
const _off = SiteConfig(region: _region, capabilities: {'nodeClaims'});
final settingsScroll = find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;
final _driverKey = 'ms_${'A' * 43}';

class ProofHarness extends Harness {
  ScriptedLink? link;
  @override
  FakeCmatClient newClient(Uri u) => FakeProofClient(u)..verifySignature = false;
  FakeProofClient get proof => client as FakeProofClient;
  ProofHarness() {
    selfInfo = SelfInfo(
        publicKey: k('A'), name: 'Truck Radio', radio: const Radio(freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5, txDbm: 22), firmware: 'v1.9.0');
    linkMaker = (info) => link = ScriptedLink(info);
  }
}

Future<ProofHarness> open(WidgetTester tester, {required SiteConfig caps, bool connect = true, String? key}) async {
  useTallScreen(tester);
  final h = ProofHarness();
  h.settings.saved = Settings(driverKey: key ?? _driverKey, keyStatus: DriverKeyStatus.approved, display: 'KE4BFI');
  await h.state.init();
  h.client.siteConfigResult = caps;
  await h.state.refreshSiteConfig();
  await h.state.refreshUploadSiteConfig(force: true);
  if (connect) {
    await h.state.connectSimulator();
    expect(h.state.radioKind, RadioKind.simulator);
  }
  await tester.pumpWidget(MeshSonarApp(state: h.state));
  await tester.pump();
  return h;
}

/// The one-line notice the app said (it goes through AppState's notice, so it is in the diagnostics too).
bool said(ProofHarness h, String part) => h.state.diagnostics.lines.any((l) => l.contains(part));

Future<void> settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> openScreen(WidgetTester tester, Widget screen) async {
  tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => screen));
  await tester.pumpAndSettle();
}

void main() {
  group('flag OFF: the old flow, byte for byte', () {
    testWidgets('connecting a radio makes no radio-proof call, no person call, and never touches the Keychain', (tester) async {
      final h = await open(tester, caps: _off);
      await settle(tester, () => false);
      expect(h.state.radioProofCapable, isFalse);
      expect(h.proof.wire.where((w) => w.startsWith('start') || w.startsWith('complete') || w.startsWith('decide') || w.startsWith('person') || w.startsWith('link')), isEmpty,
          reason: 'wire: ${h.proof.wire}');
      expect(h.secretStore.length, 0);
      expect(find.byKey(const Key('radio-proof-sheet')), findsNothing);
    });

    testWidgets('Devices is the old driver-key page and Account still has the key row; no add-to-account button', (tester) async {
      final h = await open(tester, caps: _off, connect: false);
      await openScreen(tester, const DevicesScreen());
      expect(find.text('Devices and keys'), findsOneWidget);
      expect(find.byKey(const Key('devices-screen')), findsOneWidget);
      expect(find.byKey(const Key('person-devices-screen')), findsNothing);
      expect(h.proof.wire.where((w) => w.startsWith('person')), isEmpty);
    });

    testWidgets('Account section keeps the key reveal row', (tester) async {
      await open(tester, caps: _off, connect: false);
      await openSettingsTab(tester);
      await tester.scrollUntilVisible(find.byKey(const Key('masked-key')), -100, scrollable: settingsScroll);
      expect(find.byKey(const Key('key-reveal')), findsOneWidget);
      expect(find.byKey(const Key('add-to-account')), findsNothing);
    });
  });

  group('flag ON: radio proof at connect', () {
    testWidgets('nobody owned it: proved on connect, one line says so, asked once per radio per session', (tester) async {
      final h = await open(tester, caps: _on);
      await settle(tester, () => h.proof.completes > 0);
      expect(h.proof.wire.first, startsWith('start $_driverKey ${k('a')}'));
      expect(h.proof.completes, 1);
            expect(said(h, 'is yours now'), isTrue);
      // reconnect events for the same radio do not ask again
      h.state.radioProof.radioChanged();
      await settle(tester, () => false);
      expect(h.proof.wire.where((w) => w.startsWith('start')), hasLength(1));
    });

    testWidgets('owned by someone else: the sheet asks, Yes joins and says so', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      h.proof.answer = ProofKind.ownedByOther;
      h.proof.decideAnswers = const [DecideResult(DecideKind.joined)];
      await h.state.connectSimulator();
      await settle(tester, () => find.byKey(const Key('radio-proof-sheet')).evaluate().isNotEmpty);
      expect(find.byKey(const Key('radio-proof-sheet')), findsOneWidget);
      expect(find.text('This radio is on KE4BFI\'s account. Is that you?'), findsOneWidget);
      expect(find.textContaining('Yes, add this'), findsOneWidget);
      expect(find.text('No, the radio is mine now'), findsOneWidget);
      // Build 76: one card per answer, and Not now is a full-width 48 pt button.
      expect(find.byKey(const Key('radio-proof-yes-card')), findsOneWidget);
      expect(find.byKey(const Key('radio-proof-no-card')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('radio-proof-later'))).height, greaterThanOrEqualTo(48));
      expect(h.proof.decides, 0);
      await tester.tap(find.byKey(const Key('radio-proof-join')));
      await settle(tester, () => h.proof.decides > 0);
      expect(h.proof.decisions, [true]);
      expect(said(h, 'account now'), isTrue);
    });

    testWidgets('No takes the radio alone; the ask-me-first note shows when the owner switched it on', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      h.proof
        ..answer = ProofKind.ownedByOther
        ..askFirst = true
        ..decideAnswers = const [DecideResult(DecideKind.taken)];
      await h.state.connectSimulator();
      await settle(tester, () => find.byKey(const Key('radio-proof-sheet')).evaluate().isNotEmpty);
      expect(find.byKey(const Key('radio-proof-askfirst')), findsOneWidget);
      await tester.tap(find.byKey(const Key('radio-proof-take')));
      await settle(tester, () => h.proof.decides > 0);
      expect(h.proof.decisions, [false]);
    });

    testWidgets('a device signed in to an account is offered only "No" (cannot join)', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      h.proof
        ..answer = ProofKind.ownedByOther
        ..canJoin = false;
      await h.state.connectSimulator();
      await settle(tester, () => find.byKey(const Key('radio-proof-sheet')).evaluate().isNotEmpty);
      expect(find.byKey(const Key('radio-proof-nojoin')), findsOneWidget);
      expect(find.byKey(const Key('radio-proof-join')), findsNothing);
      expect(find.byKey(const Key('radio-proof-take')), findsOneWidget);
      await tester.tap(find.byKey(const Key('radio-proof-take')));
      await settle(tester, () => h.proof.decides > 0);
      expect(h.proof.decisions, [false]);
    });

    testWidgets('Not now closes the question and decides nothing', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      h.proof.answer = ProofKind.ownedByOther;
      await h.state.connectSimulator();
      await settle(tester, () => find.byKey(const Key('radio-proof-sheet')).evaluate().isNotEmpty);
      await tester.tap(find.byKey(const Key('radio-proof-later')));
      await settle(tester, () => false);
      expect(h.proof.decides, 0);
      expect(find.byKey(const Key('radio-proof-sheet')), findsNothing);
    });

    testWidgets('a server refusal is said in words (429)', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      h.proof.startError = const CmatException('slow', status: 429);
      await h.state.connectSimulator();
      await settle(tester, () => said(h, 'Too many radio checks'));
      expect(said(h, 'Too many radio checks'), isTrue);
    });
  });

  group('flag ON: Keychain copy of the key', () {
    testWidgets('settings.json key is copied to the Keychain and stays in settings.json', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      await settle(tester, () => h.secretStore.length > 0);
      expect(await DriverKeyVault(h.secretStore).read(Uri.parse(h.state.settings.serverUrl).host), _driverKey);
      expect(h.state.settings.driverKey, _driverKey, reason: 'the old copy is kept until step 7');
    });

    testWidgets('a reinstall (no settings key, Keychain has it) gets the key back instead of a new one', (tester) async {
      useTallScreen(tester);
      final h = ProofHarness();
      h.settings
        ..saved = const Settings(autoKey: true)
        ..autoKeyOn = true;
      await DriverKeyVault(h.secretStore).write(Uri.parse(h.state.settings.serverUrl).host, _driverKey);
      h.client.siteConfigResult = const SiteConfig(region: _region, capabilities: {'radioProof'});
      await h.state.init();
      await settle(tester, () => h.state.hasKey);
      expect(h.state.settings.driverKey, _driverKey);
      expect(h.proof.requestCalls, 0, reason: 'no new driver was made');
    });

    testWidgets('flag OFF: the same reinstall makes a new key exactly as before and the Keychain stays untouched', (tester) async {
      useTallScreen(tester);
      final h = ProofHarness();
      h.settings
        ..saved = const Settings(autoKey: true)
        ..autoKeyOn = true;
      await DriverKeyVault(h.secretStore).write(Uri.parse(h.state.settings.serverUrl).host, _driverKey);
      h.client.siteConfigResult = const SiteConfig(region: _region, capabilities: {'nodeClaims'});
      await h.state.init();
      await settle(tester, () => h.state.hasKey);
      expect(h.state.hasKey, isTrue);
      expect(h.proof.requestCalls, 1);
      expect(h.state.settings.driverKey, isNot(_driverKey));
      expect(h.secretStore.length, 1, reason: 'still only what the test put there');
    });

    test('vault: reconcile prefers settings, adopts only when settings is empty, ignores junk', () async {
      final store = InMemorySecretStore();
      final v = DriverKeyVault(store);
      expect((await v.reconcile('h', null)).key, isNull);
      expect((await v.reconcile('h', _driverKey)), (key: _driverKey, adopted: false));
      expect(await v.read('h'), _driverKey);
      expect((await v.reconcile('h', null)), (key: _driverKey, adopted: true));
      final other = 'ms_${'B' * 43}';
      expect((await v.reconcile('h', other)).key, other);
      expect(await v.read('h'), other, reason: 'the working key wins and refreshes the copy');
      await v.write('x', 'not-a-key');
      expect(await v.read('x'), isNull);
      await v.delete('h');
      expect(await v.read('h'), isNull);
    });
  });

  group('flag ON: More > Devices and Account', () {
    testWidgets('lists devices with model / build / OS and a This phone marker; no key anywhere', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      await openScreen(tester, const DevicesScreen());
      await settle(tester, () => find.byKey(const Key('device-d1')).evaluate().isNotEmpty);
      expect(find.byKey(const Key('person-devices-screen')), findsOneWidget);
      expect(find.byKey(const Key('devices-screen')), findsNothing);
      expect(find.text('iPhone17,1 · build 73 · iOS 27.2'), findsOneWidget);
      expect(find.byKey(const Key('device-current-d1')), findsOneWidget);
      expect(find.byKey(const Key('device-remove-d1')), findsNothing, reason: 'this phone is not removed from itself');
      expect(find.byKey(const Key('device-remove-d2')), findsOneWidget);
      expect(find.textContaining(_driverKey), findsNothing);
      expect(h.proof.wire.where((w) => w.startsWith('driver')), isEmpty);
      expect(find.text('Phones and tablets on your account. No key to copy.'), findsOneWidget, reason: 'the intro is one short line');
      expect(find.byKey(const Key('person-notices-title')), findsNothing, reason: 'no empty Notices heading');
      // the list people come for is above the setting about it
      expect(tester.getTopLeft(find.byKey(const Key('device-d1'))).dy, lessThan(tester.getTopLeft(find.byKey(const Key('ask-first-switch'))).dy));
      for (final k in ['device-rename-d1', 'device-rename-d2', 'device-remove-d2']) {
        expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(44), reason: k);
      }
    });

    testWidgets('375 pt wide at 2x text: devices, notices and the rename sheet lay out with no overflow', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      tester.view.physicalSize = const Size(750, 1334);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      h.proof.notices = [
        PersonNotice(id: 'n1', kind: 'join_request', createdAt: DateTime.utc(2026, 11, 22, 9), pubkey: k('a'), nodeName: 'Truck Radio', deviceName: 'iPad'),
      ];
      await openScreen(tester, const PersonDevicesScreen());
      await settle(tester, () => find.byKey(const Key('notice-n1')).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(FilledButton, 'Yes, add it'), findsOneWidget);
      final scroll = find.descendant(of: find.byKey(const Key('person-devices-screen')), matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(find.byKey(const Key('device-rename-d2')), 200, scrollable: scroll);
      await tester.ensureVisible(find.byKey(const Key('device-rename-d2')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('device-rename-d2')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('device-rename-cancel')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('person-devices-website')), 300, scrollable: scroll);
      expect(tester.takeException(), isNull);
    });

    testWidgets('rename: Done on the keyboard saves, trimmed', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      await openScreen(tester, const PersonDevicesScreen());
      await settle(tester, () => find.byKey(const Key('device-d2')).evaluate().isNotEmpty);
      await tester.tap(find.byKey(const Key('device-rename-d2')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('device-rename-field')), ' Truck iPad ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester, () => h.proof.wire.contains('rename d2 Truck iPad'));
      expect(h.proof.wire, contains('rename d2 Truck iPad'));
    });

    testWidgets('notices: requests come first, the newest three show, Show all opens the rest', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      h.proof.notices = [
        for (var i = 1; i <= 5; i++) PersonNotice(id: 'j$i', kind: 'device_joined', createdAt: DateTime.utc(2026, 11, 20, i), deviceName: 'Phone $i'),
        PersonNotice(id: 'req', kind: 'join_request', createdAt: DateTime.utc(2026, 11, 19), pubkey: k('a'), nodeName: 'Truck Radio', deviceName: 'iPad'),
      ];
      await openScreen(tester, const PersonDevicesScreen());
      await settle(tester, () => find.byKey(const Key('notice-req')).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('Notices (6 new)'), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const Key('notice-req'))).dy, lessThan(tester.getTopLeft(find.byKey(const Key('notice-j1'))).dy), reason: 'what waits for an answer is on top');
      expect(find.byKey(const Key('notice-j2')), findsOneWidget);
      expect(find.byKey(const Key('notice-j3')), findsNothing);
      await tester.tap(find.byKey(const Key('person-notices-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notice-j5')), findsOneWidget);
      expect(find.byKey(const Key('person-notices-all')), findsNothing);
    });

    testWidgets('rename, remove (with confirm) and ask me first', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      await openScreen(tester, const PersonDevicesScreen());
      await settle(tester, () => find.byKey(const Key('device-d2')).evaluate().isNotEmpty);
      await tester.tap(find.byKey(const Key('device-rename-d2')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('device-rename-field')), 'Kitchen iPad');
      await tester.tap(find.byKey(const Key('device-rename-save')));
      await settle(tester, () => h.proof.wire.contains('rename d2 Kitchen iPad'));
      await tester.pumpAndSettle();
      expect(find.text('Kitchen iPad'), findsOneWidget);

      await tester.tap(find.byKey(const Key('device-remove-d2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-remove-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('device-remove-cancel')));
      await tester.pumpAndSettle();
      expect(h.proof.wire.where((w) => w.startsWith('remove')), isEmpty);
      await tester.tap(find.byKey(const Key('device-remove-d2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device-remove-confirm')));
      await settle(tester, () => h.proof.wire.contains('remove d2'));
      expect(find.byKey(const Key('device-d2')), findsNothing);

      await tester.tap(find.byKey(const Key('ask-first-switch')));
      await settle(tester, () => h.proof.wire.contains('ask-first true'));
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('ask-first-switch'))).value, isTrue);
    });

    testWidgets('notices: a join request can be approved; a plain notice is marked read', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      h.proof.notices = [
        PersonNotice(id: 'n1', kind: 'join_request', createdAt: DateTime.utc(2026, 11, 22, 9), pubkey: k('a'), nodeName: 'Truck Radio', deviceName: 'iPad'),
        PersonNotice(id: 'n2', kind: 'device_joined', createdAt: DateTime.utc(2026, 11, 21, 9), deviceName: 'Old iPhone'),
      ];
      await openScreen(tester, const PersonDevicesScreen());
      await settle(tester, () => find.byKey(const Key('notice-n1')).evaluate().isNotEmpty);
      expect(find.text('iPad wants to join your account because it connected Truck Radio.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('notice-approve-n1')));
      await settle(tester, () => h.proof.wire.contains('notice n1 approve'));
      expect(find.text('You approved iPad.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('notice-read-n2')));
      await settle(tester, () => h.proof.wire.contains('notice n2 read'));
    });

    testWidgets('Account: no key row, Add this iPhone to my account opens the one-time link in the browser', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      await openSettingsTab(tester);
      await tester.scrollUntilVisible(find.byKey(const Key('add-to-account')), -100, scrollable: settingsScroll);
      expect(find.byKey(const Key('masked-key')), findsNothing);
      expect(find.byKey(const Key('key-reveal')), findsNothing);
      expect(find.byKey(const Key('key-keychain-note')), findsOneWidget);
      expect(find.text('Add this iPhone to my account'), findsOneWidget);
      await tester.tap(find.byKey(const Key('add-to-account')));
      await settle(tester, () => h.openedUrls.isNotEmpty);
      expect(h.proof.wire, contains('link-start'));
      expect(h.openedUrls.single.toString(), 'https://meshsonar.com/link?code=ABCDEFGHJKMN');
    });

    testWidgets('Account: a link failure is said in words and nothing opens', (tester) async {
      final h = await open(tester, caps: _on, connect: false);
      h.proof.linkError = const CmatException('slow', status: 429);
      await openSettingsTab(tester);
      await tester.scrollUntilVisible(find.byKey(const Key('add-to-account')), -100, scrollable: settingsScroll);
      await tester.tap(find.byKey(const Key('add-to-account')));
      await settle(tester, () => false);
      expect(h.openedUrls, isEmpty);
      expect(find.byType(ErrorBanner), findsOneWidget);
    });
  });
}
