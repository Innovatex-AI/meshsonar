// Drive/Map visual harness (plan WP-H, drive-map-redesign-plan section 22). One run walks the whole Drive capture list (22.1)
// against the real app on a simulator and prints one `SCREEN <NN-name>` line per frame; scripts/verify_sim.sh screenshots each
// one. It ends by printing `MISSING <frame>` for every frame of the list that was not captured, and `VERIFY_DONE` last. A run is
// clean when it printed zero STEPFAIL, zero MISSING and zero OVERFLOW lines.
//
// Preconditions are seeded, not tapped through (plan 22.2 a, h): Location is granted, the region is Columbus (CMH), the
// antenna profile of the simulated radio is saved, onboarding and the disclosure sheet are answered. The run prints
// `STEPFAIL precondition` if a prompt still covers the screen. Frames are taken only after `TileFetchGate.tilesSettled` (22.2 g).
//
// Dart defines (from verify_sim.sh): VT_LANDSCAPE=true (iPad landscape), VT_CS=<simctl content size>, VT_APPEARANCE=<light|dark>.
//
// Frames that name a Drive-redesign widget (panel, inspector, toast helper) are taken from the equivalent widget of the current
// app until that widget lands; each such case prints `NOTE <frame> <what was used>`, and the key table at the top of `main` is
// the single place to change when the redesign renames a key (new key first, current key as the fallback).
import 'dart:convert' show utf8;
import 'dart:io' show HttpClient, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/gps_health.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/radio/crypto.dart' show sha256, toHex;
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/design/app_surfaces.dart' show dismissAppToast, showAppToast;
import 'package:meshsonar/ui/map/coverage_map.dart' show CoverageMap;
import 'package:meshsonar/ui/map/tile_source.dart' show MapTileStats, TileFetchGate, TileOutcome;

import 'screens.dart';

// The harness app is built once and launched per variant, so these come from the launch environment (verify_sim.sh sets
// SIMCTL_CHILD_VT_*), with --dart-define as the fallback when run through `flutter test`.
final String _landscapeRaw = Platform.environment['VT_LANDSCAPE'] ?? const String.fromEnvironment('VT_LANDSCAPE');
final bool _landscape = _landscapeRaw == '1' || _landscapeRaw == 'true';
final String _contentSize = Platform.environment['VT_CS'] ?? const String.fromEnvironment('VT_CS', defaultValue: 'large');
final String _appearance = Platform.environment['VT_APPEARANCE'] ?? const String.fromEnvironment('VT_APPEARANCE', defaultValue: 'light');

/// Every frame of plan 22.1. The run fails (MISSING) for each one it did not shoot.
const _allFrames = <String>[
  '01-idle',
  '02-region-switcher',
  '03-attribution',
  '04-credits',
  '05-layers',
  '06-connected-idle',
  '07-driving-a',
  '08-driving-b',
  '09-driving-medium',
  '10-heard-list',
  '11-ping-settings',
  '12-repeater-inspector',
  '12b-repeater-details',
  '13-cell-inspector',
  '13b-cell-details',
  '14-immersive',
  '15-immersive-layers',
  '16-finished',
  '17-offline-pill',
  '17b-no-map-here',
  '18-toast',
  '19-gps-weak',
  '20-gps-denied-idle',
  '21-guide',
  '22-inspector-edge',
  '23-stop-sheet',
  '24-report',
  '25-mini-bar',
  '26-antenna-sheet',
];

final _shot = <String>{};

/// Waits for the map tiles, logs how long that took, then marks the frame.
Future<void> frame(WidgetTester t, String name) async {
  await pumpFor(t, const Duration(milliseconds: 300));
  final ms = await t.runAsync(() => TileFetchGate.tilesSettled()) ?? Duration.zero;
  // ignore: avoid_print
  print('TILES_SETTLED $name ${ms.inMilliseconds}ms');
  final ts = MapTileStats.instance;
  // ignore: avoid_print
  print('TILESTATS $name ${{for (final o in TileOutcome.values) o.name: ts.total(o)}}');
  _shot.add(name);
  await shot(t, name);
}

Finder _byKeyRe(RegExp re) => find.byWidgetPredicate((w) => w.key is ValueKey && re.hasMatch('${(w.key as ValueKey).value}'));

/// Taps the first widget with [keys] (first present wins). Scrolls it into view when it is built lazily. False (and a MISSING
/// line) when none exists.
Future<bool> tapKey(WidgetTester t, List<String> keys, {Duration wait = const Duration(seconds: 1), bool quiet = false}) async {
  Finder f = find.byKey(Key(keys.first));
  for (final k in keys) {
    f = find.byKey(Key(k));
    if (f.evaluate().isNotEmpty) break;
  }
  if (f.evaluate().isEmpty) {
    final scrollables = find.byType(Scrollable).evaluate().where((e) => (e.widget as Scrollable).axis == Axis.vertical);
    for (final k in keys) {
      if (scrollables.isEmpty) break;
      try {
        await t.scrollUntilVisible(find.byKey(Key(k)), 120, scrollable: find.byWidget(scrollables.first.widget), maxScrolls: 12);
        f = find.byKey(Key(k));
        break;
      } catch (_) {}
    }
  }
  if (f.evaluate().isEmpty) {
    // ignore: avoid_print
    if (!quiet) print('MISSING ${keys.first}');
    return false;
  }
  try {
    await t.ensureVisible(f.first);
  } catch (_) {}
  await t.tap(f.first, warnIfMissed: false);
  await pumpFor(t, wait);
  return true;
}

/// Closes the topmost sheet or dialog: pops the root navigator's top route (sheets, dialogs and action sheets are routes); when
/// nothing popped and the non-modal layers sheet is open, toggles it off. Never taps blindly at a fixed spot (a stray tap at the
/// top left once opened the guide page and left every later frame on it).
Future<void> dismiss(WidgetTester t) async {
  final ctx = t.element(find.byType(Scaffold).first);
  final popped = await Navigator.of(ctx, rootNavigator: true).maybePop();
  await pumpFor(t, const Duration(seconds: 1));
  if (!popped && find.byKey(const Key('layers-sheet')).evaluate().isNotEmpty) {
    await tapKey(t, ['drive-map-layers'], quiet: true);
  }
}

Future<void> step(String n, Future<void> Function() f) async {
  try {
    await f();
  } catch (e, st) {
    // ignore: avoid_print
    print('STEPFAIL $n: ${e.toString().split('\n').first} @ ${st.toString().split('\n').take(2).join(' ')}');
  }
}

AppState _state(WidgetTester t) => AppScope.read(t.element(find.byType(Scaffold).first));

Rect _mapRect(WidgetTester t) {
  final m = find.byKey(const Key('drive-map'));
  return m.evaluate().isEmpty ? Offset.zero & (t.view.physicalSize / t.view.devicePixelRatio) : t.getRect(m);
}

/// Opens a shell tab and waits until [marker] (a key on that tab) is on screen; retries the tap, because on a loaded machine the
/// first tap can land while the shell is still laying out.
Future<void> goTab(WidgetTester t, String label, String marker, {String? alt}) async {
  for (var i = 0; i < 4; i++) {
    final bar = find.byKey(const Key('shell-tabs')).evaluate().isNotEmpty
        ? find.byKey(const Key('shell-tabs'))
        : find.byKey(const Key('shell-rail'));
    var f = find.descendant(of: bar, matching: find.text(label));
    if (f.evaluate().isEmpty && alt != null) f = find.descendant(of: bar, matching: find.text(alt));
    if (f.evaluate().isNotEmpty) await t.tap(f.first, warnIfMissed: false);
    if (await waitFor(t, find.byKey(Key(marker)), timeout: const Duration(seconds: 8))) {
      await pumpFor(t, const Duration(seconds: 1));
      return;
    }
  }
  throw StateError('tab $label never showed $marker');
}

// The tab is called Drive from the shell redesign (WP1) on, Map before.
Future<void> toMapTab(WidgetTester t) => goTab(t, 'Drive', 'drive-map', alt: 'Map');

/// Makes Columbus (CMH) the viewing region through the region switcher like a person would (the Region screen loads that
/// region's cells and repeaters), then waits for the data.
Future<void> pickColumbus(WidgetTester t, AppState st) async {
  await goTab(t, 'Analyze', 'analyze-segments');
  final seg = find.descendant(of: find.byKey(const Key('analyze-segments')), matching: find.text('Region'));
  if (seg.evaluate().isNotEmpty) await t.tap(seg.first, warnIfMissed: false);
  await pumpFor(t, const Duration(seconds: 2));
  final chip = find.byKey(const Key('region-switch-chip'));
  if (!await waitFor(t, chip, timeout: const Duration(seconds: 30))) throw StateError('region-switch-chip never appeared');
  final label = (t.widget(chip) as ActionChip).label;
  if (label is Text && (label.data ?? '').startsWith('CMH')) return;
  await t.tap(chip);
  await pumpFor(t, const Duration(seconds: 2));
  final search = find.byKey(const Key('region-search'));
  if (await waitFor(t, search, timeout: const Duration(seconds: 15))) {
    await t.enterText(search, 'columbus');
    await pumpFor(t, const Duration(seconds: 2));
  }
  final row = _byKeyRe(RegExp(r'^region-(near|recent|option)-CMH$'));
  if (!await waitFor(t, row, timeout: const Duration(seconds: 20))) throw StateError('no CMH row in the region switcher');
  await t.tap(row.first);
  await pumpFor(t, const Duration(seconds: 10));
  if (st.viewingRegion?.code != 'CMH') throw StateError('viewing region is ${st.viewingRegion?.code} after picking Columbus');
}

/// Pinch the map out by about [levels] zoom levels (two fingers moving together).
Future<void> zoomOut(WidgetTester t, {int pinches = 2, bool zoomIn = false}) async {
  final r = _mapRect(t);
  final c = r.center;
  for (var i = 0; i < pinches; i++) {
    final a = await t.startGesture(c + Offset(zoomIn ? -25 : -90, 0), pointer: 11);
    final b = await t.startGesture(c + Offset(zoomIn ? 25 : 90, 0), pointer: 12);
    for (var k = 1; k <= 8; k++) {
      final d = zoomIn ? 25 + k * 8.0 : 90 - k * 8.0;
      await a.moveTo(c + Offset(-d, 0));
      await b.moveTo(c + Offset(d, 0));
      await t.pump(const Duration(milliseconds: 40));
    }
    await a.up();
    await b.up();
    await pumpFor(t, const Duration(seconds: 2));
  }
}

/// Prints the app's last diagnostics lines (what the app said it was doing), for runs that go off script.
void dumpDiag(AppState st, String tag, {int n = 10}) {
  final l = st.diagnostics.lines;
  // ignore: avoid_print
  print('DIAG $tag driving=${st.driving} connected=${st.connected} ${l.skip(l.length > n ? l.length - n : 0).join(' // ')}');
}

/// Taps a grid of points over the map (skipping its overlays) until the info panel opens with a body keyed [bodyKey]
/// (cell-sheet for a hex, repeater-sheet for a repeater). Returns true when found; the panel is left collapsed.
List<Rect> _overlayRects(WidgetTester t, Rect r) {
  final hint = find.byKey(const Key('map-hint'));
  return <Rect>[
    if (hint.evaluate().isNotEmpty) t.getRect(hint.first).inflate(6),
    Rect.fromLTRB(r.right - 90, r.top, r.right, r.bottom),
    Rect.fromLTRB(r.left, r.bottom - 90, r.left + 230, r.bottom),
  ];
}

Future<bool> tapUntilPanel(WidgetTester t, List<Offset> pts, String bodyKey) async {
  final r = _mapRect(t);
  final avoid = _overlayRects(t, r);
  for (final p in pts) {
    if (!r.deflate(20).contains(p) || avoid.any((a) => a.contains(p))) continue;
    await t.tapAt(p);
    await pumpFor(t, const Duration(milliseconds: 900));
    if (find.byKey(const Key('info-panel-header')).evaluate().isEmpty) continue;
    await t.tap(find.byKey(const Key('info-panel-header')), warnIfMissed: false);
    await pumpFor(t, const Duration(milliseconds: 600));
    if (find.byKey(Key(bodyKey)).evaluate().isNotEmpty) {
      await t.tap(find.byKey(const Key('info-panel-header')), warnIfMissed: false);
      await pumpFor(t, const Duration(milliseconds: 600));
      return true;
    }
    await tapKey(t, ['link-clear'], quiet: true);
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('drive visual', (t) async {
    FlutterError.onError = (d) {
      final s = d.exceptionAsString();
      if (s.contains('Barometer is not available')) return;
      // ignore: avoid_print
      print('${s.contains('overflow') ? 'OVERFLOW' : 'EXC'} ${s.split('\n').take(3).join(' | ')} ${d.context ?? ''}');
    };
    if (_landscape) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
    }
    await app.main();
    // First-run prompts (onboarding, the collection disclosure) arrive on their own schedule, later on a cold debug launch.
    // Answer whatever shows up until the shell has been quiet for 8 s, so no sheet is left over the Drive screen.
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
      final shell = find
          .byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))
          .evaluate()
          .isNotEmpty;
      if (shell && DateTime.now().difference(quietSince) > const Duration(seconds: 8)) break;
    }

    // ---- run facts: the AX size is recorded as a number (22.2 h)
    final ctx = t.element(find.byType(Scaffold).first);
    final mq = MediaQuery.of(ctx);
    final scale = mq.textScaler.scale(100) / 100;
    // ignore: avoid_print
    print(
      'RUN_INFO tiles_enabled=${CoverageMap.tilesByDefault} flutter_test_env=${Platform.environment.containsKey('FLUTTER_TEST')} appearance=$_appearance content_size=$_contentSize size=${mq.size.width.round()}x${mq.size.height.round()} '
      'dpr=${mq.devicePixelRatio} text_scale=${scale.toStringAsFixed(2)} brightness=${mq.platformBrightness.name} landscape=$_landscape',
    );
    if (_contentSize.startsWith('accessibility') && scale < 1.5) {
      // ignore: avoid_print
      print('STEPFAIL content_size: $_contentSize requested but the effective text scale is $scale');
    }

    // ---- seed state: region, antenna, location
    final st = _state(t);
    await step('seed', () async {
      final simKey = toHex(sha256(utf8.encode('meshsonar-sim-companion')));
      await st.saveAntennaProfile(
        AntennaProfile(mount: AntennaMount.roofMagMount, gainDbi: 3, heightM: 1.8, updatedAt: DateTime.utc(2026, 11, 1)),
        radioKey: simKey,
      );
      await st.refreshLocationAccess();
      if (st.locationAccess != LocationAccess.granted) st.debugSetLocationAccess(LocationAccess.granted);
      // The app's first fetches can hang for minutes if the simulator's network is not up yet on a cold launch. Probe the real
      // network, then make the app refetch (the same call a return to the foreground makes) until the region index is in.
      final net = await t.runAsync(() async {
        for (var i = 0; i < 30; i++) {
          try {
            final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
            final r = await (await c.getUrl(Uri.parse('https://meshsonar.com/'))).close().timeout(const Duration(seconds: 8));
            await r.drain<void>();
            c.close();
            return 'ok ${r.statusCode} after ${i + 1} tries';
          } catch (e) {
            await Future<void>.delayed(const Duration(seconds: 3));
          }
        }
        return 'FAILED';
      });
      // ignore: avoid_print
      print('NET_PROBE $net');
      for (var round = 0; round < 4 && !st.regionIndexLoaded; round++) {
        if (round > 0) st.debugOnForeground();
        final end = DateTime.now().add(const Duration(seconds: 30));
        while (!st.regionIndexLoaded && DateTime.now().isBefore(end)) {
          await t.pump(const Duration(milliseconds: 200));
        }
      }
      if (!st.regionIndexLoaded) throw StateError('region index never loaded (network)');
    });
    await step('columbus', () async {
      await pickColumbus(t, st);
    });
    await step('drive-tab', () async {
      await toMapTab(t);
      // Tile loads that started while the first camera jumps were under way can end up cancelled and cached as empty: ask
      // for every tile again (the same reset a regained network sends), then wait for them (plan 22.2 g).
      TileFetchGate.debugForceOffline.value = true;
      await pumpFor(t, const Duration(seconds: 1));
      TileFetchGate.debugForceOffline.value = false;
      await pumpFor(t, const Duration(seconds: 2));
    });
    await pumpFor(t, const Duration(seconds: 6));
    // ignore: avoid_print
    print('LOCATION_ACCESS ${st.locationAccess.name} VIEWING_REGION ${st.viewingRegion?.code}');
    await step('precondition', () async {
      if (find.byKey(const Key('location-note')).evaluate().isNotEmpty ||
          find.byKey(const Key('telemetry-keep')).evaluate().isNotEmpty ||
          find.byKey(const Key('antenna-sheet')).evaluate().isNotEmpty ||
          find.byType(BottomSheet).evaluate().isNotEmpty) {
        throw StateError(
          'a prompt or banner covers the Drive screen: location-note=${find.byKey(const Key('location-note')).evaluate().length} '
          'telemetry=${find.byKey(const Key('telemetry-keep')).evaluate().length} antenna=${find.byKey(const Key('antenna-sheet')).evaluate().length} '
          'sheets=${find.byType(BottomSheet).evaluate().length}',
        );
      }
      if (st.viewingRegion?.code != 'CMH') throw StateError('viewing region is ${st.viewingRegion?.code}, not CMH');
    });

    // ---- idle
    await frame(t, '01-idle');
    await step('region', () async {
      if (await tapKey(t, ['region-chip-outside'], quiet: true)) {
        await frame(t, '02-region-switcher');
        await dismiss(t);
      } else {
        // Current app: the chip is a plain label when a region is known; the switcher is the Region screen's chip.
        // ignore: avoid_print
        print('NOTE 02-region-switcher via Analyze > Region > region-switch-chip (region-chip is not tappable in this build)');
        await goTab(t, 'Analyze', 'analyze-segments');
        final seg = find.descendant(of: find.byKey(const Key('analyze-segments')), matching: find.text('Region'));
        if (seg.evaluate().isNotEmpty) await t.tap(seg.first, warnIfMissed: false);
        await pumpFor(t, const Duration(seconds: 2));
        if (await tapKey(t, ['region-chip', 'region-switch-chip'], wait: const Duration(seconds: 2))) {
          await frame(t, '02-region-switcher');
          await dismiss(t);
        }
        await toMapTab(t);
      }
    });
    await step('credits', () async {
      await frame(t, '03-attribution');
      // WP2: the credit line opens the credits sheet (which also holds the map source pill); older builds fold a legend instead.
      if (await tapKey(t, ['map-attribution-info', 'map-credits-toggle'], wait: const Duration(seconds: 2))) {
        await frame(t, '04-credits');
        await dismiss(t);
      }
    });
    await step('layers+guide', () async {
      if (await tapKey(t, ['drive-map-layers'])) {
        await frame(t, '05-layers');
        if (await tapKey(t, ['layers-legend'], wait: const Duration(seconds: 2))) {
          await frame(t, '21-guide');
          await dismiss(t);
        }
        await dismiss(t);
      }
    });
    // ---- connected idle
    await step('connect', () async {
      if (!await st.connectSimulator()) throw StateError('could not connect the simulator radio');
      final end = DateTime.now().add(const Duration(seconds: 30));
      while ((!st.connected || st.busy) && DateTime.now().isBefore(end)) {
        await t.pump(const Duration(milliseconds: 250));
      }
      await toMapTab(t);
      await pumpFor(t, const Duration(seconds: 3));
      if (find.byKey(const Key('antenna-sheet')).evaluate().isNotEmpty) throw StateError('antenna sheet opened despite the seeded profile');
      await frame(t, '06-connected-idle');
    });

    await step('antenna', () async {
      if (await tapKey(t, ['antenna-chip'], wait: const Duration(seconds: 2))) {
        if (!await waitFor(t, find.byKey(const Key('antenna-sheet')), timeout: const Duration(seconds: 8)))
          throw StateError('antenna sheet did not open');
        await frame(t, '26-antenna-sheet');
        await dismiss(t);
      }
    });

    // ---- driving
    await step('drive', () async {
      if (!st.connected) await st.connectSimulator();
      await toMapTab(t);
      final readyEnd = DateTime.now().add(const Duration(seconds: 90));
      while ((st.busy || !st.connected) && DateTime.now().isBefore(readyEnd)) {
        await t.pump(const Duration(milliseconds: 250));
      }
      dumpDiag(st, 'before-start', n: 4);
      for (var attempt = 1; attempt <= 3 && !st.driving; attempt++) {
        await tapKey(t, ['start-stop']);
        final end = DateTime.now().add(const Duration(seconds: 15));
        while (!st.driving && DateTime.now().isBefore(end)) {
          await t.pump(const Duration(milliseconds: 200));
        }
        if (!st.driving) dumpDiag(st, 'start-attempt-$attempt', n: 6);
      }
      if (!st.driving) throw StateError('drive did not start');
      await pumpFor(t, const Duration(seconds: 35));
      await frame(t, '07-driving-a');
      await pumpFor(t, const Duration(seconds: 25));
      await frame(t, '08-driving-b');
      // Medium detent: the panel does not exist yet; the current equivalent is the drive page scrolled to its end.
      if (find.byKey(const Key('drive-panel-grabber')).evaluate().isNotEmpty) {
        await t.drag(find.byKey(const Key('drive-panel-grabber')), const Offset(0, -300));
        await pumpFor(t, const Duration(seconds: 1));
      } else {
        // ignore: avoid_print
        print('NOTE 09-driving-medium: no panel in this build; drive page scrolled to its end');
        final sc = t
            .stateList<ScrollableState>(find.byType(Scrollable))
            .where((s) => s.axisDirection == AxisDirection.down && s.position.maxScrollExtent > 0);
        if (sc.isNotEmpty) sc.first.position.jumpTo(sc.first.position.maxScrollExtent);
        await pumpFor(t, const Duration(seconds: 1));
      }
      await frame(t, '09-driving-medium');
      for (final sc in t.stateList<ScrollableState>(find.byType(Scrollable)).where((s) => s.axisDirection == AxisDirection.down)) {
        sc.position.jumpTo(sc.position.minScrollExtent);
      }
      await pumpFor(t, const Duration(seconds: 1));
    });

    // ---- inspectors (while driving: markers and cells are only drawn once there is a drive and data)
    await step('zoom', () async {
      await zoomOut(t, pinches: 2);
      dumpDiag(st, 'after-zoom', n: 3);
    });
    await step('cell', () async {
      final c = _mapRect(t).center;
      final pts = <Offset>[
        for (var ring = 0; ring <= 9; ring++)
          for (var k = 0; k < (ring == 0 ? 1 : 10); k++) c + Offset.fromDirection(k * 3.14159 / 5, ring * 30.0),
      ];
      if (!await tapUntilPanel(t, pts, 'cell-sheet')) throw StateError('no hex under ${pts.length} taps');
      await frame(t, '13-cell-inspector');
      await t.tap(find.byKey(const Key('info-panel-header')), warnIfMissed: false);
      await pumpFor(t, const Duration(seconds: 1));
      await frame(t, '13b-cell-details');
      await tapKey(t, ['link-clear'], quiet: true);
    });
    // Repeaters are painted by the cluster layers (no widgets to find), so project the region's repeater positions through the map
    // camera: the first one inside [bounds] and clear of the map's overlays is returned as a screen point.
    Future<Offset?> findRepeater(Rect bounds) async {
      final sync = st.repeaterSync;
      final slug = st.viewingRegion?.slug;
      final layer = find.byType(TileLayer);
      if (sync == null || layer.evaluate().isEmpty) return null;
      final rows = sync.regionSet(slug).rows;
      final cam = MapCamera.of(layer.evaluate().first);
      final origin = t.getTopLeft(find.byType(FlutterMap).first);
      final mr = _mapRect(t);
      final avoid = _overlayRects(t, mr);
      // ignore: avoid_print
      print('REPEATERS ${rows.length} in the region set, camera zoom ${cam.zoom.toStringAsFixed(1)}');
      Offset? best;
      var bestD = double.infinity;
      for (final r in rows) {
        final p = origin + cam.latLngToScreenOffset(LatLng(r.lat, r.lon));
        if (!bounds.contains(p) || avoid.any((a) => a.contains(p))) continue;
        final d = (p - mr.center).distanceSquared;
        if (d < bestD) {
          best = p;
          bestD = d;
        }
      }
      return best;
    }

    await step('repeater', () async {
      var opened = false;
      for (var attempt = 0; attempt < 4 && !opened; attempt++) {
        final c = await findRepeater(_mapRect(t).deflate(70));
        if (c != null) opened = await tapUntilPanel(t, [c], 'repeater-sheet');
        // Painted repeaters merge into count bubbles when zoomed out (a tap zooms in instead): zoom in a notch and look again.
        if (!opened) await zoomOut(t, pinches: 1, zoomIn: true);
      }
      if (!opened) throw StateError('no repeater could be opened (none projected into view, or only clusters)');
      await frame(t, '12-repeater-inspector');
      await t.tap(find.byKey(const Key('info-panel-header')), warnIfMissed: false);
      await pumpFor(t, const Duration(seconds: 1));
      await frame(t, '12b-repeater-details');
      await tapKey(t, ['link-clear'], quiet: true);
    });
    await step('edge', () async {
      final mr = _mapRect(t);
      final c = await findRepeater(mr.deflate(70));
      if (c == null) throw StateError('no repeater to pan');
      final target = Offset(mr.right - 110, mr.center.dy);
      await t.dragFrom(mr.center, target - c);
      await pumpFor(t, const Duration(seconds: 2));
      final c2 = await findRepeater(Rect.fromLTRB(mr.left, mr.top + 40, mr.right, mr.bottom - 40));
      if (c2 == null) throw StateError('repeater left the map after the pan');
      if (!await tapUntilPanel(t, [c2], 'repeater-sheet')) throw StateError('edge repeater tap opened no repeater panel');
      await frame(t, '22-inspector-edge');
      await tapKey(t, ['link-clear'], quiet: true);
    });

    await step('drive-sheets', () async {
      if (await tapKey(t, ['heard-toggle'])) await frame(t, '10-heard-list');
      await tapKey(t, ['heard-toggle'], quiet: true);
      if (await tapKey(t, ['ping-settings-chip'])) {
        await frame(t, '11-ping-settings');
        await dismiss(t);
      }
    });
    await step('toast', () async {
      final c = t.element(find.byKey(const Key('drive-map')));
      showAppToast(
        c,
        'Location is on, the radio is connected and pings are saved to this phone before anything else happens. '
        'Nothing here leaves your phone until you upload the drive.',
        duration: const Duration(seconds: 30),
      );
      await pumpFor(t, const Duration(seconds: 1));
      await frame(t, '18-toast');
      dismissAppToast();
      await pumpFor(t, const Duration(milliseconds: 600));
    });
    await step('mini-bar', () async {
      await openShellTab(t, 'Chat');
      await pumpFor(t, const Duration(seconds: 2));
      if (!await waitFor(t, find.byKey(const Key('mini-drive-bar')), timeout: const Duration(seconds: 10)))
        throw StateError('no mini drive bar on the Chat tab while driving');
      await frame(t, '25-mini-bar');
      await toMapTab(t);
    });
    await step('gps-weak', () async {
      st.gpsHealth.value = const GpsHealth(
        GpsHealthKind.weak,
        'GPS weak (47 m)',
        advice: 'Move the phone where it sees more sky.',
        accuracyM: 47,
      );
      await pumpFor(t, const Duration(milliseconds: 800));
      if (find.byKey(const Key('gps-health-line')).evaluate().isEmpty) throw StateError('GPS weak line not shown');
      await frame(t, '19-gps-weak');
    });
    await step('offline', () async {
      TileFetchGate.debugForceOffline.value = true;
      await pumpFor(t, const Duration(seconds: 3));
      // The source pill lives in the credits sheet.
      if (!await tapKey(t, ['map-attribution-info', 'map-credits-toggle'], wait: const Duration(seconds: 2)))
        throw StateError('no credits entry');
      if (find.byKey(const Key('map-offline')).evaluate().isEmpty) throw StateError('offline pill (map-offline) not shown');
      await frame(t, '17-offline-pill');
      MapTileStats.instance.resetForTest();
      await pumpFor(t, const Duration(seconds: 2));
      await frame(t, '17b-no-map-here');
      await dismiss(t);
      TileFetchGate.debugForceOffline.value = false;
      await pumpFor(t, const Duration(seconds: 3));
    });
    await step('immersive', () async {
      if (await tapKey(t, ['map-fullscreen'], wait: const Duration(seconds: 4))) {
        await frame(t, '14-immersive');
        if (await tapKey(t, ['drive-map-layers', 'map-layers'])) {
          await frame(t, '15-immersive-layers');
          await dismiss(t);
        }
        await tapKey(t, ['fullscreen-close']);
      }
    });
    await step('stop', () async {
      await tapKey(t, ['start-stop']);
      if (find.byKey(const Key('stop-drive-dialog')).evaluate().isEmpty) throw StateError('stop sheet did not open');
      await frame(t, '23-stop-sheet');
      await t.tap(find.byKey(const Key('stop-drive-confirm')));
      await pumpFor(t, const Duration(seconds: 3));
      await frame(t, '16-finished');
      if (await tapKey(t, ['view-report'], wait: const Duration(seconds: 4))) await frame(t, '24-report');
    });

    // Last, and never restored: re-granting restarts the idle location stream, which ends the run.
    await step('gps-denied', () async {
      // The report page from the step above is still open: close it ("Done") and come back to the Drive tab.
      final done = find.text('Done');
      if (done.evaluate().isNotEmpty) await t.tap(done.first, warnIfMissed: false);
      await pumpFor(t, const Duration(seconds: 2));
      await toMapTab(t);
      if (st.driving) await st.stopDrive();
      await pumpFor(t, const Duration(seconds: 2));
      st.debugSetLocationAccess(LocationAccess.deniedForever);
      await pumpFor(t, const Duration(seconds: 2));
      if (find.byKey(const Key('location-note')).evaluate().isEmpty) throw StateError('denied state shows no location-note');
      await frame(t, '20-gps-denied-idle');
    });

    for (final f in _allFrames) {
      // ignore: avoid_print
      if (!_shot.contains(f)) print('MISSING $f');
    }
    // ignore: avoid_print
    print('FRAMES ${_shot.length}/${_allFrames.length}');
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
