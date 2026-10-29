// AppState with a 559-region index: shared borders ("also in"), seams between thinned outlines, exact outlines near an
// edge, remembered lookups, the resume cadence, 429 on the index, and entering a region that has no radio preset.
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../support/regions_559.dart';
import '../ui/fakes.dart';

GeoFix at(double lat, double lon) => GeoFix(lat: lat, lon: lon, at: DateTime.utc(2026, 10, 16, 18));

Harness harnessAt(double lat, double lon, List<RegionIndexEntry> index) {
  final h = Harness();
  h.location.currentFix = () => at(lat, lon);
  h.client.regionsIndexResult = index;
  return h;
}

void main() {
  final west = square('WST', 0, 0, 2.01, 2), east = square('EST', 1.99, 0, 4, 2);

  testWidgets('a position held by two regions: the smaller / first one is current, the other is reported as also here', (tester) async {
    final h = harnessAt(1.0, 2.0, [west, east]);
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.state.currentRegion, isNotNull);
    expect(h.state.regionAlsoIn.length, 1);
    expect({h.state.currentRegion!.code, h.state.regionAlsoIn.single.code}, {'WST', 'EST'});
  });

  testWidgets('a position held by one region reports no "also in"', (tester) async {
    final h = harnessAt(1.0, 0.5, [west, east]);
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.state.currentRegion!.code, 'WST');
    expect(h.state.regionAlsoIn, isEmpty);
  });

  testWidgets('a position on the seam between two thinned outlines is still a region (the nearest outline), not "outside coverage"', (tester) async {
    final a = square('AAA', 0, 0, 1, 1), b = square('BBB', 1.002, 0, 2, 1);
    final h = harnessAt(0.5, 1.0008, [a, b]); // 90 m from AAA's edge, 130 m from BBB's
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.state.currentRegion?.code, 'AAA');
  });

  testWidgets('559 regions: the viewed region and the switcher list are remembered, not recomputed on every notification', (tester) async {
    final h = harnessAt(5.0, -100.0, syntheticIndex559());
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    final a = h.state.switcherRegions;
    for (var i = 0; i < 20; i++) {
      h.state.viewingRegion;
      h.state.notifyListeners();
    }
    expect(identical(h.state.switcherRegions, a), isTrue);
    expect(a.length, 559);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 500; i++) {
      h.state.viewingRegion;
    }
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(500), reason: '500 reads of viewingRegion: ${sw.elapsedMilliseconds} ms');
  });

  testWidgets('near an edge (within 300 m) the exact outline is fetched once for the regions around the phone and used', (tester) async {
    // The thin outline is a square; the exact one has its north edge 110 m further south, where the phone is (55 m from it).
    final thin = square('AAA', 0, 0, 1, 1);
    final exact = RegionIndexEntry(code: 'AAA', slug: 'aaa', name: 'AAA, US', url: thin.url, bbox: thin.bbox, boundary: {
      'type': 'Polygon',
      'coordinates': [
        [[0, 0], [1, 0], [1, 0.999], [0, 0.999], [0, 0]]
      ],
    });
    final h = harnessAt(0.9995, 0.5, [thin]);
    h.client.regionsIndexDetailResult = [exact];
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.client.regionsIndexDetailAsks, [
      ['aaa']
    ], reason: 'asked once, for the region around the phone');
    expect(h.state.regionIndex.single.boundary!['coordinates'].toString(), contains('0.999'));
    expect(h.state.currentRegion?.code, 'AAA', reason: 'within the seam distance of the exact edge: still AAA, no flap');
  });

  testWidgets('far from every edge nothing extra is fetched', (tester) async {
    final thin = square('AAA', 0, 0, 1, 1);
    final h = harnessAt(0.5, 0.5, [thin]);
    h.client.regionsIndexDetailResult = [thin];
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.client.regionsIndexDetailAsks, isEmpty);
  });

  testWidgets('foreground: the index is asked for again only when due (not within 6 h, not while a 429 backs off)', (tester) async {
    final h = harnessAt(40.126, -82.93, [syntheticRegion(1)]);
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.client.regionsIndexCalls, 1);
    void resume() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    resume();
    await tester.pumpAndSettle();
    expect(h.client.regionsIndexCalls, 1, reason: 'fetched a minute ago: not due');
    h.clockNow = h.clockNow.add(const Duration(hours: 7));
    resume();
    await tester.pumpAndSettle();
    expect(h.client.regionsIndexCalls, 2, reason: 'older than 6 h: due');
    // Now the server rate-limits us: one failure, then no more asks during the back-off.
    h.client.regionsIndexError = const CmatException('server answered 429', status: 429, retryAfterSec: 300);
    h.clockNow = h.clockNow.add(const Duration(hours: 7));
    resume();
    await tester.pumpAndSettle();
    expect(h.client.regionsIndexCalls, 3);
    expect(h.state.regionIndexStale, isTrue);
    expect(h.state.regionIndex, isNotEmpty, reason: 'the stored index stays in use');
    h.clockNow = h.clockNow.add(const Duration(seconds: 100));
    resume();
    await tester.pumpAndSettle();
    expect(h.client.regionsIndexCalls, 3, reason: 'Retry-After 300 s: still backing off');
    h.clockNow = h.clockNow.add(const Duration(seconds: 250));
    resume();
    await tester.pumpAndSettle();
    expect(h.client.regionsIndexCalls, 4);
  });

  testWidgets('first launch offline with no cache and no region: the app still starts, region features say "not loaded"', (tester) async {
    final h = Harness();
    h.client.regionsIndexError = const CmatException('network error', status: null);
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.state.regionIndex, isEmpty);
    expect(h.state.viewingRegion, isNull);
    expect(h.state.switcherRegions, isEmpty);
    expect(h.state.regionAlsoIn, isEmpty);
    expect(h.state.regionIndexLoaded, isFalse);
  });
}
