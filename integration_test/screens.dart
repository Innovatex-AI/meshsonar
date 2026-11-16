// The list of screens scripts/verify_sim.sh screenshots. Add a ScreenStep to extend it.
// Each step runs in order against the real app; `shot('name')` prints "SCREEN name" and holds still so the script
// can grab a simulator screenshot. A step with `optional: true` is skipped (not failed) when it can't find its UI,
// which is how screens that only exist on some checkouts (e.g. a region hub) are covered.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;

Future<void> pumpFor(WidgetTester t, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<bool> waitFor(WidgetTester t, Finder f, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return true;
  }
  return false;
}

/// Back to the first route of every navigator (closes sheets and pushed screens on every tab).
Future<void> popToRoots(WidgetTester t) async {
  for (final n in t.stateList<NavigatorState>(find.byType(Navigator, skipOffstage: false))) {
    n.popUntil((r) => r.isFirst);
  }
  await pumpFor(t, const Duration(seconds: 1));
}

/// Marks a screenshot point. The script watches stdout for these lines.
Future<void> shot(WidgetTester t, String name) async {
  await pumpFor(t, const Duration(milliseconds: 800));
  // ignore: avoid_print
  print('SCREEN $name');
  await pumpFor(t, const Duration(seconds: 3));
}

/// Taps a shell destination (bottom bar on phones, rail on iPad) by its label.
Future<void> openShellTab(WidgetTester t, String label) async {
  final bar = find.byKey(const Key('shell-tabs')).evaluate().isNotEmpty
      ? find.byKey(const Key('shell-tabs'))
      : find.byKey(const Key('shell-rail'));
  final f = find.descendant(of: bar, matching: find.text(label));
  expect(await waitFor(t, f), isTrue, reason: '$label tab');
  await t.tap(f);
  await pumpFor(t, const Duration(seconds: 1));
}

Future<void> _openMoreRow(WidgetTester t, String key) async {
  await openShellTab(t, 'More');
  // The More tab keeps its own stack: tapping it again goes back to its list.
  if (find.byKey(const Key('more-list')).hitTestable().evaluate().isEmpty) await openShellTab(t, 'More');
  final row = find.byKey(Key(key));
  if (row.evaluate().isEmpty) {
    await t.scrollUntilVisible(row, 150,
        scrollable: find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first);
  }
  await t.ensureVisible(row);
  await t.tap(row);
  await pumpFor(t, const Duration(seconds: 1));
}

Future<void> _analyze(WidgetTester t, String segment) async {
  await openShellTab(t, 'Analyze');
  await t.tap(find.descendant(of: find.byKey(const Key('analyze-segments')), matching: find.text(segment)));
  await pumpFor(t, const Duration(seconds: 1));
}

/// Opens a screen by its pre-0.25 tab name (Drive, Region, Drives, Radio, Settings) or by a shell tab name (Chat, Map,
/// Analyze, Plan, More). The old names now live inside the five tabs.
Future<void> openTab(WidgetTester t, String label) async {
  switch (label) {
    case 'Drive':
      await openShellTab(t, 'Drive');
    case 'Region':
      await _analyze(t, 'Region');
    case 'Drives':
      await _analyze(t, 'Drives');
    case 'Radio':
      await _openMoreRow(t, 'more-radio');
    case 'Settings':
      await _openMoreRow(t, 'more-settings');
    default:
      await openShellTab(t, label);
  }
}

/// Scrolls the first vertical scrollable (under [within] when given) top to bottom in ~85% viewport steps, shooting each stop.
Future<void> shootFullScroll(WidgetTester t, String prefix, {Finder? within}) async {
  final scrollables = within == null ? find.byType(Scrollable) : find.descendant(of: within, matching: find.byType(Scrollable));
  final scrollable = t.stateList<ScrollableState>(scrollables).firstWhere(
        (s) => s.axisDirection == AxisDirection.down && s.position.maxScrollExtent > 0,
      );
  final pos = scrollable.position;
  final step = pos.viewportDimension * 0.85;
  var i = 1;
  await shot(t, '$prefix-$i');
  while (pos.pixels < pos.maxScrollExtent - 1 && i < 20) {
    pos.jumpTo((pos.pixels + step).clamp(0, pos.maxScrollExtent));
    i++;
    await shot(t, '$prefix-$i');
  }
}

class ScreenStep {
  const ScreenStep(this.name, this.run, {this.optional = false});
  final String name;
  final Future<void> Function(WidgetTester t) run;
  final bool optional;
}

/// Extend here. Steps run in order and share one app instance; each starts wherever the previous left off,
/// so navigate explicitly with openTab.
final List<ScreenStep> screens = [
  // First launch: the disclosure sheet sits over the Drive tab until the person answers it.
  ScreenStep('disclosure', (t) async {
    final keep = find.byKey(const Key('telemetry-keep'));
    if (!await waitFor(t, keep, timeout: const Duration(seconds: 6))) throw const _Skip();
    await shot(t, 'disclosure');
    await t.tap(keep);
    await pumpFor(t, const Duration(seconds: 1));
  }, optional: true),
  ScreenStep('drive', (t) async {
    await openTab(t, 'Drive');
    await shot(t, 'drive');
  }),
  // Connect screen: scanning / nothing found (the simulator has no Bluetooth radios), then the debug-only Simulator.
  ScreenStep('connect', (t) async {
    final chip = find.byKey(const Key('connection-chip'));
    if (!await waitFor(t, chip)) throw const _Skip();
    await t.tap(chip);
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'connect-scanning');
    await pumpFor(t, const Duration(seconds: 14));
    await shot(t, 'connect-result');
    final sim = find.byKey(const Key('simulator'));
    if (sim.evaluate().isEmpty) {
      // Largest Dynamic Type: the row is below the fold of the lazily built list.
      try {
        await t.scrollUntilVisible(sim, 300, scrollable: find.byType(Scrollable).first);
      } catch (_) {}
    }
    if (sim.evaluate().isEmpty) {
      await t.pageBack();
      await pumpFor(t, const Duration(seconds: 1));
      throw const _Skip();
    }
    await t.ensureVisible(sim);
    // At the largest text the tile is taller than the screen: tap near its top edge, not its centre.
    await t.tapAt(t.getTopLeft(sim) + const Offset(60, 40));
    await pumpFor(t, const Duration(seconds: 4));
    await shot(t, 'connect-after-simulator');
  }, optional: true),
  // The antenna sheet after the first connect. Every control is scrolled into view before its tap: on an iPhone 17 Pro the
  // gain switch sits below the fold (y 1007 of 874), the old blind tap missed it, Save stayed disabled (gain unanswered) and
  // the sheet closed unsaved, so Start drive stayed off ("Set your antenna first") and drive-live/report/detail never ran (V-5).
  ScreenStep('antenna', (t) async {
    final sheet = find.byKey(const Key('antenna-sheet'));
    if (!await waitFor(t, sheet, timeout: const Duration(seconds: 6))) throw const _Skip();
    await shot(t, 'antenna-sheet');
    Future<void> tapIn(Finder f) async {
      await t.ensureVisible(f.first);
      await pumpFor(t, const Duration(milliseconds: 300));
      await t.tap(f.first);
      await pumpFor(t, const Duration(milliseconds: 400));
    }
    final mount = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('mount-'));
    if (mount.evaluate().isNotEmpty) await tapIn(mount);
    await tapIn(find.byKey(const Key('antenna-gain-unknown')));
    final height = find.byKey(const Key('antenna-height-field'));
    await t.ensureVisible(height);
    await t.enterText(height, '5');
    await pumpFor(t, const Duration(milliseconds: 500));
    final save = find.byKey(const Key('antenna-save'));
    await t.ensureVisible(save);
    await pumpFor(t, const Duration(milliseconds: 300));
    if (t.widget<ButtonStyleButton>(save).onPressed == null) _stepFail('antenna: Save is still disabled after mount, gain and height were answered');
    await t.tap(save);
    await pumpFor(t, const Duration(seconds: 2));
    final app = AppScope.of(t.element(find.byType(Scaffold).first));
    if (sheet.evaluate().isNotEmpty || app.needsAntennaSetup) _stepFail('antenna: Save did not store the antenna setup');
    _stepOk('antenna');
  }, optional: true),
  ScreenStep('drive-ready', (t) async {
    await openTab(t, 'Drive');
    await shot(t, 'drive-ready');
  }),
  // The five tabs, with a radio connected and no drive running.
  ScreenStep('tabs', (t) async {
    await openTab(t, 'Chat');
    await shot(t, 'tab-chat');
    await openTab(t, 'Region');
    await shot(t, 'tab-analyze-region');
    await openTab(t, 'Drives');
    await shot(t, 'tab-analyze-drives');
    await openTab(t, 'Plan');
    await shot(t, 'tab-plan');
    await openShellTab(t, 'More');
    await shot(t, 'tab-more');
    await openTab(t, 'Drive');
  }),
  // drive-live / drive-report / drive-detail (V-5, build 67): a real drive on the simulated radio, its report, then its
  // card in Analyze > Drives. They need the debug-only simulated radio (the connect step): without it they skip. With it,
  // every miss is a STEPFAIL (they used to be optional end to end, so a disabled Start drive skipped all three silently:
  // the tour ran without a location grant, and Start drive is off until location is allowed).
  ScreenStep('drive-live', (t) async {
    _droveOk = false;
    final app = AppScope.of(t.element(find.byType(Scaffold).first));
    if (!app.connected) throw const _Skip(); // no simulated radio on this checkout / release build
    await popToRoots(t);
    await openTab(t, 'Drive');
    final go = find.byKey(const Key('start-stop'));
    if (!await waitFor(t, go, timeout: const Duration(seconds: 10))) _stepFail('drive-live: no Start drive button on the Drive tab');
    if (t.widget<ButtonStyleButton>(go.first).onPressed == null) {
      _stepFail('drive-live: Start drive is disabled (${_text(t, 'dock-subtitle') ?? 'no reason shown'})');
    }
    await t.tap(go.first);
    if (!await _until(t, () => app.driving, const Duration(seconds: 15))) {
      _stepFail('drive-live: tapping Start drive did not start a drive (${_text(t, 'dock-subtitle') ?? 'no reason shown'})');
    }
    await pumpFor(t, const Duration(seconds: 30));
    await shot(t, 'drive-live');
    // The mini drive bar on every other tab, then back to the Drive tab from the bar.
    for (final tab in ['Chat', 'Plan', 'More']) {
      await openShellTab(t, tab);
      await shot(t, 'minibar-${tab.toLowerCase()}');
    }
    await openTab(t, 'Region');
    await shot(t, 'minibar-analyze');
    final bar = find.byKey(const Key('mini-bar-open'));
    if (!await waitFor(t, bar, timeout: const Duration(seconds: 5))) _stepFail('drive-live: no mini drive bar on the Analyze tab while driving');
    await t.tap(bar.first);
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'minibar-opened-drive');
    if (!await waitFor(t, go.hitTestable(), timeout: const Duration(seconds: 5))) _stepFail('drive-live: the mini bar did not bring back the Drive tab');
    await t.tap(go.hitTestable().first);
    await pumpFor(t, const Duration(milliseconds: 600));
    await shot(t, 'stop-confirm');
    final confirm = find.byKey(const Key('stop-drive-confirm'));
    if (!await waitFor(t, confirm, timeout: const Duration(seconds: 5))) _stepFail('drive-live: Stop did not ask "Stop this drive?"');
    await t.tap(confirm.first);
    if (!await _until(t, () => !app.driving, const Duration(seconds: 15))) _stepFail('drive-live: Stop drive did not end the drive');
    await pumpFor(t, const Duration(seconds: 3));
    await shot(t, 'drive-stopped');
    _droveOk = true;
    _stepOk('drive-live');
  }, optional: true),
  ScreenStep('drive-report', (t) async {
    final card = find.byKey(const Key('view-report'));
    if (!await waitFor(t, card, timeout: const Duration(seconds: 5))) {
      if (!_droveOk) throw const _Skip(); // no drive this run (no simulated radio)
      _stepFail('drive-report: no Report button after the drive was saved');
    }
    await t.tap(card.first);
    await pumpFor(t, const Duration(seconds: 3));
    if (!await waitFor(t, find.byKey(const Key('drive-report')), timeout: const Duration(seconds: 10))) {
      _stepFail('drive-report: Report did not open the drive report');
    }
    await shot(t, 'report');
    try {
      await shootFullScroll(t, 'report-scroll', within: find.byKey(const Key('drive-report')));
    } catch (_) {}
    // On iOS the report is a full-height sheet with Done, not a pushed page: pageBack() found no back button there and
    // threw, which skipped the step after its first shot.
    final done = find.byKey(const Key('report-done'));
    if (done.evaluate().isNotEmpty) {
      await t.tap(done.first);
    } else {
      await t.pageBack();
    }
    await pumpFor(t, const Duration(seconds: 1));
    if (find.byKey(const Key('drive-report')).evaluate().isNotEmpty) _stepFail('drive-report: Done did not close the report');
    _stepOk('drive-report');
  }, optional: true),
  ScreenStep('radio', (t) async {
    await openTab(t, 'Radio');
    await shot(t, 'radio');
  }),
  ScreenStep('drives', (t) async {
    await openTab(t, 'Drives');
    await shot(t, 'drives');
  }),
  ScreenStep('drive-detail', (t) async {
    // A drive card's InkWell ('open-<session id>'); other 'open-' keys (open-log, open-progress, open-app-settings) are not cards.
    final open = find.byWidgetPredicate((w) => w is InkWell && w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('open-'));
    if (!await waitFor(t, open, timeout: const Duration(seconds: 5))) {
      if (!_droveOk) throw const _Skip();
      _stepFail('drive-detail: the drive just saved has no card in Analyze > Drives');
    }
    await t.tap(open.first);
    await pumpFor(t, const Duration(seconds: 3));
    if (!await waitFor(t, find.byKey(const Key('drive-detail')), timeout: const Duration(seconds: 10))) {
      _stepFail('drive-detail: tapping the drive card did not open its detail');
    }
    await shot(t, 'detail');
    try {
      await shootFullScroll(t, 'detail-scroll', within: find.byKey(const Key('drive-detail')));
    } catch (_) {} // nothing to scroll on a big screen
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));
    if (find.byKey(const Key('drive-detail')).evaluate().isNotEmpty) _stepFail('drive-detail: Back did not close the drive detail');
    _stepOk('drive-detail');
  }, optional: true),
  ScreenStep('settings', (t) async {
    await openTab(t, 'Settings');
    await shootFullScroll(t, 'settings');
  }),
  ScreenStep('about', (t) async {
    final f = find.text('About MeshSonar');
    await t.ensureVisible(f);
    await pumpFor(t, const Duration(milliseconds: 500));
    await t.tap(f);
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'about');
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));
  }),
  // More > Observer (release 0.38: the Home observer is gone): Settings opened at the Observer section, the master switch
  // Share with MeshSonar, the observer status and the MQTT feeds (lib/ui/settings/observer_section.dart).
  ScreenStep('observer', (t) async {
    // Back out of whatever the previous steps left open (Settings, About) in every navigator, then open the row.
    await popToRoots(t);
    await openShellTab(t, 'More');
    // The More list may still be scrolled to its end (the About step): scroll back up to the Observer row.
    final row = find.byKey(const Key('more-observer'));
    if (row.hitTestable().evaluate().isEmpty) {
      await t.scrollUntilVisible(
        row,
        -200,
        scrollable: find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first,
      );
    }
    await t.ensureVisible(row);
    await pumpFor(t, const Duration(milliseconds: 500));
    await t.tap(row);
    await pumpFor(t, const Duration(seconds: 1));
    expect(await waitFor(t, find.byKey(const Key('observer-share-toggle'))), isTrue, reason: 'Settings > Observer: Share with MeshSonar');
    await shot(t, 'observer');
    final feeds = find.byKey(const Key('mqtt-add-feed'));
    await t.ensureVisible(feeds);
    await pumpFor(t, const Duration(milliseconds: 500));
    await shot(t, 'observer-mqtt-feeds');
    await popToRoots(t);
  }),
  // Plan: the Planner (release 0.38). The empty plan with its one-tap start, then each mode chip's sheet. The full flows
  // A-E and J1-J8 against the live server are integration_test/planner_visual_test.dart.
  ScreenStep('planner', (t) async {
    await popToRoots(t);
    await openShellTab(t, 'Plan');
    expect(await waitFor(t, find.byKey(const Key('planner'))), isTrue, reason: 'Plan tab is the Planner');
    expect(await waitFor(t, find.byKey(const Key('planner-sheet'))), isTrue, reason: 'planner sheet');
    await shot(t, 'planner');
    for (final m in ['link', 'coverage', 'findSites', 'whereToDrive']) {
      final chip = find.byKey(Key('planner-mode-$m'));
      expect(await waitFor(t, chip), isTrue, reason: 'mode chip $m');
      await t.tap(chip);
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'planner-mode-$m');
    }
    await t.tap(find.byKey(const Key('planner-mode-link')));
    await pumpFor(t, const Duration(milliseconds: 500));
  }),
  ScreenStep('region', (t) async {
    await openTab(t, 'Region');
    await shot(t, 'region');
  }),
  // The region picker over the real 559-region index (live, read-only): the sheet, then a search with an accent.
  ScreenStep('region-picker', (t) async {
    await openTab(t, 'Region');
    final chip = find.byKey(const Key('region-switch-chip'));
    if (!await waitFor(t, chip)) throw const _Skip();
    await t.tap(chip);
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'region-picker');
    final search = find.byKey(const Key('region-search'));
    if (search.evaluate().isNotEmpty) {
      await t.enterText(search, 'dusseldorf');
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'region-picker-search');
    }
    await t.tapAt(const Offset(20, 40)); // the scrim above the sheet closes it
    await pumpFor(t, const Duration(seconds: 1));
  }, optional: true),
];

class _Skip implements Exception {
  const _Skip();
}

/// A step that must pass once its preconditions hold: verify_sim.sh fails the run on the STEPFAIL line, and the throw ends the step.
class _StepFailed implements Exception {
  const _StepFailed(this.why);
  final String why;
  @override
  String toString() => 'StepFailed: $why';
}

bool _droveOk = false;

Never _stepFail(String why) {
  // ignore: avoid_print
  print('STEPFAIL $why');
  throw _StepFailed(why);
}

void _stepOk(String step) {
  // ignore: avoid_print
  print('STEP $step ok');
}

Future<bool> _until(WidgetTester t, bool Function() cond, Duration timeout) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 200));
    if (cond()) return true;
  }
  return false;
}

/// The text of the Text widget keyed [k], or null.
String? _text(WidgetTester t, String k) {
  final f = find.byKey(Key(k));
  if (f.evaluate().isEmpty) return null;
  final w = t.widget(f.first);
  return w is Text ? w.data : null;
}
