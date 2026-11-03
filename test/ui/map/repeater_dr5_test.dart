// Design review DR5 renderer (Drive plan WP5): repeater badges and names at z11 / z13 / z15, light and dark, Chart and
// Street, plus the colour-blind simulations. Runs only with WP5_SHOTS=<dir> (writes PNGs); skipped otherwise. The base
// map is painted flat (land colour, a few roads and a stand-in for the raster's own labels), so what is judged is our
// layer: badge, halo or pill, legibility, collisions. Arial stands in for SF Pro, which the test engine cannot load.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/ui/design/map_tokens.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';
import 'package:meshsonar/ui/map/layers/repeater_name_labels.dart';
import 'package:meshsonar/ui/map/layers/repeater_painter_layer.dart';
import 'package:meshsonar/ui/map/layers/repeater_sprites.dart';
import 'package:meshsonar/core/repeater_points.dart';
import 'package:meshsonar/ui/theme.dart';

import 'repeater_visuals_test.dart' show simulate;

const _names = [
  'Westerville Water Tower', 'Otterbein Hill', 'Polaris Rooftop', 'Easton Mast', 'OSU West Campus', 'Hoover Dam Park',
  'Alum Creek N1', 'Genoa Ridge', 'Sunbury Silo', 'Delaware Hub', 'Dublin Bridge St', 'Grandview 5th Ave',
  'New Albany Tank', 'Gahanna Fire 2', 'Clintonville Pole', 'Worthington Hill', 'Hilliard Ridge', 'Upper Arlington',
  'Reynoldsburg 70', 'Pickerington Mast', 'Lewis Center', 'Powell Tower', 'Galena Lake', 'Johnstown Silo',
  'Marysville Hub', 'Plain City', 'Grove City 71', 'Canal Winchester', 'Groveport Depot', 'Lancaster Ridge',
  'Heath Tower', 'Newark Courthouse', 'Granville Hill', 'Pataskala 16', 'Blacklick Pole', 'Etna Water',
  'Kilbourne Mast', 'Orange Rd 23', 'Africa Rd Silo', 'Harlem Rd N',
];

Future<Uint8List> _font() async => File('/System/Library/Fonts/Supplemental/Arial.ttf').readAsBytesSync();

void main() {
  final out = Platform.environment['WP5_SHOTS'];
  testWidgets('DR5 contact sheets', skip: out == null, (t) async {
    final loader = FontLoader('Arial')..addFont(Future.value(ByteData.sublistView(await _font())));
    await loader.load();
    LabelPainter.fontFamily = 'Arial';
    addTearDown(() => LabelPainter.fontFamily = null);
    Directory(out!).createSync(recursive: true);

    final rnd = math.Random(5);
    const center = LatLng(40.1, -82.93);
    final rows = <MapRepeaterRow>[
      for (var i = 0; i < _names.length; i++)
        MapRepeaterRow(
          key: (i + 16).toRadixString(16).padLeft(2, '0') * 32,
          name: _names[i],
          lat: center.latitude + (rnd.nextDouble() - 0.5) * (i < 12 ? 0.012 : 0.12),
          lon: center.longitude + (rnd.nextDouble() - 0.5) * (i < 12 ? 0.016 : 0.16),
          isRoom: i % 13 == 5,
          lastSeen: DateTime.now().subtract(Duration(hours: [2, 30, 200, 900][i % 4])),
        ),
    ];
    final feed = StaticRepeaterMapFeed(global: MapRepeaterSet(rows: rows, state: MapFeedState.ready));
    final source = RepeaterMapSource(feed);
    await t.runAsync(() => source.settled);
    // Three heard on the drive, one of them selected: they are claimed out of the list.
    final heardKeys = {for (final r in rows.take(3)) r.key};
    source.claimedKeys = heardKeys;
    await t.runAsync(() => source.settled);
    final badges = [
      for (final (i, r) in rows.take(3).indexed)
        RepeaterBadge(
          key: r.key,
          name: r.name!,
          lat: r.lat,
          lon: r.lon,
          isRoom: r.isRoom,
          freshness: RepeaterFreshness.fresh,
          heard: true,
          heardLast: i < 2,
          snr: i == 0 ? '+10.5' : (i == 1 ? '-3.0' : null),
        ),
    ];
    final selectedKey = rows.first.key;

    Widget cell(double zoom, Brightness b, bool street) {
      final land = b == Brightness.dark ? MapTokens.chartDark : MapTokens.landLight;
      return SizedBox(
        width: 300,
        height: 420,
        child: ClipRect(
          child: MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 2),
            child: Theme(
              data: meshSonarTheme(b).copyWith(textTheme: meshSonarTheme(b).textTheme.apply(fontFamily: 'Arial')),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Stack(
                  children: [
                    Positioned.fill(child: CustomPaint(painter: _FakeBase(land, street, b))),
                    FlutterMap(
                      options: MapOptions(initialCenter: center, initialZoom: zoom, backgroundColor: Colors.transparent),
                      children: [
                        RepeaterPainterLayer(sources: [(source, kNetworkLayerId)], badges: badges, selectedKey: selectedKey),
                        RepeaterNameLabels(
                          sources: [(source, kNetworkLayerId)],
                          badges: badges,
                          selectedKey: selectedKey,
                          selectedDetail: 'Heard now · +10.5 dB · 0.3 mi',
                          pill: street,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final key = GlobalKey();
    final combos = [
      for (final (b, street) in [(Brightness.light, false), (Brightness.light, true), (Brightness.dark, false), (Brightness.dark, true)]) (b, street),
    ];
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: Colors.white,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (b, street) in combos)
                  Column(mainAxisSize: MainAxisSize.min, children: [for (final z in [11.0, 13.0, 15.0]) Padding(padding: const EdgeInsets.all(2), child: cell(z, b, street))]),
              ],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600)); // the sprite atlas
    });
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 2);
      final raw = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      final w = img.width, h = img.height;
      for (final sim in ['normal', 'grey', 'protan', 'deutan']) {
        final px = simulate(raw, sim);
        final done = Completer<ui.Image>();
        ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, done.complete);
        final png = (await (await done.future).toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        File('$out/dr5-$sim.png').writeAsBytesSync(png);
      }
    });
    source.dispose();
  });
}

/// A flat stand-in for the raster base map: land colour, a road grid, and grey text where its own labels would be.
class _FakeBase extends CustomPainter {
  final Color land;
  final bool street;
  final Brightness b;
  _FakeBase(this.land, this.street, this.b);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = land);
    final road = Paint()
      ..color = b == Brightness.dark ? const Color(0xFF3A4048) : (street ? const Color(0xFFFFFFFF) : const Color(0xFFE2DED6))
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke;
    final edge = Paint()
      ..color = street ? const Color(0xFFB8B2A5) : Colors.transparent
      ..strokeWidth = 7
      ..style = PaintingStyle.stroke;
    for (final p in [
      [Offset(0, size.height * 0.3), Offset(size.width, size.height * 0.38)],
      [Offset(0, size.height * 0.7), Offset(size.width, size.height * 0.62)],
      [Offset(size.width * 0.3, 0), Offset(size.width * 0.4, size.height)],
      [Offset(size.width * 0.75, 0), Offset(size.width * 0.65, size.height)],
    ]) {
      canvas.drawLine(p[0], p[1], edge);
      canvas.drawLine(p[0], p[1], road);
    }
    if (street) {
      final tp = TextPainter(
        text: const TextSpan(text: 'Main Street      Cleveland Ave      Schrock Rd', style: TextStyle(fontSize: 10, color: Color(0xFF666666), fontFamily: 'Arial')),
        textDirection: TextDirection.ltr,
      )..layout();
      for (final y in [0.2, 0.35, 0.5, 0.66, 0.8]) {
        tp.paint(canvas, Offset(-20, size.height * y));
      }
    }
  }

  @override
  bool shouldRepaint(_FakeBase o) => false;
}
