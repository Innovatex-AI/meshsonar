import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/ping_detail_sheet.dart';
import 'package:meshsonar/ui/ping_log_screen.dart';
import 'package:meshsonar/ui/repeater_widgets.dart';

import 'fakes.dart';

String k(String p) => p.padRight(64, '0');

const polaris = RepeaterRef(key: 'df01aa0000000000', name: 'Polaris Tower', lat: 40.145, lon: -82.984);

DrivePing at(String id, int sec, List<Echo> echoes, {Neighbor? neighbor}) => DrivePing(
      id: id,
      ts: DateTime.utc(2026, 10, 16, 18, 0, sec),
      lat: 40.126,
      lon: -82.93,
      gpsAccuracyM: 4,
      speedMps: 13.4,
      noiseFloorDbm: -110,
      echoes: echoes,
      neighbor: neighbor,
    );

Widget wrap(Widget child) => MaterialApp(theme: meshSonarTheme(Brightness.dark), home: Scaffold(body: child));

void main() {
  group('EchoTile', () {
    testWidgets('shows name, id, SNR, hops, RSSI, delay, distance + bearing and source', (tester) async {
      final lookup = RepeaterLookup([
        (RepeaterSource.cmat, const [polaris]),
      ]);
      await tester.pumpWidget(wrap(EchoTile(
        echo: const Echo(repeater: 'df01', snrDb: 6.5, rssiDbm: -92, hops: 1, delayMs: 840),
        lookup: lookup,
        fromLat: 40.126,
        fromLon: -82.93,
      )));
      expect(find.text('Polaris Tower'), findsOneWidget);
      expect(find.text('DF01'), findsOneWidget);
      expect(find.text('+6.5 dB'), findsOneWidget);
      expect(find.text('CMAT'), findsOneWidget);
      final facts = tester.widget<Text>(find.byKey(const ValueKey('echo-facts-df01'))).data!;
      expect(facts, 'direct · RSSI -92 dBm · 840 ms · 5.1 km NW');
    });

    testWidgets('multi-hop path shown as names; unknown repeater shows its hex id; map badge', (tester) async {
      final lookup = RepeaterLookup([
        (RepeaterSource.cmat, const []),
        (RepeaterSource.publicMap, const [polaris]),
      ]);
      await tester.pumpWidget(wrap(Column(children: [
        EchoTile(echo: const Echo(repeater: 'df01', snrDb: -3, hops: 2, path: ['df01', 'c3']), lookup: lookup),
        EchoTile(echo: const Echo(repeater: 'c3', snrDb: null), lookup: lookup),
      ])));
      expect(find.text('via Polaris Tower → C3'), findsOneWidget);
      expect(find.text('map'), findsOneWidget);
      expect(find.text('2 hops'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('echo-name-c3'))).data, 'Unknown repeater');
      expect(find.text('C3'), findsOneWidget); // id chip
      expect(find.text('SNR —'), findsOneWidget);
    });

    testWidgets('ambiguous short prefix says how many repeaters it could be', (tester) async {
      final lookup = RepeaterLookup([
        (RepeaterSource.publicMap, [
          RepeaterRef(key: k('ab12'), name: 'North', lat: 40.2, lon: -82.9),
          RepeaterRef(key: k('ab34'), name: 'South', lat: 40.0, lon: -82.9),
        ]),
      ]);
      await tester.pumpWidget(wrap(EchoTile(echo: const Echo(repeater: 'ab', snrDb: 1), lookup: lookup, fromLat: 40.1, fromLon: -82.9)));
      expect(find.text('2 possible repeaters'), findsOneWidget);
      expect(find.text('AB'), findsOneWidget);
      expect(find.textContaining('km'), findsNothing, reason: 'no distance for an ambiguous id');
    });
  });

  group('PingLogScreen (saved drive)', () {
    Future<Harness> open(WidgetTester tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.cache.items = const [polaris];
      h.store.seed(
        DriveSession(id: 'd1', startedAt: DateTime.utc(2026, 10, 16, 18), endedAt: DateTime.utc(2026, 10, 16, 18, 10), label: 'Evening loop'),
        [
          at('p1', 0, const [Echo(repeater: 'df01', snrDb: 6.5, rssiDbm: -92, hops: 1, delayMs: 800), Echo(repeater: 'ee', snrDb: -4, hops: 2)]),
          at('p2', 30, const []),
          at('p3', 59, const [Echo(repeater: 'df01', snrDb: 2.0, hops: 1)],
              neighbor: const Neighbor(repeater: 'df01', localSnrDb: 3.25, remoteSnrDb: 1.5)),
        ],
      );
      await h.pumpApp(tester);
      await tester.tap(find.text('Drives'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-d1')));
      await tester.pumpAndSettle();
      final btn = find.byKey(const Key('detail-ping-log'));
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pumpAndSettle();
      return h;
    }

    String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

    testWidgets('summary, newest first, filters', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('ping-log')), findsOneWidget);
      expect(textOf(tester, 'log-sum-pings'), '3');
      expect(textOf(tester, 'log-sum-heard'), '67%');
      expect(textOf(tester, 'log-sum-repeaters'), '2');
      expect(find.text('Evening loop'), findsOneWidget);

      final rows = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('log-ping-'));
      expect(tester.widgetList(rows).map((w) => (w.key as ValueKey).value).toList(), ['log-ping-p3', 'log-ping-p2', 'log-ping-p1']);
      expect(find.text('Heard 2'), findsOneWidget);
      expect(find.text('Heard nothing'), findsWidgets); // the row and the filter chip

      await tester.tap(find.byKey(const Key('log-filter-heard')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('log-ping-p2')), findsNothing);
      expect(find.byKey(const ValueKey('log-ping-p1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('log-filter-nothing')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('log-ping-p2')), findsOneWidget);
      expect(find.byKey(const ValueKey('log-ping-p1')), findsNothing);

      await tester.tap(find.byKey(const Key('log-filter-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('log-ping-p1')), findsOneWidget);
    });

    testWidgets('tap a ping → detail sheet with every echo, neighbour and copy as text', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('log-ping-p1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ping-detail')), findsOneWidget);
      expect(find.byType(EchoTile), findsNWidgets(2));
      expect(find.text('±4 m'), findsOneWidget);
      expect(find.text('-110 dBm'), findsOneWidget);
      expect(find.text('48 km/h · 30 mph'), findsOneWidget);

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final copy = find.byKey(const Key('ping-copy'));
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copied, contains('Polaris Tower [DF01]'));
      expect(copied, contains('SNR +6.5 dB'));
      expect(copied, contains('Echo: EE [EE], SNR -4.0 dB, 2 hops'));
    });

    testWidgets('neighbour exchange shows in the detail sheet', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('log-ping-p3')));
      await tester.pumpAndSettle();
      expect(find.text('Neighbour exchange'), findsOneWidget);
      expect(find.text('we heard it +3.3 dB · it heard us +1.5 dB'), findsOneWidget);
    });

    testWidgets('repeaters tab aggregates the drive; tap → repeater detail with sparkline', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('log-tab-repeaters')));
      await tester.pumpAndSettle();
      expect(find.byType(HeardRepeaterTile), findsNWidgets(2));
      expect(textOf(tester, 'heard-facts-df01'), contains('2× heard'));
      expect(textOf(tester, 'heard-facts-df01'), contains('best +6.5 dB'));
      await tester.tap(find.byKey(const ValueKey('heard-df01')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('repeater-detail')), findsOneWidget);
      expect(find.byKey(const Key('snr-sparkline')), findsOneWidget);
      expect(find.text('df01aa0000000000'), findsOneWidget);
      expect(find.text('5.1 km NW'), findsOneWidget);
    });
  });

  testWidgets('live log (no sessionId) updates as pings arrive', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.state.init();
    await h.state.connectSimulator();
    await h.state.startDrive();
    await tester.pumpWidget(AppScope(
      state: h.state,
      child: MaterialApp(theme: meshSonarTheme(Brightness.dark), home: const PingLogScreen()),
    ));
    await tester.pump();
    expect(find.text('No pings yet'), findsOneWidget);
    expect(find.text('Current drive · live'), findsOneWidget);

    h.engines.last.emit(heardPing('l1', const [Echo(repeater: 'a1b2', snrDb: 6.5, hops: 1)]));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('log-ping-l1')), findsOneWidget);
    expect(find.text('Heard 1'), findsOneWidget);

    h.engines.last.emit(silentPing('l2'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('log-ping-l2')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('log-sum-pings'))).data, '2');
    expect(tester.widget<Text>(find.byKey(const Key('log-sum-heard'))).data, '50%');

    await tester.tap(find.byKey(const Key('log-tab-repeaters')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('heard-a1b2')), findsOneWidget);
    await h.state.stopDrive();
    await tester.pumpAndSettle();
  });

  test('pingAsText leaves unmeasured values out', () {
    final s = pingAsText(DrivePing(id: 'x', ts: DateTime.utc(2026), lat: 1, lon: 2), RepeaterLookup.empty);
    expect(s, contains('Result: Heard nothing'));
    expect(s, isNot(contains('Speed')));
    expect(s, isNot(contains('Noise')));
  });
}
