// The Coverage mode simulator tour (release 0.38 A9). Under `flutter test` it is one more walk through every state; on the
// iPhone 17 Pro simulator,
//   flutter run -d <sim> -t test/ui/plan/modes/coverage_sim_tour_test.dart
// draws it on the device (LiveTestWidgetsFlutterBinding), prints `SIMSHOT <name>` and holds each state for a few seconds so
// a script can take `xcrun simctl io <sim> screenshot`. plan-verify answers from coverage_kit.dart (a real 0.5 dB grid): the
// live CMH server does not have the 0.38 planner endpoints deployed yet.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/plan/plan_analysis.dart' show offsetM;
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/ui/map/coverage_map.dart' show CoverageMap;
import 'package:meshsonar/ui/plan/planner_screen.dart';

import '../../fakes.dart';
import '../../shell_test.dart' show drain;
import '../planner_test.dart' show openPlanner, settle, tapIn;
import 'coverage_kit.dart';

bool get _live => WidgetsBinding.instance is LiveTestWidgetsFlutterBinding;

const _a = PlanPoint(40.10, -82.90);

PlanVerifyResult _verify() {
  // Margin falls with distance and a little with bearing (a ridge to the west), so the footprint is not a perfect disc.
  final v = verifyAt(0, 0,
      marginDb: (r, j) => 22.0 - j * 0.9 - (r > 20 && r < 30 ? 6 : 0),
      links: const [PlanPredictedLink(publicKey: 'ab', name: 'North Ridge', km: 6.2, marginDb: 7.1)]);
  return PlanVerifyResult.parse(Map<String, dynamic>.from(v.raw)..remove('params'));
}

const _profile = PlanProfile(distanceKm: [0, 1, 2, 3], groundM: [250, 240, 238, 251]);
const _link = PlanLinkResult(km: 3, profile: _profile, verdict: PlanVerdict.likely, marginDb: 8, fresnelClearancePct: 70, provenance: PlanProvenance(terrain: 'test'));

Future<void> shot(WidgetTester tester, String name) async {
  await settle(tester);
  final e = tester.takeException();
  if (!_live) expect(e, isNull, reason: name);
  if (!_live) return;
  // ignore: avoid_print
  print('SIMSHOT $name');
  await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 4)));
}

void size(WidgetTester tester, {double scale = 1.0}) {
  // No basemap tiles on the device run: the harness has no tile server, and their load errors would fail the walk.
  final tiles = CoverageMap.tilesByDefault;
  CoverageMap.tilesByDefault = false;
  addTearDown(() => CoverageMap.tilesByDefault = tiles);
  // On the device the real screen is the view (the live binding letterboxes a resized one).
  if (!_live) {
    tester.view.physicalSize = const Size(402 * 3, 874 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
}

Future<void> sheet(WidgetTester tester, double dy) async {
  await tester.fling(find.byKey(const Key('planner-sheet-handle')), Offset(0, dy), 1500);
  await settle(tester);
}

Future<void> scrollTo(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await settle(tester);
}

Future<PlannerScreenState> _open(WidgetTester tester, Harness h) async {
  h.client.planVerifyResult = _verify();
  h.client.planLinkResult = _link;
  final st = await openPlanner(tester, h);
  await tapIn(tester, find.byKey(const Key('planner-mode-coverage')));
  await settle(tester);
  return st;
}

void main() {
  testWidgets('tour: one site, the layer and its controls', (tester) async {
    size(tester);
    final h = Harness();
    final st = await _open(tester, h);
    final n = st.controller!.addNode(name: 'Hilltop', lat: _a.lat, lon: _a.lon);
    st.selectNodeForTest(n.id);
    await shot(tester, '01-coverage-site-picked');
    await tapIn(tester, find.byKey(const Key('coverage-run')));
    await shot(tester, '02-footprint-on-map-medium');
    await sheet(tester, -600);
    await shot(tester, '03-site-stats-full');
    await scrollTo(tester, const Key('coverage-min-snr'));
    await shot(tester, '04-layer-controls');
    tester.widget<Slider>(find.byKey(const Key('coverage-min-snr-slider'))).onChangeEnd!(10); // +5 dB
    await settle(tester);
    await sheet(tester, 600);
    await shot(tester, '05-min-snr-raised-map');
    await drain(tester);
  });

  testWidgets('tour: three sites, union, spot check, link matrix, drag', (tester) async {
    size(tester);
    final h = Harness();
    final st = await _open(tester, h);
    final c = st.controller!;
    c.addNode(name: 'Water tower', lat: _a.lat, lon: _a.lon, status: PlanNodeStatus.existing, existingKey: 'ab' * 32);
    final b = offsetM(_a, 1200, 2600), d = offsetM(_a, -1800, 1200);
    c.addNode(name: 'Barn roof', lat: b.lat, lon: b.lon);
    final third = c.addNode(name: 'Church', lat: d.lat, lon: d.lon);
    st.selectNodeForTest(third.id);
    await settle(tester);
    await tapIn(tester, find.byKey(const Key('coverage-run-all')));
    for (var i = 0; i < 4; i++) {
      await settle(tester);
    }
    await tapIn(tester, find.byKey(const Key('coverage-colour-sites')));
    await shot(tester, '06-three-sites-by-count-map');
    await sheet(tester, -600);
    await scrollTo(tester, const Key('coverage-union'));
    await shot(tester, '07-union-card');
    await tapIn(tester, find.byKey(const Key('coverage-spot-centre')));
    await settle(tester);
    await scrollTo(tester, const Key('coverage-spot-result'));
    await shot(tester, '08-spot-check');
    await tapIn(tester, find.byKey(const Key('coverage-matrix-run')));
    await settle(tester);
    await scrollTo(tester, const Key('coverage-classes'));
    await shot(tester, '09-link-matrix-classes');
    await sheet(tester, 600);
    await shot(tester, '10-matrix-links-on-map');
    // Drag the church: long-press its marker and move it.
    final start = tester.getCenter(find.byKey(ValueKey('plan-drag-${third.id}')));
    final g = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 700));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(-10, -6));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await g.up();
    await shot(tester, '11-dragged-moved-toast');
    await tester.pump(const Duration(seconds: 2));
    await shot(tester, '12-re-estimated-after-drag');
    await drain(tester);
  });

  testWidgets('tour: verify loop of an installed node', (tester) async {
    size(tester);
    final h = Harness();
    CoverageCell cell(PlanPoint p, {required bool heard, double? snr}) =>
        CoverageCell(lat: p.lat, lon: p.lon, pings: 5, heard: heard ? 3 : 0, bestSnr: snr, medianSnr: snr, repeaters: heard ? 1 : 0, lastAt: '2026-11-14T12:00:00Z');
    h.client.publicCoverageResult = PublicCoverage(cells: [
      for (var i = 0; i < 8; i++) cell(offsetM(_a, 250.0 * i, 120.0 * i), heard: i < 6, snr: i < 6 ? 6.0 - i * 2 : null),
      cell(offsetM(_a, -2200, 0), heard: true, snr: -11),
    ], asOf: '2026-11-15T00:00:00Z', grid: const CoverageGrid.square(cellDeg: 0.002));
    final st = await _open(tester, h);
    final n = st.controller!.addNode(name: 'Hilltop', lat: _a.lat, lon: _a.lon, status: PlanNodeStatus.installed);
    st.selectNodeForTest(n.id);
    await settle(tester);
    await tapIn(tester, find.byKey(const Key('coverage-run')));
    await sheet(tester, -600);
    await scrollTo(tester, const Key('coverage-verify-loop'));
    await shot(tester, '13-verify-loop');
    await drain(tester);
  });

  testWidgets('tour: large text (AX3)', (tester) async {
    size(tester, scale: 2.35);
    final h = Harness();
    final st = await _open(tester, h);
    final n = st.controller!.addNode(name: 'Hilltop on the ridge above the river', lat: _a.lat, lon: _a.lon);
    st.selectNodeForTest(n.id);
    await settle(tester);
    await tapIn(tester, find.byKey(const Key('coverage-run')));
    await sheet(tester, -600);
    await shot(tester, '14-ax3-site-card');
    await scrollTo(tester, const Key('coverage-min-snr'));
    await shot(tester, '15-ax3-layer-controls');
    await drain(tester);
  });
}
