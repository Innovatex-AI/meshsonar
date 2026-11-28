// Build 77 AX fix: the Drive map's inspector (repeater, cell, ping) never overflows at the largest text sizes.
// AX3 on an iPhone 18 Pro (402 x 874 pt, text about 2.4x) overflowed the repeater inspector by 224 px: the summary, the
// "Show all links on the map" button and the "Heard by MeshSonar drivers" figures were fixed above a scrolling body.
// Now everything under the header scrolls as one. Each panel is pumped the way coverage_map.dart builds it, in the room
// the Drive screen leaves above its dock and tab bar.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/coverage_v2.dart';
import 'package:meshsonar/core/map_links.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';
import 'package:meshsonar/core/repeater_reach.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/design/map_panel.dart';
import 'package:meshsonar/ui/map/cell_sheet.dart';
import 'package:meshsonar/ui/map/map_info_panel.dart';
import 'package:meshsonar/ui/map/sheets/coverage_cell_sheet.dart';
import 'package:meshsonar/ui/map/sheets/repeater_sheet.dart';
import 'package:meshsonar/ui/ping_detail_sheet.dart';
import 'package:meshsonar/ui/theme.dart';

const _iphone18Pro = Size(402, 874);

/// The Drive dock (stats, Stop) plus the tab bar at AX3, measured from the AX run's 12b-repeater-details frame.
const double _dockAx = 258;

/// The same at the default text size.
const double _dockNormal = 190;

Map<String, dynamic> _json(String n) => jsonDecode(File('test/fixtures/coverage_v2/$n').readAsStringSync()) as Map<String, dynamic>;

String _k(String c) => c * 64;

/// The test font draws every glyph as a 1 em square, about twice as wide as the phone's, so widths are measured with the
/// iPhone system font (as mini_drive_bar_fit_test.dart does). Skipped on a machine without it.
final _sf = File('/System/Library/Fonts/SFNS.ttf');
final _loaded = <String>{};

Future<void> _loadPhoneFont(WidgetTester tester) async {
  final tt = meshSonarTheme(Brightness.dark).textTheme;
  final families = {
    for (final s in [tt.displayLarge, tt.headlineSmall, tt.titleLarge, tt.titleMedium, tt.titleSmall, tt.bodyLarge, tt.bodyMedium, tt.bodySmall, tt.labelLarge, tt.labelMedium, tt.labelSmall])
      s?.fontFamily ?? 'Roboto',
  }.difference(_loaded);
  for (final f in families) {
    final loader = FontLoader(f)..addFont(Future.value(ByteData.sublistView(_sf.readAsBytesSync())));
    await tester.runAsync(loader.load);
    _loaded.add(f);
  }
}

Future<void> _pump(WidgetTester tester, Widget panel, {required double scale, required double dock}) async {
  await _loadPhoneFont(tester);
  tester.view.physicalSize = _iphone18Pro * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  MapPanelStore.clear();
  await tester.pumpWidget(MaterialApp(
    theme: meshSonarTheme(Brightness.dark),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: 62, bottom: 34),
          viewPadding: const EdgeInsets.only(top: 62, bottom: 34),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: Column(children: [
            // The map, with the inspector sitting directly above the dock (bottomSafe false, as on Drive).
            Expanded(child: Stack(fit: StackFit.expand, children: [const ColoredBox(color: Colors.black), Positioned.fill(child: panel)])),
            SizedBox(height: dock, key: const Key('dock')),
          ]),
        ),
      ),
    ),
  ));
  await tester.pump();
  expect(tester.takeException(), isNull, reason: 'collapsed header');
  // It opens collapsed: open it, as the person does, to see the figures.
  await tester.tap(find.byKey(const Key('info-panel-header')));
  await tester.pumpAndSettle();
}

/// The one scroll view under the header.
ScrollPosition _scroll(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byKey(const Key('info-panel-body')), matching: find.byType(Scrollable)).first)
    .position;

void main() {
  final now = DateTime.now();
  final point = RepeaterPoint(
    layerId: 'repeaters',
    source: RepeaterPointSource.roster,
    key: _k('a'),
    name: 'OH.FRA.Main/Cleveland Atom 1 Repeater',
    isRoom: false,
    lat: 40.01,
    lon: -83,
    band: 0,
    lastSeen: now.subtract(const Duration(hours: 3)),
    roster: RegionRepeater(
      key: _k('a'),
      hashPrefix: 'aa',
      name: 'OH.FRA.Main/Cleveland Atom 1 Repeater',
      status: RepeaterActivity.active,
      snrMeanDb: 4.5,
      signalGrade: 'Good',
      adverts24h: 12,
      neighbours: 7,
    ),
  );
  final totals = ReachTotals(
    heardPings: 955,
    drives: 129,
    drivers: 14,
    bestSnr: 11.25,
    medianSnr: -2.5,
    farthestKm: 31.4,
    lastHeardAt: now.subtract(const Duration(minutes: 20)),
  );

  Widget repeaterPanel() => MapInfoPanel(
        title: point.name,
        summary: 'Heard in 148 cells  ·  tap to expand',
        busy: false,
        onFit: () {},
        onClose: () {},
        bottomSafe: false,
        body: RepeaterInspectorBody(
          showReach: true,
          totals: totals,
          cells: 148,
          distance: (km) => Units.metric.distance(km * 1000),
          details: RepeaterSheet(point: point, dismissOnOpen: false, scrollable: false, ctx: RepeaterSheetContext(clock: () => now, units: Units.metric)),
        ),
      );

  final ends = [
    for (var i = 0; i < 8; i++) LinkEnd(lat: 40, lon: -83, id: _k('$i'), name: 'Repeater number $i on the hill', pings: 3 + i, snr: 2.0 - i),
  ];
  Widget cellPanel() => MapInfoPanel(
        title: 'Coverage cell',
        summary: '8 repeaters heard here (+2 not on the map)',
        busy: false,
        onFit: () {},
        onClose: () {},
        bottomSafe: false,
        body: Column(mainAxisSize: MainAxisSize.min, children: [
          const CellSheet(
            cell: NetworkCell(
              id: '40,-83',
              boundary: [],
              level: CoverageLevel.good,
              cell: CoverageCell(lat: 40, lon: -83, pings: 40, heard: 31, bestSnr: 9.5, medianSnr: 1.5, repeaters: 8, lastAt: '2026-11-27T12:00:00Z'),
            ),
          ),
          CellRepeaterList(ends: ends),
        ]),
      );

  Widget v2CellPanel() {
    final info = CoverageCellInfo.fromJson(_json('cell-measured.json'));
    final meta = CoverageMeta.fromJson(_json('meta.json'));
    return MapInfoPanel(
      title: 'Measured cell',
      summary: coverageCellSummary(info, meta),
      busy: false,
      onFit: () {},
      onClose: () {},
      bottomSafe: false,
      body: Column(mainAxisSize: MainAxisSize.min, children: [
        CoverageCellSheet(info: info, meta: meta, h3: info.h3, now: now),
        CellRepeaterList(ends: ends),
      ]),
    );
  }

  final ping = DrivePing(
    id: 'p1',
    ts: now.subtract(const Duration(minutes: 2)),
    lat: 40.0,
    lon: -83.0,
    gpsAccuracyM: 6,
    speedMps: 14,
    noiseFloorDbm: -112,
    echoes: [for (var i = 0; i < 6; i++) Echo(repeater: '${i}a', snrDb: 4.0 - i, rssiDbm: -90.0 - i, hops: 1)],
  );
  Widget pingPanel(ScrollController c) => MapInfoPanel(
        title: 'Ping at 6:58 PM',
        summary: 'Heard 6 repeaters  ·  best +4.0 dB',
        busy: false,
        onFit: () {},
        onClose: () {},
        bottomSafe: false,
        scrollController: c,
        body: PingDetailSheet(ping: ping, lookup: RepeaterLookup.empty, embedded: true),
      );

  group('AX3 (402 x 874, text 2.4x): no overflow, the content scrolls', skip: !_sf.existsSync(), () {
    testWidgets('repeater inspector: summary, Show all links, Heard by MeshSonar drivers, details', (tester) async {
      await _pump(tester, repeaterPanel(), scale: 2.4, dock: _dockAx);
      expect(tester.takeException(), isNull);
      expect(find.text('Show all links on the map'), findsOneWidget);
      expect(find.text('Heard by MeshSonar drivers'), findsOneWidget);
      // More than fits: before this fix that excess was the overflow; now it is scroll room.
      final pos = _scroll(tester);
      expect(pos.maxScrollExtent, greaterThan(0));
      // Every row is reachable by scrolling, and scrolling to the end raises nothing either.
      final body = tester.getRect(find.byKey(const Key('info-panel-body')));
      for (var i = 0; i < 20 && pos.pixels < pos.maxScrollExtent; i++) {
        await tester.dragFrom(Offset(body.center.dx, body.top + 20), Offset(0, -(body.height - 40)));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      expect(pos.pixels, pos.maxScrollExtent);
      expect(find.byKey(const Key('repeater-sheet-source')).hitTestable(), findsOneWidget);
      // The panel stays inside the room above the dock.
      expect(tester.getRect(find.byKey(const Key('map-panel-drive.inspect'))).bottom, lessThanOrEqualTo(874 - _dockAx + 0.01));
    });

    testWidgets('cell inspector (coverage v1 cell + repeaters heard here)', (tester) async {
      await _pump(tester, cellPanel(), scale: 2.4, dock: _dockAx);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('cell-sheet')), findsOneWidget);
      expect(_scroll(tester).maxScrollExtent, greaterThan(0));
    });

    testWidgets('cell inspector (coverage v2 measured cell)', (tester) async {
      await _pump(tester, v2CellPanel(), scale: 2.4, dock: _dockAx);
      expect(tester.takeException(), isNull);
      expect(_scroll(tester).maxScrollExtent, greaterThan(0));
    });

    testWidgets('ping inspector: one scroll view, driven by the map\'s controller', (tester) async {
      final c = ScrollController();
      addTearDown(c.dispose);
      await _pump(tester, pingPanel(c), scale: 2.4, dock: _dockAx);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('ping-detail')), findsOneWidget);
      expect(c.hasClients, isTrue);
      expect(c.position.maxScrollExtent, greaterThan(0));
      c.jumpTo(c.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('ping-copy')).hitTestable(), findsOneWidget);
    });
  });

  testWidgets('normal text size: the repeater inspector looks as before (summary, button, figures in order, no overflow)', skip: !_sf.existsSync(), (tester) async {
    await _pump(tester, repeaterPanel(), scale: 1, dock: _dockNormal);
    expect(tester.takeException(), isNull);
    final summary = tester.getRect(find.text('Heard in 148 cells  ·  tap to expand').last);
    final button = tester.getRect(find.byKey(const Key('link-fit-button')));
    final heard = tester.getRect(find.text('Heard by MeshSonar drivers'));
    final name = tester.getRect(find.byKey(const Key('repeater-sheet-name')));
    expect(summary.bottom, lessThanOrEqualTo(button.top));
    expect(button.bottom, lessThanOrEqualTo(heard.top));
    expect(heard.bottom, lessThan(name.top));
    expect(button.height, 48);
  });
}
