// Build 73 map visual harness (MAP slices 1 to 3 + the size choices), against the real server: the Drive map at the zoom steps
// of the coverage ladder (country, states, region, metro, city, street), a tap on a summary hexagon, the Layers sheet with Label
// size / Icon size / Colour nodes by, the same view at Small and at Large, Colour by Status, and the Network > Live map with its
// nodes and names. Prints `SCREEN <name>` per frame for scripts/verify_sim.sh (HARNESS=1) and `VERIFY_DONE`.
//
//   HARNESS=1 FLOW_TEST=integration_test/map73_visual_test.dart VARIANTS="dark:large" scripts/verify_sim.sh . <out>
import 'dart:io' show HttpClient;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/main_map_focus.dart';

import 'drive_visual_test.dart' show dismiss, frame, pickColumbus, step, tapKey, toMapTab;
import 'screens.dart';

const _frames = <String>[
  'm73-04b-z8.6-summary-card','m73-08-layers-size-rows',
  'm73-08-layers-size-rows',
];
final _done = <String>{};

Future<void> mframe(WidgetTester t, String name) async {
  await frame(t, name);
  _done.add(name);
}

const _columbus = LatLng(39.96, -83.0);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('map 73 extra', (t) async {
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
    final d = ActiveMapDefinition.current;
    // ignore: avoid_print
    print('RUN_INFO definition=${d.version} capabilities=${d.capabilities.length} summary=${d.hasCapability('coverage.summary')} labelsSpec=${d.hasCapability('labels.spec')} symbolsSet=${d.hasCapability('symbols.set')}');

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
    // Make sure the definition in use is the live version 2 one (the store refreshes at launch).
    await step('definition', () async {
      for (var i = 0; i < 20 && !ActiveMapDefinition.current.hasCapability('coverage.summary'); i++) {
        await ActiveMapDefinition.follow('cmh');
        await pumpFor(t, const Duration(seconds: 1));
      }
      // ignore: avoid_print
      print('DEFINITION ${ActiveMapDefinition.current.version} summary=${ActiveMapDefinition.current.hasCapability('coverage.summary')}');
    });
    await step('map', () async {
      await toMapTab(t);
      await pumpFor(t, const Duration(seconds: 3));
    });

    Future<void> look(double zoom, {Duration wait = const Duration(seconds: 9)}) async {
      MainMapFocus.request(_columbus, zoom);
      await pumpFor(t, const Duration(milliseconds: 600));
      await pumpFor(t, wait);
    }

    await step('z8.6', () async {
      await look(8.6);
      // a tap on a red road hexagon (logical 258, 258 on the phone): a summary hexagon opens its card
      await t.tapAt(const Offset(258, 258));
      await pumpFor(t, const Duration(seconds: 4));
      await mframe(t, 'm73-04b-z8.6-summary-card');
      await tapKey(t, ['info-panel-close', 'map-panel-close'], quiet: true);
    });
    await step('layers', () async {
      await look(12.4, wait: const Duration(seconds: 3));
      if (!await tapKey(t, ['drive-map-layers'])) throw StateError('no Layers button');
      await pumpFor(t, const Duration(seconds: 2));
      final size = find.byKey(const Key('map-size-controls'));
      for (var i = 0; i < 20 && size.evaluate().isEmpty; i++) {
        await t.drag(find.byKey(const Key('layers-sheet')), const Offset(0, -300), warnIfMissed: false);
        await pumpFor(t, const Duration(milliseconds: 400));
      }
      if (size.evaluate().isEmpty) throw StateError('no size rows in the Layers sheet');
      await mframe(t, 'm73-08-layers-size-rows');
      await dismiss(t);
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
