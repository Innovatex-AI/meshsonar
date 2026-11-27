// The Planner's Link mode (release 0.38 A8, job A "Will A hear B"): ends from the plan / network, the three-state verdict
// from the server's own plan-link answers (test/fixtures/plan_server/), raise + ridge, measured next to predicted,
// direction, receiver height, profile scrubbing, relay finder, snap to high ground, offline re-judging on the phone, the
// glossary and large text. Driven through the real Planner with the fake CmatClient answering plan-link.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/ui/plan/modes/link_mode.dart';

import '../../fakes.dart';
import '../../plan_drive_next_test.dart' show cell;
import '../../shell_test.dart' show phone, drain;
import '../planner_test.dart' show openPlanner, tapIn, settle;

Map<String, dynamic> _fixture(String name) => jsonDecode(File('test/fixtures/plan_server/$name.json').readAsStringSync()) as Map<String, dynamic>;

PlanLinkResult _answer(String kind) => PlanLinkResult.parse(_fixture('plan-link.$kind.response'));

const _aKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _bKey = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _eu = PlanRadio(freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 8);

void main() {
  group('flow A: will A hear B', () {
    testWidgets('two network repeaters: measured evidence beside the model, verdict follows the measurement, ridge on the map', (tester) async {
      phone(tester, h: 1400);
      final h = Harness();
      h.client.planLinkResult = _answer('measured');
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      c.addNode(name: 'Ridge Top', lat: 37.25, lon: -79.93, status: PlanNodeStatus.existing, existingKey: _aKey, heightM: 8);
      c.addNode(name: 'Valley', lat: 37.33, lon: -79.95, status: PlanNodeStatus.existing, existingKey: _bKey, heightM: 8);
      await settle(tester);

      // The request is the server fixture's request: ends, heights, the plan's radio, clutter, direction, the public keys.
      expect(h.client.planLinkAsks, hasLength(1));
      expect(h.client.planLinkAsks.single.toJson(), _fixture('plan-link.measured.request'));

      expect(find.text('Works (Estimate)'), findsOneWidget);
      expect(find.byKey(const Key('link-disagree')), findsOneWidget, reason: 'model margin -126 dB says Unlikely; 41 packets say it works');
      expect(find.textContaining('41 packets heard'), findsOneWidget);
      expect(find.text('Measured mean SNR'), findsOneWidget, reason: 'the figure is under The numbers');
      expect(find.textContaining('mean SNR 2.5 dB'), findsNothing);
      expect(find.byKey(const Key('link-confidence')), findsOneWidget);
      expect(find.textContaining('Confidence: Measured'), findsOneWidget);
      expect(find.byKey(const Key('link-profile')), findsOneWidget);
      expect(find.byKey(const Key('link-ridge')), findsOneWidget);
      expect(find.byKey(const Key('link-relay-find')), findsNothing, reason: 'a link that works needs no relay');
      expect(find.byKey(const Key('link-snap-a')), findsNothing, reason: 'existing repeaters are not moved');
      // The pair is drawn by its verdict and the ridge is flagged on the map at the server's point.
      expect(st.overlayForTest.plan.links.single.verdict.name, 'likely');
      final ridge = st.overlayForTest.targets.singleWhere((t) => t.id == 'link-ridge');
      expect(ridge.at.latitude, 37.29);
      await drain(tester);
    });

    testWidgets('a planned site to a handheld on the plan\'s EU radio, Down: Unlikely, raise B with one tap, receiver height', (tester) async {
      phone(tester, h: 1400);
      final h = Harness();
      h.client.planLinkResult = _answer('estimate');
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      c.setRadio(_eu);
      c.addNode(name: 'Hill site', lat: 37.1, lon: -80.2, heightM: 10);
      final b = c.addNode(name: 'Walker', lat: 37.12, lon: -80.14, role: PlanNodeRole.handheld);
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('link-dir-down')));
      await settle(tester);
      expect(tester.state<LinkModeBodyState>(find.byType(LinkModeBody)).direction, PlanDirection.down);
      // Never a hard-coded radio: the plan's EU setting, the handheld at the receiver height, Down.
      expect(h.client.planLinkAsks.last.toJson(), _fixture('plan-link.estimate.request'));

      expect(find.text('Unlikely (Estimate)'), findsOneWidget);
      expect(find.byKey(const Key('link-raise')), findsOneWidget);
      expect(find.textContaining(RegExp(r'^Raise Walker .+ to clear (the hill|the ground in between)\.$')), findsOneWidget,
          reason: 'B is the lower antenna, the raise goes there; plain words (round 4 P-U4)');
      expect(find.textContaining('Fresnel zone.'), findsNothing, reason: 'the 60 % figure is under The numbers');
      expect(find.byKey(const Key('link-margin')), findsOneWidget, reason: 'the link margin is under The numbers');
      expect(tester.getTopLeft(find.byKey(const Key('link-raise'))).dy, lessThan(tester.getTopLeft(find.byKey(const Key('link-margin'))).dy),
          reason: 'advice before the figures');
      // Link no longer repeats the radio and tree settings (they live in Radio and trees).
      for (final gone in const ['link-radio', 'link-canopy', 'link-clutter']) {
        expect(find.byKey(Key(gone)), findsNothing, reason: gone);
      }
      expect(find.byKey(const Key('link-receiver')), findsOneWidget);
      expect(find.byKey(const Key('link-ridge')), findsOneWidget);
      expect(find.byKey(const Key('link-relay-find')), findsOneWidget);
      expect(find.byKey(const Key('link-snap-a')), findsOneWidget, reason: 'a planned end can snap to high ground');
      expect(find.byKey(const Key('link-measured-none')), findsOneWidget);
      expect(find.textContaining('Confidence: Estimate'), findsOneWidget);
      expect(st.overlayForTest.plan.links.single.verdict.name, 'unlikely');

      // Receiver height: the handheld end follows the plan's receiverM.
      c.setReceiverM(3);
      await settle(tester);
      expect(h.client.planLinkAsks.last.hbM, 3);
      expect(c.plan.receiverM, 3);

      // One tap applies the raise (one undo step).
      await tapIn(tester, find.byKey(const Key('link-raise-apply')));
      await settle(tester);
      expect(c.plan.node(b.id)!.heightM, 3 + 188);
      expect(h.client.planLinkAsks.last.hbM, 191);
      c.undo();
      await settle(tester);
      expect(c.plan.node(b.id)!.heightM, isNull);
      await drain(tester);
    });

    testWidgets('scrubbing the profile moves a crosshair: readout at the finger, the spot on the map, VoiceOver adjustable', (tester) async {
      phone(tester, h: 1400);
      final h = Harness();
      h.client.planLinkResult = _answer('estimate');
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      c.addNode(name: 'A', lat: 37.1, lon: -80.2, heightM: 10);
      c.addNode(name: 'B', lat: 37.12, lon: -80.14, heightM: 1.5);
      await settle(tester);
      final chart = find.byKey(const Key('link-profile'));
      await tester.ensureVisible(chart);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Touch and drag along the chart'), findsWidgets);
      final box = tester.getRect(chart);
      final g = await tester.startGesture(Offset(box.left + box.width * 0.2, box.center.dy));
      await g.moveTo(Offset(box.left + box.width * 0.63, box.center.dy));
      await g.up();
      await settle(tester);
      final readout = tester.widget<Text>(find.byKey(const Key('link-scrub-readout'))).data!;
      expect(readout, contains('from A: ground'));
      expect(readout, contains('above the line of sight (blocked)'), reason: 'at 63 % the second hill is above the line');
      final scrub = st.overlayForTest.targets.singleWhere((t) => t.id == 'link-scrub');
      expect(scrub.at.latitude, closeTo(37.1 + 0.02 * 0.63, 0.002));

      final handle = tester.ensureSemantics();
      final node = tester.getSemantics(chart);
      expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
      expect(node.value, readout);
      tester.semantics.performAction(find.semantics.byLabel(RegExp(r'^Terrain profile from A to B')), SemanticsAction.increase);
      await settle(tester);
      final after = st.overlayForTest.targets.singleWhere((t) => t.id == 'link-scrub');
      expect(after.at.latitude, greaterThan(scrub.at.latitude));
      handle.dispose();
      await drain(tester);
    });

    testWidgets('relay finder: ranked points with both hops, drawn on the map, Add puts one in the plan', (tester) async {
      phone(tester, h: 1400);
      final h = Harness();
      h.client.planLinkResult = _answer('estimate');
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      c.addNode(name: 'A', lat: 37.1, lon: -80.2, heightM: 10);
      c.addNode(name: 'B', lat: 37.12, lon: -80.14, heightM: 1.5);
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('link-relay-find')));
      await settle(tester);
      expect(find.byKey(const Key('link-relay-0')), findsOneWidget);
      expect(find.textContaining('R1: '), findsOneWidget);
      expect(st.overlayForTest.targets.where((t) => t.id.startsWith('link-relay-')), isNotEmpty);
      await tapIn(tester, find.byKey(const Key('link-relay-add-0')));
      await settle(tester);
      expect(c.nodes, hasLength(3));
      expect(c.nodes.last.name, 'Relay 1');
      expect(c.nodes.last.status, PlanNodeStatus.planned);
      expect(find.textContaining('Added Relay 1'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('snap to high ground moves a planned end to the highest terrain nearby (Undo puts it back)', (tester) async {
      phone(tester, h: 1400);
      final h = Harness();
      h.client.planLinkResult = _answer('estimate');
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      final a = c.addNode(name: 'Pole', lat: 37.1, lon: -80.2, heightM: 10);
      c.addNode(name: 'B', lat: 37.12, lon: -80.14, status: PlanNodeStatus.existing, heightM: 8);
      await settle(tester);
      expect(find.byKey(const Key('link-snap-b')), findsNothing);
      await tapIn(tester, find.byKey(const Key('link-snap-a')));
      await settle(tester);
      final moved = c.plan.node(a.id)!;
      expect(moved.lat == 37.1 && moved.lon == -80.2, isFalse);
      expect(find.textContaining('Moved Pole'), findsOneWidget);
      c.undo();
      expect(c.plan.node(a.id)!.lat, 37.1);
      await drain(tester);
    });
  });

  group('states', () {
    testWidgets('empty: no spots shows the first-run card only; one spot asks for the other end with Add a spot and the network picker', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      expect(find.byKey(const Key('plan-first-run')), findsOneWidget);
      expect(find.text('Add two spots to check a link'), findsNothing, reason: 'round 4 P-V2: one empty state');
      st.controller!.addNode(name: 'Only', lat: 40.1, lon: -82.9);
      await settle(tester);
      expect(find.text('Add one more spot to check a link'), findsOneWidget);
      expect(find.text('Add a spot'), findsWidgets);
      expect(find.text('Add from the network'), findsWidgets);
      // The ends use the app's pick field, not a Material dropdown (P-V4).
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      await drain(tester);
    });

    testWidgets('offline with no answer anywhere: an honest error with a retry; offline after one answer: re-judged on the phone', (tester) async {
      phone(tester, h: 1400);
      final h = Harness();
      h.client.planLinkError = const CmatException('no connection');
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      final a = c.addNode(name: 'A', lat: 37.1, lon: -80.2, heightM: 10);
      c.addNode(name: 'B', lat: 37.12, lon: -80.14, heightM: 1.5);
      await settle(tester);
      expect(find.byKey(const Key('link-error')), findsOneWidget);
      expect(find.text('No answer: the link could not be checked'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      // The connection comes back for one check...
      h.client.planLinkError = null;
      h.client.planLinkResult = _answer('estimate');
      await tapIn(tester, find.byKey(const Key('link-run')));
      await settle(tester);
      expect(find.text('Unlikely (Estimate)'), findsOneWidget);
      // ...then goes again, and A is raised: the same terrain profile is judged on the phone for the new height.
      h.client.planLinkError = const CmatException('timed out after 45 s');
      c.updateNode(a.id, (n) => n.copyWith(heightM: 200));
      await settle(tester);
      expect(h.client.planLinkAsks.last.haM, 200);
      expect(find.byKey(const Key('link-error')), findsNothing);
      expect(find.byKey(const Key('link-result')), findsOneWidget);
      expect(find.byKey(const Key('plan-ondevice-note')), findsOneWidget);
      expect(find.byKey(const Key('plan-offline-note')), findsOneWidget);
      expect(find.byKey(const Key('link-stale')), findsNothing, reason: 'the on-phone answer is for the new height');
      await drain(tester);
    });

    testWidgets('drive cells near each end are the measured evidence line', (tester) async {
      phone(tester, h: 1400);
      final h = Harness();
      h.client.planLinkResult = _answer('estimate');
      h.client.publicCoverageResult = PublicCoverage(
        asOf: '2026-11-15T00:00:00Z',
        grid: const CoverageGrid.square(cellDeg: 0.005),
        cells: [cell(40.101, -82.901), cell(40.105, -82.905), cell(40.5, -82.5)],
      );
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      c.addNode(name: 'A', lat: 40.10, lon: -82.90);
      c.addNode(name: 'B', lat: 40.15, lon: -82.80);
      await settle(tester);
      expect(find.textContaining(RegExp(r'^Drive data near A: 2 drive cells within .+; near B: no drives within .+ \(unobserved, estimate\)\.$')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('the glossary explains the words in plain language', (tester) async {
      phone(tester, h: 1400);
      final h = Harness();
      h.client.planLinkResult = _answer('estimate');
      final st = await openPlanner(tester, h);
      st.controller!.addNode(name: 'A', lat: 37.1, lon: -80.2, heightM: 10);
      st.controller!.addNode(name: 'B', lat: 37.12, lon: -80.14, heightM: 1.5);
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('link-glossary')));
      await settle(tester);
      expect(find.byKey(const Key('link-glossary-sheet')), findsOneWidget);
      expect(find.text('Fresnel zone'), findsOneWidget);
      expect(find.text('Fade margin'), findsOneWidget);
      expect(find.textContaining('A 10 dB safety margin'), findsOneWidget);
      await drain(tester);
    });
  });

  group('Dynamic Type', () {
    for (final scale in [1.0, 2.35]) {
      testWidgets('no overflow at ${scale}x: result, chart, scrub, relays, settings and glossary', (tester) async {
        phone(tester, scale: scale, w: 390, h: 844);
        final h = Harness();
        h.client.planLinkResult = _answer('estimate');
        final st = await openPlanner(tester, h);
        st.controller!.addNode(name: 'A very long site name on the ridge above the river', lat: 37.1, lon: -80.2, heightM: 10);
        st.controller!.addNode(name: 'Walker with a long name', lat: 37.12, lon: -80.14, role: PlanNodeRole.handheld);
        await settle(tester);
        expect(find.byKey(const Key('link-result')), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('link-profile')));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tapAt(tester.getCenter(find.byKey(const Key('link-profile'))));
        await settle(tester);
        await tapIn(tester, find.byKey(const Key('link-relay-find')));
        await settle(tester);
        await tester.ensureVisible(find.byKey(const Key('link-receiver')));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: 'link mode at ${scale}x');
        await tapIn(tester, find.byKey(const Key('link-glossary')));
        await settle(tester);
        expect(find.byKey(const Key('link-glossary-sheet')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'glossary at ${scale}x');
        await drain(tester);
      });
    }
  });
}
