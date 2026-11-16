// The 0.38 Planner end to end on a simulator against the DEPLOYED server (build plan §11 "End to end", Q3;
// meshsonar-infra docs/VERIFY-ON-DEVICE.md Part 6 flows A-E and Part 7 J1-J8). Run it with
//   GRANT_LOCATION=1 FLOW_TEST=integration_test/planner_visual_test.dart scripts/verify_sim.sh <checkout>
// (iPhone 17 Pro, dark). It prints `SCREEN <name>` for the script's screenshots, `OPENURL <url>` for the script to open a
// link in the simulator (`xcrun simctl openurl`, J8), `STEP <name> ok|note` per check, and `STEPFAIL <why>` / `OVERFLOW
// <what>` for problems; the script fails the run on any STEPFAIL, MISSING or OVERFLOW line, and the test itself fails at the
// end when a step failed. Debug builds only (it drives the simulated radio for J2/J3).
//
// Live data decides some answers, so each flow accepts every HONEST state and fails only on a broken one:
//   * Find sites may answer "preparing this region" while the server builds its planning table (E11): that is a pass with
//     a note; an error view is a failure.
//   * A Coverage or Link check must come back with a result (the server is deployed): an error view is a failure.
// J2 is a required step (V-5, build 67). Not covered here (no way on a simulator): J6 "mine" needs a radio claimed under a signed-in account (widget-tested in
// test/ui/plan/q1_sim_tour_test.dart and the node-action matrix); exports through the Files app (the share sheet is shot
// at the very end, it cannot be dismissed from a Flutter test).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/core/plan/plan_controller.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/map/main_map_focus.dart';
import 'package:meshsonar/ui/plan/planner_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'screens.dart';

final List<String> _fails = [];
final List<String> _notes = [];

void _fail(String why) {
  _fails.add(why);
  // ignore: avoid_print
  print('STEPFAIL $why');
}

void _ok(String step, [String? note]) {
  if (note != null) _notes.add('$step: $note');
  // ignore: avoid_print
  print('STEP $step ${note == null ? 'ok' : 'note: $note'}');
}

Finder _key(String k) => find.byKey(Key(k));
Finder _prefix(String p) => find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith(p));

/// The first of [keys] that appears within [timeout], or null.
Future<String?> _firstOf(WidgetTester t, List<String> keys, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 200));
    for (final k in keys) {
      if (_key(k).evaluate().isNotEmpty) return k;
    }
  }
  return null;
}

/// Brings [f] into view (inside the sheet's scroll) and taps it. False when it is not there.
Future<bool> _tap(WidgetTester t, Finder f, {Duration wait = const Duration(seconds: 10), String? what}) async {
  if (!await waitFor(t, f, timeout: wait)) {
    if (what != null) _fail('MISSING $what');
    return false;
  }
  try {
    await t.ensureVisible(f.first);
  } catch (_) {}
  await pumpFor(t, const Duration(milliseconds: 400));
  await t.tap(f.first, warnIfMissed: false);
  await pumpFor(t, const Duration(milliseconds: 800));
  return true;
}

Future<void> _show(WidgetTester t, Finder f) async {
  try {
    await t.ensureVisible(f.first);
    await pumpFor(t, const Duration(milliseconds: 400));
  } catch (_) {}
}

/// Closes the sheet or route that holds [k].
Future<void> _closeOver(WidgetTester t, String k) async {
  final f = _key(k);
  if (f.evaluate().isEmpty) return;
  Navigator.of(t.element(f.first)).pop();
  await pumpFor(t, const Duration(seconds: 1));
}

/// The words under [k] (every Text and RichText, joined).
String _words(WidgetTester t, String k) {
  final out = <String>[];
  for (final e in find.descendant(of: _key(k), matching: find.byWidgetPredicate((w) => w is Text || w is RichText)).evaluate()) {
    final w = e.widget;
    if (w is Text) {
      out.add(w.data ?? w.textSpan?.toPlainText() ?? '');
    } else if (w is RichText) {
      out.add(w.text.toPlainText());
    }
  }
  return out.toSet().join(' ');
}

PlannerScreenState _planner(WidgetTester t) => t.state<PlannerScreenState>(find.byType(PlannerScreen, skipOffstage: false));
PlanController _plan(WidgetTester t) => _planner(t).controller!;

Future<bool> _until(WidgetTester t, bool Function() cond, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 200));
    if (cond()) return true;
  }
  return false;
}

/// Back to the first route of every navigator (closes sheets, pushed screens).
Future<void> _home(WidgetTester t) async {
  for (final n in t.stateList<NavigatorState>(find.byType(Navigator, skipOffstage: false))) {
    n.popUntil((r) => r.isFirst);
  }
  await pumpFor(t, const Duration(seconds: 1));
}

Future<void> _openPlanner(WidgetTester t) async {
  await openShellTab(t, 'Plan');
  if (!await waitFor(t, _key('planner'))) _fail('MISSING planner');
  await _until(t, () => _planner(t).controller != null);
}

Future<void> _menu(WidgetTester t, String item) async {
  await _tap(t, _key('plan-menu'), what: 'plan-menu');
  await _tap(t, _key(item), what: item);
  await pumpFor(t, const Duration(seconds: 1));
}

Future<void> _newPlan(WidgetTester t) async {
  await _menu(t, 'plan-menu-new');
  if (!await _until(t, () => _plan(t).nodes.isEmpty, timeout: const Duration(seconds: 8))) _fail('New plan did not open an empty plan');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('planner flows A-E and J1-J8 against the deployed server', (t) async {
    await app.main();
    final info = await PackageInfo.fromPlatform();
    // ignore: avoid_print
    print('APP_VERSION ${info.version}+${info.buildNumber}');

    // Every layout overflow on the way is reported (the script fails the run on an OVERFLOW line).
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) {
      final s = d.exceptionAsString();
      if (s.contains('overflowed')) {
        // ignore: avoid_print
        print('OVERFLOW ${s.split('\n').first}');
      }
      prevOnError?.call(d);
    };
    addTearDown(() => FlutterError.onError = prevOnError);

    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      for (var i = 0; i < 5 && _key('onboarding-next').evaluate().isNotEmpty; i++) {
        await t.tap(_key('onboarding-next'));
        await pumpFor(t, const Duration(milliseconds: 700));
      }
    }
    expect(await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))), isTrue, reason: 'home shell');
    if (await waitFor(t, _key('telemetry-keep'), timeout: const Duration(seconds: 6))) {
      await t.tap(_key('telemetry-keep'));
      await pumpFor(t, const Duration(seconds: 1));
    }
    final state = AppScope.of(t.element(find.byType(Scaffold).first));
    // The region's repeaters (live) feed the node picker; give the first sync a moment.
    await pumpFor(t, const Duration(seconds: 6));

    // ------------------------------------------------------------------------------------------ Plan opens
    await _openPlanner(t);
    final quick = await _firstOf(t, ['plan-quick-here', 'plan-quick-centre'], timeout: const Duration(seconds: 15));
    if (quick == null) _fail('MISSING the one-tap start (plan-quick-here / plan-quick-centre) on an empty plan');
    await shot(t, 'planner-01-empty');

    // ------------------------------------------------------------------------------------------ A: will A hear B
    await _tap(t, _key('plan-quick-network'), what: 'plan-quick-network');
    if (await waitFor(t, _key('node-picker'))) {
      final rows = _prefix('node-pick-');
      if (await waitFor(t, rows, timeout: const Duration(seconds: 40))) {
        await shot(t, 'planner-02-node-picker');
        final n = rows.evaluate().length;
        // The nearest repeater and one a few rows down (two side by side on one roof are too close to judge).
        await t.tap(rows.at(0));
        await pumpFor(t, const Duration(milliseconds: 800));
        await t.tap(rows.at(n > 3 ? 3 : n - 1));
        await pumpFor(t, const Duration(milliseconds: 800));
      } else {
        _fail('A: the node picker listed no repeaters near the map (live region data)');
      }
      await _closeOver(t, 'node-picker');
    } else {
      _fail('MISSING node-picker');
    }
    await _tap(t, _key('planner-mode-link'), what: 'planner-mode-link');
    if (_plan(t).nodes.length >= 2) {
      if (_key('link-tooclose').evaluate().isNotEmpty || _key('link-toofar').evaluate().isNotEmpty) {
        _ok('A', 'the two picked repeaters are out of the link range; checking anyway after a swap of B');
      }
      final r = await _firstOf(t, ['link-verdict', 'link-error'], timeout: const Duration(seconds: 75));
      if (r == 'link-verdict') {
        _ok('A1 verdict', _words(t, 'link-verdict'));
        await _show(t, _key('link-verdict'));
        await shot(t, 'planner-03-link-verdict');
        if (_key('link-profile').evaluate().isEmpty) _fail('A1: no terrain profile with the verdict');
        // A2: scrub the profile.
        final prof = _key('link-profile');
        if (prof.evaluate().isNotEmpty) {
          await _show(t, prof);
          final g = await t.startGesture(t.getCenter(prof.first) - const Offset(80, 0));
          await g.moveBy(const Offset(120, 0));
          await pumpFor(t, const Duration(milliseconds: 600));
          if (await waitFor(t, _key('link-scrub-readout'), timeout: const Duration(seconds: 4))) {
            _ok('A2 scrub');
          } else {
            _fail('A2: no scrub readout while dragging on the profile');
          }
          await shot(t, 'planner-04-link-scrub');
          await g.up();
          await pumpFor(t, const Duration(milliseconds: 600));
        }
        // A3: raise advice / ridge when the pair is not clear; A5 measured next to predicted; A4 the plan's radio.
        if (_key('link-raise').evaluate().isNotEmpty || _key('link-ridge').evaluate().isNotEmpty || _key('link-raise-relay').evaluate().isNotEmpty) {
          _ok('A3 advice shown');
        }
        if (_key('link-measured').evaluate().isEmpty && _key('link-measured-none').evaluate().isEmpty && _key('link-never-heard').evaluate().isEmpty) {
          _fail('A5: no Measured line (measured / none yet / never heard) beside the Estimate');
        }
        if (_key('link-confidence').evaluate().isEmpty) _fail('A: no calibration-confidence line (improvement 16)');
        await _show(t, _key('link-confidence'));
        await shot(t, 'planner-05-link-measured');
        // A5 direction-aware: Up re-checks.
        if (await _tap(t, _key('link-dir-up'), what: 'link-dir-up')) {
          final r2 = await _firstOf(t, ['link-verdict', 'link-error'], timeout: const Duration(seconds: 60));
          if (r2 != 'link-verdict') _fail('A5: no verdict after switching the direction to Up');
        }
        await _show(t, _key('link-radio'));
        if (_key('link-radio').evaluate().isEmpty) _fail('A4: the plan radio row is not in Link mode');
        await shot(t, 'planner-06-link-radio');
      } else {
        _fail('A: Link check ${r == null ? 'gave no answer in 75 s' : 'showed the error view'} against the deployed server');
        await shot(t, 'planner-03-link-failed');
      }
    } else {
      _fail('A: fewer than two nodes in the plan after the picker');
    }

    // ------------------------------------------------------------------------------------------ B: what would one here cover
    await _newPlan(t);
    final q = await _firstOf(t, ['plan-quick-here', 'plan-quick-centre'], timeout: const Duration(seconds: 10));
    if (q == null) {
      _fail('B: no one-tap start on the new empty plan');
    } else {
      if (q == 'plan-quick-centre') _ok('B', 'no phone position: started from the map centre');
      await _tap(t, _key(q));
      final r = await _firstOf(t, ['coverage-area', 'coverage-error'], timeout: const Duration(seconds: 120));
      if (r == 'coverage-area') {
        _ok('B2 footprint');
        await shot(t, 'planner-07-coverage-footprint');
        for (final k in ['coverage-opacity', 'coverage-min-snr', 'coverage-legend']) {
          if (_key(k).evaluate().isEmpty) _fail('B2: $k missing beside the footprint');
        }
        await _show(t, _key('coverage-result'));
        await shot(t, 'planner-08-coverage-stats');
      } else {
        _fail('B: coverage ${r == null ? 'gave no answer in 120 s' : 'showed the error view'}');
        await shot(t, 'planner-07-coverage-failed');
      }
      // B1/B3: long-press an empty spot above the sheet drops a second node; the link matrix and the spot check.
      final size = t.view.physicalSize / t.view.devicePixelRatio;
      final before = _plan(t).nodes.length;
      await t.longPressAt(Offset(size.width * 0.7, size.height * 0.22));
      await pumpFor(t, const Duration(seconds: 2));
      if (!await _until(t, () => _plan(t).nodes.length > before, timeout: const Duration(seconds: 5))) {
        _fail('B1: a long-press on the map dropped no node');
      } else {
        _ok('B1 long-press drop');
        await shot(t, 'planner-09-dropped-pin');
        await _tap(t, _key('planner-mode-coverage'));
        if (await _tap(t, _key('coverage-matrix-run'), wait: const Duration(seconds: 8))) {
          if (await waitFor(t, _key('coverage-matrix'), timeout: const Duration(seconds: 90))) {
            _ok('B3 link matrix');
            await _show(t, _key('coverage-matrix'));
            await shot(t, 'planner-10-link-matrix');
          } else {
            _fail('B3: the link matrix did not appear');
          }
        } else {
          _fail('MISSING coverage-matrix-run with two nodes');
        }
        if (await _tap(t, _key('coverage-spot-centre'), wait: const Duration(seconds: 4))) {
          if (await waitFor(t, _key('coverage-spot-result'), timeout: const Duration(seconds: 30))) {
            _ok('B3 how many repeaters see this spot');
          } else {
            _ok('B3 spot', 'no spot result (needs a footprint for each site first)');
          }
        }
      }
    }

    // ------------------------------------------------------------------------------------------ D: did it work (verify loop)
    {
      final c = _plan(t);
      final n = c.nodes.firstOrNull;
      if (n == null) {
        _fail('D: no node to mark installed');
      } else {
        _planner(t).selectNodeForTest(n.id);
        await pumpFor(t, const Duration(seconds: 1));
        if (await _tap(t, _key('plan-selected-edit'), what: 'plan-selected-edit')) {
          if (await waitFor(t, _key('node-editor'))) {
            await _tap(
              t,
              find.descendant(of: _key('node-status'), matching: find.text('Installed')),
              what: 'node-status Installed',
            );
            await shot(t, 'planner-11-node-installed');
            await _closeOver(t, 'node-editor');
          }
        }
        await _tap(t, _key('planner-mode-coverage'));
        if (_key('coverage-verify-loop').evaluate().isEmpty) await _tap(t, _key('coverage-run'));
        if (await waitFor(t, _key('coverage-verify-loop'), timeout: const Duration(seconds: 120))) {
          _ok('D verify loop');
          await _show(t, _key('coverage-verify-loop'));
          await shot(t, 'planner-12-verify-loop');
        } else {
          _fail('D: no "Did it work?" verify loop for an installed node');
        }
      }
    }

    // ------------------------------------------------------------------------------------------ C: where should I put one
    await _tap(t, _key('planner-mode-findSites'), what: 'planner-mode-findSites');
    var sitesShown = false;
    if (await waitFor(t, _key('plan-mode-sites'))) {
      await _tap(t, _key('sites-goal-overall'), what: 'sites-goal-overall');
      await _tap(t, _key('sites-run'), what: 'sites-run');
      final r = await _firstOf(t, ['sites-result', 'sites-preparing', 'sites-empty', 'sites-error'], timeout: const Duration(seconds: 40));
      switch (r) {
        case 'sites-result':
          sitesShown = true;
          _ok('C1 ranked sites (${_prefix('site-add-').evaluate().length})');
          await shot(t, 'planner-13-find-sites');
          await _tap(t, _key('sites-goal-coverage'));
          if (await _firstOf(t, ['sites-result', 'sites-preparing', 'sites-empty'], timeout: const Duration(seconds: 30)) == null) {
            _fail('C2: no answer after switching the goal to Coverage');
          }
          await shot(t, 'planner-14-find-sites-coverage');
          if (await _tap(t, _key('sites-verify'), wait: const Duration(seconds: 4))) {
            if (await waitFor(t, _prefix('site-check-'), timeout: const Duration(seconds: 60))) {
              _ok('C3 verify');
              await _show(t, _prefix('site-check-'));
              await shot(t, 'planner-15-find-sites-verify');
            } else {
              _fail('C3: Verify top 5 showed no check on any site');
            }
          }
          final add = _prefix('site-add-');
          if (add.evaluate().isNotEmpty) {
            final before = _plan(t).nodes.length;
            await _show(t, add);
            await t.tap(add.first, warnIfMissed: false);
            await pumpFor(t, const Duration(seconds: 1));
            if (_plan(t).nodes.length > before) {
              _ok('C4 add to plan');
            } else {
              _fail('C4: Add to plan added no node');
            }
          }
        case 'sites-preparing':
          _ok('C1', 'the server is still preparing this region (honest preparing state)');
          await shot(t, 'planner-13-find-sites-preparing');
        case 'sites-empty':
          _ok('C1', 'no candidates in this view (empty state)');
          await shot(t, 'planner-13-find-sites-empty');
        case 'sites-error':
          _fail('C1: Find sites showed the error view');
          await shot(t, 'planner-13-find-sites-error');
        default:
          _fail('C1: Find sites gave no answer in 40 s');
      }
      // C5: the wizard with a ZIP code, looked up on the phone, rounded to about 1 km.
      await _tap(t, _key('sites-tab-wizard'), what: 'sites-tab-wizard');
      if (await waitFor(t, _key('wizard-address'))) {
        await _show(t, _key('wizard-address'));
        await t.enterText(_key('wizard-address'), '43215');
        await pumpFor(t, const Duration(milliseconds: 500));
        await t.testTextInput.receiveAction(TextInputAction.done);
        await pumpFor(t, const Duration(milliseconds: 500));
        await _tap(t, _key('wizard-find-address'));
        var got = await _firstOf(t, ['wizard-point', 'wizard-lookup-error'], timeout: const Duration(seconds: 20));
        if (got == 'wizard-lookup-error') {
          _fail('C5: the ZIP lookup on the phone (GeocoderChannel) failed for 43215');
          if (await _tap(t, _key('wizard-use-here'), wait: const Duration(seconds: 3))) {
            got = await _firstOf(t, ['wizard-point'], timeout: const Duration(seconds: 5));
          }
        }
        if (got == 'wizard-point') {
          final text = _words(t, 'wizard-point');
          if (!RegExp(r'Around -?\d+\.\d{2}, -?\d+\.\d{2}\b').hasMatch(text)) _fail('C5: the wizard point is not shown rounded to 2 decimals: $text');
          _ok('C5 point', text);
          await _show(t, _key('wizard-point'));
          await shot(t, 'planner-16-wizard-point');
          await _tap(t, _key('wizard-run'), what: 'wizard-run');
          final w = await _firstOf(t, ['wizard-list-coverage', 'wizard-list-mesh', 'wizard-preparing', 'wizard-error-coverage', 'wizard-error-mesh'], timeout: const Duration(seconds: 50));
          if (w == null || w.startsWith('wizard-error')) {
            _fail('C5: the wizard ${w == null ? 'gave no answer' : 'showed an error'}');
          } else {
            _ok('C5 wizard', w == 'wizard-preparing' ? 'the server is still preparing this region' : null);
          }
          await pumpFor(t, const Duration(seconds: 2));
          await _show(t, _key(w ?? 'wizard-run'));
          await shot(t, 'planner-17-wizard-lists');
        } else {
          _fail('C5: no approximate point in the wizard');
        }
      } else {
        _fail('MISSING wizard-address');
      }
      // J4: Find-sites results drawn on the Drive map.
      if (sitesShown) {
        await _tap(t, _key('sites-tab-view'));
        await pumpFor(t, const Duration(seconds: 2));
        if (await _tap(t, _key('sites-drive-map'), wait: const Duration(seconds: 6))) {
          await pumpFor(t, const Duration(seconds: 3));
          if (MainMapFocus.overlay.isActive) {
            _ok('J4 sites on the Drive map (${MainMapFocus.overlay.drawnNodes.length} drawn)');
          } else {
            _fail('J4: the Drive map overlay is empty after Show all on the Drive map');
          }
          await shot(t, 'planner-18-drive-map-sites');
        }
      } else {
        _ok('J4', 'no Find-sites results to send to the Drive map (region preparing); J3 sends a chat point instead');
      }
    } else {
      _fail('MISSING plan-mode-sites');
    }

    // ------------------------------------------------------------------------------------------ J5: where to drive
    await _openPlanner(t);
    await _tap(t, _key('planner-mode-whereToDrive'), what: 'planner-mode-whereToDrive');
    if (await waitFor(t, _key('plan-mode-drive'))) {
      await pumpFor(t, const Duration(seconds: 4));
      await shot(t, 'planner-19-where-to-drive');
      if (await _tap(t, _key('drive-next-show-map'), wait: const Duration(seconds: 6))) {
        await pumpFor(t, const Duration(seconds: 3));
        if (MainMapFocus.overlay.isActive) {
          _ok('J5 targets on the Drive map');
        } else {
          _fail('J5: Show on the Drive map left the Drive map without targets');
        }
        await shot(t, 'planner-20-drive-map-targets');
      } else {
        _ok('J5', 'no drive targets here (Where to drive shows its own empty / location state)');
      }
    } else {
      _fail('MISSING plan-mode-drive');
    }

    // ------------------------------------------------------------------------------------------ E: share, paste import, J8 link
    await _openPlanner(t);
    await _newPlan(t);
    // Where to drive needs no nodes, so it shows no quick start: back to Link, whose empty plan offers it.
    await _tap(t, _key('planner-mode-link'), what: 'planner-mode-link (E)');
    await _tap(t, _key('plan-quick-network'), what: 'plan-quick-network (E)');
    if (await waitFor(t, _prefix('node-pick-'), timeout: const Duration(seconds: 20))) {
      final rows = _prefix('node-pick-');
      for (var i = 0; i < 3 && i < rows.evaluate().length; i++) {
        await t.tap(rows.at(i));
        await pumpFor(t, const Duration(milliseconds: 600));
      }
    }
    await _closeOver(t, 'node-picker');
    final shared = _plan(t).plan;
    final sharedCount = shared.nodes.length;
    String? link;
    if (sharedCount == 0) {
      _fail('E: no nodes to share');
    } else {
      await _menu(t, 'plan-menu-share');
      if (await waitFor(t, _key('plan-share'))) {
        await shot(t, 'planner-21-share');
        await Clipboard.setData(const ClipboardData(text: ''));
        await _tap(t, _key('plan-share-copy'), what: 'plan-share-copy');
        link = (await Clipboard.getData('text/plain'))?.text;
        if (link == null || !RegExp(r'^https://meshsonar\.com/share/plan#.+').hasMatch(link)) {
          _fail('E1: the copied link is not https://meshsonar.com/share/plan#…: $link');
          link = null;
        } else {
          _ok('E1 link (${link.length} chars)');
        }
        // E3: MeshCore setup lines carry name, lat, lon.
        if (await _tap(t, _key('plan-export-cli-copy'), wait: const Duration(seconds: 4))) {
          final cli = (await Clipboard.getData('text/plain'))?.text ?? '';
          if (!cli.contains('set lat') && !cli.contains('lat')) _fail('E3: the setup commands have no lat line');
        }
        await _closeOver(t, 'plan-share');
      } else {
        _fail('MISSING plan-share');
      }
    }
    if (link != null) {
      // E2: paste-import of the produced link into a different (new) plan.
      await _newPlan(t);
      await Clipboard.setData(ClipboardData(text: link));
      await _menu(t, 'plan-menu-import');
      if (await waitFor(t, _key('plan-import'))) {
        await shot(t, 'planner-22-import');
        await _tap(t, _key('plan-import-paste'), what: 'plan-import-paste');
        // A pasted plan link goes straight to the planner; other pastes need Continue.
        if (_key('plan-import').evaluate().isNotEmpty) await _tap(t, _key('plan-import-go'), wait: const Duration(seconds: 2));
        if (await _until(t, () => _plan(t).nodes.length == sharedCount && _plan(t).plan.name.contains(shared.name), timeout: const Duration(seconds: 15))) {
          _ok('E2 paste import round trip ($sharedCount nodes)');
          await shot(t, 'planner-23-imported');
        } else {
          _fail('E2: the pasted link did not open the plan (${_plan(t).nodes.length} nodes, "${_plan(t).plan.name}")');
        }
      } else {
        _fail('MISSING plan-import');
      }
      // J8: the same plan from a meshsonar://plan#<code> link opened by the system.
      await _newPlan(t);
      final code = link.substring(link.indexOf('#') + 1);
      // ignore: avoid_print
      print('OPENURL meshsonar://plan#$code');
      if (await _until(t, () => _plan(t).nodes.length == sharedCount, timeout: const Duration(seconds: 25))) {
        _ok('J8 meshsonar://plan link opened the plan');
        await shot(t, 'planner-24-opened-from-link');
      } else {
        _fail('J8: meshsonar://plan#<code> did not open the plan (${_plan(t).nodes.length} nodes)');
      }
    }

    // ------------------------------------------------------------------------------------------ J1: a repeater anywhere
    await _home(t);
    await openShellTab(t, 'Analyze');
    await _tap(t, find.descendant(of: _key('analyze-segments'), matching: find.text('Region')));
    final repTab = find.descendant(of: find.byType(TabBar), matching: find.text('Repeaters'));
    if (await _tap(t, repTab, wait: const Duration(seconds: 20))) {
      final row = _prefix('repeater-row-');
      if (await waitFor(t, row, timeout: const Duration(seconds: 30))) {
        final key = (t.widget(row.first).key as ValueKey<String>).value.substring('repeater-row-'.length).toLowerCase();
        await t.tap(row.first);
        await pumpFor(t, const Duration(seconds: 2));
        if (await waitFor(t, _key('node-actions'), timeout: const Duration(seconds: 20))) {
          await _show(t, _key('node-actions'));
          await shot(t, 'planner-25-repeater-actions');
          for (final a in ['planFrom', 'addToPlan', 'linkTo']) {
            if (_key('node-action-$a').evaluate().isEmpty) _fail('J1: the region repeater page has no $a action');
          }
          if (await _tap(t, _key('node-action-planFrom'), what: 'node-action-planFrom')) {
            if (await _until(t, () => _plan(t).nodes.any((n) => n.existingKey == key), timeout: const Duration(seconds: 10))) {
              _ok('J1 Plan from here');
              await shot(t, 'planner-26-plan-from-repeater');
            } else {
              _fail('J1: Plan from here did not start a plan at the repeater');
            }
          }
        } else {
          _fail('J1: no node actions on the region repeater page');
        }
      } else {
        _fail('J1: the region Repeaters list is empty (live)');
      }
    } else {
      _fail('J1: no Repeaters tab on the region page');
    }

    // ------------------------------------------------------------------------------------------ J3 + J2: the simulated radio
    await _home(t);
    final scanner = state.services.simulatorScanner as SimulatedRadioScanner;
    if (await state.connectSimulator()) {
      await pumpFor(t, const Duration(seconds: 3));
      // The first connect asks how the radio's antenna is set up: answer it (as the screen tour does).
      if (await waitFor(t, _key('antenna-sheet'), timeout: const Duration(seconds: 10))) {
        final mount = _prefix('mount-');
        if (mount.evaluate().isNotEmpty) await t.tap(mount.first, warnIfMissed: false);
        await pumpFor(t, const Duration(milliseconds: 500));
        await _tap(t, _key('antenna-gain-unknown'));
        if (_key('antenna-height-field').evaluate().isNotEmpty) await t.enterText(_key('antenna-height-field'), '5');
        await pumpFor(t, const Duration(milliseconds: 500));
        await _tap(t, _key('antenna-save'), what: 'antenna-save');
        await pumpFor(t, const Duration(seconds: 2));
      }
      while (find.byType(BottomSheet).evaluate().isNotEmpty) {
        await t.tapAt(const Offset(2, 2));
        await pumpFor(t, const Duration(seconds: 1));
      }
      // J3: a message with coordinates offers Open in Planner.
      final radio = scanner.lastTransport!;
      radio.injectDirectMessage('Ann KE8ANN', 'Meet at the water tower 39.9612,-83.0007 at 10');
      await pumpFor(t, const Duration(seconds: 5));
      await openShellTab(t, 'Chat');
      if (!await _tap(t, _key('segment-chats'), wait: const Duration(seconds: 8))) {
        await shot(t, 'planner-27-chat-no-segments');
        _fail('MISSING segment-chats on the Chat tab');
      } else {
        if (await _tap(t, find.text('Ann KE8ANN'), wait: const Duration(seconds: 15), what: 'the Ann KE8ANN conversation')) {
          final chip = _prefix('coord-planner-');
          if (await waitFor(t, chip, timeout: const Duration(seconds: 10))) {
            await shot(t, 'planner-27-chat-coordinates');
            await t.tap(chip.first);
            await pumpFor(t, const Duration(seconds: 3));
            if (await _until(t, () => _plan(t).nodes.any((n) => (n.lat - 39.9612).abs() < 0.001 && (n.lon + 83.0007).abs() < 0.001), timeout: const Duration(seconds: 10))) {
              _ok('J3 chat coordinates to the Planner');
              await shot(t, 'planner-28-chat-point-in-plan');
            } else {
              _fail('J3: Open in Planner put no pin at 39.9612,-83.0007');
            }
          } else {
            _fail('J3: no Open in Planner chip under a message with coordinates');
          }
        }
      }
      // J2: a repeater contact > Link to… (V-5, build 67: a required step now). Repeaters live under Chat > Network
      // (rows 'network-row-<prefix>'), below the radio card and the Nearby section in a lazily built CustomScrollView,
      // so on a phone the Repeaters rows are not built until the list is scrolled: the old lookup waited for a row that
      // was never built and noted "no repeater rows". The contact profile is a lazy ListView too (the plan rows sit under
      // the claim card), so Link to… is scrolled into view inside 'contact-profile', not the first Scrollable on screen.
      await _home(t);
      await openShellTab(t, 'Chat');
      await _tap(t, _key('segment-network'), what: 'segment-network');
      final tile = _prefix('network-row-');
      final rows = await scrollToFind(t, tile, _key('chat-scroll'));
      if (!rows) {
        await shot(t, 'planner-29-network-no-repeater');
        _fail('J2: no repeater rows under Chat > Network with the simulated radio');
      } else {
        final prefix = (t.widget(tile.first).key as ValueKey<String>).value.substring('network-row-'.length).toLowerCase();
        final before = _plan(t).nodes.length;
        await t.tap(tile.first, warnIfMissed: false);
        await pumpFor(t, const Duration(seconds: 1));
        final link2 = _key('node-action-linkTo');
        if (!await waitFor(t, _key('contact-profile'), timeout: const Duration(seconds: 10))) {
          _fail('J2: tapping a repeater row did not open its contact profile');
        } else if (!await scrollToFind(t, link2, _key('contact-profile'))) {
          await shot(t, 'planner-29-contact-profile');
          _fail('J2: the repeater contact profile has no Link to… row (the simulated repeaters all have a position)');
        } else {
          await shot(t, 'planner-29-contact-profile');
          await t.tap(link2.first, warnIfMissed: false);
          await pumpFor(t, const Duration(seconds: 1));
          if (await _until(t, () => _plan(t).nodes.any((n) => n.existingKey?.toLowerCase().startsWith(prefix) ?? false), timeout: const Duration(seconds: 10)) &&
              await waitFor(t, _key('plan-mode-link'), timeout: const Duration(seconds: 5))) {
            _ok('J2 contact to Link');
            await shot(t, 'planner-30-contact-link');
          } else {
            await shot(t, 'planner-30-contact-link-missing');
            _fail('J2: Link to… did not open Link mode with the contact as an end (plan had $before nodes, now ${_plan(t).nodes.length})');
          }
        }
      }
    } else {
      _fail('J2/J3: the simulated radio did not connect');
    }

    // ------------------------------------------------------------------------------------------ E1: the system share sheet (last:
    // a native sheet a Flutter test cannot dismiss).
    await _home(t);
    await _openPlanner(t);
    if (_plan(t).nodes.isNotEmpty) {
      await _menu(t, 'plan-menu-share');
      if (await _tap(t, _key('plan-share-link'), what: 'plan-share-link')) {
        await pumpFor(t, const Duration(seconds: 3));
        await shot(t, 'planner-31-system-share-sheet');
      }
    }

    // ignore: avoid_print
    print('RUN_INFO planner notes=${_notes.length} fails=${_fails.length}');
    for (final n in _notes) {
      // ignore: avoid_print
      print('NOTE $n');
    }
    // ignore: avoid_print
    print('VERIFY_DONE');
    expect(_fails, isEmpty, reason: _fails.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 30)));
}
