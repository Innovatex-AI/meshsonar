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
  ScreenStep('drive', (t) async {
    await openTab(t, 'Drive');
    await shot(t, 'drive');
  }),
  ScreenStep('drives', (t) async {
    await openTab(t, 'Drives');
    await shot(t, 'drives');
  }),
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
  // Region hub / panels: only on checkouts that have lib/ui/region. Adjust the label when that screen lands.
  ScreenStep('region', (t) async {
    final f = find.textContaining(RegExp(r'Region|Coverage'));
    if (f.evaluate().isEmpty) throw const _Skip();
    await t.tap(f.first);
    await pumpFor(t, const Duration(seconds: 3));
    await shot(t, 'region');
  }, optional: true),
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
