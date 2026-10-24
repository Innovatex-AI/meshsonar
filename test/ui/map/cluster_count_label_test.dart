// Every cluster bubble shows its count legibly: painted as text (13/15 px, heavy weight) on an opaque fill whose ink is
// chosen for contrast (>= 4.5:1 for every band colour, light and dark theme), and exposed to screen readers as
// "1,234 repeaters". Andy, Oct 24 2026: the global layer is on by default and must read like the other MeshCore maps.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/repeater_points.dart';
import 'package:meshsonar/ui/map/layers/clustered_points_layer.dart';
import 'package:meshsonar/ui/map/layers/repeater_cluster_layer.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';
import 'package:meshsonar/ui/theme.dart';

final now = DateTime.utc(2026, 10, 24, 12);

void main() {
  test('label helpers: grouped screen-reader text, font size, bubble grows to fit the text', () {
    expect(clusterSemanticsLabel(7), '7 repeaters');
    expect(clusterSemanticsLabel(55601), '55,601 repeaters');
    expect(clusterFontSize(12), 13);
    expect(clusterFontSize(150), 15);
    expect(clusterBubbleRadius(2, 60), 35, reason: 'a wide label never overflows its bubble');
  });

  for (final dark in [false, true]) {
    testWidgets('every band colour gets >= 4.5:1 count ink (${dark ? 'dark' : 'light'} theme)', (t) async {
      late List<Color> colours;
      await t.pumpWidget(MaterialApp(
        theme: meshSonarTheme(dark ? Brightness.dark : Brightness.light),
        home: Builder(builder: (context) {
          colours = [...networkBandColors(context), ...rosterBandColors()];
          return const SizedBox();
        }),
      ));
      for (final c in colours) {
        final fill = c.withValues(alpha: 1);
        expect(contrastRatio(clusterLabelInk(fill), fill), greaterThanOrEqualTo(4.5), reason: '$c');
      }
    });

    testWidgets('count bubbles paint their numbers and expose them to semantics (${dark ? 'dark' : 'light'})', (t) async {
      final sem = t.ensureSemantics();
      final rnd = math.Random(7);
      final rows = [
        for (var i = 0; i < 600; i++)
          MapRepeaterRow(key: (i + 1).toRadixString(16).padLeft(64, '0'), lat: 38 + rnd.nextDouble() * 4, lon: -86 + rnd.nextDouble() * 6, lastSeen: now),
      ];
      final src = RepeaterMapSource(StaticRepeaterMapFeed(global: MapRepeaterSet(rows: rows, state: MapFeedState.ready)), clock: () => now);
      await t.pump();
      await src.settled;
      await t.pumpWidget(MaterialApp(
        theme: meshSonarTheme(dark ? Brightness.dark : Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: FlutterMap(
              options: const MapOptions(initialCenter: LatLng(40, -83), initialZoom: 4.5),
              children: [RepeaterClusterLayer(source: src, layerId: kNetworkLayerId)],
            ),
          ),
        ),
      ));
      await t.pump();
      final paint = find.byKey(const ValueKey('layer-network-paint'));
      final painter = t.widget<CustomPaint>(paint).painter! as ClusteredPointsPainter;
      final clusters = [for (var k = 0; k < painter.slice.length; k++) if (painter.slice.count[k] > 1) painter.slice.count[k]];
      expect(clusters, isNotEmpty, reason: 'zoomed out: grouped');
      // One paragraph (the count) per cluster bubble.
      var p = paints;
      for (var i = 0; i < clusters.length; i++) {
        p = p..paragraph();
      }
      expect(t.renderObject(paint), p);
      final labels = <String>[];
      t.getSemantics(paint).visitChildren((n) {
        labels.add(n.label);
        return true;
      });
      expect(labels.toSet(), {for (final n in clusters) clusterSemanticsLabel(n)}, reason: 'one readable node per visible cluster');
      final total = clusters.fold<int>(0, (a, b) => a + b) + painter.slice.length - clusters.length;
      expect(total, lessThanOrEqualTo(600));
      sem.dispose();
      src.dispose();
    });
  }
}
