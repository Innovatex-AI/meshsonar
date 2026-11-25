// Drive tab map tools on screen: what the map draws for each base-map style, the filter drawer (from
// the Map layers sheet), the map key and credits, and the ping sound + haptic settings. (The footer's base-map cycler and the
// leaderboard trophy went with the old Drive layout in build 70.)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/basemap.dart' show BasemapLook;
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/core/network_kind.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/region_stats_api.dart';
import 'package:meshsonar/ui/device_feedback.dart';
import 'package:meshsonar/ui/map/basemap_layer.dart' show BasemapLayer;
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/map_key.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/map_layers.dart' show PingColorMode;
import 'package:meshsonar/ui/ping_cue.dart';
import 'package:meshsonar/ui/region/stats_panel.dart' show regionStatsApiFactory;
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart';
import '../settings_controls_test.dart' show openSettings, show;

class _Feedback implements DeviceFeedback {
  final List<bool> pings = [];
  @override
  Future<void> keepAwake(bool on) async {}
  @override
  Future<void> pingResult({required bool heard}) async => pings.add(heard);
}

class _Sound implements PingSoundPlayer {
  final List<bool> played = [];
  @override
  Future<void> play({required bool heard}) async => played.add(heard);
}

/// The filter drawer opens from the Map layers sheet ("Filter pings and cells").
Future<void> openFilter(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('drive-map-layers')));
  await settleLive(tester);
  final list = find.descendant(of: find.byKey(const Key('layers-sheet')), matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(find.byKey(const Key('layers-filter')), 200, scrollable: list);
  await settleLive(tester);
  await tester.tap(find.byKey(const Key('layers-filter')));
  await settleLive(tester);
}

/// Closes the filter drawer and the layers sheet (Done) so nothing is left over the map.
Future<void> closeSheets(WidgetTester tester) async {
  for (var i = 0; i < 3 && find.byKey(const Key('map-filter-sheet')).evaluate().isNotEmpty; i++) {
    Navigator.of(tester.element(find.byKey(const Key('map-filter-sheet')))).pop();
    await settleLive(tester);
  }
  if (find.byKey(const Key('layers-done')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const Key('layers-done')));
    await settleLive(tester);
  }
}

Future<Harness> driving(WidgetTester tester, {List<DrivePing> pings = const []}) async {
  useTallScreen(tester);
  final h = Harness();
  await h.pumpApp(tester);
  await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
  await h.state.startDrive();
  await settleLive(tester);
  for (final p in pings) {
    h.engines.single.emit(p);
    await settleLive(tester);
  }
  return h;
}

Future<void> stop(WidgetTester tester, Harness h) async {
  await h.state.stopDrive();
  await tester.pump(const Duration(seconds: 20));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('maptools');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });
  tearDown(() {
    DeviceFeedbackScope.fallback = const NoDeviceFeedback();
    regionStatsApiFactory = (b) => RegionStatsApi(b);
    tmp.deleteSync(recursive: true);
  });

  group('base map', () {
    Future<void> mapWith(WidgetTester tester, BaseMapStyle style, {Brightness b = Brightness.light}) => tester.pumpWidget(
      MaterialApp(
        theme: meshSonarTheme(b),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: CoverageMap(pings: const [], showTiles: true, baseStyle: style, fallbackCenter: const LatLng(39.96, -83.0)),
          ),
        ),
      ),
    );

    testWidgets('Chart / Light / Dark / Topo draw our vector basemap, Satellite the definition\'s imagery; each credits its source', (tester) async {
      for (final s in BaseMapStyle.values) {
        await mapWith(tester, s);
        await tester.pump();
        if (s.isVector) {
          final layer = tester.widget<BasemapLayer>(find.byType(BasemapLayer));
          expect(layer.dark, s.darkLook, reason: s.id);
          expect(layer.look, s.look, reason: s.id);
          expect(find.byType(TileLayer), findsNothing, reason: s.id);
          expect(find.descendant(of: find.byKey(const Key('map-attribution')), matching: find.text('Protomaps © OpenStreetMap contributors')), findsOneWidget);
        } else {
          final layers = tester.widgetList<TileLayer>(find.byType(TileLayer)).toList();
          expect(layers.map((l) => l.urlTemplate), [contains('/api/map/satellite/esri/'), contains('basemap.nationalmap.gov')], reason: 'Esri (our proxy) then NAIP, from the definition');
          expect(layers.map((l) => l.maxNativeZoom), [18, 16]);
          expect(layers.map((l) => l.maxZoom), [22, 17], reason: 'NAIP is drawn up to z17 only');
          expect(layers.map((l) => l.tileBuilder), everyElement(isNull), reason: 'imagery is drawn as served');
          expect(find.byType(BasemapLayer), findsOneWidget, reason: 'our names over the imagery');
          expect(tester.widget<BasemapLayer>(find.byType(BasemapLayer)).look, BasemapLook.labels);
          expect(find.descendant(of: find.byKey(const Key('map-attribution')), matching: find.textContaining('Powered by Esri')), findsOneWidget);
        }
      }
      final light = MeshSonarColors.forPalette(ColourPalette.standard, Brightness.light).tileMatrix;
      for (final s in BaseMapStyle.values) {
        expect(tileMatrixFor(s, light), isNull, reason: '${s.id}: no colour grading (the vector styles are the website\'s light / dark)');
      }
    });

    testWidgets('no connection: every base map says so (an honest message, never a silent blank map); back online it clears', (tester) async {
      final net = FakeNetworkMonitor(NetworkKind.offline);
      CoverageMap.debugNetwork = net;
      addTearDown(() => CoverageMap.debugNetwork = null);
      for (final s in BaseMapStyle.values) {
        await mapWith(tester, s);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const Key('map-needs-network')), findsOneWidget, reason: s.id);
        expect(find.textContaining('No connection.'), findsOneWidget, reason: s.id);
        expect(find.textContaining('ffline'), findsNothing, reason: '${s.id}: nothing on the map mentions offline maps');
      }
      net.emit(NetworkKind.wifi);
      await tester.pump();
      expect(find.byKey(const Key('map-needs-network')), findsNothing, reason: 'online again');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('filter drawer', () {
    testWidgets('narrows the pings drawn, says how many, the layers sheet counts it, and Reset brings them back', (tester) async {
      final h = await driving(tester, pings: [
        heardPing('hit', const [Echo(repeater: 'a1', snrDb: 6)]),
        silentPing('miss'),
      ]);
      expect(find.byKey(const ValueKey('map-ping-hit')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-ping-miss')), findsOneWidget);

      await openFilter(tester);
      expect(find.byKey(const Key('map-filter-sheet')), findsOneWidget);
      expect(find.text('Showing 2 of 2 of your pings, 0 of 0 network cells.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('filter-heard-heard')));
      await settleLive(tester);
      expect(find.text('Showing 1 of 2 of your pings, 0 of 0 network cells.'), findsOneWidget);

      await closeSheets(tester);
      expect(find.byKey(const ValueKey('map-ping-hit')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-ping-miss')), findsNothing);
      await tester.tap(find.byKey(const Key('drive-map-layers')));
      await settleLive(tester);
      await tester.scrollUntilVisible(find.byKey(const Key('layers-filter')), 200,
          scrollable: find.descendant(of: find.byKey(const Key('layers-sheet')), matching: find.byType(Scrollable)).first);
      expect(find.descendant(of: find.byKey(const Key('layers-filter')), matching: find.text('1 active')), findsOneWidget,
          reason: 'the layers sheet counts one active filter');
      await closeSheets(tester);

      await openFilter(tester);
      await tester.tap(find.byKey(const Key('filter-reset')));
      await settleLive(tester);
      expect(find.text('Showing 2 of 2 of your pings, 0 of 0 network cells.'), findsOneWidget);
      await closeSheets(tester);
      expect(find.byKey(const ValueKey('map-ping-miss')), findsOneWidget);
      await stop(tester, h);
    });

    testWidgets('repeater filter lists the repeaters heard and keeps only their pings; own pings hides network cells', (tester) async {
      final h = await driving(tester, pings: [
        heardPing('by-a1', const [Echo(repeater: 'a1', snrDb: 6)]),
        heardPing('by-b2', const [Echo(repeater: 'b2', snrDb: 2)]),
      ]);
      await openFilter(tester);
      await tester.tap(find.byKey(const Key('filter-repeater')));
      await settleLive(tester);
      expect(find.text('Any repeater').hitTestable(), findsWidgets);
      // The two heard repeaters are offered (named by their label, here the id).
      final items = tester.widgetList<DropdownMenuItem<String?>>(find.byWidgetPredicate((w) => w is DropdownMenuItem<String?>)).map((e) => e.value).toSet();
      expect(items, containsAll(<String?>[null, 'a1', 'b2']));
      await tester.tap(find.byWidgetPredicate((w) => w is DropdownMenuItem<String?> && w.value == 'a1').last);
      await settleLive(tester);
      expect(find.text('Showing 1 of 2 of your pings, 0 of 0 network cells.'), findsOneWidget);
      expect(find.textContaining('Network cells list no repeaters'), findsOneWidget);
      await stop(tester, h);
    });
  });

  group('map key follows the view', () {
    testWidgets('the key names what is drawn: pings by SNR or heard/not, nothing for a layer that is off, repeater dots as "last advert"', (tester) async {
      final h = await driving(tester, pings: [heardPing('p1', const [Echo(repeater: 'a1', snrDb: 6)]), silentPing('p2')]);
      final model = DriveMapModel(h.state);
      addTearDown(model.dispose);
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: Scaffold(body: MapKey(model: model))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('map-key-pings')), findsOneWidget);
      expect(find.text('+10 dB'), findsOneWidget, reason: 'default ping colours are by SNR');
      expect(find.textContaining('last advert'), findsNothing, reason: 'no repeater layer data: no repeater line');
      model.pingColors = PingColorMode.result;
      await tester.pump();
      expect(find.text('+10 dB'), findsNothing);
      expect(find.text('heard'), findsOneWidget);
      model.setLayer('pings', false);
      await tester.pump();
      expect(find.byKey(const Key('map-key-pings')), findsNothing, reason: 'pings layer off: not in the key');
      await stop(tester, h);
    });
  });

  group('map credits', () {
    testWidgets('the credit line is always visible, bottom-right, and the (i) opens the Credits sheet with the source state', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.light),
        home: Scaffold(body: SizedBox(width: 400, height: 400, child: CoverageMap(pings: const [], showTiles: true, fallbackCenter: const LatLng(39.96, -83.0)))),
      ));
      await tester.pump();
      final line = find.byKey(const Key('map-attribution'));
      expect(line, findsOneWidget, reason: 'the tile credit is always visible');
      final r = tester.getRect(line);
      expect(r.right, greaterThan(400 - 20), reason: 'right edge');
      expect(r.bottom, greaterThan(400 - 20), reason: 'bottom edge');
      expect(find.byKey(const Key('map-source')), findsNothing, reason: 'the source chip left the map');
      await tester.tap(find.byKey(const Key('map-attribution-info')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('credits-sheet')), findsOneWidget);
      expect(find.byKey(const Key('credits-source')), findsOneWidget);
      expect(find.byKey(const Key('map-source')), findsOneWidget, reason: 'where the base map comes from, in the sheet');
    });

    testWidgets('no coverage percentage box and no neighbouring-region pointers on the map', (tester) async {
      final h = await driving(tester, pings: [heardPing('p1', const [Echo(repeater: 'a1', snrDb: 6)])]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('drive-coverage-pct')), findsNothing);
      expect(find.byKey(const Key('region-neighbours-layer')), findsNothing);
      await stop(tester, h);
    });
  });

  group('ping feedback', () {
    test('defaults: haptics on, sound off; saved only when changed', () {
      const s = Settings();
      expect((s.pingHaptics, s.pingSound), (true, false));
      expect(s.toJson().containsKey('ping_haptics'), isFalse);
      expect(s.toJson().containsKey('ping_sound'), isFalse);
      final j = s.copyWith(pingHaptics: false, pingSound: true).toJson();
      final back = Settings.fromJson(j);
      expect((back.pingHaptics, back.pingSound), (false, true));
    });

    test('PingCue honours both switches and tells heard from heard-nothing', () async {
      final fb = _Feedback(), snd = _Sound();
      PingCue.player = snd;
      addTearDown(() => PingCue.player = const NoPingSound());
      await PingCue.ping(const Settings(), fb, heard: true);
      expect(fb.pings, [true]);
      expect(snd.played, <bool>[]); // sound is off by default
      await PingCue.ping(const Settings(pingSound: true), fb, heard: false);
      expect(fb.pings, [true, false]);
      expect(snd.played, [false]);
      await PingCue.ping(const Settings(pingHaptics: false, pingSound: true), fb, heard: true);
      expect(fb.pings, [true, false]);
      expect(snd.played, [false, true]);
      await PingCue.ping(const Settings(pingHaptics: false), fb, heard: true);
      expect(fb.pings.length, 2);
      expect(snd.played.length, 2);
    });

    testWidgets('a finished ping on the drive screen plays the sound only once the setting is on', (tester) async {
      final fb = _Feedback(), snd = _Sound();
      DeviceFeedbackScope.fallback = fb;
      PingCue.player = snd;
      addTearDown(() => PingCue.player = const NoPingSound());
      final h = await driving(tester);
      h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1', snrDb: 3)]));
      await settleLive(tester);
      expect(fb.pings, [true]);
      expect(snd.played, <bool>[]);
      await h.state.updateSettings(h.state.settings.copyWith(pingSound: true));
      h.engines.single.emit(silentPing('p2'));
      await settleLive(tester);
      expect(fb.pings, [true, false]);
      expect(snd.played, [false]);
      await h.state.updateSettings(h.state.settings.copyWith(pingHaptics: false));
      h.engines.single.emit(heardPing('p3', const [Echo(repeater: 'a1', snrDb: 3)]));
      await settleLive(tester);
      expect(fb.pings, [true, false]);
      expect(snd.played, [false, true]);
      await stop(tester, h);
    });

    testWidgets('Settings > Wardriving has the two switches (sound off) and they save', (tester) async {
      final h = await openSettings(tester);
      await show(tester, 'ping-sound');
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('ping-sound'))).value, isFalse);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('ping-haptics'))).value, isTrue);
      await tester.tap(find.byKey(const Key('ping-sound')));
      await tester.pumpAndSettle();
      expect(h.settings.saved.pingSound, isTrue);
      await show(tester, 'ping-haptics');
      await tester.tap(find.byKey(const Key('ping-haptics')));
      await tester.pumpAndSettle();
      expect(h.settings.saved.pingHaptics, isFalse);
    });
  });
}
