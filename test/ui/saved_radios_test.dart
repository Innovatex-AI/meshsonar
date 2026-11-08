// CR5 + CR6 UI: Settings > Radio > Auto-connect (three choices, the mid-drive footer, saved in prefs), the saved radios list on
// the connect screen (above the scan, tap connects without a scan, swipe to forget with a confirm, long-press for nickname and
// star, "In range" instead of a duplicate row), Settings > Radio > Saved radios, the strip staying quiet when Off, and the
// rename of the server-claims screens to "Claimed radios".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_coordinator.dart';
import 'package:meshsonar/alerts/alert_prefs.dart';
import 'package:meshsonar/alerts/alerts_runtime.dart';
import 'package:meshsonar/alerts/ble_lifecycle_log.dart';
import 'package:meshsonar/alerts/launch_reconnect.dart';
import 'package:meshsonar/alerts/radio_queue_watch.dart';
import 'package:meshsonar/alerts/saved_radios_store.dart';
import 'package:meshsonar/ui/alerts/alerts_status_strip.dart';
import 'package:meshsonar/ui/claims/my_radios_screen.dart';
import 'package:meshsonar/ui/connect_screen.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/saved_radios_screen.dart';

import '../alerts/fakes.dart';
import 'fakes.dart';
import 'settings_test_kit.dart';

class SavedRig {
  final prefs = AlertPrefs();
  final SavedRadiosStore store;
  late final AlertsRuntime runtime = AlertsRuntime(
    prefs: prefs,
    coordinator: AlertCoordinator(notifications: FakeLocalNotifications(), prefs: prefs),
    log: BleLifecycleLog(),
    queue: RadioQueueWatch(),
    savedRadios: store,
  );
  SavedRig(this.store);
}

/// Two saved radios: "aa:bb" (also in the fake scan, MeshCore-Truck) and "zz:zz" (out of range), most recent first.
SavedRadiosStore twoSaved() => SavedRadiosStore(initial: [
      SavedRadio(id: 'aa:bb', name: 'MeshCore-Truck', publicKeyHex: 'abcdef0123', model: 'Heltec V3', lastConnected: DateTime.now().subtract(const Duration(minutes: 5))),
      SavedRadio(id: 'zz:zz', name: 'Base Station', lastConnected: DateTime.now().subtract(const Duration(days: 3))),
    ]);

SavedRig install(WidgetTester tester, SavedRadiosStore store) {
  final r = SavedRig(store);
  final old = AlertsHost.runtime.value;
  AlertsHost.runtime.value = r.runtime;
  addTearDown(() {
    AlertsHost.runtime.value = old;
    dismissAppToast();
  });
  return r;
}

Future<void> openConnect(WidgetTester tester, Harness h) async {
  useTallScreen(tester);
  await h.pumpApp(tester);
  final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
  nav.push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen()));
  await tester.pumpAndSettle();
}

void main() {
  group('lastConnectedText', () {
    final now = DateTime(2026, 11, 7, 15);
    test('words for every distance', () {
      expect(lastConnectedText(now.subtract(const Duration(seconds: 30)), now), 'Last connected just now');
      expect(lastConnectedText(now.subtract(const Duration(minutes: 12)), now), 'Last connected 12 min ago');
      expect(lastConnectedText(DateTime(2026, 11, 7, 9), now), 'Last connected 6 h ago');
      expect(lastConnectedText(DateTime(2026, 11, 6, 23), now), 'Last connected yesterday');
      expect(lastConnectedText(DateTime(2026, 10, 28), now), 'Last connected 10 days ago');
      expect(lastConnectedText(DateTime(2026, 3, 3), now), 'Last connected on 3 Mar 2026');
      expect(lastConnectedText(null, now), 'Last connection time unknown');
    });
  });

  group('connect screen: Saved radios', () {
    testWidgets('shown above Nearby radios, starred first; a saved radio in the scan is marked In range, not listed twice', (tester) async {
      install(tester, twoSaved());
      final h = Harness();
      await openConnect(tester, h);
      expect(find.byKey(const Key('saved-radios-section')), findsOneWidget);
      final savedY = tester.getTopLeft(find.text('Saved radios')).dy;
      final nearbyY = tester.getTopLeft(find.text('Nearby radios')).dy;
      expect(savedY, lessThan(nearbyY));
      expect(tester.getTopLeft(find.byKey(const ValueKey('saved-radio-aa:bb'))).dy,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('saved-radio-zz:zz'))).dy));
      expect(find.byKey(const ValueKey('saved-radio-star-aa:bb')), findsOneWidget, reason: 'the most recent radio carries the star');
      expect(find.byKey(const ValueKey('device-aa:bb')), findsNothing, reason: 'no duplicate row in the scan list');
      expect(find.byKey(const ValueKey('device-cc:dd')), findsOneWidget);
      expect(find.textContaining('In range · Last connected 5 min ago'), findsOneWidget);
      expect(find.textContaining('Heltec V3'), findsOneWidget);
    });

    testWidgets('no saved radios: the section is not there', (tester) async {
      install(tester, SavedRadiosStore());
      await openConnect(tester, Harness());
      expect(find.byKey(const Key('saved-radios-section')), findsNothing);
      expect(find.byKey(const ValueKey('device-aa:bb')), findsOneWidget);
    });

    testWidgets('tap a saved radio that is not in range: connects to it by its id, no scan needed', (tester) async {
      install(tester, twoSaved());
      final h = Harness();
      await openConnect(tester, h);
      final before = h.bt.connects;
      await tester.tap(find.byKey(const ValueKey('saved-radio-zz:zz')));
      await tester.pumpAndSettle();
      expect(h.bt.connects, before + 1);
      expect(h.state.connected, isTrue);
      expect(h.state.device?.id, 'zz:zz');
      expect(find.byType(ConnectScreen), findsNothing, reason: 'the screen closes after a connect, as for a scanned radio');
    });

    testWidgets('swipe left asks before forgetting; Cancel keeps it, Forget removes it from the list only', (tester) async {
      final store = twoSaved();
      install(tester, store);
      await openConnect(tester, Harness());
      await tester.drag(find.byKey(const ValueKey('saved-radio-zz:zz')), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('saved-radio-forget-dialog')), findsOneWidget);
      expect(find.textContaining('Chat history, contacts and its antenna setup stay'), findsOneWidget);
      await tester.tap(find.byKey(const Key('saved-radio-forget-cancel')));
      await tester.pumpAndSettle();
      expect(store.byId('zz:zz'), isNotNull);
      expect(find.byKey(const ValueKey('saved-radio-zz:zz')), findsOneWidget);
      await tester.drag(find.byKey(const ValueKey('saved-radio-zz:zz')), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('saved-radio-forget-confirm')));
      await tester.pumpAndSettle();
      expect(store.byId('zz:zz'), isNull);
      expect(find.byKey(const ValueKey('saved-radio-zz:zz')), findsNothing);
      expect(store.radios.single.id, 'aa:bb');
    });

    testWidgets('forgetting a radio that is in range puts it back in the scan list', (tester) async {
      final store = twoSaved();
      install(tester, store);
      await openConnect(tester, Harness());
      await tester.drag(find.byKey(const ValueKey('saved-radio-aa:bb')), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('saved-radio-forget-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-aa:bb')), findsOneWidget);
    });

    testWidgets('long-press: star a radio for auto-connect, then follow the most recent again', (tester) async {
      final store = twoSaved();
      install(tester, store);
      await openConnect(tester, Harness());
      await tester.longPress(find.byKey(const ValueKey('saved-radio-zz:zz')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('saved-radio-actions')), findsOneWidget);
      await tester.tap(find.byKey(const Key('saved-radio-star')));
      await tester.pumpAndSettle();
      expect(store.starredId, 'zz:zz');
      expect(store.starPinned, isTrue);
      expect(find.byKey(const ValueKey('saved-radio-star-zz:zz')), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const ValueKey('saved-radio-zz:zz'))).dy,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('saved-radio-aa:bb'))).dy), reason: 'the starred radio is listed first');
      await tester.tap(find.byKey(const ValueKey('saved-radio-info-zz:zz')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('saved-radio-star')), findsNothing);
      await tester.tap(find.byKey(const Key('saved-radio-follow-recent')));
      await tester.pumpAndSettle();
      expect(store.starredId, 'aa:bb');
      expect(store.starPinned, isFalse);
    });

    testWidgets('info button: set a nickname; the card shows it with the radio\'s own name underneath', (tester) async {
      final store = twoSaved();
      install(tester, store);
      await openConnect(tester, Harness());
      await tester.tap(find.byKey(const ValueKey('saved-radio-info-zz:zz')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('saved-radio-nickname')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('edit-field')), 'Home base');
      await tester.tap(find.byKey(const Key('edit-save')));
      await tester.pumpAndSettle();
      expect(store.byId('zz:zz')?.nickname, 'Home base');
      expect(find.text('Home base'), findsOneWidget);
      expect(find.textContaining('Base Station'), findsOneWidget);
    });
  });

  group('Settings > Radio', () {
    testWidgets('Auto-connect: three choices, Always by default, the mid-drive footer; a choice is saved', (tester) async {
      final r = install(tester, twoSaved());
      final h = Harness();
      useTallScreen(tester);
      await h.pumpApp(tester);
      await openSettingsTab(tester);
      await showSetting(tester, 'auto-connect');
      expect(find.byKey(const Key('auto-connect-always')), findsOneWidget);
      expect(find.byKey(const Key('auto-connect-launch')), findsOneWidget);
      expect(find.byKey(const Key('auto-connect-off')), findsOneWidget);
      expect(tester.widget<ListTile>(find.byKey(const Key('auto-connect-always'))).selected, isTrue);
      expect(find.text('While driving, a dropped radio is always reconnected.'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('auto-connect-off')));
      await tester.tap(find.byKey(const Key('auto-connect-off')));
      await tester.pumpAndSettle();
      expect(r.prefs.autoConnect, AutoConnectMode.off);
      expect(tester.widget<ListTile>(find.byKey(const Key('auto-connect-off'))).selected, isTrue);
      await tester.ensureVisible(find.byKey(const Key('auto-connect-launch')));
      await tester.tap(find.byKey(const Key('auto-connect-launch')));
      await tester.pumpAndSettle();
      expect(r.prefs.autoConnect, AutoConnectMode.launchOnly);
    });

    testWidgets('Saved radios row: counts, names the auto-connect radio, opens the same list (tap connects there)', (tester) async {
      install(tester, twoSaved());
      final h = Harness();
      useTallScreen(tester);
      await h.pumpApp(tester);
      await openSettingsTab(tester);
      await showSetting(tester, 'saved-radios');
      expect(find.textContaining('2 radios. Auto-connect: MeshCore-Truck'), findsOneWidget);
      await tester.tap(find.byKey(const Key('saved-radios')));
      await tester.pumpAndSettle();
      expect(find.byType(SavedRadiosScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('saved-radio-aa:bb')), findsOneWidget);
      expect(find.byKey(const ValueKey('saved-radio-zz:zz')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('saved-radio-zz:zz')));
      await tester.pumpAndSettle();
      expect(h.state.device?.id, 'zz:zz');
      expect(h.state.connected, isTrue);
      expect(find.byType(SavedRadiosScreen), findsOneWidget, reason: 'stays on the list');
    });

    testWidgets('Saved radios screen with nothing saved says how radios get there', (tester) async {
      install(tester, SavedRadiosStore());
      final h = Harness();
      useTallScreen(tester);
      await h.pumpApp(tester);
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.push(MaterialPageRoute<void>(builder: (_) => const SavedRadiosScreen()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('saved-radios-empty')), findsOneWidget);
    });
  });

  testWidgets('Auto-connect Off: a launch shows no "Reconnecting" strip', (tester) async {
    final r = install(tester, twoSaved());
    await r.prefs.setAutoConnect(AutoConnectMode.off);
    final lr = LaunchReconnect(
      store: r.store,
      connect: (_) async => false,
      isConnected: () => false,
      mode: () => r.prefs.autoConnect,
      wait: (_) async {},
      maxAttempts: 1,
    );
    r.runtime.reconnect = lr;
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AlertsStatusStrip())));
    await lr.run(reason: 'launch');
    await lr.onForeground();
    await tester.pump();
    expect(find.byKey(const Key('reconnect-strip')), findsNothing);
  });

  group('Claimed radios (renamed from My radios)', () {
    testWidgets('More row, Settings section and the screen title say Claimed radios', (tester) async {
      install(tester, SavedRadiosStore());
      final h = Harness();
      useTallScreen(tester);
      await h.pumpApp(tester);
      await tapShellTab(tester, 'More');
      expect(find.text('Claimed radios'), findsOneWidget);
      expect(find.text('My radios and claims'), findsNothing);
      await openSettingsTab(tester);
      await showSetting(tester, 'my-radios');
      expect(find.text('CLAIMED RADIOS'), findsOneWidget, reason: 'section header');
      expect(find.descendant(of: find.byKey(const Key('my-radios')), matching: find.text('Claimed radios')), findsOneWidget);
      expect(find.text('My radios'), findsNothing);
      expect(find.text('MY RADIOS'), findsNothing);
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.push(MaterialPageRoute<void>(builder: (_) => const MyRadiosScreen()));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Claimed radios')), findsOneWidget);
    });
  });
}
