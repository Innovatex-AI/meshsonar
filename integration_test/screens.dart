// The list of screens scripts/verify_sim.sh screenshots. Add a ScreenStep to extend it.
// Build 71 (the app as a gateway to the site data): the app starts on the Network tab; the tour covers the Network header,
// its seven sections (Live first since build 72, then Packets, Nodes, Channels, Observers, Analytics with the region's
// Findings and Region overview, Tools), All regions (Regions, Channels, Analytics, Tools), a node / packet /
// observer page, the Drive map's panels (Drive panel, Layers, legend), the Plan sheet, Chat's three segments, More,
// More > Radio, More > Help and Settings.
// Each step runs in order against the real app; `shot('name')` prints "SCREEN name" and holds still so the script
// can grab a simulator screenshot. A step with `optional: true` is skipped (not failed) when it can't find its UI,
// which is how screens that only exist on some checkouts (e.g. a region hub) are covered.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/app.dart' show AppScope, MoreItem, ShellController;
import 'package:meshsonar/ui/alerts/alerts_status_strip.dart';
import 'package:meshsonar/ui/plan/planner_screen.dart';
import 'package:meshsonar/ui/shell/blur_bar.dart';
import 'package:meshsonar/ui/shell/mini_drive_bar.dart';

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

/// Scrolls the Scrollable under [within] down until [f] is built (lazy lists build rows only near the viewport), then
/// brings it into view. False when the end of the list comes first.
Future<bool> scrollToFind(WidgetTester t, Finder f, Finder within, {Duration wait = const Duration(seconds: 15)}) async {
  if (!await waitFor(t, within, timeout: wait)) return false;
  // The search only scrolls down: a list an earlier step left scrolled past the row (a lazy list does not keep rows far
  // above the viewport) would never show it. Start from the top when the row is not built.
  if (f.evaluate().isEmpty) {
    final top = t.stateList<ScrollableState>(find.descendant(of: within.first, matching: find.byType(Scrollable))).where((x) => x.axisDirection == AxisDirection.down).firstOrNull;
    if (top != null && top.position.pixels > 0) {
      top.position.jumpTo(0);
      await pumpFor(t, const Duration(milliseconds: 400));
    }
  }
  final end = DateTime.now().add(wait);
  while (DateTime.now().isBefore(end)) {
    if (f.evaluate().isNotEmpty) {
      // Centred, not at the top edge: a pinned header (the Chat search and segments) would cover a row scrolled to the top.
      try {
        await Scrollable.ensureVisible(t.element(f.first), alignment: 0.5);
      } catch (_) {}
      await pumpFor(t, const Duration(milliseconds: 400));
      return true;
    }
    final states = t.stateList<ScrollableState>(find.descendant(of: within.first, matching: find.byType(Scrollable)));
    final s = states.where((x) => x.axisDirection == AxisDirection.down).firstOrNull;
    if (s == null) {
      await pumpFor(t, const Duration(milliseconds: 300));
      continue;
    }
    final p = s.position;
    if (p.pixels >= p.maxScrollExtent - 1) {
      // At the end: the rows may still be on their way (the radio's contact sync); wait a little and look again.
      await pumpFor(t, const Duration(milliseconds: 500));
      if (f.evaluate().isNotEmpty) continue;
      if (p.pixels >= p.maxScrollExtent - 1 && DateTime.now().isAfter(end.subtract(const Duration(seconds: 5)))) return false;
      continue;
    }
    p.jumpTo((p.pixels + p.viewportDimension * 0.6).clamp(0, p.maxScrollExtent));
    await pumpFor(t, const Duration(milliseconds: 300));
  }
  return f.evaluate().isNotEmpty;
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

/// Opens a Network section by its name on the strip (home, packets, live, nodes, channels, observers, analytics, tools).
/// The strip scrolls sideways, so the name is brought into view first. Leaves "All regions" when the section needs a region.
Future<bool> openNetworkSection(WidgetTester t, String name) async {
  await openShellTab(t, 'Network');
  final chip = find.byKey(Key('network-section-$name'));
  if (chip.evaluate().isEmpty) {
    final back = find.byKey(const Key('all-regions-back'));
    if (back.evaluate().isNotEmpty) {
      await t.tap(back.first);
      await pumpFor(t, const Duration(seconds: 1));
    }
  }
  if (!await waitFor(t, chip, timeout: const Duration(seconds: 20))) return false;
  await t.ensureVisible(chip);
  await pumpFor(t, const Duration(milliseconds: 500));
  await t.tap(chip);
  // The strip scrolls to the picked name (200 ms) and the section loads.
  await pumpFor(t, const Duration(seconds: 1));
  return true;
}

/// Opens the region switcher from the Network header (build 71: the region name is the button).
Future<bool> openRegionSwitcher(WidgetTester t) async {
  await openShellTab(t, 'Network');
  final b = find.byKey(const Key('network-region-button'));
  if (!await waitFor(t, b, timeout: const Duration(seconds: 20))) return false;
  await t.tap(b);
  await pumpFor(t, const Duration(seconds: 1));
  return true;
}

/// Closes the Drive map's Layers panel (build 71: a panel on the map, not a route: a Navigator pop or a tap on the map
/// does not close it). The panel's X is 'layers-done'; a second tap on the Layers button closes it too.
Future<void> closeLayersPanel(WidgetTester t) async {
  final done = find.byKey(const Key('layers-done'));
  if (done.evaluate().isNotEmpty) {
    await t.tap(done.first, warnIfMissed: false);
  } else if (find.byKey(const Key('layers-sheet')).evaluate().isNotEmpty) {
    final b = find.byKey(const Key('drive-map-layers'));
    if (b.evaluate().isNotEmpty) await t.tap(b.first, warnIfMissed: false);
  }
  await pumpFor(t, const Duration(seconds: 1));
}

/// A row inside a More page (More > Radio, More > Help): opens [parent] on the More list, then taps [key] in it.
Future<void> openMoreSubRow(WidgetTester t, String parent, String key) async {
  await _openMoreRow(t, parent);
  final row = find.byKey(Key(key));
  if (!await waitFor(t, row, timeout: const Duration(seconds: 3))) {
    final list = find.byKey(Key(parent == 'more-radio' ? 'more-radio-list' : 'more-help-list'));
    await scrollToFind(t, row, list);
  }
  await t.ensureVisible(row.first);
  await pumpFor(t, const Duration(milliseconds: 400));
  await t.tap(row.first);
  await pumpFor(t, const Duration(seconds: 1));
}

/// A Settings section that had its own More row before build 71 (Observer, Wardriving, Notifications, Privacy, Claimed
/// radios): opened the way the app's own links open it.
Future<void> openSettingsSection(WidgetTester t, MoreItem item) async {
  ShellController.active?.openMore(item);
  await pumpFor(t, const Duration(seconds: 2));
}

/// One step back: the page's Back button, else the site page's close button, else the top route of the root navigator.
Future<void> backOne(WidgetTester t) async {
  final b = find.byTooltip('Back');
  if (b.evaluate().isNotEmpty) {
    await t.tap(b.last, warnIfMissed: false);
  } else {
    await t.state<NavigatorState>(find.byType(Navigator).first).maybePop();
  }
  await pumpFor(t, const Duration(seconds: 1));
}

/// Waits for a site page shown inside the app (SitePageView) to finish loading. Null when it did; else what went wrong.
Future<String?> sitePageProblem(WidgetTester t, {Duration timeout = const Duration(seconds: 60)}) async {
  if (!await waitFor(t, find.byKey(const Key('site-page')), timeout: const Duration(seconds: 10))) return 'the site page did not open';
  final end = DateTime.now().add(timeout);
  // The bar shows as soon as the load starts; give it a moment to appear before waiting for it to go.
  await pumpFor(t, const Duration(seconds: 1));
  while (DateTime.now().isBefore(end)) {
    if (find.byKey(const Key('site-page-error')).evaluate().isNotEmpty) return 'the page did not load ("Can\'t reach MeshSonar")';
    if (find.byKey(const Key('site-page-no-engine')).evaluate().isNotEmpty) return 'no web view on this device';
    if (find.byKey(const Key('site-page-bad-address')).evaluate().isNotEmpty) return 'the app refused the address';
    if (find.byKey(const Key('site-page-loading')).evaluate().isEmpty) {
      // Loaded: let the page's own data requests draw.
      await pumpFor(t, const Duration(seconds: 4));
      return null;
    }
    await pumpFor(t, const Duration(milliseconds: 500));
  }
  return 'still loading after ${timeout.inSeconds} s';
}

Future<void> _openMoreRow(WidgetTester t, String key) async {
  await openShellTab(t, 'More');
  // The More tab keeps its own stack (Radio and Help push pages over pages): tapping it again goes back to its list.
  final list = find.byKey(const Key('more-list'));
  for (var i = 0; i < 3 && list.hitTestable().evaluate().isEmpty; i++) {
    await openShellTab(t, 'More');
  }
  final row = find.byKey(Key(key));
  if (row.evaluate().isEmpty) {
    // A lazily built list scrolled past the row does not hold it: start from the top.
    final sc = t.stateList<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable))).firstOrNull;
    sc?.position.jumpTo(0);
    await pumpFor(t, const Duration(milliseconds: 400));
  }
  if (!await scrollToFind(t, row, list, wait: const Duration(seconds: 8))) {
    final keys = [
      for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('more-')).evaluate())
        (e.widget.key as ValueKey<String>).value
    ];
    throw StateError('no $key on the More list (list on screen: ${list.hitTestable().evaluate().isNotEmpty}; more-* keys: $keys)');
  }
  await t.ensureVisible(row.first);
  await pumpFor(t, const Duration(milliseconds: 300));
  await t.tap(row.first);
  await pumpFor(t, const Duration(seconds: 1));
}

/// The Network tab (Analyze until build 71, AZ-3.1).
Future<void> _network(WidgetTester t) async {
  await openShellTab(t, 'Network');
  await pumpFor(t, const Duration(seconds: 1));
}

/// Opens a screen by its pre-0.25 tab name (Drive, Region, Drives, Radio, Settings) or by a shell tab name (Network,
/// Drive, Chat, Plan, More). The old names now live inside the five tabs.
Future<void> openTab(WidgetTester t, String label) async {
  switch (label) {
    case 'Drive':
      await openShellTab(t, 'Drive');
    case 'Region':
      await _network(t);
    case 'Drives':
      // Drives live under More since build 71 (AZ-3.1).
      await _openMoreRow(t, 'more-drives');
    case 'Radio':
      // Build 71: More > Radio is the radio's lists; the read-only settings comparison is a row inside it.
      await openMoreSubRow(t, 'more-radio', 'more-radioSettings');
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

/// Build 70, item 70-2: the Drive panel slides over a map that never shrinks. Checks the map is the whole screen and shoots
/// the panel at [name]; STEPFAIL when the map was resized.
Future<void> _panelShot(WidgetTester t, String name) async {
  await pumpFor(t, const Duration(milliseconds: 900));
  final view = t.view.physicalSize / t.view.devicePixelRatio;
  final map = find.byKey(const Key('drive-map'));
  if (map.evaluate().isEmpty) _stepFail('$name: no Drive map');
  final size = t.getSize(map.first);
  if ((size.width - view.width).abs() > 1 || (size.height - view.height).abs() > 1) {
    _stepFail('$name: the map is ${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}, the screen ${view.width.toStringAsFixed(0)}x${view.height.toStringAsFixed(0)}');
  }
  await shot(t, name);
}

double _panelTop(WidgetTester t) {
  final p = find.byKey(const Key('drive-panel'));
  return p.evaluate().isEmpty ? double.infinity : t.getTopLeft(p.first).dy;
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
  // First launch: the disclosure sheet sits over the first tab (Network since build 71) until the person answers it.
  ScreenStep('disclosure', (t) async {
    final keep = find.byKey(const Key('telemetry-keep'));
    if (!await waitFor(t, keep, timeout: const Duration(seconds: 6))) throw const _Skip();
    await shot(t, 'disclosure');
    await t.tap(keep);
    await pumpFor(t, const Duration(seconds: 1));
  }, optional: true),
  // Build 71: a fresh install opens on Network. One header line (region name, pulse chip, search, overflow), one strip of
  // eight sections, and no second bar above the tab bar.
  ScreenStep('network-header', (t) async {
    if (!await waitFor(t, find.byKey(const Key('network-tab')).hitTestable(), timeout: const Duration(seconds: 5))) {
      _stepFail('network-header: the app did not open on the Network tab');
    }
    if (!await waitFor(t, find.byKey(const Key('network-sections')), timeout: const Duration(seconds: 40))) {
      _stepFail('network-header: no section strip (${_shellStateOf(t)})');
    }
    await pumpFor(t, const Duration(seconds: 4));
    final view = t.view.physicalSize / t.view.devicePixelRatio;
    final header = t.getRect(find.byKey(const Key('network-header')));
    if ((header.width - view.width).abs() > 1 || (header.height - 48).abs() > 1) _stepFail('network-header: the header is ${header.width}x${header.height}');
    for (final k in ['network-region-button', 'network-search', 'network-overflow']) {
      if (find.byKey(Key(k)).hitTestable().evaluate().isEmpty) _stepFail('network-header: no $k');
    }
    for (final n in _networkSections) {
      if (find.byKey(Key('network-section-$n')).evaluate().isEmpty) _stepFail('network-header: no "$n" on the strip');
    }
    // Build 72: no Home section; the tab opens on Live, the first name on the strip.
    if (find.byKey(const Key('network-section-home')).evaluate().isNotEmpty) _stepFail('network-header: the strip still has Home');
    if (!await waitFor(t, find.byKey(const Key('live-map')).hitTestable(), timeout: const Duration(seconds: 15))) {
      _stepFail('network-header: the Network tab did not open on Live');
    }
    final liveLeft = t.getTopLeft(find.byKey(const Key('network-section-live'))).dx;
    for (final n in _networkSections.skip(1)) {
      if (t.getTopLeft(find.byKey(Key('network-section-$n'))).dx <= liveLeft) _stepFail('network-header: "$n" comes before Live on the strip');
    }
    await shot(t, 'network-header');
    // No second bar and no blank band: the section runs down to the tab bar.
    final tabs = t.getRect(find.byKey(const Key('shell-tabs')));
    final body = t.getRect(find.byKey(const Key('network-section-body-live')));
    final gap = tabs.top - body.bottom;
    final pad = t.view.padding.bottom / t.view.devicePixelRatio;
    _stepNote('network-header',
        'screen ${view.width.toStringAsFixed(0)}x${view.height.toStringAsFixed(0)}, safe bottom ${pad.toStringAsFixed(0)}, tab bar ${tabs.top.toStringAsFixed(0)}..${tabs.bottom.toStringAsFixed(0)}, section body ..${body.bottom.toStringAsFixed(0)}, strips: ${_rectsOf(t, [AlertsStatusStrip, MiniDriveBar, BlurBar])}');
    // The tab bar is 72 pt plus the bottom safe area; a taller one means an inset crept in above the icons.
    if ((tabs.height - (72 + pad)).abs() > 2) _stepFail('network-header: the tab bar is ${tabs.height.toStringAsFixed(0)} pt tall (expected ${(72 + pad).toStringAsFixed(0)})');
    if (gap.abs() > 2) _stepFail('network-header: ${gap.toStringAsFixed(0)} pt between the bottom of the section and the tab bar (expected none)');
    await t.tap(find.byKey(const Key('network-overflow')));
    await pumpFor(t, const Duration(seconds: 1));
    if (find.byKey(const Key('network-share')).evaluate().isEmpty || find.byKey(const Key('region-report-export')).evaluate().isEmpty) {
      _stepFail('network-header: the overflow menu lacks Share link or Export region report');
    }
    await shot(t, 'network-overflow');
    await popToRoots(t); // the overflow is the app's action sheet (a route)
    if (find.byKey(const Key('network-share')).evaluate().isNotEmpty) _stepFail('network-header: the overflow sheet did not close');
    _stepOk('network-header');
  }, optional: true),
  ScreenStep('drive', (t) async {
    await openTab(t, 'Drive');
    await shot(t, 'drive');
  }),
  // No radio: the panel sits at the Dock (bottom quarter of the screen), never the middle, over a full-screen map.
  ScreenStep('panel-noradio', (t) async {
    await openTab(t, 'Drive');
    final view = t.view.physicalSize / t.view.devicePixelRatio;
    await _panelShot(t, 'panel-noradio-dock');
    if (_panelTop(t) < view.height * 0.7) _stepFail('panel-noradio: the panel is not at the Dock (top ${_panelTop(t).toStringAsFixed(0)})');
    _stepOk('panel-noradio');
  }),
  // Connect screen: scanning / nothing found (the simulator has no Bluetooth radios), then the debug-only Simulator.
  ScreenStep('connect', (t) async {
    await openTab(t, 'Drive'); // the connection chip is on the Drive tab (the app starts on Network since build 71)
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
  // Every detent by drag and fling: Dock, Medium, Full (pulled past Medium, finger down), back to Dock, the collapsed pill, and
  // the map pans at the Dock. The map is the whole screen at each one.
  ScreenStep('panel-detents', (t) async {
    await popToRoots(t);
    await openTab(t, 'Drive');
    final header = find.byKey(const Key('drive-panel-header'));
    if (!await waitFor(t, header, timeout: const Duration(seconds: 5))) _stepFail('panel-detents: no panel header');
    await _panelShot(t, 'panel-dock');
    final dock = _panelTop(t);
    await t.timedDrag(header, const Offset(0, -320), const Duration(milliseconds: 700));
    await _panelShot(t, 'panel-medium');
    final medium = _panelTop(t);
    if (medium > dock - 100) _stepFail('panel-detents: a drag up did not open Medium (top $medium, dock $dock)');
    final g = await t.startGesture(t.getCenter(find.byKey(const Key('drive-panel-grabber'))));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, -30));
      await t.pump(const Duration(milliseconds: 16));
    }
    await _panelShot(t, 'panel-full');
    await g.up();
    await pumpFor(t, const Duration(milliseconds: 900));
    await t.fling(header, const Offset(0, 400), 1500);
    await _panelShot(t, 'panel-dock-again');
    if ((_panelTop(t) - dock).abs() > 4) _stepFail('panel-detents: a fling down did not return to the Dock');
    await t.dragFrom(Offset(t.view.physicalSize.width / t.view.devicePixelRatio / 2, 300), const Offset(-80, 60));
    await pumpFor(t, const Duration(milliseconds: 600));
    if ((_panelTop(t) - dock).abs() > 4) _stepFail('panel-detents: panning the map moved the panel');
    await t.fling(header, const Offset(0, 160), 1500);
    await _panelShot(t, 'panel-collapsed');
    final nub = find.byKey(const Key('pill-nub'));
    if (nub.evaluate().isNotEmpty) {
      await t.tap(nub.first); // back to the Dock (the pill's Start button would start a drive)
    } else if (header.evaluate().isNotEmpty) {
      await t.fling(header, const Offset(0, -160), 1500);
    }
    await pumpFor(t, const Duration(seconds: 1));
    _stepOk('panel-detents');
  }, optional: true),
  // Build 71: Layers and the legend are panels on the Drive map (not routes): the map stays live above them, each closes
  // with its own X, and only one is open at a time.
  ScreenStep('drive-map-panels', (t) async {
    await popToRoots(t);
    await openTab(t, 'Drive');
    final layers = find.byKey(const Key('drive-map-layers'));
    if (!await waitFor(t, layers.hitTestable(), timeout: const Duration(seconds: 8))) _stepFail('drive-map-panels: no Layers button on the Drive map');
    await t.tap(layers.first);
    await pumpFor(t, const Duration(seconds: 1));
    if (!await waitFor(t, find.byKey(const Key('layers-sheet')), timeout: const Duration(seconds: 5))) _stepFail('drive-map-panels: Layers did not open');
    await _panelShot(t, 'drive-layers-panel');
    // Not a route: popping every navigator leaves it open; its X closes it.
    await popToRoots(t);
    if (find.byKey(const Key('layers-sheet')).evaluate().isEmpty) _stepFail('drive-map-panels: a Navigator pop closed the Layers panel (it should be a panel, not a route)');
    if (find.byKey(const Key('layers-done')).evaluate().isEmpty) _stepFail('drive-map-panels: the Layers panel has no close button (layers-done)');
    await closeLayersPanel(t);
    if (find.byKey(const Key('layers-sheet')).evaluate().isNotEmpty) _stepFail('drive-map-panels: the X did not close the Layers panel');
    final legend = find.byKey(const Key('legend-card-toggle'));
    if (!await waitFor(t, legend.hitTestable(), timeout: const Duration(seconds: 5))) _stepFail('drive-map-panels: no legend chip on the Drive map');
    await t.tap(legend.first);
    await pumpFor(t, const Duration(seconds: 1));
    if (!await waitFor(t, find.byKey(const Key('map-panel-drive.legend')), timeout: const Duration(seconds: 5))) _stepFail('drive-map-panels: the legend did not open as a panel');
    await _panelShot(t, 'drive-legend-panel');
    final close = find.byKey(const Key('map-panel-drive.legend-close'));
    if (close.evaluate().isEmpty) _stepFail('drive-map-panels: the legend panel has no close button');
    await t.tap(close.first, warnIfMissed: false);
    await pumpFor(t, const Duration(seconds: 1));
    if (find.byKey(const Key('map-panel-drive.legend')).evaluate().isNotEmpty) _stepFail('drive-map-panels: the X did not close the legend panel');
    _stepOk('drive-map-panels');
  }, optional: true),
  // The five tabs (Network | Drive | Chat | Plan | More), with a radio connected and no drive running.
  ScreenStep('tabs', (t) async {
    await openTab(t, 'Chat');
    await shot(t, 'tab-chat');
    // Chat has three segments since build 71 (Radio moved to More > Radio).
    if (find.byKey(const Key('segment-radio')).evaluate().isNotEmpty) _stepFail('tabs: Chat still has a Radio segment');
    for (final seg in ['contacts', 'channels', 'chats']) {
      final f = find.byKey(Key('segment-$seg'));
      if (f.evaluate().isEmpty) continue; // no chat services yet (no radio): the empty state has no segments
      await t.tap(f.first);
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'chat-segment-$seg');
    }
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
  // card in More > Drives. They need the debug-only simulated radio (the connect step): without it they skip. With it,
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
  // More > Radio (the Chat tab's Radio segment until build 71): the radio card, nearby nodes, repeaters, rooms, sensors,
  // then Radio settings and region preset and the radio tools; then the settings comparison itself.
  ScreenStep('radio', (t) async {
    await popToRoots(t);
    await _openMoreRow(t, 'more-radio');
    if (!await waitFor(t, find.byKey(const Key('more-radio-screen')), timeout: const Duration(seconds: 5))) _stepFail('radio: More > Radio did not open');
    await shot(t, 'more-radio');
    try {
      await shootFullScroll(t, 'more-radio-scroll', within: find.byKey(const Key('more-radio-screen')));
    } catch (_) {} // nothing to scroll with no radio
    await openTab(t, 'Radio');
    if (!await waitFor(t, find.byKey(const Key('radio-list')), timeout: const Duration(seconds: 5)) &&
        find.byKey(const Key('radio-not-connected')).evaluate().isEmpty) {
      _stepFail('radio: Radio settings and region preset did not open from More > Radio');
    }
    await shot(t, 'radio');
    _stepOk('radio');
  }, optional: true),
  ScreenStep('drives', (t) async {
    await openTab(t, 'Drives');
    await shot(t, 'drives');
  }),
  ScreenStep('drive-detail', (t) async {
    // A drive card's InkWell ('open-<session id>' inside 'session-<session id>'). Other 'open-' keys are not drive cards:
    // 'open-progress' (the Your progress card above the list, also an InkWell) opened Progress instead, and open-log /
    // open-app-settings live on other screens.
    final open = find.descendant(
      of: find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('session-')),
      matching: find.byWidgetPredicate((w) => w is InkWell && w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('open-')),
    );
    if (!await waitFor(t, open, timeout: const Duration(seconds: 5))) {
      if (!_droveOk) throw const _Skip();
      _stepFail('drive-detail: the drive just saved has no card in More > Drives');
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
  // J2 (V-5, build 67): a repeater contact > Link to… opens the Planner in Link mode with the contact as an end. Runs here on
  // the simulated radio (no server needed) as well as in planner_visual_test.dart. Repeaters live under More > Radio (build 71;
  // Chat > Radio before) below the radio card and the Nearby section, in a lazily built list: the rows only exist once
  // scrolled near the viewport.
  ScreenStep('j2-contact-link', (t) async {
    final app = AppScope.of(t.element(find.byType(Scaffold).first));
    if (!app.connected) throw const _Skip();
    await popToRoots(t);
    await _openMoreRow(t, 'more-radio');
    if (!await waitFor(t, find.byKey(const Key('more-radio-list')), timeout: const Duration(seconds: 8))) _stepFail('j2: More > Radio did not open');
    final tile = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('network-row-'));
    if (!await scrollToFind(t, tile, find.byKey(const Key('more-radio-list')))) _stepFail('j2: no repeater rows under More > Radio with the simulated radio');
    final prefix = (t.widget(tile.first).key as ValueKey<String>).value.substring('network-row-'.length).toLowerCase();
    await t.tap(tile.first, warnIfMissed: false);
    await pumpFor(t, const Duration(seconds: 1));
    if (!await waitFor(t, find.byKey(const Key('contact-profile')), timeout: const Duration(seconds: 10))) _stepFail('j2: the repeater row did not open its profile');
    final link = find.byKey(const Key('node-action-linkTo'));
    if (!await scrollToFind(t, link, find.byKey(const Key('contact-profile')))) _stepFail('j2: the repeater profile has no Link to… row');
    await shot(t, 'j2-contact-profile');
    await t.tap(link.first, warnIfMissed: false);
    await pumpFor(t, const Duration(seconds: 1));
    final planner = find.byType(PlannerScreen, skipOffstage: false);
    final ok = await _until(t, () {
      if (planner.evaluate().isEmpty) return false;
      final c = t.state<PlannerScreenState>(planner).controller;
      return c != null && c.nodes.any((n) => n.existingKey?.toLowerCase().startsWith(prefix) ?? false) && find.byKey(const Key('plan-mode-link')).evaluate().isNotEmpty;
    }, const Duration(seconds: 15));
    if (!ok) _stepFail('j2: Link to… did not open the Planner in Link mode with the repeater as an end');
    await shot(t, 'j2-contact-link');
    _stepOk('j2-contact-link');
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
  // Settings > Observer (release 0.38: the Home observer is gone; build 71: its More row moved into Settings): the master
  // switch Share with MeshSonar, the observer status and the MQTT feeds (lib/ui/settings/observer_section.dart).
  ScreenStep('observer', (t) async {
    // Back out of whatever the previous steps left open (Settings, About) in every navigator, then open the section.
    await popToRoots(t);
    await openShellTab(t, 'More');
    if (find.byKey(const Key('more-observer')).evaluate().isNotEmpty) _stepFail('observer: More still has an Observer row (it only jumped into Settings)');
    await openSettingsSection(t, MoreItem.observer);
    expect(await waitFor(t, find.byKey(const Key('observer-share-toggle'))), isTrue, reason: 'Settings > Observer: Share with MeshSonar');
    await shot(t, 'observer');
    final feeds = find.byKey(const Key('mqtt-add-feed'));
    await t.ensureVisible(feeds);
    await pumpFor(t, const Duration(milliseconds: 500));
    await shot(t, 'observer-mqtt-feeds');
    await popToRoots(t);
  }),
  // More after the build 71 clutter pass: nine rows and no group headers; Help holds the six help rows.
  ScreenStep('more', (t) async {
    await popToRoots(t);
    await openShellTab(t, 'More');
    if (find.byKey(const Key('more-list')).hitTestable().evaluate().isEmpty) await openShellTab(t, 'More');
    const rows = ['more-drives', 'more-radio', 'more-devices', 'more-leaderboard', 'more-observerJoin', 'more-chat', 'more-settings', 'more-help', 'more-about'];
    final list = find.byKey(const Key('more-list'));
    for (final k in rows) {
      if (!await scrollToFind(t, find.byKey(Key(k)), list, wait: const Duration(seconds: 4))) {
        final seen = [for (final e in _prefixed('more-').evaluate()) (e.widget.key as ValueKey<String>).value];
        _stepFail('more: no row $k (More list on screen: ${list.hitTestable().evaluate().isNotEmpty}; rows built: $seen)');
      }
    }
    final n = find.descendant(of: list, matching: find.byType(ListTile), skipOffstage: false).evaluate().length;
    if (n > rows.length) _stepFail('more: $n rows on the More list, expected ${rows.length}');
    final sc = t.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable)).first);
    sc.position.jumpTo(0);
    await shot(t, 'more');
    await _openMoreRow(t, 'more-help');
    if (!await waitFor(t, find.byKey(const Key('more-help-list')), timeout: const Duration(seconds: 5))) _stepFail('more: More > Help did not open');
    for (final k in ['more-howItWorks', 'more-method', 'more-legend', 'more-report', 'more-myReports', 'more-privacy-policy']) {
      if (find.byKey(Key(k)).evaluate().isEmpty) _stepFail('more: Help has no $k');
    }
    await shot(t, 'more-help');
    await popToRoots(t);
    _stepOk('more');
  }, optional: true),
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
    // Build 71: the Plan sheet follows the map-panel rules: a tap on its handle toggles Collapsed and Open.
    final handle = find.byKey(const Key('planner-sheet-handle'));
    if (handle.evaluate().isEmpty) _stepFail('planner: the sheet has no handle');
    double h() => t.getSize(find.byKey(const Key('planner-sheet'))).height;
    final first = h();
    await t.tap(handle.first, warnIfMissed: false);
    await pumpFor(t, const Duration(seconds: 1));
    final second = h();
    await shot(t, second < first ? 'planner-sheet-collapsed' : 'planner-sheet-open');
    await t.tap(handle.first, warnIfMissed: false);
    await pumpFor(t, const Duration(seconds: 1));
    final third = h();
    await shot(t, third < second ? 'planner-sheet-collapsed' : 'planner-sheet-open');
    if ((first - second).abs() < 40 || (second - third).abs() < 40) _stepFail('planner: a tap on the sheet handle did not toggle the sheet ($first, $second, $third)');
    // Leave it open for the flows that follow.
    if (third < second) {
      await t.tap(handle.first, warnIfMissed: false);
      await pumpFor(t, const Duration(seconds: 1));
    }
  }),
  // ------------------------------------------------------------------ build 71: the Network tab, section by section
  // Each step is optional so a failure in one section does not hide the others; every miss is a STEPFAIL line, which fails
  // the run in scripts/verify_sim.sh.
  ScreenStep('region', (t) async {
    await popToRoots(t);
    // Build 72: the region's first section is Live (the Home section is gone).
    if (!await openNetworkSection(t, 'live')) _stepFail('region: no Live on the strip (${_shellStateOf(t)})');
    if (!await waitFor(t, find.byKey(const Key('network-section-body-live')), timeout: const Duration(seconds: 10))) _stepFail('region: Live did not open');
    await pumpFor(t, const Duration(seconds: 4));
    await shot(t, 'region');
    _stepOk('region');
  }, optional: true),
  ScreenStep('network-packets', (t) async {
    await popToRoots(t);
    if (!await openNetworkSection(t, 'packets')) _stepFail('network-packets: no Packets on the strip');
    if (!await waitFor(t, find.byKey(const Key('packet-list-view')), timeout: const Duration(seconds: 15))) _stepFail('network-packets: the packet list did not open');
    if (find.byKey(const Key('network-sub-packets')).evaluate().isNotEmpty) _stepFail('network-packets: Packets still has a List | Live switch');
    final row = _prefixed('packet-row-', not: ['packet-row-expand-', 'packet-row-obs-', 'packet-row-snr-']);
    final has = await waitFor(t, row, timeout: const Duration(seconds: 30));
    await shot(t, 'network-packets');
    if (!has) {
      if (find.byKey(const Key('packets-error')).evaluate().isNotEmpty) _stepFail('network-packets: the packet list shows an error');
      _stepNote('network-packets', 'no packet rows for this region (${_firstKeyOf(t, ['packets-empty', 'packets-loading'])}): no packet page shot');
      return;
    }
    await t.ensureVisible(row.first);
    await pumpFor(t, const Duration(milliseconds: 400));
    await t.tap(row.first, warnIfMissed: false);
    if (!await waitFor(t, find.byKey(const Key('network-packet-screen')), timeout: const Duration(seconds: 15))) _stepFail('network-packets: a packet row did not open the packet page');
    await _settled(t, ['packet-loading'], const Duration(seconds: 20));
    if (find.byKey(const Key('packet-error')).evaluate().isNotEmpty) _stepFail('packet-page: the packet page shows an error');
    await shot(t, 'packet-page');
    try {
      await shootFullScroll(t, 'packet-page-scroll', within: find.byKey(const Key('network-packet-screen')));
    } catch (_) {}
    await backOne(t);
    if (find.byKey(const Key('network-packet-screen')).evaluate().isNotEmpty) _stepFail('packet-page: Back did not close the packet page');
    _stepOk('network-packets');
  }, optional: true),
  // Live: one panel on the map (build 71). Collapsed = its header only; open = controls and the feed inside it.
  ScreenStep('network-live', (t) async {
    await popToRoots(t);
    if (!await openNetworkSection(t, 'live')) _stepFail('network-live: no Live on the strip');
    if (!await waitFor(t, find.byKey(const Key('live-map')), timeout: const Duration(seconds: 15))) _stepFail('network-live: the live map did not open');
    final header = find.byKey(const Key('live-panel-header'));
    if (!await waitFor(t, header, timeout: const Duration(seconds: 10))) _stepFail('network-live: no panel header on the live map');
    await pumpFor(t, const Duration(seconds: 6)); // tiles and the first packets
    bool open() => find.byKey(const Key('live-panel-body')).hitTestable().evaluate().isNotEmpty;
    if (open()) {
      await t.tap(header.first, warnIfMissed: false);
      await pumpFor(t, const Duration(seconds: 1));
    }
    if (open()) _stepFail('network-live: a tap on the panel header did not collapse the panel');
    await shot(t, 'network-live-collapsed');
    await t.tap(header.first, warnIfMissed: false);
    await pumpFor(t, const Duration(seconds: 1));
    if (!open()) _stepFail('network-live: a tap on the panel header did not open the panel');
    await shot(t, 'network-live-open');
    final view = t.view.physicalSize / t.view.devicePixelRatio;
    final panelTop = t.getTopLeft(find.byKey(const Key('live-panel-header')).first).dy;
    if (panelTop < view.height * 0.3) _stepFail('network-live: the open panel covers more than 60% of the screen (top ${panelTop.toStringAsFixed(0)} of ${view.height.toStringAsFixed(0)})');
    await t.tap(header.first, warnIfMissed: false);
    await pumpFor(t, const Duration(seconds: 1));
    _stepOk('network-live');
  }, optional: true),
  ScreenStep('network-nodes', (t) async {
    await popToRoots(t);
    if (!await openNetworkSection(t, 'nodes')) _stepFail('network-nodes: no Nodes on the strip');
    if (!await waitFor(t, find.byKey(const Key('network-nodes-directory')), timeout: const Duration(seconds: 10))) _stepFail('network-nodes: the node directory did not open');
    if (find.byKey(const Key('network-sub-nodes')).evaluate().isNotEmpty) _stepFail('network-nodes: Nodes still has a Nodes | Observers switch');
    final row = _prefixed('node-row-');
    final has = await waitFor(t, row, timeout: const Duration(seconds: 30));
    await shot(t, 'network-nodes');
    if (!has) {
      if (find.byKey(const Key('nodes-error')).evaluate().isNotEmpty) _stepFail('network-nodes: the node list shows an error');
      _stepNote('network-nodes', 'no node rows for this region: no node page shot');
      return;
    }
    _nodeKeys = [for (final e in row.evaluate()) (e.widget.key as ValueKey<String>).value.substring('node-row-'.length).toLowerCase()];
    await t.ensureVisible(row.first);
    await pumpFor(t, const Duration(milliseconds: 400));
    await t.tap(row.first, warnIfMissed: false);
    if (!await waitFor(t, find.byKey(const Key('network-node-screen')), timeout: const Duration(seconds: 15))) _stepFail('network-nodes: a node row did not open the node page');
    if (!await waitFor(t, find.byKey(const Key('node-page')), timeout: const Duration(seconds: 20))) {
      _stepFail('node-page: the node page did not load (${_firstKeyOf(t, ['node-error'])})');
    }
    await pumpFor(t, const Duration(seconds: 3));
    await shot(t, 'node-page');
    try {
      await shootFullScroll(t, 'node-page-scroll', within: find.byKey(const Key('network-node-screen')));
    } catch (_) {}
    await backOne(t);
    if (find.byKey(const Key('network-node-screen')).evaluate().isNotEmpty) _stepFail('node-page: Back did not close the node page');
    _stepOk('network-nodes');
  }, optional: true),
  // Channels: the list, a channel's reader, and the message search.
  ScreenStep('network-channels', (t) async {
    await popToRoots(t);
    if (!await openNetworkSection(t, 'channels')) _stepFail('network-channels: no Channels on the strip');
    final listed = await waitFor(t, find.byKey(const Key('channels-list')), timeout: const Duration(seconds: 25));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'network-channels');
    if (!listed) {
      if (find.byKey(const Key('channels-error')).evaluate().isNotEmpty) _stepFail('network-channels: the channel list shows an error');
      final state = _firstKeyOf(t, ['channels-empty', 'channels-store-off']);
      if (state == 'none') _stepFail('network-channels: Channels shows no list and no empty state (blank)');
      _stepNote('network-channels', 'no channel list for this region ($state): no reader or search shot');
      return;
    }
    final row = _prefixed('channel-row-');
    if (row.evaluate().isEmpty) _stepFail('network-channels: the channel list has no rows');
    await t.ensureVisible(row.first);
    await pumpFor(t, const Duration(milliseconds: 400));
    await t.tap(row.first, warnIfMissed: false);
    if (!await waitFor(t, find.byKey(const Key('channel-title')), timeout: const Duration(seconds: 15))) _stepFail('channel-reader: a channel row did not open the reader');
    await _until(t, () => _firstKeyOf(t, ['channel-messages', 'channel-empty', 'channel-error', 'channel-private']) != 'none', const Duration(seconds: 25));
    if (find.byKey(const Key('channel-error')).evaluate().isNotEmpty) _stepFail('channel-reader: the reader shows an error');
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'channel-reader');
    final search = find.byKey(const Key('channel-search'));
    if (search.evaluate().isEmpty) {
      // A channel whose text is not stored has no search of its own: use the list's search.
      await backOne(t);
      final ls = find.byKey(const Key('channels-search'));
      if (ls.evaluate().isEmpty) _stepFail('channel-search: no search on the reader or on the channel list');
      await t.tap(ls.first, warnIfMissed: false);
    } else {
      await t.tap(search.first, warnIfMissed: false);
    }
    final field = find.byKey(const Key('channel-search-field'));
    if (!await waitFor(t, field, timeout: const Duration(seconds: 8))) _stepFail('channel-search: the search page did not open');
    await t.enterText(field, 'test');
    await _until(t, () => _firstKeyOf(t, ['channel-search-results', 'channel-search-empty', 'channel-search-error']) != 'none', const Duration(seconds: 25));
    if (find.byKey(const Key('channel-search-error')).evaluate().isNotEmpty) _stepFail('channel-search: the search shows an error');
    if (_firstKeyOf(t, ['channel-search-results', 'channel-search-empty']) == 'none') _stepFail('channel-search: no results and no "nothing found" after 25 s');
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'channel-search');
    await popToRoots(t);
    _stepOk('network-channels');
  }, optional: true),
  ScreenStep('network-observers', (t) async {
    await popToRoots(t);
    if (!await openNetworkSection(t, 'observers')) _stepFail('network-observers: no Observers on the strip');
    if (!await waitFor(t, find.byKey(const Key('network-observers')), timeout: const Duration(seconds: 10))) _stepFail('network-observers: the Observers section did not open');
    final row = _prefixed('observer-row-');
    final has = await waitFor(t, row, timeout: const Duration(seconds: 30));
    await shot(t, 'network-observers');
    if (!has) {
      if (find.byKey(const Key('observers-error')).evaluate().isNotEmpty) _stepFail('network-observers: the observer list shows an error');
      _stepNote('network-observers', 'no observer rows for this region (${_firstKeyOf(t, ['observers-empty'])}): no observer page shot');
      return;
    }
    await t.ensureVisible(row.first);
    await pumpFor(t, const Duration(milliseconds: 400));
    await t.tap(row.first, warnIfMissed: false);
    if (!await waitFor(t, find.byKey(const Key('network-observer-screen')), timeout: const Duration(seconds: 15))) _stepFail('network-observers: an observer row did not open the observer page');
    if (!await waitFor(t, find.byKey(const Key('observer-page')), timeout: const Duration(seconds: 20))) {
      _stepFail('observer-page: the observer page did not load (${_firstKeyOf(t, ['observer-error'])})');
    }
    await pumpFor(t, const Duration(seconds: 3));
    await shot(t, 'observer-page');
    await backOne(t);
    if (find.byKey(const Key('network-observer-screen')).evaluate().isNotEmpty) _stepFail('observer-page: Back did not close the observer page');
    _stepOk('network-observers');
  }, optional: true),
  // Analytics: the list of the site's tabs, then ONE of them (Overview) opened as a site page inside the app.
  ScreenStep('network-analytics', (t) async {
    await popToRoots(t);
    if (!await openNetworkSection(t, 'analytics')) _stepFail('network-analytics: no Analytics on the strip');
    if (!await waitFor(t, find.byKey(const Key('analytics-section')), timeout: const Duration(seconds: 10))) _stepFail('network-analytics: the Analytics list did not open (blank)');
    await shot(t, 'network-analytics');
    // Build 72: the region's Findings and Region overview (the Home section until then) are the first two rows; each
    // opens its native panel in place, with a back arrow to the list.
    for (final (slug, panel) in [('findings', 'network-findings'), ('region-overview', 'network-region-overview')]) {
      final row = find.byKey(Key('analytics-tab-$slug'));
      if (row.evaluate().isEmpty) _stepFail('network-analytics: no $slug row');
      if (t.getTopLeft(row.first).dy >= t.getTopLeft(find.byKey(const Key('analytics-tab-overview')).first).dy) {
        _stepFail('network-analytics: $slug is not above the site tabs');
      }
      await t.tap(row.first, warnIfMissed: false);
      if (!await waitFor(t, find.byKey(Key(panel)), timeout: const Duration(seconds: 10))) _stepFail('network-analytics: $slug did not open its panel');
      await pumpFor(t, const Duration(seconds: 4));
      await shot(t, 'analytics-$slug');
      if (find.byKey(const Key('network-sections')).hitTestable().evaluate().isEmpty) _stepFail('network-analytics: $slug covers the section strip (it should open in place)');
      final back = find.byKey(const Key('in-place-back'));
      if (back.evaluate().isEmpty) _stepFail('network-analytics: $slug has no back arrow');
      await t.tap(back.first, warnIfMissed: false);
      await pumpFor(t, const Duration(seconds: 1));
      if (find.byKey(const Key('analytics-section')).evaluate().isEmpty) _stepFail('network-analytics: Back from $slug did not return to the list');
    }
    final tab = find.byKey(const Key('analytics-tab-overview'));
    if (tab.evaluate().isEmpty) _stepFail('network-analytics: no Overview row');
    await t.ensureVisible(tab.first);
    await pumpFor(t, const Duration(milliseconds: 400));
    await t.tap(tab.first, warnIfMissed: false);
    final problem = await sitePageProblem(t);
    await shot(t, 'analytics-overview');
    if (problem != null) _stepFail('analytics-overview: $problem');
    await popToRoots(t);
    if (find.byKey(const Key('site-page')).evaluate().isNotEmpty) _stepFail('analytics-overview: the site page did not close');
    _stepOk('network-analytics');
  }, optional: true),
  // Tools: the list, the three native tools with a real query each, and one site page (Status).
  ScreenStep('network-tools', (t) async {
    await popToRoots(t);
    if (!await openNetworkSection(t, 'tools')) _stepFail('network-tools: no Tools on the strip');
    final list = find.byKey(const Key('tools-section'));
    if (!await waitFor(t, list, timeout: const Duration(seconds: 10))) _stepFail('network-tools: the Tools list did not open (blank)');
    await shot(t, 'network-tools');
    try {
      await shootFullScroll(t, 'network-tools-scroll', within: list);
    } catch (_) {}
    Future<void> openTool(String id, String screenKey) async {
      await popToRoots(t);
      await openNetworkSection(t, 'tools');
      final row = find.byKey(Key('tool-row-$id'));
      if (!await scrollToFind(t, row, list, wait: const Duration(seconds: 6))) _stepFail('network-tools: no $id row');
      await t.tap(row.first, warnIfMissed: false);
      if (!await waitFor(t, find.byKey(Key(screenKey)), timeout: const Duration(seconds: 10))) _stepFail('network-tools: $id did not open');
      await pumpFor(t, const Duration(seconds: 1));
    }

    // Real query material: hop prefixes and a prefix from nodes of this region (the Nodes step), else common ones.
    final keys = _nodeKeys.where((k) => RegExp(r'^[0-9a-f]{64}$').hasMatch(k)).toList();
    final hops = keys.length >= 2 ? '${keys[0].substring(0, 2)} ${keys[1].substring(0, 2)}' : 'a1 3f';
    final prefix = keys.isNotEmpty ? keys[0].substring(0, 2) : 'a1';

    // Path Inspector.
    await openTool('path', 'tool-path');
    await t.enterText(find.byKey(const Key('path-hops')), hops);
    await pumpFor(t, const Duration(milliseconds: 400));
    await _dismissKeyboard(t);
    await t.ensureVisible(find.byKey(const Key('path-inspect')));
    await t.tap(find.byKey(const Key('path-inspect')), warnIfMissed: false);
    await _until(t, () => _firstKeyOf(t, ['path-candidate-1', 'path-none', 'path-unknown', 'path-error']) != 'none', const Duration(seconds: 25));
    await shot(t, 'tool-path');
    final pathState = _firstKeyOf(t, ['path-error', 'path-candidate-1', 'path-none', 'path-unknown']);
    if (pathState == 'path-error') _stepFail('tool-path: Inspect "$hops" shows an error (${_text(t, 'path-error') ?? ''})');
    if (pathState == 'none') _stepFail('tool-path: Inspect "$hops" gave no answer in 25 s');
    _stepNote('tool-path', 'query "$hops" -> $pathState');

    // Trace Viewer: the recent traces of the region; the first one opened when there is one.
    await openTool('trace', 'tool-trace-viewer');
    await _until(t, () => _prefixed('trace-recent-', not: ['trace-recent-error', 'trace-recent-none']).evaluate().isNotEmpty || _firstKeyOf(t, ['trace-recent-none', 'trace-recent-error']) != 'none',
        const Duration(seconds: 25));
    await shot(t, 'tool-trace');
    if (find.byKey(const Key('trace-recent-error')).evaluate().isNotEmpty) _stepFail('tool-trace: the recent traces show an error');
    final recent = _prefixed('trace-recent-', not: ['trace-recent-error', 'trace-recent-none']);
    if (recent.evaluate().isNotEmpty) {
      await t.ensureVisible(recent.first);
      await t.tap(recent.first, warnIfMissed: false);
      await _until(t, () => _firstKeyOf(t, ['trace-summary', 'trace-local-summary', 'trace-missing', 'trace-error']) != 'none', const Duration(seconds: 25));
      await shot(t, 'tool-trace-view');
      final st = _firstKeyOf(t, ['trace-error', 'trace-summary', 'trace-local-summary', 'trace-missing']);
      if (st == 'trace-error') _stepFail('tool-trace: opening a recent trace shows an error');
      if (st == 'none') _stepFail('tool-trace: opening a recent trace gave no answer in 25 s');
      _stepNote('tool-trace', 'a recent trace -> $st');
    } else if (find.byKey(const Key('trace-recent-none')).evaluate().isNotEmpty) {
      _stepNote('tool-trace', 'no TRACE packets in this region in the last 7 days: the list says so, no trace opened');
    } else {
      _stepFail('tool-trace: no recent traces and no "none heard" line after 25 s');
    }

    // Prefix Tool.
    await openTool('prefix', 'tool-prefix');
    await t.enterText(find.byKey(const Key('prefix-input')), prefix);
    await pumpFor(t, const Duration(milliseconds: 400));
    await _dismissKeyboard(t);
    await t.tap(find.byKey(const Key('prefix-check')), warnIfMissed: false);
    await _until(t, () => _firstKeyOf(t, ['prefix-check-1', 'prefix-check-2', 'prefix-check-3', 'prefix-recommendation', 'prefix-error']) != 'none', const Duration(seconds: 25));
    await shot(t, 'tool-prefix');
    final prefixState = _firstKeyOf(t, ['prefix-error', 'prefix-check-1', 'prefix-check-2', 'prefix-check-3', 'prefix-recommendation']);
    if (prefixState == 'prefix-error') _stepFail('tool-prefix: Check "$prefix" shows an error (${_text(t, 'prefix-error') ?? ''})');
    if (prefixState == 'none') _stepFail('tool-prefix: Check "$prefix" gave no answer in 25 s');
    _stepNote('tool-prefix', 'query "$prefix" -> $prefixState');

    // One site page: Status.
    await popToRoots(t);
    await openNetworkSection(t, 'tools');
    final status = find.byKey(const Key('tool-row-status'));
    if (!await scrollToFind(t, status, list, wait: const Duration(seconds: 6))) _stepFail('network-tools: no Status row');
    await t.tap(status.first, warnIfMissed: false);
    final problem = await sitePageProblem(t);
    await shot(t, 'tool-status');
    if (problem != null) _stepFail('tool-status: $problem');
    await popToRoots(t);
    _stepOk('network-tools');
  }, optional: true),
  // The region picker over the real 559-region index (live, read-only): the sheet, then a search with an accent.
  ScreenStep('region-picker', (t) async {
    await popToRoots(t);
    if (!await openRegionSwitcher(t)) _stepFail('region-picker: no region button in the Network header');
    if (!await waitFor(t, find.byKey(const Key('region-switcher')), timeout: const Duration(seconds: 8))) _stepFail('region-picker: the switcher did not open');
    await shot(t, 'region-picker');
    final search = find.byKey(const Key('region-search'));
    if (search.evaluate().isNotEmpty) {
      await t.enterText(search, 'dusseldorf');
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'region-picker-search');
    }
    await popToRoots(t); // the sheet is a route
    _stepOk('region-picker');
  }, optional: true),
  // All regions (the switcher's first entry): the network summary, the global search and the busiest regions; four
  // sections; "Back to <region>" returns.
  ScreenStep('all-regions', (t) async {
    await popToRoots(t);
    final app = AppScope.of(t.element(find.byType(Scaffold).first));
    final before = app.viewingRegion?.code;
    if (!await openRegionSwitcher(t)) _stepFail('all-regions: no region button in the Network header');
    final all = find.byKey(const Key('region-all'));
    if (!await scrollToFind(t, all, find.byKey(const Key('region-switcher')), wait: const Duration(seconds: 8))) _stepFail('all-regions: the switcher has no All regions entry');
    await t.tap(all.first, warnIfMissed: false);
    if (!await waitFor(t, find.byKey(const Key('network-all-regions')), timeout: const Duration(seconds: 10))) _stepFail('all-regions: All regions did not open');
    final title = _text(t, 'region-title');
    if (title != 'All regions') _stepFail('all-regions: the header says "$title"');
    for (final n in [..._networkSections, 'regions']) {
      final there = find.byKey(Key('network-section-$n')).evaluate().isNotEmpty;
      final hub = const ['regions', 'channels', 'analytics', 'tools'].contains(n);
      if (there != hub) _stepFail('all-regions: "$n" is ${there ? 'on' : 'missing from'} the strip');
    }
    await _until(t, () => _firstKeyOf(t, ['busy-regions', 'busy-regions-empty', 'busy-regions-not-live', 'busy-regions-offline', 'busy-regions-error']) != 'none', const Duration(seconds: 25));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'all-regions');
    final busy = _firstKeyOf(t, ['busy-regions', 'busy-regions-empty', 'busy-regions-not-live', 'busy-regions-offline', 'busy-regions-error']);
    if (busy == 'busy-regions-error' || busy == 'busy-regions-offline' || busy == 'none') _stepFail('all-regions: the busiest regions did not load ($busy)');
    if (busy == 'busy-regions-not-live') _stepFail('all-regions: the hub has no /v1/regions/busy');
    final rows = _prefixed('busy-region-').evaluate().length;
    _stepNote('all-regions', 'busiest regions: $busy, $rows rows');
    if (find.byKey(const Key('network-search-field')).evaluate().isEmpty) _stepFail('all-regions: no global search field');
    if (find.byKey(const Key('live-map')).evaluate().isNotEmpty) _stepFail('all-regions: a live map is shown (there is no world live map on the phone)');
    final back = find.byKey(const Key('all-regions-back'));
    if (back.evaluate().isEmpty) _stepFail('all-regions: no "Back to <region>" row');
    await t.ensureVisible(back.first);
    await t.tap(back.first, warnIfMissed: false);
    await pumpFor(t, const Duration(seconds: 2));
    if (find.byKey(const Key('network-all-regions')).evaluate().isNotEmpty) _stepFail('all-regions: "Back to" did not leave All regions');
    if (app.viewingRegion?.code != before) _stepFail('all-regions: the viewed region changed from $before to ${app.viewingRegion?.code}');
    _stepOk('all-regions');
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

/// A region's sections in strip order (build 72: Live first, no Home).
const List<String> _networkSections = ['live', 'packets', 'nodes', 'channels', 'observers', 'analytics', 'tools'];

/// Node keys seen on Network > Nodes (lowercase hex), for the tools' real queries.
List<String> _nodeKeys = const [];

/// A step's remark that is not a failure (what the region had, which query ran).
void _stepNote(String step, String what) {
  // ignore: avoid_print
  print('NOTE $step: $what');
}

/// Widgets whose string key starts with [prefix] (and with none of [not]).
Finder _prefixed(String prefix, {List<String> not = const []}) => find.byWidgetPredicate((w) {
      final k = w.key;
      if (k is! ValueKey<String>) return false;
      return k.value.startsWith(prefix) && !not.any(k.value.startsWith);
    });

/// The first of [keys] that is on screen, or 'none'.
String _firstKeyOf(WidgetTester t, List<String> keys) {
  for (final k in keys) {
    if (find.byKey(Key(k)).evaluate().isNotEmpty) return k;
  }
  return 'none';
}

/// Which Network shell state shows when there is no section strip.
String _shellStateOf(WidgetTester t) => _firstKeyOf(t, ['network-loading', 'network-offline', 'network-error', 'network-empty']);

/// Waits until none of [busyKeys] is on screen.
Future<void> _settled(WidgetTester t, List<String> busyKeys, Duration timeout) async {
  await _until(t, () => _firstKeyOf(t, busyKeys) == 'none', timeout);
  await pumpFor(t, const Duration(seconds: 1));
}

Future<void> _dismissKeyboard(WidgetTester t) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFor(t, const Duration(milliseconds: 600));
}

/// "Type top..bottom" for each of [types] on screen (layout diagnostics in a NOTE line).
String _rectsOf(WidgetTester t, List<Type> types) => [
      for (final ty in types)
        for (final e in find.byType(ty).evaluate())
          '$ty ${t.getRect(find.byElementPredicate((x) => identical(x, e))).top.toStringAsFixed(0)}..${t.getRect(find.byElementPredicate((x) => identical(x, e))).bottom.toStringAsFixed(0)}'
    ].join(', ');
