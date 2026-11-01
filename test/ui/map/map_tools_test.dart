// Map tab quick wins on screen: the base-map cycler (and what the map draws for each style, offline packs respected), the
// filter drawer, the coverage % pill, the leaderboard / my stats sheet, and the ping sound + haptic settings.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/map_filter.dart' show CoverageSummary;
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/region_stats_api.dart';
import 'package:meshsonar/ui/device_feedback.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/map_tools.dart';
import 'package:meshsonar/ui/map/offline_basemap.dart';
import 'package:meshsonar/ui/ping_cue.dart';
import 'package:meshsonar/ui/region/stats_panel.dart' show regionStatsApiFactory;
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart';
import '../offline_basemap_test.dart' show basemapWith, cmhBox;
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
    OfflineBasemap.debugInstance = null;
    OfflineBasemapLayer.debugBuilder = null;
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

    testWidgets('each style asks its own tile server and credits it', (tester) async {
      for (final s in BaseMapStyle.values) {
        await mapWith(tester, s);
        await tester.pump();
        final layer = tester.widget<TileLayer>(find.byType(TileLayer));
        expect(layer.urlTemplate, s.tileUrl, reason: s.id);
        expect(layer.maxNativeZoom, s.maxNativeZoom);
        expect(find.descendant(of: find.byKey(const Key('map-attribution')), matching: find.text(s.attribution)), findsOneWidget);
      }
    });

    testWidgets('Street and Topo are drawn as served; Chart follows the theme and Dark is forced dark', (tester) async {
      for (final s in [BaseMapStyle.street, BaseMapStyle.topo]) {
        await mapWith(tester, s);
        await tester.pump();
        expect(tester.widget<TileLayer>(find.byType(TileLayer)).tileBuilder, isNull, reason: s.id);
      }
      for (final s in [BaseMapStyle.chart, BaseMapStyle.dark]) {
        await mapWith(tester, s);
        await tester.pump();
        expect(tester.widget<TileLayer>(find.byType(TileLayer)).tileBuilder, isNotNull, reason: s.id);
      }
      final light = MeshSonarColors.forPalette(ColourPalette.standard, Brightness.light).tileMatrix;
      expect(tileMatrixFor(BaseMapStyle.chart, light), light);
      expect(tileMatrixFor(BaseMapStyle.dark, light), kDarkTileMatrix, reason: 'forced dark even in a light theme');
      expect(tileMatrixFor(BaseMapStyle.street, light), isNull);
      expect(tileMatrixFor(BaseMapStyle.topo, light), isNull);
    });

    testWidgets('an installed offline pack is drawn for Chart, Street and Dark (light/dark look) but not for Topo', (tester) async {
      late OfflineBasemap b;
      await tester.runAsync(() async => b = await basemapWith(Directory('${tmp.path}/p'), {'CMH': cmhBox}));
      OfflineBasemap.debugInstance = b;
      final looks = <bool?>[];
      OfflineBasemapLayer.debugBuilder = (_) => const SizedBox.shrink();
      for (final s in [BaseMapStyle.chart, BaseMapStyle.street, BaseMapStyle.dark]) {
        await mapWith(tester, s);
        await tester.pump();
        final layer = tester.widget<OfflineBasemapLayer>(find.byType(OfflineBasemapLayer));
        looks.add(layer.dark);
        expect(find.byType(TileLayer), findsNothing, reason: '${s.id} uses the pack');
      }
      expect(looks, [null, false, true], reason: 'chart follows the theme, street is the light look, dark is forced dark');
      await mapWith(tester, BaseMapStyle.topo);
      await tester.pump();
      expect(find.byType(OfflineBasemapLayer), findsNothing, reason: 'there is no offline topo');
      expect(tester.widget<TileLayer>(find.byType(TileLayer)).urlTemplate, BaseMapStyle.topo.tileUrl);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => b.debugClose());
    });

    testWidgets('the cycler button steps chart > street > dark > topo > chart, saves the choice and says what it is', (tester) async {
      final h = await driving(tester);
      expect(h.state.settings.baseMapStyle, 'chart');
      final seen = <String>[];
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const Key('drive-map-style')));
        await settleLive(tester);
        seen.add(h.state.settings.baseMapStyle);
        expect(find.textContaining('${BaseMapStyle.parse(seen.last).label}:'), findsOneWidget);
      }
      expect(seen, ['street', 'dark', 'topo', 'chart']);
      expect(h.settings.saved.baseMapStyle, 'chart');
      await stop(tester, h);
    });
  });

  group('filter drawer', () {
    testWidgets('narrows the pings drawn, says how many, badges the button, and Reset brings them back', (tester) async {
      final h = await driving(tester, pings: [
        heardPing('hit', const [Echo(repeater: 'a1', snrDb: 6)]),
        silentPing('miss'),
      ]);
      expect(find.byKey(const ValueKey('map-ping-hit')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-ping-miss')), findsOneWidget);

      await tester.tap(find.byKey(const Key('drive-map-filter')));
      await settleLive(tester);
      expect(find.byKey(const Key('map-filter-sheet')), findsOneWidget);
      expect(find.text('Showing 2 of 2 of your pings, 0 of 0 network cells.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('filter-heard-heard')));
      await settleLive(tester);
      expect(find.text('Showing 1 of 2 of your pings, 0 of 0 network cells.'), findsOneWidget);

      await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
      await settleLive(tester);
      expect(find.byKey(const ValueKey('map-ping-hit')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-ping-miss')), findsNothing);
      expect(find.text('1'), findsWidgets, reason: 'the badge counts one active filter');

      await tester.tap(find.byKey(const Key('drive-map-filter')));
      await settleLive(tester);
      await tester.tap(find.byKey(const Key('filter-reset')));
      await settleLive(tester);
      expect(find.text('Showing 2 of 2 of your pings, 0 of 0 network cells.'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await settleLive(tester);
      expect(find.byKey(const ValueKey('map-ping-miss')), findsOneWidget);
      await stop(tester, h);
    });

    testWidgets('repeater filter lists the repeaters heard and keeps only their pings; own pings hides network cells', (tester) async {
      final h = await driving(tester, pings: [
        heardPing('by-a1', const [Echo(repeater: 'a1', snrDb: 6)]),
        heardPing('by-b2', const [Echo(repeater: 'b2', snrDb: 2)]),
      ]);
      await tester.tap(find.byKey(const Key('drive-map-filter')));
      await settleLive(tester);
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

  group('coverage %', () {
    testWidgets('the pill reports the share of your tx pings in view that were heard', (tester) async {
      final h = await driving(tester, pings: [
        heardPing('p1', const [Echo(repeater: 'a1', snrDb: 6)]),
        heardPing('p2', const [Echo(repeater: 'a1', snrDb: 2)]),
        silentPing('p3'),
        silentPing('p4'),
      ]);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('drive-coverage-pct')), findsOneWidget);
      expect(find.text('50% of your 4 pings heard'), findsOneWidget);
      await stop(tester, h);
    });

    test('coverageLine words: cells and pings, singular, and nothing at all when nothing is in view', () {
      expect(coverageLine(const CoverageSummary()), isNull);
      expect(coverageLine(const CoverageSummary(cells: 140, cellsHeard: 87)), 'In view: 62% of 140 cells heard');
      expect(coverageLine(const CoverageSummary(cells: 1, cellsHeard: 1, pings: 1, pingsHeard: 0)), 'In view: 100% of 1 cell heard\n0% of your 1 ping heard');
    });
  });

  group('leaderboard and my stats', () {
    testWidgets('shows the region leaderboard from the public endpoint and says there are no drives on the phone yet', (tester) async {
      regionStatsApiFactory = (b) => RegionStatsApi(
        b,
        client: MockClient((r) async {
          if (r.url.path == '/api/cmh/leaderboard') {
            return http.Response(
              '{"period":"30d","rows":[{"rank":1,"callsign":"KE4BFI","km":123.4,"drives":9,"cells":50,"repeatersHeard":12}]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 404);
        }),
      );
      final h = await driving(tester);
      await tester.tap(find.byKey(const Key('drive-map-leaders')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('map-leaders-sheet')), findsOneWidget);
      expect(find.text('KE4BFI'), findsOneWidget);
      expect(find.textContaining('9 drives'), findsOneWidget);
      expect(find.byKey(const Key('leaders-me')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await settleLive(tester);
      await stop(tester, h);
    });

    testWidgets('a leaderboard that cannot be reached says so and the personal part still shows', (tester) async {
      regionStatsApiFactory = (b) => RegionStatsApi(b, client: MockClient((r) async => http.Response('nope', 500)));
      final h = await driving(tester);
      await tester.tap(find.byKey(const Key('drive-map-leaders')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      final board = tester.widget<Text>(find.byKey(const Key('leaders-board')));
      expect(board.data, isNotEmpty);
      expect(find.byKey(const Key('leaders-me')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await settleLive(tester);
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
