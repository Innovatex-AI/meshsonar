// Pre-release visual QA sweep (0.26). Run on a simulator with --dart-define=QA_PHASE=<phase>:
//   first | plan | region | more | map | all. Prints "SCREEN <name>" for a script to screenshot, and
//   "OVERFLOW <detail>" / "EXC <detail>" for every framework error raised while it ran (instead of failing).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;

import 'screens.dart';

const phase = String.fromEnvironment('QA_PHASE', defaultValue: 'all');
const landscape = bool.fromEnvironment('QA_LAND');
bool want(String p) => phase == 'all' || phase == p;

Future<void> back(WidgetTester t) async {
  final b = find.byTooltip('Back');
  if (b.evaluate().isNotEmpty) {
    await t.tap(b.first);
  } else {
    await t.pageBack();
  }
  await pumpFor(t, const Duration(seconds: 1));
}

Future<void> step(String name, Future<void> Function() f) async {
  try {
    await f();
  } catch (e) {
    // ignore: avoid_print
    print('STEPFAIL $name: ${e.toString().split('\n').first}');
  }
}

Future<void> scrollShots(WidgetTester t, String prefix, {int max = 3}) async {
  try {
    final sc = t.stateList<ScrollableState>(find.byType(Scrollable)).where((s) => s.axisDirection == AxisDirection.down && s.position.maxScrollExtent > 0).toList();
    if (sc.isEmpty) return;
    final pos = sc.last.position;
    final step = pos.viewportDimension * 0.85;
    for (var i = 2; i <= max && pos.pixels < pos.maxScrollExtent - 1; i++) {
      pos.jumpTo((pos.pixels + step).clamp(0, pos.maxScrollExtent));
      await shot(t, '$prefix-$i');
    }
  } catch (_) {}
}

Future<void> connectSimulator(WidgetTester t) async {
  await openShellTab(t, 'Drive');
  final chip = find.byKey(const Key('connection-chip'));
  if (!await waitFor(t, chip)) return;
  await t.tap(chip);
  await pumpFor(t, const Duration(seconds: 3));
  final sim = find.byKey(const Key('simulator'));
  if (sim.evaluate().isEmpty) {
    try {
      await t.scrollUntilVisible(sim, 300, scrollable: find.byType(Scrollable).first);
    } catch (_) {}
  }
  await t.ensureVisible(sim);
  await t.tapAt(t.getTopLeft(sim) + const Offset(60, 40));
  await pumpFor(t, const Duration(seconds: 4));
  final sheet = find.byKey(const Key('antenna-sheet'));
  if (await waitFor(t, sheet, timeout: const Duration(seconds: 6))) {
    final mount = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('mount-'));
    if (mount.evaluate().isNotEmpty) await t.tap(mount.first);
    await pumpFor(t, const Duration(milliseconds: 500));
    await t.tap(find.byKey(const Key('antenna-gain-unknown')));
    await t.enterText(find.byKey(const Key('antenna-height-field')), '5');
    await pumpFor(t, const Duration(milliseconds: 500));
    final save = find.byKey(const Key('antenna-save'));
    await t.ensureVisible(save);
    await t.tap(save);
    await pumpFor(t, const Duration(seconds: 2));
  }
}

Future<void> openPlanTool(WidgetTester t, String id) async {
  await openShellTab(t, 'Plan');
  var row = find.byKey(Key('plan-$id'));
  if (!await waitFor(t, row, timeout: const Duration(seconds: 3))) {
    await openShellTab(t, 'Plan');
    row = find.byKey(Key('plan-$id'));
  }
  if (row.evaluate().isEmpty) {
    await t.scrollUntilVisible(row, 150, scrollable: find.descendant(of: find.byKey(const Key('plan-list')), matching: find.byType(Scrollable)).first);
  }
  await t.ensureVisible(row);
  await t.tap(row);
  await pumpFor(t, const Duration(seconds: 3));
}

/// Makes Columbus (CMH) the viewing region through the region switcher, like a person would.
Future<void> selectColumbus(WidgetTester t) async {
  await openShellTab(t, 'Analyze');
  await t.tap(find.descendant(of: find.byKey(const Key('analyze-segments')), matching: find.text('Region')));
  await pumpFor(t, const Duration(seconds: 2));
  final chip = find.byKey(const Key('region-switch-chip'));
  if (!await waitFor(t, chip)) return;
  if ('${(t.widget(chip) as ActionChip).label is Text ? ((t.widget(chip) as ActionChip).label as Text).data : ''}'.startsWith('CMH')) return;
  await t.tap(chip);
  await pumpFor(t, const Duration(seconds: 2));
  final search = find.byKey(const Key('region-search'));
  if (search.evaluate().isNotEmpty) {
    await t.enterText(search, 'columbus');
    await pumpFor(t, const Duration(seconds: 2));
  }
  final row = find.byWidgetPredicate((w) => w.key is ValueKey && RegExp(r'^region-(near|recent|option)-CMH$').hasMatch('${(w.key as ValueKey).value}'));
  // ignore: avoid_print
  print('CMH-ROW ${row.evaluate().length}');
  if (row.evaluate().isEmpty) return;
  await t.tap(row.first);
  await pumpFor(t, const Duration(seconds: 8));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('qa sweep', (t) async {
    FlutterError.onError = (d) {
      final s = d.exceptionAsString();
      if (s.contains('Barometer is not available')) return;
      // ignore: avoid_print
      print('${s.contains('overflow') ? 'OVERFLOW' : 'EXC'} ${s.split('\n').take(3).join(' | ')} ${d.context ?? ''}');
    };
    if (landscape) await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      await shot(t, 'onboarding-1');
      for (var i = 2; i <= 4; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(seconds: 1));
        if (want('first')) await shot(t, 'onboarding-$i');
      }
      await t.tap(find.byKey(const Key('onboarding-next')));
      await pumpFor(t, const Duration(seconds: 1));
    }
    await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail')));
    final keep = find.byKey(const Key('telemetry-keep'));
    if (await waitFor(t, keep, timeout: const Duration(seconds: 6))) {
      await shot(t, 'disclosure');
      await t.tap(keep);
      await pumpFor(t, const Duration(seconds: 1));
    }

    if (phase != 'first' && phase != 'more') await step('columbus', () => selectColumbus(t));

    if (want('first')) {
      await step('tabs', () async {
        for (final tab in ['Chat', 'Drive', 'Analyze', 'Plan', 'More']) {
          await openShellTab(t, tab);
          await shot(t, 'tab-${tab.toLowerCase()}');
          if (tab == 'More') await scrollShots(t, 'tab-more', max: 4);
        }
      });
    }

    if (want('plan')) {
      const ids = ['planner', 'recommended', 'sites', 'scenarios', 'tracker', 'link', 'painter', 'airtime', 'presets', 'check', 'field'];
      for (final id in ids) {
        await step('plan-$id', () async {
          await openPlanTool(t, id);
          await shot(t, 'plan-$id');
          await scrollShots(t, 'plan-$id');
          await back(t);
        });
      }
    }

    if (want('region')) {
      await step('region', () async {
        await openShellTab(t, 'Analyze');
        await t.tap(find.descendant(of: find.byKey(const Key('analyze-segments')), matching: find.text('Region')));
        await pumpFor(t, const Duration(seconds: 6));
        await shot(t, 'region-initial');
        const tabs = ['Overview', 'Repeaters', 'Observers', 'Packets', 'Routes', 'Analysis', 'RF', 'Growth', 'Findings', 'Reports', 'Stats', 'Live', 'Hops', 'Silent', 'Wardrive'];
        for (final name in tabs) {
          await step('region-$name', () async {
            final tab = find.descendant(of: find.byType(TabBar), matching: find.text(name));
            await t.ensureVisible(tab.first);
            await t.tap(tab.first);
            await pumpFor(t, const Duration(seconds: 5));
            await shot(t, 'region-$name');
            await scrollShots(t, 'region-$name', max: 2);
          });
        }
      });
      // Plan tools again, now with a viewing region.
      if (phase == 'all') {
        for (final id in ['planner', 'recommended', 'sites', 'scenarios', 'link', 'painter', 'airtime', 'check']) {
          await step('plan2-$id', () async {
            await openPlanTool(t, id);
            await shot(t, 'plan-region-$id');
            await back(t);
          });
        }
      }
    }

    if (want('more')) {
      const rows = ['more-devices', 'more-myReports', 'more-leaderboard', 'more-notifications', 'more-wardriving', 'more-observerJoin', 'more-radio', 'more-repeaters', 'more-myRadios', 'more-method', 'more-settings', 'more-about', 'more-privacy', 'more-trace', 'more-discover', 'more-adverts', 'more-rxLog', 'more-noiseFloor', 'more-telemetry', 'more-radioSetup'];
      for (final key in rows) {
        await step(key, () async {
          await openShellTab(t, 'More');
          if (find.byKey(const Key('more-list')).hitTestable().evaluate().isEmpty) await openShellTab(t, 'More');
          final row = find.byKey(Key(key));
          final sc = find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first;
          t.state<ScrollableState>(sc).position.jumpTo(0);
          await t.pump(const Duration(milliseconds: 300));
          if (row.evaluate().isEmpty) {
            await t.scrollUntilVisible(row, 150, scrollable: sc);
          }
          await t.ensureVisible(row);
          await t.tap(row);
          await pumpFor(t, const Duration(seconds: 3));
          await shot(t, key);
          await scrollShots(t, key, max: 3);
          if (key == 'more-settings') {
            final diag = find.text('Diagnostics');
            if (diag.evaluate().isNotEmpty) {
              await t.scrollUntilVisible(diag, 200, scrollable: find.byType(Scrollable).first);
              await t.tap(diag.first);
              await pumpFor(t, const Duration(seconds: 2));
              await shot(t, 'settings-diagnostics');
              final ov = find.byKey(const Key('map-health-overlay'));
              if (ov.evaluate().isNotEmpty) {
                await t.ensureVisible(ov);
                await t.tap(ov.first);
                await pumpFor(t, const Duration(seconds: 1));
                await shot(t, 'settings-diagnostics-overlay-on');
              }
              await back(t);
            }
          }
          await back(t);
        });
      }
    }

    if (want('map')) {
      await step('map', () async {
        await connectSimulator(t);
        await openShellTab(t, 'Drive');
        await shot(t, 'map-ready');
        await t.tap(find.byKey(const Key('start-stop')));
        await pumpFor(t, const Duration(seconds: 25));
        for (var i = 1; i <= 4; i++) {
          await shot(t, 'map-drive-$i');
        }
        // finger drag pauses follow
        await t.dragFrom(t.getCenter(find.byKey(const Key('drive-map'))) + const Offset(40, 50), const Offset(60, 20));
        await pumpFor(t, const Duration(seconds: 1));
        await shot(t, 'map-dragged');
        final rc = find.byKey(const Key('map-recenter'));
        // ignore: avoid_print
        print('RECENTER-VISIBLE ${rc.evaluate().isNotEmpty}');
        if (rc.evaluate().isNotEmpty) {
          await t.tap(rc);
          await pumpFor(t, const Duration(seconds: 2));
          await shot(t, 'map-recentered');
        }
        await t.tap(find.byKey(const Key('ping-now')));
        await pumpFor(t, const Duration(seconds: 3));
        await shot(t, 'map-ping');
        await pumpFor(t, const Duration(seconds: 8));
        await shot(t, 'map-ping-after');
        final lay = find.byKey(const Key('drive-map-layers'));
        if (lay.evaluate().isNotEmpty) {
          await t.tap(lay);
          await pumpFor(t, const Duration(seconds: 1));
          await shot(t, 'map-layers');
          await t.tapAt(const Offset(5, 60));
          await pumpFor(t, const Duration(seconds: 1));
        }
        final chip = find.byKey(const Key('ping-settings-chip'));
        if (chip.evaluate().isNotEmpty) {
          await t.tap(chip);
          await pumpFor(t, const Duration(seconds: 1));
          await shot(t, 'map-ping-settings');
          await t.tapAt(const Offset(5, 60));
          await pumpFor(t, const Duration(seconds: 1));
        }
        final fs = find.byKey(const Key('map-fullscreen'));
        if (fs.evaluate().isNotEmpty) {
          await t.tap(fs);
          await pumpFor(t, const Duration(seconds: 4));
          await shot(t, 'map-fullscreen');
          final ml = find.byKey(const Key('map-layers'));
          if (ml.evaluate().isNotEmpty) {
            await t.tap(ml);
            await pumpFor(t, const Duration(seconds: 1));
            await shot(t, 'map-fullscreen-layers');
            await t.tapAt(const Offset(5, 60));
            await pumpFor(t, const Duration(seconds: 1));
          }
          await t.tap(find.byKey(const Key('fullscreen-close')));
          await pumpFor(t, const Duration(seconds: 1));
        }
        await t.tap(find.byKey(const Key('start-stop')));
        await pumpFor(t, const Duration(milliseconds: 600));
        final confirm = find.byKey(const Key('stop-drive-confirm'));
        if (confirm.evaluate().isNotEmpty) await t.tap(confirm);
        await pumpFor(t, const Duration(seconds: 3));
        await shot(t, 'map-stopped');
      });
    }
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 25)));
}
