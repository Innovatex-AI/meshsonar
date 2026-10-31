import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/rf_thresholds.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/tools/radio_tools.dart';
import 'package:meshsonar/radio/session.dart' show LinkState;
import 'package:meshsonar/ui/tools/noise_screen.dart';

import '../../support/tools_rig.dart';
import '../../support/tools_ui_rig.dart';

/// A phone tall enough to build the whole list (a ListView builds only what is near the screen).
void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 2600 * 3);
}

/// Buttons and rows are at least 48 px, except the shared ChartFrame Chart/Table switch, whose segments are 40 px tall but
/// padded to a 48 px hit area (MaterialTapTargetSize.padded).
void targets(WidgetTester tester) {
  final small = <String>[];
  final toggle = find.byKey(const Key('chart-noise-toggle'));
  for (final e in find.byWidgetPredicate((w) => w is ButtonStyleButton || w is ListTile).evaluate()) {
    final f = find.byElementPredicate((x) => identical(x, e));
    if (toggle.evaluate().isNotEmpty && find.descendant(of: toggle, matching: f).evaluate().isNotEmpty) continue;
    final w = e.widget;
    if (w is ButtonStyleButton && !w.enabled) continue;
    final size = tester.getSize(f);
    if (size.height < 47.5 || size.width < 47.5) small.add('${w.runtimeType} $size');
  }
  expect(small, isEmpty);
}

Future<void> leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

/// A host on a scripted radio: exact numbers, microtask-fast.
(FakeToolsRadio, RadioTools, FakeToolsHost) scripted(int Function() noise, {int rssi = -100}) {
  final fake = FakeToolsRadio()..stats = () => RadioStatsFrame(noise(), rssi, 2.5, 7, 9);
  fake.core = const CoreStatsFrame(batteryMv: 3900, uptimeSecs: 100, errFlags: 0, queueLen: 2);
  fake.packets = const PacketStatsFrame(recv: 5, sent: 4, floodTx: 1, directTx: 1, floodRx: 1, directRx: 1, recvErrors: 3);
  final tools = RadioTools(fake, testArbiter());
  final host = FakeToolsHost()..toolsValue = tools;
  return (fake, tools, host);
}

Future<void> sample(WidgetTester tester, RadioTools tools, [int n = 1]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => tools.noise.sampleNow());
  }
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('no radio: the gate, not an empty screen', (tester) async {
    final host = FakeToolsHost()..linkState = LinkState.disconnected;
    await pumpTool(tester, const NoiseScreen(), host);
    expect(find.byKey(const Key('tool-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('noise-list')), findsNothing);
  });

  testWidgets('real simulated radio: the first reading appears, Quiet at -112, tiles and counters filled', (tester) async {
    final (rig, host) = await connectedRig(tester, noiseFloorDbm: -112);
    await pumpTool(tester, const NoiseScreen(), host);
    tall(tester);
    expect(find.byKey(const Key('noise-waiting')), findsOneWidget);
    await settleReal(tester);
    expect(rig.tools.noise.samples, isNotEmpty);
    expect(find.byKey(const Key('noise-waiting')), findsNothing);
    expect(find.text('Quiet'), findsOneWidget);
    expect(find.byKey(const Key('noise-tiles')), findsOneWidget);
    expect(find.textContaining('Noise floor looks healthy'), findsOneWidget);
    expect(find.textContaining('Same thresholds as the website'), findsOneWidget);
    expect(find.byKey(const Key('noise-sampling-note')), findsOneWidget);
    expect(find.byKey(const Key('noise-flags-none')), findsOneWidget);
    expect(find.textContaining('packets waiting to send'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('Noisy at -95 shows the website text; Raised at -105; stats tiles carry the numbers', (tester) async {
    var v = -95;
    final (_, tools, host) = scripted(() => v);
    await pumpTool(tester, const NoiseScreen(), host);
    tall(tester);
    await sample(tester, tools, 3);
    expect(find.text('Noisy'), findsOneWidget);
    expect(find.text(noiseVerdictText(NoiseVerdict.interference)), findsOneWidget);
    expect(find.text('-95 dBm'), findsNWidgets(3), reason: 'lowest, average, highest');
    expect(find.text('${tools.noise.samples.length}'), findsOneWidget, reason: 'readings');
    tools.noise.clear();
    v = -105;
    await sample(tester, tools, 2);
    expect(find.text('Raised'), findsOneWidget);
    expect(find.text(noiseVerdictText(NoiseVerdict.elevated)), findsOneWidget);
    await leave(tester);
  });

  testWidgets('a floor of 0 is "not measured yet", never 0 dBm', (tester) async {
    final (_, tools, host) = scripted(() => 0);
    await pumpTool(tester, const NoiseScreen(), host);
    tall(tester);
    await sample(tester, tools, 2);
    expect(find.byKey(const Key('noise-unmeasured')), findsOneWidget);
    expect(find.byKey(const Key('noise-tiles')), findsNothing);
    expect(find.text('0 dBm'), findsNothing);
    await leave(tester);
  });

  testWidgets('firmware without stats: the unsupported note', (tester) async {
    final fake = FakeToolsRadio()..stats = () => null;
    final tools = RadioTools(fake, testArbiter());
    final host = FakeToolsHost()..toolsValue = tools;
    await pumpTool(tester, const NoiseScreen(), host);
    await sample(tester, tools, 4);
    expect(find.byKey(const Key('noise-unsupported')), findsOneWidget);
    expect(find.textContaining('needs version 8 or newer'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('chart summary is one semantics label with the numbers; spikes are announced; table view lists readings', (tester) async {
    final sem = tester.ensureSemantics();
    var i = 0;
    final (_, tools, host) = scripted(() => i == 9 ? -90 : -112 + (i % 2));
    await pumpTool(tester, const NoiseScreen(), host);
    for (i = 0; i < 12; i++) {
      await sample(tester, tools);
    }
    expect(find.bySemanticsLabel(RegExp(r'^Noise floor\. Noise floor averaged -11\d dBm over .* \(lowest -112, highest -90\)\. .*1 spike\.')), findsOneWidget);
    await tester.tap(find.text('Table'));
    await tester.pump();
    expect(find.byKey(const Key('chart-noise-table')), findsOneWidget);
    await leave(tester);
    sem.dispose();
  });

  testWidgets('error flags and receive errors are put in words', (tester) async {
    final (fake, tools, host) = scripted(() => -110);
    fake.core = const CoreStatsFrame(batteryMv: 3900, uptimeSecs: 1, errFlags: RadioErrFlag.queueFull | RadioErrFlag.cadTimeout, queueLen: 1);
    await pumpTool(tester, const NoiseScreen(), host);
    tall(tester);
    await sample(tester, tools);
    expect(find.byKey(const Key('noise-flags')), findsOneWidget);
    expect(find.textContaining('send queue filled up'), findsOneWidget);
    expect(find.textContaining('timed out'), findsOneWidget);
    expect(find.textContaining('with errors since boot: 3'), findsOneWidget);
    expect(find.textContaining('1 packet waiting to send'), findsOneWidget);
    expect(noiseErrorWords(0), isEmpty);
    await leave(tester);
  });

  testWidgets('interval chooser sets the monitor; sampling starts on open and stops on leaving', (tester) async {
    final (_, tools, host) = scripted(() => -110);
    await pumpTool(tester, const NoiseScreen(), host);
    await tester.pump();
    expect(tools.noise.running, isTrue);
    await tester.tap(find.text('30 s'));
    await tester.pump();
    expect(tools.noise.interval, const Duration(seconds: 30));
    expect(tools.noise.running, isTrue);
    await leave(tester);
    expect(tools.noise.running, isFalse);
  });

  testWidgets('own airtime card: numbers from the ledger and the honest 1% note', (tester) async {
    final (_, tools, host) = scripted(() => -110);
    tools.arbiter.admitUserSend(300);
    await pumpTool(tester, const NoiseScreen(), host);
    tall(tester);
    await sample(tester, tools);
    expect(find.text('0.3 s of 36 s used in the last hour (0.8%)'), findsOneWidget);
    expect(find.textContaining('not legal advice'), findsOneWidget);
    expect(find.textContaining('1 message sent this session'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('clear empties the readings', (tester) async {
    final (_, tools, host) = scripted(() => -110);
    await pumpTool(tester, const NoiseScreen(), host);
    tall(tester);
    await sample(tester, tools, 2);
    expect(find.byKey(const Key('noise-tiles')), findsOneWidget);
    await tester.tap(find.byKey(const Key('noise-clear')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tools.noise.samples, isEmpty);
    expect(find.byKey(const Key('noise-waiting')), findsOneWidget);
    await leave(tester);
  });

  testWidgets('every look: no overflow at 2.5x text, small phone, tablet, dark; targets >= 48', (tester) async {
    final (_, tools, host) = scripted(() => -100);
    tools.arbiter.admitUserSend(800);
    var k = 0;
    for (k = 0; k < 10; k++) {
      await tester.runAsync(() => tools.noise.sampleNow());
    }
    await forEachLook(tester, () => const NoiseScreen(), () => host, (t) async {
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('noise-list')), findsOneWidget);
      targets(t);
      await t.drag(find.byKey(const Key('noise-list')), const Offset(0, -4000));
      await t.pump();
      expect(find.byKey(const Key('noise-clear')), findsOneWidget);
      targets(t);
    });
    await leave(tester);
  });
}
