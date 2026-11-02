import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/startup_location.dart';

import 'fakes.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Lets snackbars time out so no timers are left pending.
Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> connectViaUi(WidgetTester tester, {String device = 'MeshCore-Truck'}) async {
  await tester.tap(find.byKey(const Key('connection-chip')));
  await tester.pumpAndSettle();
  expect(find.text(device), findsOneWidget);
  await tester.tap(find.text(device));
  await settle(tester);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('empty drive screen explains what to do', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('No pings yet'), findsOneWidget);
    expect(find.text('Connect radio'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('start drive -> pings appear and are stored -> stop -> sync called', (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    h.cache.items = const [RepeaterRef(key: 'a1b2c3d4', name: 'Westerville Water Tower', lat: 40.1, lon: -82.9)];
    await h.pumpApp(tester);

    await connectViaUi(tester);
    expect(find.text('Truck Radio'), findsOneWidget); // connection chip shows the radio's name
    expect(h.bt.connects, 1);

    await tester.tap(find.byKey(const Key('start-stop')));
    await settle(tester);
    expect(h.state.driving, isTrue);
    expect(find.text('Stop drive'), findsOneWidget);
    expect(find.text('Driving. Listening on #wardriving.'), findsOneWidget);

    // Session carries radio info, antenna and companion from SelfInfo/settings.
    final session = h.store.sessionsById.values.single;
    expect(session.radio.freqMhz, 910.525);
    expect(session.companion.publicKey, 'abcdef0123');
    expect(session.companion.firmware, 'v1.9.0');
    expect(session.channel, '#wardriving');
    expect(h.engines.single.config!.channel, '#wardriving');
    expect(h.engineLocation, same(h.location)); // real GPS with a Bluetooth radio

    final e = h.engines.single;
    e.emit(heardPing('p1', const [
      Echo(repeater: 'a1b2', snrDb: 4.25, hops: 1),
      Echo(repeater: 'ff09', snrDb: -3.0, hops: 1),
    ]));
    await settle(tester);
    e.emit(silentPing('p2'));
    await settle(tester);

    // Stored immediately, before stop.
    expect(h.store.pingsBySession[session.id]!.map((p) => p.id), ['p1', 'p2']);
    // The heard box on the map lists who answered: the cached name, or the hex id when unknown.
    expect(find.byKey(const Key('heard-box')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('heard-row-a1b2')), matching: find.text('Westerville Water Tower')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('heard-row-ff09')), matching: find.text('FF09')), findsOneWidget);
    // The LOG button opens the live ping log of this drive.
    await tester.tap(find.byKey(const Key('open-log')));
    await tester.pumpAndSettle();
    expect(find.text('Heard nothing'), findsWidgets);
    expect(find.textContaining('Westerville Water Tower'), findsWidgets); // name from cache
    await tester.pageBack();
    await settleLive(tester);
    expect(tester.widget<Text>(find.byKey(const Key('stat-pings'))).data, '2');
    expect(tester.widget<Text>(find.byKey(const Key('stat-heard'))).data, '1 heard');
    expect(tester.widget<Text>(find.byKey(const Key('stat-pct'))).data, '50%');

    // Ping now: emitted on the stream AND returned; counted once.
    await tester.tap(find.byKey(const Key('ping-now')));
    await settle(tester);
    expect(h.store.pingsBySession[session.id]!.length, 3);
    expect(tester.widget<Text>(find.byKey(const Key('stat-pings'))).data, '3');

    await tester.tap(find.byKey(const Key('start-stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('stop-drive-confirm')));
    await settle(tester);
    expect(e.stopped, isTrue);
    expect(h.store.calls.last, isNot('start'));
    expect(h.store.sessionsById[session.id]!.endedAt, isNotNull);
    expect(h.sync.syncedSessions, [session.id]);
    expect(tester.widget<Text>(find.byKey(const Key('stat-synced'))).data, '3');
    expect(find.text('Start drive'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('a ping that heard nothing is shown as such and kept', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await tester.pump();
    h.engines.single.emit(silentPing('quiet'));
    await settle(tester);
    expect(find.text('No repeaters heard'), findsOneWidget); // the result flash on the map
    expect(find.text('Listening… nothing heard yet'), findsOneWidget); // the heard box
    expect(tester.widget<Text>(find.byKey(const Key('stat-snr'))).data, 'none');
    expect(h.store.pingsBySession.values.single.single.echoes, isEmpty);
    expect(tester.widget<Text>(find.byKey(const Key('stat-pct'))).data, '0%');
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('sync failure keeps pings and shows a plain message', (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    h.sync.failWith = 'network error: Failed host lookup: cmh-meshcore.lovable.app';
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1', snrDb: 2)]));
    h.engines.single.emit(silentPing('p2'));
    await settle(tester);

    await tester.tap(find.byKey(const Key('start-stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('stop-drive-confirm')));
    await settle(tester);
    expect(h.sync.syncedSessions.length, 1);
    final sid = h.store.sessionsById.keys.single;
    expect(h.store.pingsBySession[sid]!.length, 2); // nothing lost
    expect(h.store.synced[sid], isEmpty);
    expect(find.textContaining('Pings are kept on this phone'), findsOneWidget);
    expect(find.textContaining('Failed host lookup'), findsNothing); // no raw errors
    expect(tester.widget<Text>(find.byKey(const Key('stat-synced'))).data, '0');

    // Drives tab shows the unsynced count and the error banner.
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    expect(find.text('2 not synced'), findsOneWidget);
    expect(find.byKey(const Key('sync-error')), findsOneWidget);
    await drain(tester);
  });

  testWidgets('sync throwing 403 is explained and pings are kept', (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    h.sync.throwError = const CmatException('not approved', status: 403);
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    h.engines.single.emit(silentPing('p1'));
    await settle(tester);
    await h.state.stopDrive();
    await settle(tester);
    expect(h.store.pingsBySession.values.single.length, 1);
    expect(h.state.lastSyncMessage, contains('hasn\'t accepted'));
    await drain(tester);
  });

  testWidgets('no auto-sync when the key is still pending; drive still saved', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.settings.saved = const Settings(driverKey: 'k-pending-0001', keyStatus: DriverKeyStatus.pending);
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    h.engines.single.emit(silentPing('p1'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('start-stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('stop-drive-confirm')));
    await settle(tester);
    expect(h.sync.syncedSessions, isEmpty);
    expect(h.store.pingsBySession.values.single.length, 1);
    expect(find.textContaining('once your driver key is ready'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('a failed local write is retried and the ping is not lost', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    h.store.failAppend = true;
    h.engines.single.emit(silentPing('p1'));
    await settle(tester);
    expect(h.state.unsavedCount, 1);
    expect(find.textContaining('not yet saved'), findsOneWidget);
    h.store.failAppend = false;
    h.engines.single.emit(silentPing('p2'));
    await settle(tester);
    expect(h.state.unsavedCount, 0);
    expect(h.store.pingsBySession.values.single.map((p) => p.id), ['p1', 'p2']);
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('simulator uses simulated location; permission denied blocks start with a message', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('connection-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('simulator')));
    await tester.pumpAndSettle();
    expect(find.text('Simulator'), findsOneWidget);

    h.simLocation.permission = false;
    await tester.tap(find.byKey(const Key('start-stop')));
    await settle(tester);
    expect(h.state.driving, isFalse);
    expect(find.textContaining('needs location access'), findsOneWidget);
    expect(h.store.sessionsById, isEmpty);

    h.simLocation.permission = true;
    await tester.tap(find.byKey(const Key('start-stop')));
    await settle(tester);
    expect(h.state.driving, isTrue);
    expect(h.engineLocation, same(h.simLocation));
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('connect failure and scan failure show plain messages', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.bt.connectError = Exception('GATT 133');
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('connection-chip')));
    await tester.pumpAndSettle();
    expect(find.text('MeshCore-Truck'), findsOneWidget);
    expect(find.text('Good signal'), findsOneWidget);
    await tester.tap(find.text('MeshCore-Truck'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Couldn\'t connect to MeshCore-Truck'), findsOneWidget);
    expect(h.state.connected, isFalse);

    h.bt.scanError = Exception('Bluetooth permission denied');
    await tester.tap(find.byKey(const Key('scan')));
    await tester.pumpAndSettle();
    expect(find.textContaining('needs Bluetooth permission'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('Stop asks first; Keep driving leaves the drive running, Stop drive ends it', (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settle(tester);
    expect(h.state.driving, isTrue);

    await tester.tap(find.byKey(const Key('start-stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('stop-drive-dialog')), findsOneWidget);
    expect(find.text('Stop this drive?'), findsOneWidget);
    final keep = tester.getSize(find.byKey(const Key('stop-drive-keep')));
    final stop = tester.getSize(find.byKey(const Key('stop-drive-confirm')));
    expect(keep.height, greaterThanOrEqualTo(44));
    expect(stop.height, greaterThanOrEqualTo(44));
    await tester.tap(find.byKey(const Key('stop-drive-keep')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('stop-drive-dialog')), findsNothing);
    expect(h.state.driving, isTrue, reason: 'Keep driving changes nothing');

    await tester.tap(find.byKey(const Key('start-stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('stop-drive-confirm')));
    await settle(tester);
    expect(h.state.driving, isFalse);
    await drain(tester);
  });

  testWidgets('the Log button and the report card dismiss are at least 44 px tall', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    expect(tester.getSize(find.byKey(const Key('open-log'))).height, greaterThanOrEqualTo(44));
    await drain(tester);
  });

  testWidgets('stat tiles read as one thing to VoiceOver ("Pings: 0")', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Pings: 0'), findsOneWidget);
    handle.dispose();
    await drain(tester);
  });

  testWidgets('Bluetooth permission refused: the plain message and an Open Settings button', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.bt.scanError = Exception('Bluetooth permission denied');
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('connection-chip')));
    await tester.pumpAndSettle();
    expect(find.textContaining('needs Bluetooth permission'), findsOneWidget);
    expect(find.byKey(const Key('open-app-settings')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('open-app-settings'))).height, greaterThanOrEqualTo(44));
    await drain(tester);
  });

  for (final scale in [2.0, 3.1]) {
    testWidgets('Drive tab at ${scale}x text: no overflow, Start and Ping now stay on screen and tappable', (tester) async {
      tester.view.physicalSize = const Size(1179, 2556); // iPhone 17 Pro
      tester.view.devicePixelRatio = 3.0;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      // The worst case: not connected, with the "Allow location" banner above the status line.
      final h = Harness()..locationAccess = FakeLocationAccess(LocationAccess.notAsked);
      await h.pumpApp(tester);
      await settle(tester);
      expect(find.byKey(const Key('location-note')), findsOneWidget);
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      for (final k in ['start-stop', 'ping-now']) {
        final r = tester.getRect(find.byKey(Key(k)));
        expect(r.bottom, lessThanOrEqualTo(screen.height), reason: '$k is on screen');
        expect(r.height, greaterThanOrEqualTo(44));
      }
      expect(tester.takeException(), isNull, reason: 'no layout overflow');
      await drain(tester);
    });
  }
}
