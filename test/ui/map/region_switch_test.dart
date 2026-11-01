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
    testWidgets('asks "Switch to Dayton?", starts on Cancel, Cancel changes nothing', (tester) async {
      final h = await harness(tester);
      final before = h.state.viewingRegion?.code;
      await pumpAsk(tester, h, day);
      expect(find.text('Switch to Dayton?'), findsOneWidget);
      expect(find.text('The map and stats will show that region.'), findsOneWidget);
      final cancel = tester.widget<OutlinedButton>(k('region-switch-cancel'));
      expect(cancel.autofocus, isTrue, reason: 'Cancel is the default');
      expect(tester.getSize(k('region-switch-cancel')).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(k('region-switch-confirm')).height, greaterThanOrEqualTo(48));
      await tester.tap(k('region-switch-cancel'));
      await tester.pumpAndSettle();
      expect(h.state.viewingRegion?.code, before);
      expect(h.state.settings.regionManual, isNull);
    });

    testWidgets('Switch makes Dayton the viewed region (saved as the manual pick), remembers it as recent', (tester) async {
      final h = await harness(tester);
      await pumpAsk(tester, h, day);
      await tester.tap(k('region-switch-confirm'));
      await tester.pumpAndSettle();
      expect(h.state.settings.regionManual, 'DAY');
      expect(h.state.viewingRegion?.code, 'DAY');
      expect(uiPrefsFor(h.state).recentRegions, ['DAY']);
      expect(h.state.regionNeighbours?.viewing.code, 'DAY', reason: 'the neighbours are now Dayton\'s');
    });

    testWidgets('the switcher lists the last three switches first, most recent first', (tester) async {
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

    testWidgets('with no GPS fix the switcher lists the regions near the one on screen', (tester) async {
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
    testWidgets('the chip offers the nearest regions; picking one still asks first', (tester) async {
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
      expect(find.text('Switch to Dayton?'), findsOneWidget);
      await tester.tap(k('region-switch-confirm'));
      await tester.pumpAndSettle();
      expect(h.state.settings.regionManual, 'DAY');
      expect(find.text('Nearest regions'), findsNothing, reason: 'the sheet closes after a switch');
    });
  });

  group('layout', () {
    for (final (name, size, scale, dark) in [
      ('iPhone', const Size(393, 852), 1.0, false),
      ('iPhone 2.5x text dark', const Size(393, 852), 2.5, true),
      ('iPad dark landscape', const Size(1366, 1024), 1.0, true),
    ]) {
      testWidgets('$name: the confirm sheet fits, buttons are 48 px targets, no overflow', (tester) async {
        final h = await harness(tester);
        await pumpAsk(tester, h, day, size: size, textScale: scale, brightness: dark ? Brightness.dark : Brightness.light);
        expect(find.text('Switch to Dayton?'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(k('region-switch-confirm')).height, greaterThanOrEqualTo(47.9));
        expect(tester.getRect(k('region-switch-sheet')).bottom, lessThanOrEqualTo(size.height + 0.5));
        await tester.tap(k('region-switch-cancel'));
        await tester.pumpAndSettle();
      });
    }

    testWidgets('VoiceOver: the sheet title is a header', (tester) async {
      final handle = tester.ensureSemantics();
      final h = await harness(tester);
      await pumpAsk(tester, h, day);
      expect(tester.getSemantics(find.text('Switch to Dayton?')).flagsCollection.isHeader, isTrue);
      handle.dispose();
    });
  });
}
