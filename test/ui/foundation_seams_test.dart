// Release 0.38 foundation seams (app): the Plan tab intake (ShellController.openPlan, plan links through AppState.planInbox),
// More > Observer replacing the Home observer row, the Settings Observer section, the plan map layer, the new hit kinds
// and the "open the map with this overlay" request.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/app/plan_inbox.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/map/core/map_hit_resolver.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/main_map_focus.dart';
import 'package:meshsonar/ui/map/sheets/map_hit_sheet.dart';
import 'package:meshsonar/ui/settings/observer_section.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

import 'fakes.dart';

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> _drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('plan intake', () {
    test('plan links: meshsonar.com /share/plan and /plan, meshsonar://plan; nothing else', () {
      expect(isPlanLink(Uri.parse('https://meshsonar.com/share/plan#p=abc')), isTrue);
      expect(isPlanLink(Uri.parse('https://meshsonar.com/plan/#p=abc')), isTrue);
      expect(isPlanLink(Uri.parse('https://cmh.meshsonar.com/share/plan')), isTrue);
      expect(isPlanLink(Uri.parse('meshsonar://plan#p=abc')), isTrue);
      expect(isPlanLink(Uri.parse('meshsonar://map?lat=1&lon=2')), isFalse);
      expect(isPlanLink(Uri.parse('https://meshsonar.com/coverage')), isFalse);
      expect(isPlanLink(Uri.parse('https://evil.example/share/plan')), isFalse);
      expect(isPlanLink(Uri.parse('https://notmeshsonar.com/plan')), isFalse);
      expect(isPlanLink(Uri.parse('http://meshsonar.com/plan')), isFalse);
      final inbox = PlanInbox();
      var n = 0;
      inbox.addListener(() => n++);
      expect(inbox.offer(Uri.parse('https://meshsonar.com/coverage')), isFalse);
      expect(inbox.offer(Uri.parse('https://meshsonar.com/plan#a')), isTrue);
      expect(inbox.offer(Uri.parse('https://meshsonar.com/plan#a')), isTrue, reason: 'the same link twice is kept once');
      expect(inbox.pending, hasLength(1));
      expect(n, 1);
      expect(inbox.take(), Uri.parse('https://meshsonar.com/plan#a'));
      expect(inbox.take(), isNull);
    });

    test('ShellController.openPlan: the Plan tab, and the request waits until the tab takes it', () {
      final c = ShellController();
      const seed = PlanNodeSeed(key: 'ab', name: 'Hilltop', lat: 40, lon: -83, source: 'repeater');
      c.openPlan(const PlanRequest.linkTo(seed));
      expect(c.tab, AppTab.plan);
      expect(c.pendingPlan, const PlanRequest.linkTo(seed));
      c.openPlan(const PlanRequest.openSaved('p1'));
      expect(c.takePendingPlan(), const PlanRequest.openSaved('p1'), reason: 'a newer request replaces one not taken');
      expect(c.takePendingPlan(), isNull);
      expect(const PlanRequest.point(seed).kind, PlanRequestKind.point);
    });

    testWidgets('a plan link that reaches the app opens the Plan tab with it; other links are ignored', (tester) async {
      _phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      final shell = ShellScope.maybeOf(tester.element(find.byType(DriveScreen)))!;
      h.incomingLinks.add(Uri.parse('https://meshsonar.com/coverage?lat=1'));
      await tester.pump();
      expect(shell.tab, AppTab.drive);
      final link = Uri.parse('https://meshsonar.com/share/plan#p=eJw');
      h.incomingLinks.add(link);
      await tester.pump();
      await tester.pump();
      expect(shell.tab, AppTab.plan);
      // The Plan tab (the Planner, release 0.38 A7) takes the request as soon as it is shown.
      expect(shell.pendingPlan, isNull, reason: 'the Plan tab took the link');
      expect(h.state.planInbox.isEmpty, isTrue);
      await _drain(tester);
    });
  });

  group('observer', () {
    testWidgets('More has no Home observer row; the Observer row moved into Settings (build 71) and MoreItem.observer opens that section', (tester) async {
      _phone(tester);
      final h = Harness()..approveKey();
      await h.pumpApp(tester);
      await tapShellTab(tester, 'More');
      expect(find.byKey(const Key('more-homeObserver')), findsNothing);
      expect(find.byKey(const Key('more-observer')), findsNothing, reason: 'a row that only jumped into Settings');
      ShellController.active!.openMore(MoreItem.observer);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('observer-status')), findsOneWidget);
      await _drain(tester);
    });

    test('the status line says what the observer waits for', () async {
      final h = Harness();
      await h.state.init();
      expect(observerStatusLine(h.state), contains('driver key'));
      h.settings.saved = h.state.settings.copyWith(telemetryEnabled: false);
      await h.state.updateSettings(h.state.settings.copyWith(telemetryEnabled: false));
      expect(observerStatusLine(h.state), startsWith('Off.'));
      final k = Harness()..approveKey();
      await k.state.init();
      expect(observerStatusLine(k.state), 'On: starts when your radio is connected.');
    });
  });

  group('map', () {
    test('the plan layer: registered, on top, off by default, never in the layers sheet, in app links', () {
      final plan = layerSpec(kPlanLayerId)!;
      expect(plan.z, greaterThan(kMapLayers.where((l) => l.id != kPlanLayerId).map((l) => l.z).reduce((a, b) => a > b ? a : b)));
      expect(plan.defaultOn, isFalse);
      expect(kDefaultLayerState.isOn(kPlanLayerId), isFalse);
      expect(appLayerId('plan'), kPlanLayerId);
      expect(definitionLayerId(kPlanLayerId), 'plan');
      for (final (_, rows) in sheetRows(MapDefinition.bundled)) {
        expect(rows.map((r) => r.id), isNot(contains(kPlanLayerId)));
      }
      final on = const MapLayerState().toggle(kPlanLayerId, true);
      expect(on.toShow(web: false), 'plan');
      expect(on.toShow(), '', reason: 'never in a website link');
    });

    test('a plan node wins a tap over everything else', () {
      final log = <String>[];
      final r = MapHitResolver();
      r.submit(MapHitCandidate(MapHitKind.ping, () => log.add('ping')));
      r.submit(MapHitCandidate(MapHitKind.planNode, () => log.add('plan')));
      r.resolveNow();
      expect(log, ['plan']);
      r.dispose();
    });

    testWidgets('plan-node and long-press hits go to the host handlers; without one nothing opens', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      const node = PlanNodeHit(nodeId: 'n1', name: 'Site A', lat: 40, lon: -83);
      const press = LongPressHit(lat: 40.5, lon: -83.5);
      expect(await showMapHitSheet(ctx, node), isFalse);
      expect(await showMapHitSheet(ctx, press), isFalse);
      final got = <MapHit>[];
      expect(await showMapHitSheet(ctx, node, onPlanNode: (_, h) async {
        got.add(h);
        return true;
      }), isTrue);
      expect(await showMapHitSheet(ctx, press, onLongPress: (_, h) async {
        got.add(h);
        return true;
      }), isTrue);
      expect(got, [node, press]);
    });

    test('MainMapFocus: a request can carry layers, a plan and targets', () {
      addTearDown(() => MainMapFocus.notifier.value = null);
      MainMapFocus.request(const LatLng(40, -83), 30);
      expect(MainMapFocus.notifier.value!.zoom, 18);
      expect(MainMapFocus.notifier.value!.hasOverlay, isFalse);
      const t = MapFocusTarget(id: 's1', at: LatLng(40.1, -83.1), label: 'Tree at 24 m');
      MainMapFocus.request(const LatLng(40, -83), 12, showLayers: {kPlanLayerId}, planId: 'p1', targets: const [t]);
      final r = MainMapFocus.notifier.value!;
      expect(r.hasOverlay, isTrue);
      expect(r.showLayers, {kPlanLayerId});
      expect(r.planId, 'p1');
      expect(r.targets, [t]);
      MainMapFocus.taken(r);
      expect(MainMapFocus.notifier.value, isNull);
    });
  });
}
