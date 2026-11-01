import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_timing.dart';
import 'package:meshsonar/core/gps_health.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/ui/drive/drive_timing_card.dart';
import 'package:meshsonar/ui/drive/gps_health_banner.dart';

Widget host(Widget child, {double textScale = 1}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: const Size(360, 800), textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

GpsHealth h(Duration since, {Duration? age, double? acc, bool usable = true, LocationAccess access = LocationAccess.granted, BackgroundLocation bg = BackgroundLocation.notApplicable}) =>
    computeGpsHealth(sinceStart: since, fixAge: age, accuracyM: acc, haveUsableFix: usable, access: access, background: bg);

void main() {
  testWidgets('each state shows its plain-English line; idle and good-without-advice can be hidden', (tester) async {
    final cases = <GpsHealth, String>{
      h(const Duration(seconds: 12), usable: false): 'Waiting for GPS (12 s)',
      h(const Duration(minutes: 1), age: const Duration(seconds: 1), acc: 47): 'GPS weak (47 m)',
      h(const Duration(minutes: 1), age: const Duration(seconds: 9), acc: 5): 'No GPS for 9 s',
      h(const Duration(minutes: 1), age: const Duration(seconds: 1), acc: 5): 'GPS good (5 m)',
      h(const Duration(seconds: 3), usable: false, access: LocationAccess.approximate): 'Precise Location is off.',
    };
    for (final e in cases.entries) {
      await tester.pumpWidget(host(GpsHealthView(health: e.key)));
      expect(find.text(e.value), findsOneWidget, reason: e.value);
    }
    await tester.pumpWidget(host(const GpsHealthView(health: GpsHealth.idle)));
    expect(find.byKey(const Key('gps-health-line')), findsNothing);
    await tester.pumpWidget(host(GpsHealthView(health: h(const Duration(minutes: 1), age: const Duration(seconds: 1), acc: 5), showWhenGood: false)));
    expect(find.byKey(const Key('gps-health-line')), findsNothing);
  });

  testWidgets('Precise Location off: the advice and an Open Settings button that calls back; fits at 2x text on a phone', (tester) async {
    var opened = 0;
    await tester.pumpWidget(host(
      GpsHealthView(health: h(const Duration(seconds: 3), usable: false, access: LocationAccess.approximate), onAction: () => opened++),
      textScale: 2,
    ));
    expect(find.textContaining('Settings > MeshSonar > Location'), findsOneWidget);
    await tester.tap(find.byKey(const Key('gps-health-action')));
    expect(opened, 1);
    expect(tester.getSize(find.byKey(const Key('gps-health-action'))).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('While Using shows the Always advice, spoken as one phrase for VoiceOver', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(GpsHealthView(
        health: h(const Duration(minutes: 1), age: const Duration(seconds: 1), acc: 5, bg: BackgroundLocation.whileUsing))));
    expect(find.textContaining('While Using'), findsOneWidget);
    expect(tester.getSemantics(find.byType(GpsHealthView)).label, startsWith('GPS. GPS good (5 m) Location is set to While Using'));
    handle.dispose();
  });

  testWidgets('the timing card says sent vs expected, gaps, lateness and what held pings back', (tester) async {
    const s = DriveTimingSummary(
      sent: 79,
      expected: 80,
      gapP50S: 15,
      gapP95S: 15,
      gapMaxS: 21,
      lateP50S: 0,
      lateMaxS: 6,
      firstPingS: 2.5,
      skipped: {'no_fix': 3, 'distance': 2},
      lowAccuracyPings: 12,
    );
    await tester.pumpWidget(host(const DriveTimingView(summary: s, over: '164 ft'), textScale: 2));
    expect(find.text('Sent 79 of 80 expected. typical gap 15 s, worst 21 s'), findsOneWidget);
    expect(find.textContaining('Held back: 3x waiting for GPS, 2x waiting to move'), findsOneWidget);
    expect(find.textContaining('12 pings were sent from a GPS fix worse than 164 ft'), findsOneWidget);
    expect(find.textContaining('First ping after 2.5 s'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
