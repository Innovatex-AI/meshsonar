// Coverage mode (release 0.38 A9; plan §4.2 flow B, improvements 8, 9, 13, 20): the footprint drawn as a layer on the
// planner map, re-styled by the opacity / minimum-SNR sliders and by a new spreading factor without a new request, the
// per-site and whole-plan stats, "how many repeaters see this spot", the link matrix with node classes, mount presets and
// the receiver, the verify loop, the error state, results kept across mode switches, and large text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/plan/plan_analysis.dart' show offsetM;
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/map/layers/map_layer.dart' show LongPressHit;
import 'package:meshsonar/ui/plan/modes/coverage_mode.dart';
import 'package:meshsonar/ui/plan/plan_modes.dart';
import 'package:meshsonar/ui/plan/planner_screen.dart';

import '../../fakes.dart';
import '../../shell_test.dart' show phone, drain;
import '../planner_test.dart' show openPlanner, settle, tapIn;
import 'coverage_kit.dart';

const _a = PlanPoint(40.10, -82.90);

/// A verify answer whose footprint sits on whichever node asked (no `params`), decoding out to 2 km.
PlanVerifyResult _verify({List<PlanPredictedLink> links = const [PlanPredictedLink(publicKey: 'ab', name: 'North Ridge', km: 6.2, marginDb: 7.1)]}) {
  final v = verifyAt(0, 0, links: links);
  final raw = Map<String, dynamic>.from(v.raw)..remove('params');
  return PlanVerifyResult.parse(raw);
}

const _profile = PlanProfile(distanceKm: [0, 1, 2, 3], groundM: [200, 201, 202, 200]);
const _link = PlanLinkResult(km: 3, profile: _profile, verdict: PlanVerdict.likely, provenance: PlanProvenance(terrain: 'test'));

Future<CoverageBodyState> _coverage(WidgetTester tester, PlannerScreenState st) async {
  await tapIn(tester, find.byKey(const Key('planner-mode-coverage')));
  await settle(tester);
  expect(st.mode, PlanModeId.coverage);
  return tester.state<CoverageBodyState>(find.byType(CoverageBody));
}

Future<void> _estimate(WidgetTester tester, {String key = 'coverage-run'}) async {
  await tapIn(tester, find.byKey(Key(key)));
  await settle(tester);
}

void main() {
  testWidgets('Estimate draws the footprint as a layer on the planner map, with the site and plan cards', (tester) async {
    phone(tester);
    final h = Harness();
    h.client.planVerifyResult = _verify();
    final st = await openPlanner(tester, h);
    final n = st.controller!.addNode(name: 'Hilltop', lat: _a.lat, lon: _a.lon);
    st.controller!.setReceiverM(1.8); // car roof
    final body = await _coverage(tester, st);
    expect(find.byKey(const Key('plan-footprint-layer')), findsNothing);
    await _estimate(tester);

    final ask = h.client.planVerifyAsks.single;
    expect(ask.site, n.point);
    expect(ask.radio, st.controller!.plan.radio, reason: 'the plan\'s own radio, never a constant');
    expect(ask.receiver, 'mobile');
    expect(ask.receiverM, 1.8);
    expect(find.byKey(const Key('plan-footprint-layer')), findsOneWidget, reason: 'drawn on the map');
    expect(find.byKey(const Key('coverage-result')), findsOneWidget);
    expect(find.byKey(const Key('coverage-area')), findsOneWidget);
    expect(find.textContaining('Already covered today'), findsOneWidget);
    expect(find.textContaining('New area not covered today'), findsOneWidget);
    expect(find.textContaining('Longest predicted link'), findsOneWidget);
    expect(find.textContaining('no census counts'), findsOneWidget, reason: 'people only where census data exists');
    expect(find.byKey(const Key('coverage-union')), findsOneWidget);
    expect(find.byKey(const Key('coverage-legend')), findsOneWidget);
    expect(body.viewForTest!.areaKm2, closeTo(12.6, 1.5), reason: 'the 2 km disc at the SF7 decode limit');
    await drain(tester);
  });

  testWidgets('the minimum-SNR and opacity sliders and a new spreading factor re-draw with no new request', (tester) async {
    phone(tester);
    final h = Harness();
    h.client.planVerifyResult = _verify();
    final st = await openPlanner(tester, h);
    st.controller!.addNode(name: 'Hilltop', lat: _a.lat, lon: _a.lon);
    final body = await _coverage(tester, st);
    await _estimate(tester);
    final base = body.viewForTest!.areaKm2;

    final snr = tester.widget<Slider>(find.byKey(const Key('coverage-min-snr-slider')));
    snr.onChangeEnd!(11); // stop 11 = +7.5 dB SNR (15 dB over the SF7 floor)
    await settle(tester);
    expect(body.viewForTest!.minSnrDb, 7.5);
    expect(body.viewForTest!.areaKm2, lessThan(base * 0.5));
    expect(find.textContaining('At +7.5 dB SNR or better'), findsWidgets);

    final op = tester.widget<Slider>(find.byKey(const Key('coverage-opacity-slider')));
    op.onChangeEnd!(8); // 90 %
    await settle(tester);
    expect(find.byKey(const Key('plan-footprint-layer')), findsOneWidget);

    // Back to following the radio's decode limit, then SF12: same received power, lower floor, a bigger footprint.
    snr.onChangeEnd!(5); // -7.5
    await settle(tester);
    final r = st.controller!.plan.radio;
    st.controller!.setRadio(PlanRadio(freqMHz: r.freqMHz, bwKHz: r.bwKHz, sf: 12, cr: r.cr));
    await settle(tester);
    expect(body.viewForTest!.minSnrDb, -20);
    expect(body.viewForTest!.areaKm2, greaterThan(base * 1.5));
    expect(find.byKey(const Key('coverage-restyled')), findsOneWidget);
    expect(find.byKey(const Key('coverage-stale')), findsNothing, reason: 'SF does not change the received power');
    expect(h.client.planVerifyAsks, hasLength(1), reason: 'no new request for any of it');
    await drain(tester);
  });

  testWidgets('Estimate every node, colour by sites, the union card and "how many repeaters see this spot"', (tester) async {
    phone(tester);
    final h = Harness();
    h.client.planVerifyResult = _verify();
    final st = await openPlanner(tester, h);
    final c = st.controller!;
    c.addNode(name: 'Hilltop', lat: _a.lat, lon: _a.lon, status: PlanNodeStatus.existing, existingKey: 'aa' * 32);
    final b = offsetM(_a, 0, 3000);
    c.addNode(name: 'Barn', lat: b.lat, lon: b.lon);
    final body = await _coverage(tester, st);
    await _estimate(tester, key: 'coverage-run-all');
    await settle(tester);
    expect(h.client.planVerifyAsks, hasLength(2));
    expect(body.fieldForTest!.sites, hasLength(2));
    expect(find.text('All 2 sites together (Estimate)'), findsOneWidget);
    expect(find.textContaining('Reached by two or more sites'), findsOneWidget);
    expect(find.textContaining('Added by the planned and installed sites'), findsOneWidget);
    expect(body.viewForTest!.overlapKm2, greaterThan(0));

    await tapIn(tester, find.byKey(const Key('coverage-colour-sites')));
    expect(find.text('2 sites'), findsOneWidget, reason: 'legend by count');

    // Long-press while Check a spot is on: the spot is checked, no node is dropped.
    await tapIn(tester, find.byKey(const Key('coverage-spot-arm')));
    final mid = offsetM(_a, 0, 1500);
    await st.longPressForTest(LongPressHit(lat: mid.lat, lon: mid.lon));
    await settle(tester);
    expect(c.nodes, hasLength(2));
    expect(find.byKey(const Key('coverage-spot-result')), findsOneWidget);
    expect(find.textContaining('2 of 2 repeaters reach this spot'), findsOneWidget);
    final west = offsetM(_a, 0, -1500);
    await st.longPressForTest(LongPressHit(lat: west.lat, lon: west.lon));
    await settle(tester);
    expect(find.textContaining('1 of 2 repeaters reach this spot'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('the link matrix draws every pair by verdict and names each node\'s class', (tester) async {
    phone(tester);
    final h = Harness();
    h.client.planLinkResult = _link;
    final st = await openPlanner(tester, h);
    final c = st.controller!;
    for (var i = 0; i < 3; i++) {
      final p = offsetM(_a, 0, i * 2000.0);
      c.addNode(name: 'N$i', lat: p.lat, lon: p.lon);
    }
    await _coverage(tester, st);
    expect(find.textContaining('Check every link (3 pairs)'), findsOneWidget);
    await _estimate(tester, key: 'coverage-matrix-run');
    expect(find.byKey(const Key('coverage-matrix')), findsOneWidget);
    expect(st.overlayForTest.plan.links, hasLength(3), reason: 'every pair on the map');
    expect(find.byKey(const Key('coverage-classes')), findsOneWidget);
    for (final n in c.nodes) {
      expect(find.byKey(Key('coverage-class-${n.id}')), findsOneWidget);
    }
    expect(find.textContaining('Backbone'), findsNothing, reason: 'three nodes: two links each');
    expect(find.textContaining('Redundant'), findsNWidgets(3));
    // Moving a node makes the matrix stale.
    c.moveNode(c.nodes.first.id, 40.2, -82.8);
    await settle(tester);
    expect(find.textContaining('these are the last results'), findsOneWidget);
    expect(st.overlayForTest.plan.links, isEmpty);
    await drain(tester);
  });

  testWidgets('mount presets set the height; an edited node re-estimates itself after a pause', (tester) async {
    phone(tester);
    final h = Harness();
    h.client.planVerifyResult = _verify();
    final st = await openPlanner(tester, h);
    final n = st.controller!.addNode(name: 'Hilltop', lat: _a.lat, lon: _a.lon);
    await _coverage(tester, st);
    await _estimate(tester);
    await tapIn(tester, find.byKey(const Key('coverage-mount-tree')));
    expect(st.controller!.plan.node(n.id)!.mount, PlanMount.tree);
    expect(st.controller!.plan.node(n.id)!.antennaM, mountHeightM(PlanMount.tree));
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(h.client.planVerifyAsks, hasLength(2));
    expect(h.client.planVerifyAsks.last.antennaM, 15);
    expect(h.client.planVerifyAsks.last.mount, PlanMount.tree);
    expect(find.byKey(const Key('coverage-stale')), findsNothing);
    await drain(tester);
  });

  testWidgets('verify loop: an installed node is compared with the measured cells around it', (tester) async {
    phone(tester);
    final h = Harness();
    h.client.planVerifyResult = _verify();
    CoverageCell cell(PlanPoint p, {required bool heard, double? snr}) =>
        CoverageCell(lat: p.lat, lon: p.lon, pings: 4, heard: heard ? 3 : 0, bestSnr: snr, medianSnr: snr, repeaters: heard ? 1 : 0, lastAt: '2026-11-14T12:00:00Z');
    h.client.publicCoverageResult = PublicCoverage(
      cells: [
        cell(offsetM(_a, 300, 0), heard: true, snr: 5),
        cell(offsetM(_a, 0, 1200), heard: false),
        cell(offsetM(_a, -800, 0), heard: true, snr: -1),
      ],
      asOf: '2026-11-15T00:00:00Z',
      grid: const CoverageGrid.square(cellDeg: 0.002),
    );
    final st = await openPlanner(tester, h);
    await AppScopeRead.refresh(tester);
    st.controller!.addNode(name: 'Hilltop', lat: _a.lat, lon: _a.lon, status: PlanNodeStatus.installed);
    await _coverage(tester, st);
    await _estimate(tester);
    expect(find.byKey(const Key('coverage-verify-loop')), findsOneWidget);
    expect(find.textContaining('Measured cells inside the estimate'), findsOneWidget);
    expect(find.textContaining('Predicted to decode, but nothing was heard: 1 cell'), findsOneWidget);
    expect(find.textContaining('Mean SNR measured / predicted'), findsOneWidget);
    expect(find.textContaining('Our drives near it: 3 drive cells within 2 km'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('a planned node says how the verify loop starts; the server refusing shows the error with a retry', (tester) async {
    phone(tester);
    final h = Harness();
    h.client.planVerifyError = const CmatException('the site must be in or near this region', status: 400);
    final st = await openPlanner(tester, h);
    st.controller!.addNode(name: 'Hilltop', lat: _a.lat, lon: _a.lon);
    await _coverage(tester, st);
    await _estimate(tester);
    expect(find.byKey(const Key('coverage-error')), findsOneWidget);
    expect(find.textContaining('in or near this region'), findsOneWidget);
    expect(find.byKey(const Key('plan-footprint-layer')), findsNothing);
    h.client.planVerifyError = null;
    h.client.planVerifyResult = _verify();
    await tapIn(tester, find.text('Try again'));
    await settle(tester);
    expect(find.byKey(const Key('coverage-result')), findsOneWidget);
    expect(find.textContaining('mark it Installed'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('leaving the mode takes the layer off the map; coming back shows the kept results without a new request', (tester) async {
    phone(tester);
    final h = Harness();
    h.client.planVerifyResult = _verify();
    final st = await openPlanner(tester, h);
    st.controller!.addNode(name: 'Hilltop', lat: _a.lat, lon: _a.lon);
    await _coverage(tester, st);
    await _estimate(tester);
    expect(find.byKey(const Key('plan-footprint-layer')), findsOneWidget);
    await tapIn(tester, find.byKey(const Key('planner-mode-link')));
    await settle(tester);
    expect(find.byKey(const Key('plan-footprint-layer')), findsNothing);
    await _coverage(tester, st);
    expect(find.byKey(const Key('plan-footprint-layer')), findsOneWidget);
    expect(find.byKey(const Key('coverage-result')), findsOneWidget);
    expect(h.client.planVerifyAsks, hasLength(1));
    await drain(tester);
  });

  for (final scale in [1.0, 2.35]) {
    testWidgets('no overflow at ${scale}x text with results, the layer controls, a spot and the matrix', (tester) async {
      phone(tester, scale: scale, w: 390, h: 844);
      final h = Harness();
      h.client.planVerifyResult = _verify();
      h.client.planLinkResult = _link;
      final st = await openPlanner(tester, h);
      st.controller!.addNode(name: 'A very long site name on the ridge above the river', lat: _a.lat, lon: _a.lon);
      final b = offsetM(_a, 0, 2500);
      st.controller!.addNode(name: 'Barn', lat: b.lat, lon: b.lon, status: PlanNodeStatus.installed);
      await _coverage(tester, st);
      await _estimate(tester, key: 'coverage-run-all');
      await _estimate(tester, key: 'coverage-matrix-run');
      await tapIn(tester, find.byKey(const Key('coverage-spot-centre')));
      await settle(tester);
      expect(find.byKey(const Key('coverage-spot-result')), findsOneWidget);
      expect(tester.takeException(), isNull);
      // VoiceOver: the section titles are headers, the sliders say what they set.
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp('Minimum SNR')), findsWidgets);
      handle.dispose();
      await drain(tester);
    });
  }
}

/// Fetches the network coverage the harness serves (the verify loop's measured cells).
abstract final class AppScopeRead {
  static Future<void> refresh(WidgetTester tester) async {
    final s = tester.state<PlannerScreenState>(find.byType(PlannerScreen));
    final app = AppScope.read(s.context);
    await app.refreshNetworkCoverage();
    await settle(tester);
  }
}
