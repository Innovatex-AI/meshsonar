// Switching region from the map: the neighbouring regions layer (dashed outlines, names, off-screen pins), the tap to
// "Switch to <region>?", the confirm sheet (Cancel is the default), what the switch keeps and clears, recents in the
// switcher, the "Outside coverage" nearest-regions sheet. iPhone / iPad, 2.5x text, dark, 48 px, VoiceOver.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_neighbours.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
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

RegionNeighbourSet setFor(RegionIndexEntry v) => neighboursOf(index, v);

Future<MapController> pumpMap(
  WidgetTester tester, {
  Size size = const Size(390, 700),
  double textScale = 1.0,
  Brightness brightness = Brightness.light,
  bool layerOn = true,
  Future<bool> Function(RegionIndexEntry)? onPick,
  void Function(String?)? onSelect,
  Harness? harness,
  LatLng? position,
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final ctl = MapController();
  Widget app = MaterialApp(
    theme: meshSonarTheme(brightness),
    home: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: Builder(
          builder: (context) => CoverageMap(
            key: const Key('map'),
            pings: const [],
            showTiles: false,
            position: position,
            fallbackCenter: const LatLng(40.0, -83.0),
            overlayPadding: padding,
            layerState: layerOn ? kDefaultLayerState : kDefaultLayerState.toggle(kRegionsLayerId, false),
            regionNeighbours: setFor(cmh),
            onPickRegion: onPick ?? (r) => confirmRegionSwitch(context, r),
            onSelectRepeater: onSelect,
          ),
        ),
      ),
    ),
  );
  if (harness != null) app = AppScope(state: harness.state, child: app);
  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 200));
  return ctl;
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
  group('the layer', () {
    testWidgets('draws dashed outlines and a name button for each neighbour, not for the viewed region itself', (tester) async {
      await pumpMap(tester, onPick: (_) async => false);
      expect(k('region-outlines'), findsOneWidget);
      expect(k('region-name-DAY'), findsOneWidget);
      expect(k('region-name-ZZV'), findsOneWidget);
      expect(k('region-name-CMH'), findsNothing);
      expect(find.text('Dayton'), findsOneWidget, reason: 'the country suffix is cut');
    });

    testWidgets('off in the layers state: nothing drawn', (tester) async {
      await pumpMap(tester, layerOn: false, onPick: (_) async => false);
      expect(k('region-outlines'), findsNothing);
      expect(k('region-name-DAY'), findsNothing);
    });

    testWidgets('street level (zoomed in to a drive): hidden, so names never clutter the drive', (tester) async {
      await pumpMap(tester, position: const LatLng(39.96, -82.99), onPick: (_) async => false);
      expect(k('region-outlines'), findsNothing);
    });

    testWidgets('a neighbour off screen keeps its name pinned to the edge with an arrow, on screen inside the map', (tester) async {
      await pumpMap(tester, onPick: (_) async => false);
      expect(k('region-name-CLE'), findsNothing, reason: 'Cleveland is far north of the screen');
      final pin = k('region-edge-CLE');
      expect(pin, findsOneWidget);
      final map = tester.getRect(k('map'));
      expect(map.contains(tester.getCenter(pin)), isTrue);
      expect(tester.getCenter(pin).dy, lessThan(map.center.dy), reason: 'north of the middle');
      expect(find.descendant(of: pin, matching: find.byIcon(Icons.arrow_forward)), findsOneWidget);
      expect(tester.getSize(pin).height, greaterThanOrEqualTo(48));
    });

    testWidgets('names are not placed under the parent\'s controls (overlay padding)', (tester) async {
      await pumpMap(tester, onPick: (_) async => false, padding: const EdgeInsets.only(left: 200));
      // Dayton sits west of the middle; with the left 200 px covered its name moves to the edge pin instead of under the controls.
      final inner = tester.getRect(k('map')).deflate(0).translate(200, 0);
      for (final code in ['DAY', 'ZZV', 'CVG']) {
        final name = k('region-name-$code');
        if (name.evaluate().isNotEmpty) expect(tester.getRect(name).left, greaterThanOrEqualTo(inner.left - 1), reason: code);
      }
    });
  });

  group('tapping', () {
    testWidgets('a name asks first: the region is passed to the host, the camera frames it, the selection goes', (tester) async {
      final asked = <String>[];
      final cleared = <String?>[];
      await pumpMap(tester, onPick: (r) async {
        asked.add(r.code);
        return true;
      }, onSelect: cleared.add);
      await tester.tap(k('region-name-DAY'));
      await tester.pumpAndSettle();
      expect(asked, ['DAY']);
      expect(cleared, contains(null), reason: 'the selected repeater is dropped');
      // The map now frames Dayton's box: its centre is near -84.0.
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      final cam = map.mapController!.camera;
      expect(cam.center.longitude, closeTo(-84.025, 0.2));
    });

    testWidgets('a name when the host says no (Cancel): nothing moves', (tester) async {
      await pumpMap(tester, onPick: (_) async => false);
      final before = tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera.center;
      await tester.tap(k('region-name-DAY'));
      await tester.pumpAndSettle();
      expect(tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera.center, before);
    });

    testWidgets('a tap inside a neighbour\'s outline asks too; inside the viewed region it does not', (tester) async {
      final asked = <String>[];
      await pumpMap(tester, onPick: (r) async {
        asked.add(r.code);
        return false;
      });
      final cam = tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera;
      final origin = tester.getTopLeft(k('map'));
      // Inside Dayton's box (-84.0, 40.3) but away from its name, then inside Columbus (-83.0, 40.3).
      await tester.tapAt(origin + cam.latLngToScreenOffset(const LatLng(40.3, -84.0)));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(asked, ['DAY']);
      await tester.tapAt(origin + cam.latLngToScreenOffset(const LatLng(40.3, -83.0)));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(asked, ['DAY'], reason: 'a tap in the region you are already viewing never offers a switch');
    });
  });

  group('the confirm sheet and what the switch does', () {
    testWidgets('asks "Switch to Dayton?", starts on Cancel, Cancel changes nothing', (tester) async {
      final h = await harness(tester);
      await pumpMap(tester, harness: h);
      final before = h.state.viewingRegion?.code;
      await tester.tap(k('region-name-DAY'));
      await tester.pumpAndSettle();
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

    testWidgets('Switch makes Dayton the viewed region (saved as the manual pick), remembers it as recent, keeps the layers', (tester) async {
      final h = await harness(tester);
      await pumpMap(tester, harness: h);
      await tester.tap(k('region-name-DAY'));
      await tester.pumpAndSettle();
      await tester.tap(k('region-switch-confirm'));
      await tester.pumpAndSettle();
      expect(h.state.settings.regionManual, 'DAY');
      expect(h.state.viewingRegion?.code, 'DAY');
      expect(uiPrefsFor(h.state).recentRegions, ['DAY']);
      expect(h.state.regionNeighbours?.viewing.code, 'DAY', reason: 'the neighbours are now Dayton\'s');
      // Layer choices are not touched by a switch.
      expect(kDefaultLayerState.isOn('measured'), isTrue);
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
      ('iPhone dark', const Size(393, 852), 1.0, true),
      ('iPhone 2.5x text', const Size(393, 852), 2.5, false),
      ('iPhone 2.5x text dark', const Size(393, 852), 2.5, true),
      ('iPad', const Size(1024, 1366), 1.0, false),
      ('iPad dark landscape', const Size(1366, 1024), 1.0, true),
    ]) {
      testWidgets('$name: names are 48 px targets, no overflow, the sheet fits', (tester) async {
        final h = await harness(tester);
        await pumpMap(tester, size: size, textScale: scale, brightness: dark ? Brightness.dark : Brightness.light, harness: h);
        expect(tester.takeException(), isNull);
        for (final c in ['DAY', 'ZZV']) {
          final f = k('region-name-$c');
          if (f.evaluate().isEmpty) continue;
          expect(tester.getSize(f).height, greaterThanOrEqualTo(47.9), reason: c);
          expect(tester.getSize(f).width, greaterThanOrEqualTo(47.9), reason: c);
        }
        await tester.tap(k('region-name-DAY'));
        await tester.pumpAndSettle();
        expect(find.text('Switch to Dayton?'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final sheet = tester.getRect(k('region-switch-sheet'));
        expect(sheet.bottom, lessThanOrEqualTo(size.height + 0.5));
        await tester.tap(k('region-switch-cancel'));
        await tester.pumpAndSettle();
      });
    }

    testWidgets('VoiceOver: each name is a button that says what it does; the sheet title is a header', (tester) async {
      final handle = tester.ensureSemantics();
      final h = await harness(tester);
      await pumpMap(tester, harness: h);
      expect(find.bySemanticsLabel('Switch to Dayton'), findsOneWidget);
      expect(find.bySemanticsLabel('Switch to Zanesville'), findsOneWidget);
      final node = tester.getSemantics(find.bySemanticsLabel('Switch to Dayton'));
      expect(node.flagsCollection.isButton, isTrue);
      await tester.tap(k('region-name-DAY'));
      await tester.pumpAndSettle();
      final title = tester.getSemantics(find.text('Switch to Dayton?'));
      expect(title.flagsCollection.isHeader, isTrue);
      handle.dispose();
    });
  });
}
