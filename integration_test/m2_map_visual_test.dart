// M2 basemap visual harness: the app's maps on our Protomaps tiles (plan unified-map-system M2). Walks the real app on a
// simulator and prints `SCREEN <NN-name>` per frame (scripts/verify_sim.sh with HARNESS=1 screenshots each, per appearance
// variant), `MISSING <frame>` for frames not shot, `FRAMES n/m` and `VERIFY_DONE`. A clean run has zero STEPFAIL / MISSING.
//
//   HARNESS=1 FLOW_TEST=integration_test/m2_map_visual_test.dart DEVICES="iPhone 17 Pro|iPad Pro 11-inch" \
//     VARIANTS="light:large dark:large" scripts/verify_sim.sh . <out>
//
// Frames: the Drive map on Chart (follows the theme), its credit line and Credits sheet, zoomed in to street level, the Light
// and Dark styles, and a small map (Plan > Where to drive) with its own credit. Each frame also checks the credit text names
// our tiles (or OpenFreeMap) and never a bare OSM server line.
import 'dart:io' show HttpClient, Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/map/basemap_layer.dart' show BasemapLayer;

import 'drive_visual_test.dart' show dismiss, frame, goTab, pickColumbus, step, tapKey, toMapTab, zoomOut;
import 'screens.dart';

final String _appearance = Platform.environment['VT_APPEARANCE'] ?? const String.fromEnvironment('VT_APPEARANCE', defaultValue: 'light');

const _frames = <String>[
  'm2-01-chart',
  'm2-02-credits',
  'm2-03-street-zoom',
  'm2-04-light-style',
  'm2-05-dark-style',
  'm2-06-small-map',
];
final _done = <String>{};

Future<void> m2frame(WidgetTester t, String name) async {
  await frame(t, name);
  _done.add(name);
}

void checkCredit(String where, {String key = 'map-attribution-text'}) {
  final f = find.byKey(Key(key));
  if (f.evaluate().isEmpty) throw StateError('$where: no credit ($key)');
  final text = (f.evaluate().first.widget as Text).data ?? '';
  if (!(text.contains('Protomaps') || text.contains('OpenFreeMap') || text.contains('OpenTopoMap'))) {
    throw StateError('$where: credit "$text" does not name the basemap source');
  }
  // ignore: avoid_print
  print('CREDIT $where "$text"');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('m2 map visual', (t) async {
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
    print('RUN_INFO appearance=$_appearance size=${mq.size.width.round()}x${mq.size.height.round()} brightness=${mq.platformBrightness.name} basemap_layer=${BasemapLayer.enabled}');

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
    });
    await step('columbus', () => pickColumbus(t, st));
    Future<void> setStyle(String id) async {
      await st.updateSettings(st.settings.copyWith(baseMapStyle: id));
      await toMapTab(t);
      await pumpFor(t, const Duration(seconds: 8)); // the vector tiles render on the phone after they land
    }

    await step('chart', () async {
      await setStyle('chart');
      if (find.byType(BasemapLayer).evaluate().isEmpty) throw StateError('the Drive map has no BasemapLayer');
      checkCredit('chart');
      await m2frame(t, 'm2-01-chart');
    });
    await step('credits', () async {
      if (!await tapKey(t, ['map-attribution-info'], wait: const Duration(seconds: 2))) throw StateError('no credit (i)');
      if (find.byKey(const Key('credits-basemap')).evaluate().isEmpty) throw StateError('Credits sheet has no Base map section');
      await m2frame(t, 'm2-02-credits');
      await dismiss(t);
    });
    await step('zoom', () async {
      await zoomOut(t, pinches: 3, zoomIn: true);
      await pumpFor(t, const Duration(seconds: 8));
      checkCredit('zoom');
      await m2frame(t, 'm2-03-street-zoom');
    });
    await step('light', () async {
      await setStyle('street');
      checkCredit('light');
      await m2frame(t, 'm2-04-light-style');
    });
    await step('dark', () async {
      await setStyle('dark');
      checkCredit('dark');
      await m2frame(t, 'm2-05-dark-style');
      await setStyle('chart');
    });
    await step('small-map', () async {
      await goTab(t, 'Plan', 'plan-list');
      final card = find.byKey(const Key('plan-drive-next-map'));
      for (var i = 0; i < 12 && card.evaluate().isEmpty; i++) {
        await pumpFor(t, const Duration(seconds: 2));
      }
      if (card.evaluate().isEmpty) throw StateError('no Where to drive map on the Plan tab');
      await t.ensureVisible(card);
      await pumpFor(t, const Duration(seconds: 8));
      final credit = find.descendant(of: card, matching: find.byKey(const Key('mini-map-credit')));
      if (credit.evaluate().isEmpty) throw StateError('the small map has no credit');
      final text = (find.descendant(of: credit, matching: find.byType(Text)).evaluate().first.widget as Text).data ?? '';
      if (!text.contains('Protomaps') && !text.contains('OpenFreeMap')) throw StateError('small map credit "$text"');
      // ignore: avoid_print
      print('CREDIT small-map "$text"');
      await m2frame(t, 'm2-06-small-map');
    });

    for (final f in _frames) {
      // ignore: avoid_print
      if (!_done.contains(f)) print('MISSING $f');
    }
    // ignore: avoid_print
    print('FRAMES ${_done.length}/${_frames.length}');
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
