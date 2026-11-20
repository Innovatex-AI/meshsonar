// The admin launcher (the Repeaters screen is retired; Chat > Radio lists them), and the node actions' "Administer" (ui/nodes/node_actions.dart), through the real app state with a real
// companion link over the fake radio (and, for the negative cases, the plain fake link that cannot administer).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/radio/admin_password_vault.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/nodes/node_actions.dart';
import 'package:meshsonar/ui/nodes/node_ref.dart';
import 'package:meshsonar/ui/radios/admin_launcher.dart';

import '../../support/repeater_admin_fake.dart';
import '../fakes.dart';
import 'admin_rig.dart' show pumpUntilFound, repKey;

class _Scanner implements RadioScanner {
  final AdminFakeTransport t;
  _Scanner(this.t);
  @override
  Stream<List<RadioDevice>> scan({Duration timeout = const Duration(seconds: 8)}) => Stream.value(const [RadioDevice(id: 'sim', name: 'MeshCore-Fake')]);
  @override
  Future<ByteTransport> connect(RadioDevice device) async => t;
}

class AdminHarness extends Harness {
  late final FakeAdminRepeater rep = FakeAdminRepeater(key: repKey(), name: 'Hilltop');
  late final FakeAdminRepeater room = FakeAdminRepeater(key: Uint8List.fromList(List<int>.generate(32, (i) => 100 + i)), name: 'Valley Room', role: 'room');
  late final AdminFakeTransport transport = AdminFakeTransport({rep.keyHex: rep, room.keyHex: room});

  @override
  AppServices buildServices() {
    final s = super.buildServices();
    return AppServices(
      store: s.store,
      settingsStore: s.settingsStore,
      cmatClientFactory: s.cmatClientFactory,
      syncServiceFactory: s.syncServiceFactory,
      bluetoothScanner: s.bluetoothScanner,
      simulatorScanner: _Scanner(transport),
      linkFactory: (t) => MeshCoreCompanionLink(t, timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 250)),
      location: s.location,
      simulatedLocation: s.simulatedLocation,
      engineFactory: s.engineFactory,
      repeaterCache: s.repeaterCache,
      exportDir: s.exportDir,
      shareFile: s.shareFile,
      newId: s.newId,
      clock: s.clock,
      openUrl: s.openUrl,
      uiPrefsFile: s.uiPrefsFile,
      regionIndexCache: s.regionIndexCache,
      regionCatalogFetch: s.regionCatalogFetch,
    );
  }
}

void main() {
  setUp(() => setAdminVaultForTest(AdminPasswordVault()));
  tearDown(() => setAdminVaultForTest(null));

  testWidgets('"Administer" is dimmed with the reason without a radio and opens the admin login with one', (tester) async {
    useTallScreen(tester);
    final h = AdminHarness();
    await tester.runAsync(() => h.state.init());
    Widget host() => MeshSonarApp(state: h.state);
    await tester.pumpWidget(host());
    await tester.pump();
    final key = h.rep.keyHex;
    Future<void> showButton() async {
      await tester.pumpWidget(AppScope(state: h.state, child: MaterialApp(home: Scaffold(body: NodeActionBar(node: NodeRef(key: key, name: 'Hilltop', kind: NodeKind.repeater, source: NodeSource.network))))));
      await tester.pump();
    }

    await showButton();
    expect(find.byKey(const Key('node-action-admin')), findsOneWidget);
    expect(find.byKey(const Key('node-actions-reason')), findsOneWidget);
    expect(find.text(kNeedRadioReason), findsOneWidget, reason: 'Ping says it needs the radio first');
    await tester.tap(find.byKey(const Key('node-action-admin')));
    await tester.pump();
    expect(find.byKey(const Key('login-title')), findsNothing, reason: 'dimmed: says why, opens nothing');
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(() => h.state.connectSimulator());
    await showButton();
    expect(find.byKey(const Key('node-action-admin')), findsOneWidget);
    expect(find.byKey(const Key('node-actions-reason')), findsNothing);
    expect(tester.getSize(find.byKey(const Key('node-action-admin'))).height, greaterThanOrEqualTo(44));
    await tester.tap(find.byKey(const Key('node-action-admin')));
    await pumpUntilFound(tester, find.byKey(const Key('login-title')));
    expect(find.text('Hilltop'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => h.state.radioSession?.close() ?? Future<void>.value());
    await tester.pump(const Duration(seconds: 10));
  });
}
