// Switching region: the "Switch to <region>?" confirm sheet (Cancel is the default), what the switch keeps and clears, recents
// in the switcher, the "Outside coverage" nearest-regions sheet. iPhone / iPad, 2.5x text, dark, 48 px, VoiceOver.
// (The map no longer draws pointers to neighbouring regions: removed in 0.26.1.)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/onboarding/ui_prefs.dart';
import 'package:meshsonar/ui/region/region_switch_sheet.dart';
import 'package:meshsonar/ui/region/region_switcher.dart';

import '../fakes.dart';
import '../toast_test_kit.dart';

RegionIndexEntry box(String code, String name, double w, double s, double e, double n) => RegionIndexEntry(
      code: code,
      slug: code.toLowerCase(),
      name: name,
      url: 'https://${code.toLowerCase()}.meshsonar.com',
      bbox: [w, s, e, n],
      boundary: {
        'type': 'Polygon',
        'coordinates': [
          [[w, s], [e, s], [e, n], [w, n], [w, s]],
        ],
      },
    );

// Columbus in the middle; Dayton west, Zanesville east, Cincinnati south-west, Cleveland far north (off a zoom 8 screen).
final cmh = box('CMH', 'Columbus, US', -83.4, 39.6, -82.6, 40.4);
final day = box('DAY', 'Dayton, US', -84.6, 39.6, -83.45, 40.4);
final zzv = box('ZZV', 'Zanesville, US', -82.55, 39.6, -81.6, 40.4);
final cvg = box('CVG', 'Cincinnati, US', -84.9, 38.7, -83.8, 39.5);
final cle = box('CLE', 'Cleveland, US', -82.6, 41.1, -81.2, 41.9);
final index = [cmh, day, zzv, cvg, cle];

/// A button that asks to switch to [to], the way the region switcher and the nearest-regions sheet do.
Future<void> pumpAsk(WidgetTester tester, Harness h, RegionIndexEntry to, {Size size = const Size(390, 700), double textScale = 1.0, Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(
      theme: meshSonarTheme(brightness),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: Builder(builder: (c) => TextButton(key: const Key('ask'), onPressed: () => confirmRegionSwitch(c, to), child: const Text('ask')))),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('ask')));
  await tester.pumpAndSettle();
}

Finder k(String key) => find.byKey(Key(key));

Future<Harness> harness(WidgetTester tester) async {
  final h = Harness();
  h.client.regionsIndexResult = index;
  await h.state.init();
  await tester.pumpAndSettle();
  return h;
}

void main() {
  group('the confirm sheet and what the switch does', () {
    testWidgetsT('switches at once with no sheet; the toast says so and Undo puts the old region back', (tester) async {
      final h = await harness(tester);
      final before = h.state.viewingRegion?.code;
      await pumpAsk(tester, h, day);
      expect(k('region-switch-sheet'), findsNothing, reason: 'no confirm sheet');
      expect(find.textContaining('Switched to Dayton'), findsOneWidget);
      expect(h.state.settings.regionManual, 'DAY');
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(h.state.settings.regionManual, isNull);
      expect(h.state.viewingRegion?.code, before);
    });

    testWidgetsT('Switch makes Dayton the viewed region (saved as the manual pick), remembers it as recent', (tester) async {
      final h = await harness(tester);
      await pumpAsk(tester, h, day);
      expect(h.state.settings.regionManual, 'DAY');
      expect(h.state.viewingRegion?.code, 'DAY');
      expect(uiPrefsFor(h.state).recentRegions, ['DAY']);
      expect(h.state.regionNeighbours?.viewing.code, 'DAY', reason: 'the neighbours are now Dayton\'s');
    });

    testWidgetsT('the switcher lists the last three switches first, most recent first', (tester) async {
      final h = await harness(tester);
      attachUiPrefs(h.state, UiPrefs(seen: true));
      final p = uiPrefsFor(h.state);
      for (final c in ['DAY', 'ZZV', 'CVG', 'CLE']) {
        await p.pushRecentRegion(c);
      }
      expect(p.recentRegions, ['CLE', 'CVG', 'ZZV'], reason: 'three, most recent first');
      await p.pushRecentRegion('CVG');
      expect(p.recentRegions, ['CVG', 'CLE', 'ZZV']);
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: Scaffold(body: AppScope(state: h.state, child: RegionSwitcherSheet(state: h.state)))));
      await tester.pumpAndSettle();
      expect(k('regions-recent'), findsOneWidget);
      final order = [for (final c in ['CVG', 'CLE', 'ZZV']) tester.getTopLeft(k('region-recent-$c')).dy];
      expect(order[0], lessThan(order[1]));
      expect(order[1], lessThan(order[2]));
    });

    testWidgetsT('with no GPS fix the switcher lists the regions near the one on screen', (tester) async {
      final h = Harness();
      h.client.regionsIndexResult = index;
      h.location.currentFix = () => null;
      h.lastKnownStore = null;
      await h.state.init();
      await tester.pumpAndSettle();
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: Scaffold(body: AppScope(state: h.state, child: RegionSwitcherSheet(state: h.state)))));
      await tester.pumpAndSettle();
      expect(h.state.regionFixKnown, isFalse);
      expect(k('regions-near-view'), findsOneWidget);
      expect(k('region-near-DAY'), findsOneWidget);
    });
  });

  group('outside coverage', () {
    testWidgetsT('the chip offers the nearest regions; picking one switches and closes the sheet', (tester) async {
      final h = Harness();
      h.client.regionsIndexResult = [day, zzv];
      h.location.currentFix = () => null;
      await h.state.init();
      await tester.pumpAndSettle();
      await tester.pumpWidget(AppScope(
        state: h.state,
        child: MaterialApp(theme: meshSonarTheme(Brightness.light), home: Scaffold(body: Builder(builder: (c) => TextButton(key: const Key('open'), onPressed: () => showNearestRegionsSheet(c), child: const Text('open'))))),
      ));
      await tester.tap(k('open'));
      await tester.pumpAndSettle();
      expect(find.text('Nearest regions'), findsOneWidget);
      expect(find.textContaining('No MeshSonar region covers this location'), findsOneWidget);
      await tester.tap(k('nearest-region-DAY'));
      await tester.pumpAndSettle();
      expect(find.text('Switch to Dayton?'), findsNothing);
      expect(h.state.settings.regionManual, 'DAY');
      expect(find.text('Nearest regions'), findsNothing, reason: 'the sheet closes after a switch');
    });
  });
}
