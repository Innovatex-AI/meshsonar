// "Where MeshSonar drives heard this repeater" (repeater-reach with the driver key): every state, units, the drive
// repeater sheet hosting it, 2x text and dark mode.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/repeater_reach.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/repeater_detail_sheet.dart';
import 'package:meshsonar/ui/repeater_reach_section.dart';
import 'package:meshsonar/ui/settings_screen.dart' show DriverKeyScreen;

import 'fakes.dart';

const key = 'da5dc89c937225aadced4a1cb8a689c0d34ccab96576a0d0f69f3186c879c854';
const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');

RepeaterReach reach({bool bands = true, bool empty = false}) => empty
    ? const RepeaterReach(
        key: key, cellDeg: 0.0025, cells: [], snrByDistance: [], totals: ReachTotals(heardPings: 0, drives: 0, drivers: 0))
    : RepeaterReach(
        key: key,
        cellDeg: 0.0025,
        cells: [
          ReachCell(lat: 40.10125, lon: -82.93125, pings: 4, bestSnr: 7.5, medianSnr: 3, lastAt: DateTime.utc(2026, 10, 24, 14)),
          ReachCell(lat: 40.10375, lon: -82.93125, pings: 1, bestSnr: -3),
        ],
        totals: ReachTotals(
            heardPings: 5, drives: 2, drivers: 2, bestSnr: 7.5, medianSnr: 3, farthestKm: bands ? 3.2 : null, lastHeardAt: DateTime.utc(2026, 10, 24, 14)),
        snrByDistance: bands
            ? [
                for (final b in reachBands) ReachBandRow(label: b.$1, fromKm: b.$2, toKm: b.$3, pings: b.$1 == '0-1' ? 3 : 0, medianSnr: b.$1 == '0-1' ? 4.5 : null),
              ]
            : const [],
      );

class ReachClient extends FakeCmatClient {
  ReachClient(super.u);
  Future<RepeaterReach> Function(String key, double? lat, double? lon)? handler;
  final calls = <(String, String, double?, double?)>[];
  @override
  Future<RepeaterReach> repeaterReach(String driverKey, String repeaterKey, {double? lat, double? lon}) {
    calls.add((driverKey, repeaterKey, lat, lon));
    return handler!(repeaterKey, lat, lon);
  }
}

class ReachHarness extends Harness {
  Future<RepeaterReach> Function(String key, double? lat, double? lon)? handler;
  SiteConfig? site = const SiteConfig(region: _region, capabilities: {'reachDriverKey'});
  @override
  FakeCmatClient newClient(Uri u) => ReachClient(u)
    ..siteConfigResult = site
    ..handler = (k, a, b) => handler!(k, a, b);
  ReachClient get rc => client as ReachClient;
}

Future<ReachHarness> show(WidgetTester tester,
    {Future<RepeaterReach> Function(String, double?, double?)? handler,
    bool approved = true,
    SiteConfig? site,
    bool noCap = false,
    String repeaterKey = key,
    double? lat = 40.101,
    double? lon = -82.931,
    UnitsPreference units = UnitsPreference.metric,
    double textScale = 1}) async {
  useTallScreen(tester);
  final h = ReachHarness()..handler = handler ?? ((_, _, _) async => reach());
  if (noCap) h.site = const SiteConfig(region: _region);
  if (site != null) h.site = site;
  if (approved) h.approveKey();
  h.settings.saved = h.settings.saved.copyWith(units: units);
  await h.pumpApp(tester);
  await tester.runAsync(() => h.state.refreshUploadSiteConfig(force: true));
  Navigator.of(tester.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(
      builder: (c) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(body: ListView(children: [RepeaterReachSection(repeaterKey: repeaterKey, lat: lat, lon: lon, mapTiles: false)])))));
  await tester.pumpAndSettle();
  return h;
}

String _text(WidgetTester t, String k) => t.widget<Text>(find.byKey(Key(k))).data!;

void main() {
  testWidgets('full answer: network-wide label, tiles in metric, map, caption, band chart with its table', (tester) async {
    final h = await show(tester);
    expect(find.text('Where MeshSonar drives heard this repeater'), findsOneWidget);
    expect(find.textContaining('Not the same as "Your drives"'), findsOneWidget);
    expect(find.byKey(const Key('reach-map')), findsOneWidget);
    expect(find.text('5'), findsWidgets); // heard pings
    expect(find.text('3.2 km'), findsOneWidget);
    expect(find.text('7.5 dB'), findsOneWidget);
    expect(find.textContaining('2 cells where drives heard it'), findsOneWidget);
    expect(find.textContaining('never raw tracks'), findsOneWidget);
    expect(find.byKey(const Key('chart-reach-bands')), findsOneWidget);
    expect(find.byKey(const Key('reach-no-bands')), findsNothing);
    // the ask carried the approved key and the repeater's own position, not the phone's
    expect(h.rc.calls.single, ('secretkey-abcdef-1234', key, 40.101, -82.931));
  });

  testWidgets('imperial units for farthest and bands', (tester) async {
    await show(tester, units: UnitsPreference.imperial);
    expect(find.text('2.0 mi'), findsOneWidget); // 3.2 km
    await tester.tap(find.byKey(const Key('chart-reach-bands-toggle')).first, warnIfMissed: false);
  });

  testWidgets('no repeater position: farthest unknown and the chart says why it is missing', (tester) async {
    await show(tester, handler: (_, _, _) async => reach(bands: false), lat: null, lon: null);
    expect(find.byKey(const Key('reach-no-bands')), findsOneWidget);
    expect(_text(tester, 'reach-no-bands'), contains('position is not known'));
    expect(find.byKey(const Key('chart-reach-bands')), findsNothing);
  });

  testWidgets('nothing heard: empty state with the privacy reason', (tester) async {
    await show(tester, handler: (_, _, _) async => reach(empty: true));
    expect(_text(tester, 'reach-empty'), contains('No MeshSonar drive has heard this repeater directly yet'));
    expect(_text(tester, 'reach-empty'), contains('public drives'));
  });

  testWidgets('capability absent: the section is not there at all', (tester) async {
    await show(tester, noCap: true);
    expect(find.byKey(const Key('reach')), findsNothing);
  });

  testWidgets('short or unusable id: not shown', (tester) async {
    await show(tester, repeaterKey: 'a1b2');
    expect(find.byKey(const Key('reach')), findsNothing);
  });

  testWidgets('capability present, key missing or pending: one line and an Open driver key settings action, no ask', (tester) async {
    final h = await show(tester, approved: false);
    expect(find.byKey(const Key('reach-needs-key')), findsOneWidget);
    expect(h.clients.every((c) => (c as ReachClient).calls.isEmpty), isTrue);
    await tester.tap(find.byKey(const Key('reach-open-key-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(DriverKeyScreen), findsOneWidget);
  });

  testWidgets('errors in words: 401, 403, 429, 500, no connection; Retry asks again and succeeds', (tester) async {
    final cases = <int?, String>{
      401: "doesn't recognise your driver key",
      403: "isn't approved",
      429: 'asked for a pause',
      500: 'error (500)',
      null: 'No connection',
    };
    for (final e in cases.entries) {
      var fail = true;
      await show(tester, handler: (_, _, _) async {
        if (fail) throw CmatException(e.key == null ? 'network error: down' : 'x', status: e.key);
        return reach();
      });
      expect(find.byKey(Key('reach-error-${e.key ?? 'offline'}')), findsOneWidget, reason: '${e.key}');
      expect(find.textContaining(e.value), findsOneWidget, reason: '${e.key}');
      fail = false;
      await tester.tap(find.byKey(const Key('reach-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reach-map')), findsOneWidget, reason: '${e.key}');
    }
  });

  testWidgets('a failed refresh shows the stored copy as offline with its age, and Retry recovers', (tester) async {
    var fail = false;
    final h = await show(tester, handler: (_, _, _) async {
      if (fail) throw const CmatException('network error: down');
      return reach();
    });
    expect(find.byKey(const Key('reach-offline')), findsNothing);
    // leave the screen, come back 30 minutes later with no connection
    Navigator.of(tester.element(find.byKey(const Key('reach')))).pop();
    await tester.pumpAndSettle();
    fail = true;
    h.clockNow = h.clockNow.add(const Duration(minutes: 30));
    Navigator.of(tester.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: ListView(children: [RepeaterReachSection(repeaterKey: key, lat: 40.101, lon: -82.931, mapTiles: false)]))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reach-offline')), findsOneWidget);
    expect(find.textContaining('as of 30m ago'), findsOneWidget);
    expect(find.byKey(const Key('reach-map')), findsOneWidget, reason: 'the stored numbers are still shown');
    expect(h.rc.calls, hasLength(2));
    fail = false;
    await tester.tap(find.byKey(const Key('reach-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reach-offline')), findsNothing);
  });

  testWidgets('loading state is a progress bar', (tester) async {
    useTallScreen(tester);
    final h = ReachHarness()..handler = (_, _, _) => Future<RepeaterReach>.delayed(const Duration(seconds: 5), reach);
    h.approveKey();
    await h.pumpApp(tester);
    await tester.runAsync(() => h.state.refreshUploadSiteConfig(force: true));
    Navigator.of(tester.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: ListView(children: [RepeaterReachSection(repeaterKey: key, mapTiles: false)]))));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('reach-loading')), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('2x text does not overflow and the buttons are at least 48 dp', (tester) async {
    await show(tester, textScale: 2);
    expect(tester.takeException(), isNull);
    await show(tester, approved: false, textScale: 2);
    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byKey(const Key('reach-open-key-settings')));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('the drive repeater sheet hosts it for a resolved repeater with the repeater position', (tester) async {
    useTallScreen(tester);
    final h = ReachHarness()..handler = (_, _, _) async => reach();
    h.approveKey();
    h.cache.items = const [RepeaterRef(key: key, name: 'Albany West', lat: 40.101, lon: -82.931)];
    await h.pumpApp(tester);
    await tester.runAsync(() => h.state.refreshUploadSiteConfig(force: true));
    Navigator.of(tester.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: RepeaterDetailSheet(id: 'da5d', lookup: h.state.lookup, pings: const []))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reach')), findsOneWidget);
    expect(h.rc.calls.single.$2, key);
    expect(h.rc.calls.single.$3, 40.101);
  });
}
