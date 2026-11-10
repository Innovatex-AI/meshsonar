// M2 proper visual harness: the app renders its maps from the Map Definition (plan unified-map-system §2, §6 row M2). Walks the
// real app on a simulator and prints `SCREEN <name>` per frame (scripts/verify_sim.sh with HARNESS=1 screenshots each, per
// appearance variant), `MISSING <frame>`, `FRAMES n/m` and `VERIFY_DONE`. A clean run has zero STEPFAIL / MISSING.
//
//   HARNESS=1 FLOW_TEST=integration_test/m2_definition_visual_test.dart DEVICES="iPhone 17 Pro|iPad Pro 11-inch (M5)" \
//     VARIANTS="light:large dark:large" scripts/verify_sim.sh . <out>
//
// Frames: CMH map with the legend card (closed, open), the Layers sheet (top, then Filters + Palette), the Colour-blind safe
// palette chosen in the legend, the repeater ring symbol zoomed in, an outside-data-only region (SEA), a region outside North
// America (AAH, Aachen: OpenFreeMap fallback, no offline pack), and a preview (Plan > Where to drive) with "Open the map".
// Each step also checks what the frame shows comes from the definition (layer names, legend entries, palette names).
import 'dart:io' show HttpClient, Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/main_map_focus.dart';

import 'drive_visual_test.dart' show dismiss, frame, goTab, pickColumbus, pickRegion, step, tapKey, toMapTab;
import 'screens.dart';

final String _appearance = Platform.environment['VT_APPEARANCE'] ?? const String.fromEnvironment('VT_APPEARANCE', defaultValue: 'light');

const _frames = <String>[
  'md-01-cmh-map',
  'md-02-legend-open',
  'md-03-layers-top',
  'md-03b-layers-network',
  'md-04-layers-filters',
  'md-05-colour-blind',
  'md-06-repeater-rings',
  'md-07-sea',
  'md-08-aah',
  'md-09-preview',
  'md-10-preview-opened',
];
final _done = <String>{};

Future<void> mdframe(WidgetTester t, String name) async {
  await frame(t, name);
  _done.add(name);
}

void expectText(String where, String text) {
  if (find.textContaining(text).evaluate().isEmpty) throw StateError('$where: "$text" not on screen');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('m2 definition visual', (t) async {
    FlutterError.onError = (d) {
      final s = d.exceptionAsString();
      if (s.contains('Barometer is not available')) return;
      // ignore: avoid_print
      print('${s.contains('overflow') ? 'OVERFLOW' : 'EXC'} ${s.split('\n').take(3).join(' | ')} ${d.context ?? ''}');
    };
    await app.main();
    var quietSince = DateTime.now();
    final promptEnd = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(promptEnd)) {
      await t.pump(const Duration(milliseconds: 200));
      final skip = find.byKey(const Key('onboarding-skip'));
      final keep = find.byKey(const Key('telemetry-keep'));
      if (skip.evaluate().isNotEmpty) {
        await t.tap(skip.first, warnIfMissed: false);
        quietSince = DateTime.now();
      } else if (keep.evaluate().isNotEmpty) {
        await t.tap(keep.first, warnIfMissed: false);
        quietSince = DateTime.now();
      }
      final shell = find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail')).evaluate().isNotEmpty;
      if (shell && DateTime.now().difference(quietSince) > const Duration(seconds: 8)) break;
    }
    final st = AppScope.read(t.element(find.byType(Scaffold).first));
    final mq = MediaQuery.of(t.element(find.byType(Scaffold).first));
    // ignore: avoid_print
    print('RUN_INFO appearance=$_appearance size=${mq.size.width.round()}x${mq.size.height.round()} brightness=${mq.platformBrightness.name}');
    if (st.settings.colourPalette != ColourPalette.standard) await st.updateSettings(st.settings.copyWith(colourPalette: ColourPalette.standard));

    await step('seed', () async {
      await st.refreshLocationAccess();
      if (st.locationAccess != LocationAccess.granted) st.debugSetLocationAccess(LocationAccess.granted);
      await t.runAsync(() async {
        for (var i = 0; i < 30; i++) {
          try {
            final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
            final r = await (await c.getUrl(Uri.parse('https://meshsonar.com/'))).close().timeout(const Duration(seconds: 8));
            await r.drain<void>();
            c.close();
            return;
          } catch (_) {
            await Future<void>.delayed(const Duration(seconds: 3));
          }
        }
      });
      for (var round = 0; round < 4 && !st.regionIndexLoaded; round++) {
        if (round > 0) st.debugOnForeground();
        final end = DateTime.now().add(const Duration(seconds: 30));
        while (!st.regionIndexLoaded && DateTime.now().isBefore(end)) {
          await t.pump(const Duration(milliseconds: 200));
        }
      }
      if (!st.regionIndexLoaded) throw StateError('region index never loaded (network)');
      if (st.settings.baseMapStyle != 'chart') await st.updateSettings(st.settings.copyWith(baseMapStyle: 'chart'));
    });

    /// Shows the viewed region on the Drive map (its bbox centre) through the same channel "Open the map" uses.
    Future<void> lookAtRegion({double zoom = 9}) async {
      final b = st.viewingRegion?.bbox;
      await toMapTab(t);
      if (b != null && b.length == 4) MainMapFocus.request(LatLng((b[1] + b[3]) / 2, (b[0] + b[2]) / 2), zoom);
      await pumpFor(t, const Duration(seconds: 10));
    }

    Future<void> waitDefinition(String slug) async {
      for (var i = 0; i < 40 && ActiveMapDefinition.current.scopeSlug != slug; i++) {
        await pumpFor(t, const Duration(milliseconds: 500));
      }
      // ignore: avoid_print
      print('DEFINITION ${ActiveMapDefinition.current.scopeSlug} v=${ActiveMapDefinition.current.version} layers=${ActiveMapDefinition.current.layerDefs.map((l) => l.id).join(',')}');
      if (ActiveMapDefinition.current.scopeSlug != slug) throw StateError('definition scope is ${ActiveMapDefinition.current.scopeSlug}, wanted $slug');
    }

    await step('cmh', () async {
      await pickColumbus(t, st);
      await waitDefinition('cmh');
      await lookAtRegion(zoom: 9);
      if (find.byKey(const Key('legend-card')).evaluate().isEmpty) throw StateError('no legend card on the Drive map');
      expectText('legend', 'Weak → strong signal');
      await mdframe(t, 'md-01-cmh-map');
    });
    await step('legend-open', () async {
      if (!await tapKey(t, ['legend-card-toggle'], wait: const Duration(seconds: 2))) throw StateError('no legend toggle');
      for (final name in ['Measured coverage', 'Repeaters', 'Colours', 'Colour-blind safe']) {
        expectText('legend body', name);
      }
      await mdframe(t, 'md-02-legend-open');
    });
    await step('colour-blind', () async {
      if (!await tapKey(t, ['legend-palette-colour_blind'], wait: const Duration(seconds: 3))) throw StateError('no palette switch in the legend');
      if (st.settings.colourPalette != ColourPalette.colourBlind) throw StateError('palette is ${st.settings.colourPalette}');
      await pumpFor(t, const Duration(seconds: 4));
      await mdframe(t, 'md-05-colour-blind');
      await tapKey(t, ['legend-palette-standard'], wait: const Duration(seconds: 2));
      await tapKey(t, ['legend-card-toggle'], wait: const Duration(seconds: 1));
    });
    await step('layers', () async {
      if (!await tapKey(t, ['drive-map-layers'], wait: const Duration(seconds: 2))) throw StateError('no Layers button');
      if (find.byKey(const Key('layers-sheet')).evaluate().isEmpty) throw StateError('Layers sheet did not open');
      try {
        if (find.byKey(const Key('layers-group-coverage')).evaluate().isEmpty) throw StateError('no coverage group');
        await mdframe(t, 'md-03-layers-top');
        // The sheet's list is lazy: scroll each later group into view (the website panel's order).
        final list = find.descendant(of: find.byKey(const Key('layers-sheet')), matching: find.byType(Scrollable)).first;
        for (final key in ['layers-group-network', 'layer-network', 'layers-group-context']) {
          await t.scrollUntilVisible(find.byKey(Key(key)), 160, scrollable: list, maxScrolls: 40);
        }
        await pumpFor(t, const Duration(seconds: 1));
        for (final name in ['Moving phones', 'Observers', 'All MeshCore repeaters', 'Link lines', 'Region borders']) {
          expectText('layers network', name);
        }
        await mdframe(t, 'md-03b-layers-network');
        for (final key in ['layers-group-filters', 'layers-group-palette', 'layers-palette']) {
          await t.scrollUntilVisible(find.byKey(Key(key)), 160, scrollable: list, maxScrolls: 40);
        }
        await pumpFor(t, const Duration(seconds: 1));
        expectText('layers', 'Measured in');
        expectText('layers', 'Drives from');
        await mdframe(t, 'md-04-layers-filters');
      } finally {
        await dismiss(t);
      }
    });
    await step('rings', () async {
      if (find.byKey(const Key('layers-sheet')).evaluate().isNotEmpty) await dismiss(t);
      await toMapTab(t);
      MainMapFocus.request(const LatLng(40.0995, -82.94), 13);
      await pumpFor(t, const Duration(seconds: 10));
      await mdframe(t, 'md-06-repeater-rings');
    });
    await step('sea', () async {
      await pickRegion(t, st, query: 'seattle', code: 'SEA');
      await waitDefinition('sea');
      await lookAtRegion(zoom: 9);
      await mdframe(t, 'md-07-sea');
    });
    await step('aah', () async {
      await pickRegion(t, st, query: 'aachen', code: 'AAH');
      await waitDefinition('aah');
      await lookAtRegion(zoom: 10);
      await mdframe(t, 'md-08-aah');
    });
    await step('preview', () async {
      await pickColumbus(t, st);
      await goTab(t, 'Plan', 'plan-list');
      final card = find.byKey(const Key('plan-drive-next-map'));
      for (var i = 0; i < 12 && card.evaluate().isEmpty; i++) {
        await pumpFor(t, const Duration(seconds: 2));
      }
      if (card.evaluate().isEmpty) throw StateError('no Where to drive map on the Plan tab');
      await t.ensureVisible(card);
      await pumpFor(t, const Duration(seconds: 8));
      final open = find.descendant(of: card, matching: find.byKey(const Key('map-preview-open')));
      if (open.evaluate().isEmpty) throw StateError('the preview has no Open the map button');
      await mdframe(t, 'md-09-preview');
      await t.tap(open.first, warnIfMissed: false);
      await pumpFor(t, const Duration(seconds: 8));
      if (find.byKey(const Key('drive-map')).evaluate().isEmpty) throw StateError('Open the map did not open the Drive map');
      await mdframe(t, 'md-10-preview-opened');
    });

    for (final f in _frames) {
      // ignore: avoid_print
      if (!_done.contains(f)) print('MISSING $f');
    }
    // ignore: avoid_print
    print('FRAMES ${_done.length}/${_frames.length}');
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 25)));
}
