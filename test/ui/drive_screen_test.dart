import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/device_feedback.dart';
import 'package:meshsonar/ui/theme.dart';
import 'package:meshsonar/ui/widgets.dart';

import 'fakes.dart';

class FakeFeedback implements DeviceFeedback {
  final List<bool> awake = [];
  final List<bool> pings = [];
  @override
  Future<void> keepAwake(bool on) async => awake.add(on);
  @override
  Future<void> pingResult({required bool heard}) async => pings.add(heard);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 20));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  late FakeFeedback fb;
  setUp(() {
    fb = FakeFeedback();
    DeviceFeedbackScope.fallback = fb;
  });
  tearDown(() => DeviceFeedbackScope.fallback = const NoDeviceFeedback());

  testWidgets('screen is kept awake while driving only; each ping gives feedback', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    expect(fb.awake, isEmpty);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settle(tester);
    expect(fb.awake, [true]);

    h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1', snrDb: 3)]));
    await settle(tester);
    h.engines.single.emit(silentPing('p2'));
    await settle(tester);
    expect(fb.pings, [true, false]);
    expect(find.byKey(const Key('ping-flash')), findsOneWidget);

    await h.state.stopDrive();
    await settle(tester);
    expect(fb.awake, [true, false]);
    await drain(tester);
  });

  testWidgets('drive pings land on the map coloured by result; stats show last SNR', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    h.engines.single.emit(heardPing('good', const [Echo(repeater: 'a1', snrDb: 12)]));
    await settle(tester);
    h.engines.single.emit(silentPing('bad'));
    await settle(tester);

    final c = MeshSonarColors.of(tester.element(find.byKey(const Key('drive-map'))));
    Color dot(String id) =>
        (tester.widget<DecoratedBox>(find.byKey(ValueKey('map-ping-$id'))).decoration as BoxDecoration).color!;
    expect(dot('good'), c.snrStrong);
    expect(dot('bad'), c.silent);
    expect(tester.widget<Text>(find.byKey(const Key('stat-snr'))).data, 'none');

    h.engines.single.emit(heardPing('ok', const [Echo(repeater: 'a1', snrDb: 4.25)]));
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(const Key('stat-snr'))).data, '+4.3');
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('shows the next auto-ping countdown while driving', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settle(tester);
    expect(find.byKey(const Key('next-ping-countdown')), findsNothing);

    // Harness clock is fixed at 18:00:00; next ping due 23 s later.
    h.engines.single.setStatus(EngineStatus(EngineState.driving, nextPingAt: DateTime.utc(2026, 10, 16, 18, 0, 23)));
    await settle(tester);
    expect(find.byKey(const Key('next-ping-countdown')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('next-ping-seconds'))).data, '23');
    expect(find.text('Driving. Next ping in 23s.'), findsOneWidget);

    // While listening the countdown hides.
    h.engines.single.setStatus(const EngineStatus(EngineState.pinging));
    await settle(tester);
    expect(find.byKey(const Key('next-ping-countdown')), findsNothing);

    await h.state.stopDrive();
    await settle(tester);
    expect(find.byKey(const Key('next-ping-countdown')), findsNothing);
    await drain(tester);
  });

  testWidgets('discovery mode: Ping now is hidden (not just disabled) and the map hint says Listening',
      (tester) async {
    useTallScreen(tester);
    final h = Harness()..settings.saved = const Settings().copyWith(discoveryMode: true);
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settle(tester);

    expect(h.engines.single.config!.listenOnly, isTrue);
    expect(find.byKey(const Key('ping-now')), findsNothing);
    expect(find.byKey(const Key('start-stop')), findsOneWidget);
    expect(find.text('Listening'), findsOneWidget);
    expect(find.textContaining('Nothing is transmitted'), findsOneWidget);

    await h.state.stopDrive();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('a normal (non-discovery) drive still shows Ping now and ping-oriented hints', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settle(tester);

    expect(h.engines.single.config!.listenOnly, isFalse);
    expect(find.byKey(const Key('ping-now')), findsOneWidget);
    expect(find.text('Waiting for the first ping'), findsOneWidget);

    await h.state.stopDrive();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('empty state: hint over the map tells you what to do', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    expect(find.byKey(const Key('drive-map')), findsOneWidget);
    expect(find.byKey(const Key('map-hint')), findsOneWidget);
    expect(find.textContaining('try the Simulator'), findsOneWidget);
    // Start/Stop sits below the map (thumb reach).
    final mapBottom = tester.getBottomLeft(find.byKey(const Key('drive-map'))).dy;
    expect(tester.getTopLeft(find.byKey(const Key('start-stop'))).dy, greaterThan(mapBottom));
  });

  test('signal bars from RSSI', () {
    expect(SignalBars.barsFor(null), 0);
    expect(SignalBars.barsFor(-50), 4);
    expect(SignalBars.barsFor(-62), 3);
    expect(SignalBars.barsFor(-75), 2);
    expect(SignalBars.barsFor(-91), 0);
    expect(SignalBars.barsFor(-85), 1);
  });

  testWidgets('connect screen shows signal bars per radio', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('connection-chip')));
    await tester.pumpAndSettle();
    expect(find.text('Nearby radios'), findsOneWidget);
    expect(find.byKey(const ValueKey('signal-bars-3')), findsOneWidget); // -62
    expect(find.byKey(const ValueKey('signal-bars-0')), findsOneWidget); // -91
    expect(h.state.driving, isFalse);
    expect(AppState, isNotNull);
  });
}
