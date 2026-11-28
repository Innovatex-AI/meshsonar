// Build 77 (redesign round 5 R2, R3): the Connect screen's Bluetooth-off and failed-connect advice.
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/connect_screen.dart';

import 'fakes.dart';

Future<Harness> _open(WidgetTester tester, void Function(Harness h) setUp) async {
  useTallScreen(tester);
  final h = Harness();
  setUp(h);
  await h.state.init();
  await tester.pumpWidget(AppScope(state: h.state, child: const MaterialApp(home: ConnectScreen())));
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets('Bluetooth off: says where to turn it on, no "Open Settings", one Scan again, and scans again on return', (tester) async {
    final h = await _open(tester, (h) => h.bt.scanError = Exception('Bluetooth adapter is off'));
    expect(find.textContaining('Turn it on in Control Centre'), findsNothing, reason: 'the test platform is Android');
    expect(find.textContaining('Bluetooth is off. Turn it on in Quick Settings'), findsOneWidget);
    expect(find.byKey(const Key('open-app-settings')), findsNothing, reason: 'the app\'s own settings page cannot turn Bluetooth on');
    expect(find.text('Scan again'), findsOneWidget, reason: 'one Scan again, in the Nearby radios header');
    expect(find.byKey(const Key('scan-retry')), findsNothing);

    // Back from Control Centre with Bluetooth on: the scan runs by itself.
    h.bt.scanError = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.textContaining('Bluetooth is off'), findsNothing);
    expect(find.byKey(ValueKey('device-${h.bt.devices.first.id}')), findsOneWidget);
  });

  testWidgets('Bluetooth off on iPhone: Control Centre', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await _open(tester, (h) => h.bt.scanError = Exception('Bluetooth is powered off'));
    expect(find.textContaining('Bluetooth is off. Turn it on in Control Centre, then come back'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('permission refused: Open Settings stays (it is the right place), still one Scan again', (tester) async {
    await _open(tester, (h) => h.bt.scanError = Exception('Bluetooth permission denied'));
    expect(find.byKey(const Key('open-app-settings')), findsOneWidget);
    expect(find.text('Scan again'), findsOneWidget);
  });

  testWidgets('a failed connect names the wrong-PIN / old-pairing fix under the usual cause', (tester) async {
    final h = await _open(tester, (h) => h.bt.connectError = Exception('pairing failed'));
    await tester.tap(find.byKey(ValueKey('device-${h.bt.devices.first.id}')));
    await tester.pumpAndSettle();
    expect(h.state.connected, isFalse);
    expect(find.byKey(const Key('connect-error-tip')), findsOneWidget);
    expect(find.text(connectFailedTip), findsOneWidget);
    expect(find.byKey(const Key('connect-error-pairing')), findsOneWidget);
    expect(find.text(connectPairingTipAndroid), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('connect-error-pairing'))).dy,
        greaterThan(tester.getTopLeft(find.byKey(const Key('connect-error-tip'))).dy));
    expect(connectPairingTip, 'Wrong PIN or paired before? iPhone Settings > Bluetooth > (i) > Forget This Device, then try again.');
  });
}
