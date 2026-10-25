// "Your progress", server view (capability driverSummary): the source switch is offered only with the capability and a
// usable key; the numbers say which source they are from; every state is explicit (loading, no connection, 401, 403
// words, 429, empty, stored copy offline / paused); weekly charts carry their numbers; a drive on the phone opens its
// report, a server-only drive a sheet; 2x text and dark mode do not overflow.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/driver_summary.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/report/progress_screen.dart';

import 'fakes.dart';

class SummaryClient extends FakeCmatClient {
  SummaryClient(super.baseUrl);
  Future<DriverSummary> Function()? script;
  int asks = 0;
  final List<String> keys = [];

  @override
  Future<DriverSummary> driverSummary(String driverKey) {
    asks++;
    keys.add(driverKey);
    return script!();
  }
}

class SummaryHarness extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => SummaryClient(u);
  SummaryClient get sc => state.client as SummaryClient;
}

Map<String, dynamic> body({List<Map<String, dynamic>>? drives, Map<String, dynamic>? stats, List<Map<String, dynamic>>? weeks}) => {
      'v': 1,
      'asOf': '2026-10-16T17:59:00Z',
      'stats': stats ??
          {
            'drives': 3, 'pings': 1234, 'heardPings': 925, 'km': 87.4, 'cells': 120, 'repeatersHeard': 14,
            'firstDriveAt': '2026-09-01T12:00:00Z', 'lastDriveAt': '2026-10-14T12:00:00Z', 'settledPings': 200, 'confirmedPings': 150,
          },
      'weeks': weeks ??
          [
            {'week': '2026-09-28', 'drives': 2, 'pings': 1000, 'heardPings': 800, 'km': 66.9, 'newCells': 90},
            {'week': '2026-10-12', 'drives': 1, 'pings': 234, 'heardPings': 125, 'km': 20.5, 'newCells': 4},
          ],
      'drives': drives ??
          [
            {'id': 'd-here', 'callsign': 'KD8XYZ', 'label': 'Long run', 'startedAt': '2026-10-14T10:00:00Z', 'endedAt': '2026-10-14T11:00:00Z', 'pings': 234, 'heardPings': 125, 'km': 20.5, 'bestSnr': 8.5, 'repeaters': 9, 'review': 'ok', 'flags': [], 'settledPings': 200, 'confirmedPings': 150},
            {'id': 'd-far', 'callsign': 'KD8XYZ', 'label': null, 'startedAt': '2026-09-29T10:00:00Z', 'endedAt': '2026-09-29T11:00:00Z', 'pings': 1000, 'heardPings': 800, 'km': 66.9, 'bestSnr': 9.0, 'repeaters': 12, 'review': 'flagged', 'flags': ['gps-jump'], 'settledPings': 0, 'confirmedPings': 0},
          ],
    };

DriverSummary summary([Map<String, dynamic>? b]) => DriverSummary.parse(b ?? body());

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
final t0 = DateTime.utc(2026, 10, 14, 10);

Future<SummaryHarness> open(
  WidgetTester tester, {
  Future<DriverSummary> Function()? script,
  bool capability = true,
  DriverKeyStatus keyStatus = DriverKeyStatus.approved,
  UnitsPreference units = UnitsPreference.metric,
  void Function(SummaryHarness h)? beforeOpen,
}) async {
  useTallScreen(tester);
  final h = SummaryHarness();
  h.approveKey();
  h.settings.saved = h.settings.saved.copyWith(keyStatus: keyStatus, units: units);
  h.store.seed(DriveSession(id: 'd-here', startedAt: t0, endedAt: t0.add(const Duration(hours: 1))), [
    DrivePing(id: 'a', ts: t0, lat: 40.1, lon: -82.9, echoes: const [Echo(repeater: 'a1b2', snrDb: 5, hops: 1)]),
    DrivePing(id: 'b', ts: t0.add(const Duration(minutes: 1)), lat: 40.11, lon: -82.9, echoes: const []),
  ]);
  await h.state.init();
  h.sc.script = script ?? () async => summary();
  h.sc.siteConfigResult = SiteConfig(region: _region, capabilities: capability ? const {'driverSummary'} : const {});
  await h.state.refreshUploadSiteConfig(force: true);
  beforeOpen?.call(h);
  await tester.pumpWidget(MeshSonarApp(state: h.state));
  await tester.pump();
  openProgress(tester.element(find.byType(Scaffold).first));
  await tester.pumpAndSettle();
  return h;
}

String _text(WidgetTester t, String key) => t.widget<Text>(find.byKey(Key(key))).data!;
Finder get _list => find.descendant(of: find.byKey(const Key('progress-server-list')), matching: find.byType(Scrollable)).first;

void main() {
  testWidgets('no capability: no switch, the phone view exactly as before', (tester) async {
    final h = await open(tester, capability: false);
    expect(find.byKey(const Key('progress-source')), findsNothing);
    expect(find.byKey(const Key('progress-scope')), findsOneWidget);
    expect(h.sc.asks, 0);
  });

  testWidgets('capability but a rejected or missing key: no switch, nothing asked', (tester) async {
    final h = await open(tester, keyStatus: DriverKeyStatus.rejected);
    expect(find.byKey(const Key('progress-source')), findsNothing);
    expect(h.sc.asks, 0);
  });

  testWidgets('a pending key is allowed (the server allows it)', (tester) async {
    await open(tester, keyStatus: DriverKeyStatus.pending);
    expect(find.byKey(const Key('progress-source')), findsOneWidget);
    expect(find.byKey(const Key('progress-server-scope')), findsOneWidget);
  });

  testWidgets('server view is the default: scope, as-of, totals, compare line, then the switch shows the phone view', (tester) async {
    final h = await open(tester);
    expect(h.sc.keys, ['secretkey-abcdef-1234']);
    expect(_text(tester, 'progress-server-scope'), startsWith('Across all your drives on the server, from every phone and install on this account, since '));
    expect(find.byKey(const Key('progress-server-updated')), findsOneWidget);
    String tile(String id) => (find.descendant(of: find.byKey(Key('progress-server-total-$id')), matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data).toList()[1])!;
    expect(tile('drives'), '3');
    expect(tile('distance'), '87 km');
    expect(tile('pings'), '1,234');
    expect(tile('heard'), '75%');
    expect(tile('cells'), '120');
    expect(tile('repeaters'), '14');
    expect(_text(tester, 'progress-server-confirmed'), contains('Confirmed by the mesh: 75% (150 of 200 settled pings)'));
    expect(_text(tester, 'progress-server-confirmed'), contains('still waiting for confirmation are left out'));
    expect(_text(tester, 'progress-server-compare'), startsWith('The server has 1 drive that is not on this phone'));
    await tester.tap(find.byKey(const Key('progress-source-phone')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('progress-server-list')), findsNothing);
    expect(_text(tester, 'progress-scope'), startsWith('From drives stored on this phone: 1 drive since '));
    await tester.tap(find.byKey(const Key('progress-source-server')));
    await tester.pumpAndSettle();
    expect(h.sc.asks, 1, reason: 'switching back does not ask again');
    expect(find.byKey(const Key('progress-server-scope')), findsOneWidget);
  });

  testWidgets('imperial units for the distance', (tester) async {
    await open(tester, units: UnitsPreference.imperial);
    final texts = find.descendant(of: find.byKey(const Key('progress-server-total-distance')), matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data);
    expect(texts, contains('54 mi'));
  });

  testWidgets('weekly charts: numbers in semantics, UTC Monday weeks said, empty weeks filled and said', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-server-distance')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'^Distance per week \(km\)\. 3 weeks\. Most: Week of Sep 28, 67 km in 2 drives\.')), findsOneWidget);
    expect(find.textContaining('Weeks start on Monday, UTC.'), findsWidgets);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-server-heard')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'Best Week of Sep 28, 80% of 1000 pings\. This week 53%\.')), findsOneWidget);
    final toggle = find.descendant(of: find.byKey(const Key('chart-server-cells-toggle')), matching: find.text('Table'));
    await tester.scrollUntilVisible(find.byKey(const Key('chart-server-cells')), 200, scrollable: _list);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('chart-server-cells-table')), matching: find.text('Oct 5')), findsOneWidget, reason: 'the empty week between two listed ones');
    handle.dispose();
  });

  testWidgets('drive list: a drive on this phone opens its report, a server-only one a sheet with review words', (tester) async {
    await open(tester);
    await tester.scrollUntilVisible(find.byKey(const Key('progress-server-drive-d-far')), 300, scrollable: _list);
    expect(find.descendant(of: find.byKey(const Key('progress-server-drive-d-far')), matching: find.textContaining('Flagged for review')), findsOneWidget);
    await tester.tap(find.byKey(const Key('progress-server-drive-d-far')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('progress-server-drive-sheet')), findsOneWidget);
    expect(find.text('This drive is on the server but not on this phone.'), findsOneWidget);
    expect(find.text('Flagged for review'), findsWidgets);
    expect(find.text('gps-jump'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('progress-server-drive-d-here')), 300, scrollable: _list);
    expect(find.descendant(of: find.byKey(const Key('progress-server-drive-d-here')), matching: find.textContaining('Also on this phone')), findsOneWidget);
    await tester.tap(find.byKey(const Key('progress-server-drive-d-here')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drive-report')), findsOneWidget);
  });

  testWidgets('loading is explicit and ends', (tester) async {
    final gate = Completer<DriverSummary>();
    useTallScreen(tester);
    final h = SummaryHarness()..approveKey();
    await h.state.init();
    h.sc.script = () => gate.future;
    h.sc.siteConfigResult = const SiteConfig(region: _region, capabilities: {'driverSummary'});
    await h.state.refreshUploadSiteConfig(force: true);
    await tester.pumpWidget(MeshSonarApp(state: h.state));
    await tester.pump();
    openProgress(tester.element(find.byType(Scaffold).first));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('progress-server-loading')), findsOneWidget);
    gate.complete(summary());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('progress-server-loading')), findsNothing);
    expect(find.byKey(const Key('progress-server-scope')), findsOneWidget);
  });

  group('errors', () {
    testWidgets('no connection and nothing stored: plain words and Retry that works', (tester) async {
      var fail = true;
      final h = await open(tester, script: () async {
        if (fail) throw const CmatException('network error: down');
        return summary();
      });
      expect(find.byKey(const Key('progress-server-error-offline')), findsOneWidget);
      expect(find.textContaining('No connection to the server'), findsOneWidget);
      expect(find.byKey(const Key('progress-server-loading')), findsNothing);
      fail = false;
      await tester.tap(find.byKey(const Key('progress-server-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('progress-server-scope')), findsOneWidget);
      expect(h.sc.asks, 2);
    });

    testWidgets('401 says the key is not recognised (no retry)', (tester) async {
      await open(tester, script: () async => throw const CmatException('x-driver-key required', status: 401));
      expect(find.byKey(const Key('progress-server-error-401')), findsOneWidget);
      expect(find.textContaining('does not recognise this driver key'), findsOneWidget);
      expect(find.byKey(const Key('progress-server-retry')), findsNothing);
    });

    for (final (word, text) in [('rejected', 'was rejected'), ('revoked', 'was revoked'), ('banned', 'is banned')]) {
      testWidgets('403 $word in words', (tester) async {
        await open(tester, script: () async => throw CmatException('no', status: 403, serverStatus: word));
        expect(find.byKey(const Key('progress-server-error-403')), findsOneWidget);
        expect(find.textContaining(text), findsOneWidget);
      });
    }

    testWidgets('429 asks for a pause and offers Retry', (tester) async {
      await open(tester, script: () async => throw const CmatException('slow down', status: 429));
      expect(find.byKey(const Key('progress-server-error-429')), findsOneWidget);
      expect(find.textContaining('asked for a pause'), findsOneWidget);
      expect(find.byKey(const Key('progress-server-retry')), findsOneWidget);
    });

    testWidgets('a 500 shows the code, not the server text', (tester) async {
      await open(tester, script: () async => throw const CmatException('secret internals', status: 500));
      expect(find.textContaining('(500)'), findsOneWidget);
      expect(find.textContaining('secret internals'), findsNothing);
    });
  });

  testWidgets('empty account: "No drives uploaded yet"', (tester) async {
    await open(tester, script: () async => summary(body(drives: [], weeks: [], stats: {'drives': 0, 'pings': 0})));
    expect(find.byKey(const Key('progress-server-empty')), findsOneWidget);
    expect(find.text('No drives uploaded yet'), findsOneWidget);
  });

  testWidgets('a stored copy when the server cannot be reached: "Offline - as of", and for a 429 the pause note', (tester) async {
    var mode = 'ok';
    final h = await open(tester, script: () async {
      switch (mode) {
        case 'offline':
          throw const CmatException('network error: down');
        case 'pause':
          throw const CmatException('slow', status: 429);
        default:
          return summary();
      }
    });
    expect(find.byKey(const Key('progress-server-updated')), findsOneWidget);
    // leave and come back 2 hours later, offline
    mode = 'offline';
    h.clockNow = h.clockNow.add(const Duration(hours: 2));
    Navigator.of(tester.element(find.byKey(const Key('progress-screen')))).pop();
    await tester.pumpAndSettle();
    openProgress(tester.element(find.byType(Scaffold).first));
    await tester.pumpAndSettle();
    expect(_text(tester, 'progress-server-scope'), isNotEmpty);
    expect(find.byKey(const Key('progress-server-offline')), findsOneWidget);
    expect(find.textContaining('Offline - as of 2h ago'), findsOneWidget);
    mode = 'pause';
    h.clockNow = h.clockNow.add(const Duration(hours: 1));
    Navigator.of(tester.element(find.byKey(const Key('progress-screen')))).pop();
    await tester.pumpAndSettle();
    openProgress(tester.element(find.byType(Scaffold).first));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('progress-server-paused')), findsOneWidget);
    expect(find.textContaining('asked for a pause'), findsOneWidget);
  });

  testWidgets('pull to refresh asks again once past the 10 s floor', (tester) async {
    final h = await open(tester);
    expect(h.sc.asks, 1);
    h.clockNow = h.clockNow.add(const Duration(seconds: 11));
    await tester.fling(find.byKey(const Key('progress-server-list')), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(h.sc.asks, 2);
  });

  testWidgets('2x text and dark mode: no overflow, the switch and drives still reachable', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    final handle = tester.ensureSemantics();
    await open(tester);
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 2.5; // 360 dp wide
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('progress-source'))).height, greaterThanOrEqualTo(48));
    await tester.scrollUntilVisible(find.byKey(const Key('progress-server-drive-d-far')), 300, scrollable: _list);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });
}
