// The Map tab's dead-area chip: after 5 silent tx pings in a row during a drive, cleared by the next echo.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/core/model.dart';

import 'fakes.dart';

DrivePing tx(int i, {bool heard = false}) => DrivePing(
    id: 'p$i',
    ts: DateTime.utc(2026, 11, 1, 0, i),
    lat: 40,
    lon: -83,
    echoes: heard ? [Echo(repeater: '11', hops: 1)] : const []);

void main() {
  testWidgets('appears at 5 silent pings, keeps counting, clears on the next echo', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settleLive(tester);
    for (var i = 0; i < 4; i++) {
      h.state.debugOnPing(tx(i));
    }
    await settleLive(tester);
    expect(find.byKey(const Key('dead-area-chip')), findsNothing, reason: '4 silent pings is not yet a dead area');
    h.state.debugOnPing(tx(4));
    await settleLive(tester);
    expect(find.text('No repeaters heard for 5 pings'), findsOneWidget);
    h.state.debugOnPing(tx(5));
    await settleLive(tester);
    expect(find.text('No repeaters heard for 6 pings'), findsOneWidget);
    h.state.debugOnPing(tx(6, heard: true));
    await settleLive(tester);
    expect(find.byKey(const Key('dead-area-chip')), findsNothing);
    await h.state.stopDrive();
  });
}
