// Basemap source choice and fallback (core/basemap.dart): same rules as the website's map-style.ts: ours inside the extract
// while the health probe answers; OpenFreeMap outside it, when the probe fails, or after 4 tile errors in a row; one probe
// per minute; OpenFreeMap's tile URL from its TileJSON (host pinned); nothing at all only when both are down outside.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/basemap.dart';
import 'package:meshsonar/core/map_styles.dart';

void main() {
  test('our tile URL, probe URL and credit match the website (meshcore-insights map-style.ts BASEMAP)', () {
    expect(OurBasemap.tileUrl, 'https://api.meshsonar.com/basemap/t/na-20261108/{z}/{x}/{y}.bin');
    expect(OurBasemap.tileJsonUrl, 'https://api.meshsonar.com/basemap/t/na-20261108.json');
    expect(OurBasemap.bounds, [-170, 7, -50, 84]);
    expect(OurBasemap.maxZoom, 14);
    expect(BasemapSource.ours.attribution, 'Protomaps © OpenStreetMap contributors');
    expect(BasemapSource.openFreeMap.attribution, 'OpenFreeMap © OpenStreetMap contributors');
    expect(BasemapSource.ours.styleSource, 'protomaps');
    expect(BasemapSource.openFreeMap.styleSource, 'openmaptiles');
  });

  test('view inside the extract: same rule as viewInsideBasemap', () {
    bool inside(double w, double s, double e, double n, double z) => viewInsideOurBasemap(west: w, south: s, east: e, north: n, zoom: z);
    expect(inside(-83.2, 39.8, -82.8, 40.1, 12), isTrue); // Columbus
    expect(inside(-0.3, 51.4, 0.1, 51.6, 12), isFalse); // London
    expect(inside(-0.3, 51.4, 0.1, 51.6, 3), isTrue); // world view
    expect(inside(-60, 40, -40, 50, 5), isTrue); // centre inside, low zoom
    expect(inside(-60, 40, -40, 50, 8), isFalse); // east edge past the extract at z8
  });

  test('chart / light / dark are our vector map, topo the only raster; nothing points at a raster OSM server', () {
    for (final s in [BaseMapStyle.chart, BaseMapStyle.street, BaseMapStyle.dark]) {
      expect(s.isVector, isTrue, reason: s.id);
      expect(s.tileUrl, isNull);
      expect(s.attribution, OurBasemap.attribution);
      expect(s.usesOfflinePack, isTrue);
    }
    expect(BaseMapStyle.chart.darkLook, isNull);
    expect(BaseMapStyle.street.darkLook, isFalse);
    expect(BaseMapStyle.dark.darkLook, isTrue);
    expect(BaseMapStyle.topo.isVector, isFalse);
    expect(BaseMapStyle.parse('street'), BaseMapStyle.street, reason: 'a saved choice keeps working');
  });

  group('health', () {
    late DateTime now;
    late int probes;
    late int status;
    late String ofmBody;
    BasemapHealth make() {
      now = DateTime.utc(2026, 11, 9, 12);
      probes = 0;
      status = 200;
      ofmBody = '{"tiles":["https://tiles.openfreemap.org/planet/20261108_000000_pt/{z}/{x}/{y}.pbf"]}';
      return BasemapHealth(
        clock: () => now,
        client: () => MockClient((req) async {
          if (req.url.toString() == OurBasemap.tileJsonUrl) {
            probes++;
            return http.Response('{}', status);
          }
          if (req.url.toString() == OpenFreeMapBasemap.tileJsonUrl) return http.Response(ofmBody, 200);
          return http.Response('', 404);
        }),
      );
    }

    test('ours until the probe fails; one probe per minute', () async {
      final h = make();
      expect(h.sourceFor(inside: true), BasemapSource.ours, reason: 'not probed yet = ours (the website starts on ours too)');
      expect(await h.check(), isTrue);
      expect(await h.check(), isTrue);
      expect(probes, 1);
      status = 503;
      now = now.add(const Duration(seconds: 59));
      await h.check();
      expect(probes, 1, reason: 'within the minute: the last answer');
      now = now.add(const Duration(seconds: 2));
      final changes = <void>[];
      final sub = h.changes.listen(changes.add);
      expect(await h.check(), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(probes, 2);
      expect(h.sourceFor(inside: true), BasemapSource.openFreeMap);
      expect(changes, hasLength(1));
      status = 200;
      now = now.add(const Duration(minutes: 1));
      expect(await h.check(), isTrue);
      expect(h.sourceFor(inside: true), BasemapSource.ours, reason: 'back when it answers again');
      await sub.cancel();
    });

    test('outside the extract: OpenFreeMap', () {
      final h = make();
      expect(h.sourceFor(inside: false), BasemapSource.openFreeMap);
    });

    test('4 tile errors in a row switch to OpenFreeMap; a success resets the count', () {
      final h = make();
      for (var i = 0; i < 3; i++) {
        h.tileFailed(BasemapSource.ours);
      }
      h.tileOk(BasemapSource.ours);
      for (var i = 0; i < 3; i++) {
        h.tileFailed(BasemapSource.ours);
      }
      expect(h.sourceFor(inside: true), BasemapSource.ours);
      h.tileFailed(BasemapSource.ours);
      expect(h.sourceFor(inside: true), BasemapSource.openFreeMap);
    });

    test('both down: ours stays tried inside the extract, nothing outside it; OpenFreeMap is tried again after a minute', () {
      final h = make();
      for (var i = 0; i < 4; i++) {
        h.tileFailed(BasemapSource.ours);
        h.tileFailed(BasemapSource.openFreeMap);
      }
      expect(h.sourceFor(inside: true), BasemapSource.ours);
      expect(h.sourceFor(inside: false), BasemapSource.none);
      now = now.add(const Duration(minutes: 1));
      expect(h.sourceFor(inside: false), BasemapSource.openFreeMap);
    });

    test('OpenFreeMap tile URL from its TileJSON, only on its own host', () async {
      final h = make();
      expect(h.openFreeMapTileUrl, OpenFreeMapBasemap.defaultTileUrl);
      await h.resolveOpenFreeMap();
      expect(h.openFreeMapTileUrl, 'https://tiles.openfreemap.org/planet/20261108_000000_pt/{z}/{x}/{y}.pbf');
      final h2 = make();
      ofmBody = '{"tiles":["https://evil.example/{z}/{x}/{y}.pbf"]}';
      await h2.resolveOpenFreeMap();
      expect(h2.openFreeMapTileUrl, OpenFreeMapBasemap.defaultTileUrl);
    });

    test('a probe that throws or times out means down, never an exception', () async {
      final h = BasemapHealth(client: () => MockClient((_) async => throw http.ClientException('no network')));
      expect(await h.check(), isFalse);
      expect(h.oursUp, isFalse);
    });
  });
}
