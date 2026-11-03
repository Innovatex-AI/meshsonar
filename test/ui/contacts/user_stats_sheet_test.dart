// WP8: the Stats sheet. A person who shares only battery, battery + location with distance, env sensors with a sparkline
// and auto refresh, withheld wording, timeout -> "No reply" card, radio away.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/remote_request_queue.dart';
import 'package:meshsonar/radio/tools/lpp.dart';
import 'package:meshsonar/radio/tools/telemetry_tool.dart';
import 'package:meshsonar/radio/tools/tool_frames.dart';
import 'package:meshsonar/ui/contacts/user_stats_sheet.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../chat/contact_support.dart';
import '../../support/tools_rig.dart';

class Rig {
  final radio = FakeToolsRadio();
  late final TelemetryTool tool;
  Rig({int maxWaitMs = 100}) {
    tool = TelemetryTool(radio, testArbiter(),
        waitSlack: Duration.zero, minWait: Duration.zero, maxWait: Duration(milliseconds: maxWaitMs), minGap: Duration.zero)
      ..queue = RemoteRequestQueue();
  }

  /// The contact answers with [lpp] (a list per request; the last repeats).
  void answers(Contact c, List<List<int>> lpp) {
    var i = 0;
    radio.onSend = (f) {
      final l = lpp[i < lpp.length ? i : lpp.length - 1];
      i++;
      scheduleMicrotask(() => radio.push(encodeTelemetryResponsePush(
          Uint8List.fromList([for (var k = 0; k < 6; k++) int.parse(c.publicKey.substring(k * 2, k * 2 + 2), radix: 16)]), l)));
      return const SentFrame(flood: false, tag: 1, estTimeoutMs: 50);
    };
  }
}

Future<void> pumpBody(WidgetTester tester, Contact c, TelemetryTool? t, {double? lat, double? lon, Duration auto = const Duration(seconds: 10)}) async {
  tester.view.physicalSize = const Size(393 * 3, 852 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: meshSonarTheme(Brightness.light),
    home: Scaffold(body: UserStatsBody(controller: ScrollController(), contact: c, telemetry: t, myLat: lat, myLon: lon, autoEvery: auto, lastHeardMs: 120000)),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  final maya = radioContact(1, name: 'Maya Chen');

  testWidgets('a person who shares only battery: battery shown, location and sensors named as not shared', (tester) async {
    final r = Rig()..answers(maya, [lppVoltage(3.92)]);
    await pumpBody(tester, maya, r.tool);
    expect(find.byKey(const Key('user-stats-sheet')), findsOneWidget);
    expect(find.text('Stats · Maya Chen'), findsOneWidget);
    expect(find.byKey(const Key('stats-battery')), findsOneWidget);
    expect(find.text('3.92 V'), findsOneWidget);
    expect(find.byKey(const Key('stats-position')), findsNothing);
    expect(find.byKey(const Key('stats-withheld')), findsOneWidget);
    expect(find.text("Maya's radio doesn't share location."), findsOneWidget);
    expect(find.text("Maya's radio doesn't share sensor readings."), findsOneWidget);
    expect(find.byKey(const Key('stats-auto')), findsNothing, reason: 'auto refresh is for sensors');
    expect(find.byKey(const Key('stats-route')), findsOneWidget);
    expect(find.text('Heard'), findsOneWidget);
  });

  testWidgets('battery + location: position row with distance, only sensors withheld', (tester) async {
    final r = Rig()..answers(maya, [[...lppVoltage(3.8), ...lppGps(39.9612, -82.9988, 250)]]);
    await pumpBody(tester, maya, r.tool, lat: 39.9812, lon: -82.9988);
    expect(find.byKey(const Key('stats-position')), findsOneWidget);
    expect(find.textContaining('39.96120, -82.99880'), findsOneWidget);
    expect(find.textContaining('2.2 km away'), findsOneWidget);
    expect(find.text("Maya's radio doesn't share location."), findsNothing);
    expect(find.text("Maya's radio doesn't share sensor readings."), findsOneWidget);
  });

  testWidgets('timeout: a No reply card (not a spinner), and Refresh asks again', (tester) async {
    final r = Rig(maxWaitMs: 60);
    r.radio.onSend = (f) => const SentFrame(flood: false, tag: 1, estTimeoutMs: 20);
    await tester.runAsync(() async {
      await pumpBody(tester, maya, r.tool);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(find.byKey(const Key('stats-no-reply')), findsOneWidget);
    expect(find.text('No reply'), findsOneWidget);
    expect(find.byKey(const Key('stats-waiting')), findsNothing);
    expect(find.byKey(const Key('stats-refresh')), findsOneWidget);
    r.answers(maya, [lppVoltage(3.6)]);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('stats-refresh')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.byKey(const Key('stats-no-reply')), findsNothing);
    expect(find.text('3.60 V'), findsOneWidget);
  });

  testWidgets('sensor: readings, history sparkline after refreshes, auto refresh switch', (tester) async {
    final s = radioContact(2, type: ContactType.sensor, name: 'Roof sensor');
    final r = Rig()..answers(s, [[...lppTemperature(18.5), ...lppHumidity(41)], [...lppTemperature(19.5), ...lppHumidity(40)], [...lppTemperature(19.0), ...lppHumidity(39)]]);
    await tester.runAsync(() async {
      await pumpBody(tester, s, r.tool, auto: const Duration(milliseconds: 80));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('18.5 °C'), findsOneWidget);
    expect(find.textContaining("doesn't share"), findsNothing, reason: 'a sensor has nothing "withheld"');
    expect(find.byKey(const Key('stats-spark-temperature-1')), findsNothing, reason: 'one point is not a line');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('stats-auto')));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    expect(find.byKey(const Key('stats-spark-temperature-1')), findsOneWidget);
    expect(seriesOf(r.tool.historyFor(s.publicKey), LppKind.temperature).length, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox()); // dispose cancels the timer
  });

  testWidgets('radio away: says so, no Refresh button', (tester) async {
    await pumpBody(tester, maya, null);
    expect(find.byKey(const Key('stats-disconnected')), findsOneWidget);
    expect(find.byKey(const Key('stats-refresh')), findsNothing);
  });

  test('sparklinePoints: scales to the box, flat is the centre line, <2 points is empty', () {
    expect(sparklinePoints(const [1], 60, 20), isEmpty);
    expect(sparklinePoints(const [5, 5, 5], 60, 20).map((p) => p.dy), [10, 10, 10]);
    final p = sparklinePoints(const [0, 10, 5], 60, 20);
    expect(p.first, const Offset(0, 20));
    expect(p[1], const Offset(30, 0));
    expect(p.last, const Offset(60, 10));
  });
}
