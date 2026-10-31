// AlertsRuntime bound to a real AppState (fake Bluetooth scanner/link): the radio is remembered on connect, forgotten on a
// deliberate disconnect, kept when the link merely drops, and brought back shortly after launch.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_coordinator.dart';
import 'package:meshsonar/alerts/alert_prefs.dart';
import 'package:meshsonar/alerts/alerts_runtime.dart';
import 'package:meshsonar/alerts/ble_lifecycle_log.dart';
import 'package:meshsonar/alerts/last_radio_store.dart';
import 'package:meshsonar/alerts/launch_reconnect.dart';
import 'package:meshsonar/alerts/radio_queue_watch.dart';
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

  Future<(AlertsRuntime, Harness, MemoryLastRadioStore, RecordingKeeper, RecordingService)> rig(WidgetTester tester,
      {LastRadio? remembered, bool keeper = false}) async {
    final h = Harness();
    await h.state.init();
    final store = MemoryLastRadioStore(remembered);
    final prefs = AlertPrefs();
    if (keeper) await prefs.setIosWakeKeeper(true);
    final k = RecordingKeeper();
    final svc = RecordingService();
    final rt = AlertsRuntime(
      prefs: prefs,
      coordinator: AlertCoordinator(notifications: FakeLocalNotifications(), prefs: prefs),
      log: BleLifecycleLog(),
      queue: RadioQueueWatch(),
      lastRadio: store,
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
    expect(await store.load(), isNull);
    await h.state.connect(truck, RadioKind.bluetooth);
    await tester.pump();
    final l = await store.load();
    expect(l?.id, 'aa:bb');
    expect(l?.name, isNotEmpty);
    expect(svc.calls.single, startsWith('start '), reason: 'Android foreground service starts on connect');
    expect(rt.log.entries.any((e) => e.kind == 'connect'), isTrue);
  });

  testWidgets('a deliberate disconnect forgets the radio, releases the keeper and stops the service; a drop does not', (tester) async {
    final (rt, h, store, keeper, svc) = await rig(tester, keeper: true);
    await h.state.connect(truck, RadioKind.bluetooth);
    await tester.pump();
    expect(keeper.calls, ['arm aa:bb']);
    // the link drops under the app: remembered stays
    h.links.last.drop();
    await tester.pump();
    expect(await store.load(), isNotNull, reason: 'a dropped link is not a decision');
    // the person disconnects
    await h.state.disconnect();
    await tester.pump();
    expect(await store.load(), isNull);
    expect(keeper.calls.last, 'disarm');
    expect(svc.calls.last, 'stop');
    // and nothing reconnects by itself afterwards
    await rt.reconnect!.run();
    expect(h.state.connected, isFalse);
  });

  testWidgets('relaunch: with a remembered radio, startLaunchReconnect connects after the first wait, no tap needed', (tester) async {
    final (rt, h, _, _, _) = await rig(tester, remembered: const LastRadio('aa:bb', 'MeshCore-Truck'));
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
    final (rt, h, _, _, _) = await rig(tester, remembered: const LastRadio('aa:bb', 'MeshCore-Truck'));
    await h.state.connect(truck, RadioKind.bluetooth);
    await tester.pump();
    final before = h.links.length;
    await rt.reconnect!.run();
    expect(h.links.length, before, reason: 'already connected: no second link');
  });

  testWidgets('lifecycle changes are logged with fg/bg and a foreground return retries a lost link', (tester) async {
    final (rt, h, _, _, _) = await rig(tester, remembered: const LastRadio('aa:bb', 'MeshCore-Truck'));
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
}
