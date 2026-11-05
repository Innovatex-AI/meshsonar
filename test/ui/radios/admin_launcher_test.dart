// The admin launcher (the Repeaters screen is retired; Chat > Network lists them), and the "Administer this repeater" button, through the real app state with a real
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
import 'package:meshsonar/ui/radios/admin_launcher.dart';
import 'package:meshsonar/ui/radios/rooms/room_join_header.dart';

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

  testWidgets('the repeater sheet button is hidden without a capable radio and opens the admin login with one', (tester) async {
    useTallScreen(tester);
    final h = AdminHarness();
    await tester.runAsync(() => h.state.init());
    Widget host() => MeshSonarApp(state: h.state);
    await tester.pumpWidget(host());
    await tester.pump();
    final key = h.rep.keyHex;
    Future<void> showButton() async {
      await tester.pumpWidget(AppScope(state: h.state, child: MaterialApp(home: Scaffold(body: AdminRepeaterButton(keyHex: key, name: 'Hilltop')))));
      await tester.pump();
    }

    await showButton();
    expect(find.byKey(const Key('admin-this-repeater')), findsNothing);
    await tester.runAsync(() => h.state.connectSimulator());
    await showButton();
    expect(find.byKey(const Key('admin-this-repeater')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('admin-this-repeater'))).height, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const Key('admin-this-repeater')));
    await pumpUntilFound(tester, find.byKey(const Key('admin-login')));
    expect(find.text('Log in to Hilltop'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => h.state.radioSession?.close() ?? Future<void>.value());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a room conversation in Chat shows a join header: wrong password is plain silence, the room password joins', (tester) async {
    useTallScreen(tester);
    RoomJoins.clear();
    final h = AdminHarness();
    await tester.runAsync(() => h.state.init());
    await tester.pumpWidget(MeshSonarApp(state: h.state));
    await tester.pump();
    await tester.runAsync(() => h.state.connectSimulator());
    final key = h.room.keyHex;
    await tester.pumpWidget(AppScope(state: h.state, child: MaterialApp(home: Scaffold(body: RoomJoinHeader(keyHex: key, name: 'Valley Room')))));
    expect(find.text('A room only sends its posts to radios that have joined it.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('room-join-open')));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('room-join-go'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('room-join-password')), 'nope');
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-join-go')));
    await pumpUntilFound(tester, find.byKey(const Key('room-join-error')));
    expect(find.textContaining('No answer'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('room-join-password')), 'guest');
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-join-go')));
    await pumpUntilFound(tester, find.byKey(const Key('room-joined')));
    expect(find.text('Joined'), findsOneWidget);
    expect(RoomJoins.of(key)!.canPost, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => h.state.radioSession?.close() ?? Future<void>.value());
    await tester.pump(const Duration(seconds: 10));
  });
}
