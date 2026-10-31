// The list of screens scripts/verify_sim.sh screenshots. Add a ScreenStep to extend it.
// Each step runs in order against the real app; `shot('name')` prints "SCREEN name" and holds still so the script
// can grab a simulator screenshot. A step with `optional: true` is skipped (not failed) when it can't find its UI,
// which is how screens that only exist on some checkouts (e.g. a region hub) are covered.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// Marks a screenshot point. The script watches stdout for these lines.
Future<void> shot(WidgetTester t, String name) async {
  await pumpFor(t, const Duration(milliseconds: 800));
  // ignore: avoid_print
  print('SCREEN $name');
  await pumpFor(t, const Duration(seconds: 3));
}

Future<void> openTab(WidgetTester t, String label) async {
  final f = find.text(label);
  expect(await waitFor(t, f), isTrue, reason: '$label tab');
  await t.tap(f.last);
  await pumpFor(t, const Duration(seconds: 1));
}

/// Scrolls the first vertical scrollable top to bottom in ~85% viewport steps, shooting each stop.
Future<void> shootFullScroll(WidgetTester t, String prefix) async {
  final scrollable = t.stateList<ScrollableState>(find.byType(Scrollable)).firstWhere(
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
  ScreenStep('antenna', (t) async {
    final sheet = find.byKey(const Key('antenna-sheet'));
    if (!await waitFor(t, sheet, timeout: const Duration(seconds: 6))) throw const _Skip();
    await shot(t, 'antenna-sheet');
    final mount = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('mount-'));
    if (mount.evaluate().isNotEmpty) await t.tap(mount.first);
    await pumpFor(t, const Duration(milliseconds: 500));
    await t.tap(find.byKey(const Key('antenna-gain-unknown')));
    await pumpFor(t, const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('antenna-height-field')), '5');
    await pumpFor(t, const Duration(milliseconds: 500));
    final save = find.byKey(const Key('antenna-save'));
    await t.ensureVisible(save);
    await t.tap(save);
    await pumpFor(t, const Duration(seconds: 2));
  }, optional: true),
  ScreenStep('drive-ready', (t) async {
    await openTab(t, 'Drive');
    await shot(t, 'drive-ready');
  }),
  ScreenStep('drive-live', (t) async {
    final go = find.byKey(const Key('start-stop'));
    await t.tap(go);
    await pumpFor(t, const Duration(seconds: 30));
    await shot(t, 'drive-live');
    await t.tap(go);
    await pumpFor(t, const Duration(milliseconds: 600));
    await shot(t, 'stop-confirm');
    final confirm = find.byKey(const Key('stop-drive-confirm'));
    if (confirm.evaluate().isEmpty) throw const _Skip();
    await t.tap(confirm);
    await pumpFor(t, const Duration(seconds: 3));
    await shot(t, 'drive-stopped');
  }, optional: true),
  ScreenStep('drive-report', (t) async {
    final card = find.byKey(const Key('view-report'));
    if (card.evaluate().isEmpty) throw const _Skip();
    await t.tap(card);
    await pumpFor(t, const Duration(seconds: 3));
    await shot(t, 'report');
    try {
      await shootFullScroll(t, 'report-scroll');
    } catch (_) {}
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));
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
    final open = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('open-') && '${(w.key as ValueKey).value}' != 'open-progress');
    if (open.evaluate().isEmpty) throw const _Skip();
    await t.tap(open.first);
    await pumpFor(t, const Duration(seconds: 3));
    await shot(t, 'detail');
    try {
      await shootFullScroll(t, 'detail-scroll');
    } catch (_) {} // nothing to scroll on a big screen
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));
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
