// RepeaterPainterLayer (Drive plan 6.1-6.3, WP5): one repeater = one badge; merge priority heard > roster > network;
// level of detail by zoom; hit testing; the screen reader proxies; the sprite atlas cache.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/region_repeaters_api.dart' show RepeaterActivity;
import 'package:meshsonar/core/repeater_points.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';
import 'package:meshsonar/ui/map/layers/repeater_painter_layer.dart';
import 'package:meshsonar/ui/map/layers/repeater_sprites.dart';

String k(String c) => c * 64;

MapRepeaterRow row(String key, double lat, double lon, {String? name, bool room = false, DateTime? seen, int? band}) =>
    MapRepeaterRow(key: key, name: name ?? 'R-${key.substring(0, 2)}', lat: lat, lon: lon, isRoom: room, lastSeen: seen, band: band);

final _now = DateTime.utc(2026, 11, 2, 12);

const _size = Size(400, 600);
const _center = LatLng(40.0, -83.0);

class Probe {
  final hits = <MapHit>[];
  final badgeTaps = <RepeaterBadge>[];
  final mapTaps = <LatLng>[];
  final controller = MapController();
}

Widget harness(
  Probe probe,
  List<(RepeaterMapSource, String)> sources, {
  List<RepeaterBadge> badges = const [],
  String? selected,
  double zoom = 13,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: _size.width,
        height: _size.height,
        child: FlutterMap(
          mapController: probe.controller,
          options: MapOptions(initialCenter: _center, initialZoom: zoom, onTap: (_, p) => probe.mapTaps.add(p)),
          children: [
            RepeaterPainterLayer(sources: sources, badges: badges, selectedKey: selected, onHit: probe.hits.add, onBadgeTap: probe.badgeTaps.add),
          ],
        ),
      ),
    ),
  ),
);

RepeaterPainter painterOf(WidgetTester t) => t.widget<CustomPaint>(find.byKey(RepeaterPainterLayer.paintKey)).painter! as RepeaterPainter;

Future<RepeaterMapSource> source(WidgetTester t, {List<MapRepeaterRow> global = const [], List<MapRepeaterRow> roster = const []}) async {
  final feed = StaticRepeaterMapFeed(
    global: MapRepeaterSet(rows: global, state: MapFeedState.ready),
    region: MapRepeaterSet(rows: roster, state: MapFeedState.ready),
  );
  final s = RepeaterMapSource(feed, clock: () => _now);
  addTearDown(s.dispose);
  await t.runAsync(() => s.settled);
  return s;
}

Future<void> settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  group('freshness states', () {
    test('network age bands: 24 h Fresh, 7 d Recent, 30 d and older merge into Stale', () {
      expect([for (var b = 0; b < 4; b++) freshnessOfAdvertBand(b)], [RepeaterFreshness.fresh, RepeaterFreshness.recent, RepeaterFreshness.stale, RepeaterFreshness.stale]);
    });

    test('roster status: active and new are Fresh, quiet Recent, stale Stale', () {
      expect(freshnessOfActivity(RepeaterActivity.active), RepeaterFreshness.fresh);
      expect(freshnessOfActivity(RepeaterActivity.fresh), RepeaterFreshness.fresh);
      expect(freshnessOfActivity(RepeaterActivity.quiet), RepeaterFreshness.recent);
      expect(freshnessOfActivity(RepeaterActivity.stale), RepeaterFreshness.stale);
      expect(freshnessOfRosterBand(99), RepeaterFreshness.stale);
    });

    test('from an age: the website boundaries 24 h and 7 d, never advertised is Stale', () {
      expect(freshnessOfAge(_now.subtract(const Duration(hours: 24)), _now), RepeaterFreshness.fresh);
      expect(freshnessOfAge(_now.subtract(const Duration(hours: 24, seconds: 1)), _now), RepeaterFreshness.recent);
      expect(freshnessOfAge(_now.subtract(const Duration(days: 7)), _now), RepeaterFreshness.recent);
      expect(freshnessOfAge(_now.subtract(const Duration(days: 7, seconds: 1)), _now), RepeaterFreshness.stale);
      expect(freshnessOfAge(null, _now), RepeaterFreshness.stale);
    });
  });

  group('merge priority heard > roster > network', () {
    test('the global list leaves out the claimed keys and everything the roster knows', () {
      final roster = RepeaterPoints.fromRows([row(k('a'), 40, -83), row(k('b'), 40.1, -83)], now: _now, skipKeys: {k('b')});
      final skip = RepeaterMapSource.mergeSkipKeys(claimed: {k('c')}, roster: roster);
      expect(skip, {k('a'), k('b'), k('c')}, reason: 'a is drawn by the roster, b is claimed, c is claimed');
      expect(RepeaterMapSource.mergeSkipKeys(claimed: {k('c')}), {k('c')});
    });

    testWidgets('a claimed key is in neither list nor index, and the source still knows its colour band', (t) async {
      final s = await source(
        t,
        global: [row(k('a'), 40, -83, seen: _now.subtract(const Duration(hours: 2))), row(k('b'), 40.1, -83, seen: _now.subtract(const Duration(days: 3))), row(k('c'), 40.2, -83)],
        roster: [row(k('a'), 40, -83, band: RepeaterActivity.quiet.index)],
      );
      expect(s.rosterPoints.key, [k('a')]);
      expect(s.globalPoints.key, [k('b'), k('c')], reason: 'roster beats network');
      s.claimedKeys = {k('a'), k('b')};
      await t.runAsync(() => s.settled);
      expect(s.rosterPoints.key, isEmpty);
      expect(s.globalPoints.key, [k('c')]);
      expect(s.rosterIndex!.indexedCount + s.globalIndex!.indexedCount, 1);
      final a = s.claimedInfo(k('a'))!;
      expect((a.layerId, freshnessOfRosterBand(a.band)), (kRosterLayerId, RepeaterFreshness.recent));
      final b = s.claimedInfo(k('b'))!;
      expect((b.layerId, freshnessOfAdvertBand(b.band)), (kNetworkLayerId, RepeaterFreshness.recent));
      expect(b.lastSeen, _now.subtract(const Duration(days: 3)));
      expect(s.claimedInfo(k('z')), isNull);
      // The set is compared by content: the same keys again do not rebuild.
      final rev = s.revision;
      s.claimedKeys = {k('b'), k('a')};
      expect(s.revision, rev);
    });

    testWidgets('one repeater is one badge, whichever lists and the drive know it', (t) async {
      final s = await source(
        t,
        global: [row(k('a'), 40, -83), row(k('b'), 40.001, -83), row(k('c'), 40.002, -83)],
        roster: [row(k('a'), 40, -83), row(k('d'), 40.003, -83)],
      );
      s.claimedKeys = {k('b')};
      await t.runAsync(() => s.settled);
      final probe = Probe();
      await t.pumpWidget(harness(probe, [(s, kRosterLayerId), (s, kNetworkLayerId)], badges: [const RepeaterBadge(key: 'bb', name: 'Drive only', lat: 40.004, lon: -83.0)]));
      await settle(t);
      final keys = [for (final it in painterOf(t).scene.singles) it.key];
      expect(keys.toSet().length, keys.length, reason: 'no repeater twice: $keys');
      expect(keys, containsAll([k('a'), k('c'), k('d'), 'bb']));
    });
  });

  group('level of detail', () {
    test('donut below z11, 20 pt badge to z13, 24 pt from z13; heard 28 with a tick; selected 34', () {
      expect(spriteVariantFor(10.9), SpriteVariant.donut);
      expect(spriteVariantFor(11), SpriteVariant.badge);
      expect(spriteVariantFor(12.9), SpriteVariant.badge);
      expect(spriteVariantFor(13), SpriteVariant.badgeLarge);
      expect(spriteVariantFor(15, heard: true), SpriteVariant.heard);
      expect(spriteVariantFor(15, selected: true), SpriteVariant.selected);
      expect(spriteVariantFor(15, selected: true, heard: true), SpriteVariant.selectedHeard);
      expect([for (final v in SpriteVariant.values) v.diameter], [14, 20, 24, 28, 34, 34]);
      expect(SpriteVariant.heard.hasTick, isTrue);
      expect(SpriteVariant.badgeLarge.hasTick, isFalse);
    });

    testWidgets('the scene follows the zoom and the selection', (t) async {
      final s = await source(t, roster: [row(k('a'), 40, -83), row(k('b'), 40.15, -83.0)]);
      for (final (zoom, v) in [(10.0, SpriteVariant.donut), (12.0, SpriteVariant.badge), (15.0, SpriteVariant.badgeLarge)]) {
        final probe = Probe();
        await t.pumpWidget(harness(probe, [(s, kRosterLayerId)], zoom: zoom));
        await settle(t);
        expect({for (final it in painterOf(t).scene.singles) it.variant}, {v}, reason: 'z$zoom');
        expect(painterOf(t).scene.singles.any((it) => it.key == k('a')), isTrue);
      }
      final probe = Probe();
      await t.pumpWidget(harness(probe, [(s, kRosterLayerId)], zoom: 15, selected: k('a')));
      await settle(t);
      final items = painterOf(t).scene.singles;
      expect(items.last.key, k('a'), reason: 'the selected one is painted last, on top');
      expect(items.last.variant, SpriteVariant.selected);
      expect(items, hasLength(1), reason: 'the other repeater is off screen at z15');
    });

    testWidgets('rooms and states reach the sprite: room server rows are rounded squares', (t) async {
      final s = await source(t, roster: [row(k('a'), 40, -83, room: true, band: RepeaterActivity.stale.index)]);
      final probe = Probe();
      await t.pumpWidget(harness(probe, [(s, kRosterLayerId)]));
      await settle(t);
      final it = painterOf(t).scene.singles.single;
      expect((it.room, it.freshness), (true, RepeaterFreshness.stale));
    });
  });

  group('taps', () {
    testWidgets('a badge reports itself, a list single reports a RepeaterHit, bare map falls through', (t) async {
      final s = await source(t, roster: [row(k('a'), 40.002, -83.0)]);
      final probe = Probe();
      await t.pumpWidget(harness(probe, [(s, kRosterLayerId)], badges: [const RepeaterBadge(key: 'bb', name: 'Drive', lat: 39.998, lon: -83.0)]));
      await settle(t);
      final cam = probe.controller.camera;
      await t.tapAt(cam.latLngToScreenOffset(const LatLng(39.998, -83.0)));
      await t.pump();
      expect(probe.badgeTaps.single.key, 'bb');
      await t.tapAt(cam.latLngToScreenOffset(const LatLng(40.002, -83.0)));
      await t.pump();
      expect((probe.hits.single as RepeaterHit).point.key, k('a'));
      await t.tapAt(cam.latLngToScreenOffset(const LatLng(40.02, -83.02)));
      await t.pump(const Duration(milliseconds: 500));
      expect(probe.mapTaps, hasLength(1));
      expect(probe.badgeTaps, hasLength(1));
    });

    testWidgets('overlapping hit areas: the nearest centre within 14 pt wins, a badge wins otherwise', (t) async {
      // A roster single and a drive badge 20 px apart (z15: about 1 m is 3.7 px at 40 degrees; use 0.00006 deg).
      final s = await source(t, roster: [row(k('a'), 40.0, -83.0)]);
      final probe = Probe();
      await t.pumpWidget(harness(probe, [(s, kRosterLayerId)], badges: [const RepeaterBadge(key: 'bb', name: 'Drive', lat: 40.0, lon: -82.99985)], zoom: 17));
      await settle(t);
      final cam = probe.controller.camera;
      final a = cam.latLngToScreenOffset(const LatLng(40.0, -83.0)), b = cam.latLngToScreenOffset(const LatLng(40.0, -82.99985));
      expect((a - b).distance, inInclusiveRange(8, 40));
      // Right on the roster single: nearest centre (0 pt) wins although the badge also covers it.
      await t.tapAt(a);
      await t.pump();
      expect(probe.hits, hasLength(1));
      expect(probe.badgeTaps, isEmpty);
    });
  });

  group('screen reader', () {
    testWidgets('at most 20 repeaters get a proxy node, each with name, state and a tap', (t) async {
      final h = t.ensureSemantics();
      final rows = [for (var i = 0; i < 50; i++) row(i.toRadixString(16).padLeft(2, '0') * 32, 40.0 + i * 0.0004, -83.0)];
      final s = await source(t, roster: rows);
      final probe = Probe();
      await t.pumpWidget(harness(probe, [(s, kRosterLayerId)], badges: [const RepeaterBadge(key: 'bb', name: 'Drive tower', lat: 40.0, lon: -83.001, heard: true, freshness: RepeaterFreshness.fresh)], zoom: 14));
      await settle(t);
      final nodes = t.getSemantics(find.byKey(RepeaterPainterLayer.paintKey));
      expect(nodes, isNotNull);
      final labels = <String>[];
      void walk(SemanticsNode n) {
        if (n.label.startsWith('Repeater')) labels.add(n.label);
        n.visitChildren((c) {
          walk(c);
          return true;
        });
      }

      walk(nodes);
      expect(labels.length, lessThanOrEqualTo(kRepeaterProxyCount));
      expect(labels, isNotEmpty);
      expect(labels, contains('Repeater Drive tower, advertised in the last 24 hours, heard this drive'), reason: '$labels');
      h.dispose();
    });

    test('semantics wording per state and kind', () {
      RepeaterItem item({bool room = false, RepeaterFreshness f = RepeaterFreshness.stale, bool heard = false}) => RepeaterItem(
        key: 'abcd',
        name: 'Hill',
        room: room,
        freshness: f,
        lat: 0,
        lon: 0,
        at: Offset.zero,
        variant: SpriteVariant.badge,
        heard: heard,
        heardLast: false,
        selected: false,
        lastSeen: null,
        snr: null,
        sourceIndex: 0,
        pointIndex: 0,
        badge: null,
      );
      expect(repeaterSemanticsLabel(item()), 'Repeater Hill, not advertised for over 7 days');
      expect(repeaterSemanticsLabel(item(room: true, f: RepeaterFreshness.recent, heard: true)), 'Room server Hill, advertised in the last 7 days, heard this drive');
    });
  });

  group('sprite atlas', () {
    const theme = RepeaterSpriteTheme(brightness: Brightness.light, accent: Colors.teal, ok: Colors.green);

    test('cache keys: theme, palette and DPR each make a different key; the same inputs the same key', () {
      const a = RepeaterSpriteKey(theme, 3);
      expect(a, const RepeaterSpriteKey(RepeaterSpriteTheme(brightness: Brightness.light, accent: Colors.teal, ok: Colors.green), 3));
      expect(a.hashCode, const RepeaterSpriteKey(RepeaterSpriteTheme(brightness: Brightness.light, accent: Colors.teal, ok: Colors.green), 3).hashCode);
      expect(a, isNot(const RepeaterSpriteKey(theme, 2)));
      expect(a, isNot(const RepeaterSpriteKey(RepeaterSpriteTheme(brightness: Brightness.dark, accent: Colors.teal, ok: Colors.green), 3)));
      expect(a, isNot(const RepeaterSpriteKey(RepeaterSpriteTheme(brightness: Brightness.light, accent: Colors.teal, ok: Colors.green, highContrast: true), 3)));
      expect(a, isNot(const RepeaterSpriteKey(RepeaterSpriteTheme(brightness: Brightness.light, accent: Colors.red, ok: Colors.green), 3)));
    });

    test('every state is its own sprite: 3 freshness x 2 kinds x 6 variants = 36 distinct indices', () {
      final idx = <int>{};
      for (final f in RepeaterFreshness.values) {
        for (final room in [false, true]) {
          for (final v in SpriteVariant.values) {
            final spec = RepeaterSpriteSpec(f, room, v);
            idx.add(spec.index);
            expect(RepeaterSpriteSpec.ofIndex(spec.index), spec);
          }
        }
      }
      expect(idx.length, RepeaterSpriteSpec.count);
      expect(idx.reduce((a, b) => a > b ? a : b), RepeaterSpriteSpec.count - 1);
    });

    testWidgets('the atlas is built once per key, never per frame, and a new DPR builds a new one', (t) async {
      final sprites = RepeaterSprites.instance..clear();
      addTearDown(sprites.clear);
      const a = RepeaterSpriteKey(theme, 2);
      expect(sprites.atlasFor(a), isNull, reason: 'building; callers paint without it');
      for (var i = 0; i < 20; i++) {
        sprites.atlasFor(a);
      }
      expect(sprites.builds, 1);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      final atlas = sprites.atlasFor(a);
      expect(atlas, isNotNull);
      expect(atlas!.image.width, (kSpriteCell * 2 * 6).round());
      expect(sprites.builds, 1);
      sprites.atlasFor(const RepeaterSpriteKey(theme, 3));
      expect(sprites.builds, 2);
    });

    testWidgets('once the atlas is ready the layer repaints with it', (t) async {
      final sprites = RepeaterSprites.instance..clear();
      addTearDown(sprites.clear);
      final s = await source(t, roster: [row(k('a'), 40, -83)]);
      final probe = Probe();
      await t.pumpWidget(harness(probe, [(s, kRosterLayerId)]));
      await settle(t);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
      await settle(t);
      expect(painterOf(t).atlas, isNotNull, reason: 'the layer repaints when the atlas arrives');
    });
  });
}
