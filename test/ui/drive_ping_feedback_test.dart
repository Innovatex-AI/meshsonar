// The Drive screen's "Last ping: heard by N repeaters, M observers confirmed" line.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/core/model.dart';

import 'fakes.dart';

void main() {
  testWidgets('after a ping: what the phone heard at once, nothing invented about observers', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settleLive(tester);
    expect(find.byKey(const Key('ping-feedback')), findsNothing, reason: 'no transmitted ping yet');
    h.state.debugOnPing(DrivePing(
        id: 'a',
        ts: DateTime.utc(2026, 11, 1),
        lat: 40,
        lon: -83,
        kind: PingKind.tx,
        echoes: [Echo(repeater: '11', hops: 1), Echo(repeater: '22', hops: 1), Echo(repeater: '33', hops: 2)]));
    await settleLive(tester);
    expect(tester.widget<Text>(find.byKey(const Key('ping-feedback'))).data,
        'Last ping: heard by 3 repeaters', reason: 'no driver key in this harness: nothing is uploaded, so no observer sentence');
    h.state.debugOnPing(DrivePing(id: 'b', ts: DateTime.utc(2026, 11, 1, 0, 1), lat: 40, lon: -83, kind: PingKind.tx));
    await settleLive(tester);
    expect(tester.widget<Text>(find.byKey(const Key('ping-feedback'))).data, startsWith('Last ping: no repeater heard it'));
    await h.state.stopDrive();
  });
}
