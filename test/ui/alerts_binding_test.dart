// AlertsRuntime bound to a real AppState (fake Bluetooth scanner/link): the radio is saved on connect, auto-connect is held
// (the radio stays saved) on a deliberate disconnect, nothing changes when the link merely drops, and the starred radio is
// brought back shortly after launch as Settings > Radio > Auto-connect allows.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_coordinator.dart';
import 'package:meshsonar/alerts/alert_prefs.dart';
import 'package:meshsonar/alerts/alerts_runtime.dart';
import 'package:meshsonar/alerts/ble_lifecycle_log.dart';
import 'package:meshsonar/alerts/launch_reconnect.dart';
import 'package:meshsonar/alerts/radio_queue_watch.dart';
import 'package:meshsonar/alerts/saved_radios_store.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/platform/background_link_service.dart';
import 'package:meshsonar/platform/ios_wake_keeper.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../alerts/fakes.dart';
import 'fakes.dart';

class RecordingKeeper implements IosWakeKeeper {
  final calls = <String>[];
  @override
  Future<void> arm(String peripheralId) async => calls.add('arm $peripheralId');
  @override
  Future<void> disarm() async => calls.add('disarm');
  @override
  Future<KeeperReport> report() async => const KeeperReport();
  @override
  Future<void> clearReport() async {}
}

class RecordingService implements BackgroundLinkService {
  final calls = <String>[];
  bool _on = false;
  @override
  bool get supported => true;
  @override
  bool get running => _on;
  @override
  Future<void> start({required String radioName}) async {
    _on = true;
    calls.add('start $radioName');
  }

  @override
  Future<void> stop() async {
    _on = false;
    calls.add('stop');
  }
}

void main() {
  const truck = RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck');

  Future<(AlertsRuntime, Harness, SavedRadiosStore, RecordingKeeper, RecordingService)> rig(WidgetTester tester,
      {SavedRadio? remembered, bool keeper = false, AutoConnectMode mode = AutoConnectMode.always}) async {
    final h = Harness();
    await h.state.init();
    final store = SavedRadiosStore(initial: [?remembered]);
    final prefs = AlertPrefs();
    await prefs.setAutoConnect(mode);
    if (keeper) await prefs.setIosWakeKeeper(true);
    final k = RecordingKeeper();
    final svc = RecordingService();
    final rt = AlertsRuntime(
      prefs: prefs,
      coordinator: AlertCoordinator(notifications: FakeLocalNotifications(), prefs: prefs),
      log: BleLifecycleLog(),
      queue: RadioQueueWatch(),
      savedRadios: store,
      keeper: k,
      backgroundLink: svc,
    );
    rt.bindApp(h.state);
    addTearDown(rt.dispose);
    return (rt, h, store, k, svc);
  }

  testWidgets('connect remembers the Bluetooth radio; the simulator is never remembered', (tester) async {
    final (rt, h, store, _, svc) = await rig(tester);
    await h.state.connect(const RadioDevice(id: 'sim', name: 'Sim'), RadioKind.simulator);
    await tester.pump();
    expect(store.isEmpty, isTrue);
    await h.state.connect(truck, RadioKind.bluetooth);
    await tester.pump();
    final l = store.autoConnectTarget;
    expect(l?.id, 'aa:bb');
    expect(l?.name, isNotEmpty);
    expect(l?.publicKeyHex, 'abcdef0123', reason: 'the key is kept (lower case) so a re-addressed radio is recognised');
    expect(store.radios.single.lastConnected, isNotNull);
    expect(svc.calls.single, startsWith('start '), reason: 'Android foreground service starts on connect');
    expect(rt.log.entries.any((e) => e.kind == 'connect'), isTrue);
  });

  testWidgets('a deliberate disconnect holds auto-connect (radio stays saved), releases the keeper and stops the service; a drop does not', (tester) async {
    final (rt, h, store, keeper, svc) = await rig(tester, keeper: true);
    await h.state.connect(truck, RadioKind.bluetooth);
    await tester.pump();
    expect(keeper.calls, ['arm aa:bb']);
    // the link drops under the app: remembered stays
    h.links.last.drop();
    await tester.pump();
    expect(store.autoConnectTarget, isNotNull, reason: 'a dropped link is not a decision');
    // the person disconnects
    await h.state.disconnect();
    await tester.pump();
    expect(store.autoConnectTarget, isNull);
    expect(store.autoConnectHeld, isTrue);
    expect(store.radios.single.id, 'aa:bb', reason: 'disconnecting never removes a saved radio');
    expect(keeper.calls.last, 'disarm');
    expect(svc.calls.last, 'stop');
    // and nothing reconnects by itself afterwards
    await rt.reconnect!.run();
    expect(h.state.connected, isFalse);
  });

  testWidgets('relaunch: with a remembered radio, startLaunchReconnect connects after the first wait, no tap needed', (tester) async {
    final (rt, h, _, _, _) = await rig(tester, remembered: const SavedRadio(id: 'aa:bb', name: 'MeshCore-Truck'));
    expect(h.state.connected, isFalse);
    rt.startLaunchReconnect();
    await tester.pump();
    expect(rt.reconnect!.state, LaunchReconnectState.waiting);
    expect(rt.reconnect!.statusText, 'Reconnecting to MeshCore-Truck…');
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    await tester.pump();
    expect(h.state.connected, isTrue);
    expect(rt.reconnect!.state, LaunchReconnectState.connected);
  });

  testWidgets('relaunch while driving or connecting is left alone', (tester) async {
    final (rt, h, _, _, _) = await rig(tester, remembered: const SavedRadio(id: 'aa:bb', name: 'MeshCore-Truck'));
    await h.state.connect(truck, RadioKind.bluetooth);
    await tester.pump();
    final before = h.links.length;
    await rt.reconnect!.run();
    expect(h.links.length, before, reason: 'already connected: no second link');
  });

  testWidgets('lifecycle changes are logged with fg/bg and a foreground return retries a lost link', (tester) async {
    final (rt, h, _, _, _) = await rig(tester, remembered: const SavedRadio(id: 'aa:bb', name: 'MeshCore-Truck'));
    rt.didChangeAppLifecycleState(AppLifecycleState.paused);
    rt.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(rt.log.entries.map((e) => e.detail), containsAllInOrder(['paused', 'resumed']));
    expect(rt.log.entries.firstWhere((e) => e.detail == 'paused').foreground, isFalse);
    expect(rt.log.entries.firstWhere((e) => e.detail == 'resumed').foreground, isTrue);
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    await tester.pump();
    expect(h.state.connected, isTrue);
  });

  testWidgets('after a deliberate disconnect, the next connect lifts the hold and auto-connect works again', (tester) async {
    final (rt, h, store, _, _) = await rig(tester);
    await h.state.connect(truck, RadioKind.bluetooth);
    await tester.pump();
    await h.state.disconnect();
    await tester.pump();
    expect(store.autoConnectHeld, isTrue);
    await h.state.connect(truck, RadioKind.bluetooth);
    await tester.pump();
    expect(store.autoConnectHeld, isFalse);
    expect(store.autoConnectTarget?.id, 'aa:bb');
  });

  testWidgets('Auto-connect Off: no launch connect and no foreground connect', (tester) async {
    final (rt, h, _, _, _) = await rig(tester, remembered: const SavedRadio(id: 'aa:bb', name: 'MeshCore-Truck'), mode: AutoConnectMode.off);
    rt.startLaunchReconnect();
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(h.state.connected, isFalse);
    expect(rt.reconnect!.statusText, isNull, reason: 'nothing to nag about');
    rt.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(h.state.connected, isFalse);
    expect(rt.log.entries.map((e) => e.detail), contains('skip (launch): auto-connect Off'));
  });

  testWidgets('Auto-connect At launch only: launch connects, a later return to the front does not', (tester) async {
    final (rt, h, _, _, _) = await rig(tester, remembered: const SavedRadio(id: 'aa:bb', name: 'MeshCore-Truck'), mode: AutoConnectMode.launchOnly);
    rt.startLaunchReconnect();
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    await tester.pump();
    expect(h.state.connected, isTrue);
    h.links.last.drop();
    await tester.pump();
    final before = h.links.length;
    rt.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(h.links.length, before, reason: 'no foreground connect in At launch only');
  });

  testWidgets('setAutoConnect saves the mode and Off clears a "Could not reach" line', (tester) async {
    final (rt, _, _, _, _) = await rig(tester, remembered: const SavedRadio(id: 'zz:zz', name: 'Gone'));
    rt.reconnect = LaunchReconnect(
      store: rt.savedRadios,
      connect: (_) async => false,
      isConnected: () => false,
      mode: () => rt.prefs.autoConnect,
      wait: (_) async {},
      maxAttempts: 1,
    );
    await rt.reconnect!.run();
    expect(rt.reconnect!.state, LaunchReconnectState.gaveUp);
    await rt.setAutoConnect(AutoConnectMode.off);
    expect(rt.prefs.autoConnect, AutoConnectMode.off);
    expect(rt.reconnect!.state, LaunchReconnectState.idle);
    expect(rt.reconnect!.statusText, isNull);
  });
}
