// The privacy-zone editor: select-not-add, add by map tap and by location, limits, radius / name / move / delete+undo,
// the offline queue and lazy key, an unsupported server, and the layout on iPhone / iPad / 2.5x text / dark / 48 px / VoiceOver.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show MapController;
import 'package:latlong2/latlong.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/privacy_zones.dart';

import '../support/zones_harness.dart';

Finder k(String key) => find.byKey(Key(key), skipOffstage: false);

/// Brings a widget of the scrolling panel (under the pinned map) into view; the list builds its rows lazily.
Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

/// Back to the top of the panel (the status line lives there).
Future<void> scrollTop(WidgetTester tester) async {
  await tester.drag(k('zones-panel'), const Offset(0, 3000));
  await tester.pumpAndSettle();
}

/// Where the map is centred (it opens on the phone, the first zone, or the region).
LatLng centre(MapController map) => map.camera.center;

Future<void> addByTap(WidgetTester tester, MapController map, double lat, double lon) async {
  await scrollTo(tester, k('zone-add'));
  await tester.tap(k('zone-add'));
  await tester.pumpAndSettle();
  expect(k('zone-add-banner'), findsOneWidget);
  await tapMapAt(tester, map, lat, lon);
}

void main() {
  testWidgets('empty: explains what zones do, offers Add, adds nothing by itself', (tester) async {
    final (h, _) = await pumpZones(tester);
    expect(find.textContaining('hidden from the public map'), findsOneWidget);
    expect(find.textContaining('start and end of each drive'), findsWidgets);
    expect(find.textContaining('trimmed'), findsOneWidget);
    await scrollTo(tester, k('zones-empty'));
    expect(k('zones-empty'), findsOneWidget);
    expect(h.state.privacyZones.zones, isEmpty);
  });

  testWidgets('add by tapping the map: one tap, one zone, 4 decimals, selected, sent to the server', (tester) async {
    final (h, map) = await pumpZones(tester);
    await addByTap(tester, map, 39.961234567, -82.998765432);
    final z = h.state.privacyZones.zones;
    expect(z.length, 1);
    expect(z.single.lat, closeTo(39.9612, 0.0006)); // the tap lands on a pixel, so within a pixel of the request
    final s = '${z.single.lat}';
    expect(s.split('.')[1].length, lessThanOrEqualTo(4));
    expect('${z.single.lon}'.split('.')[1].length, lessThanOrEqualTo(4));
    expect(z.single.radiusM, kZoneDefaultRadiusM);
    expect(k('zone-editor'), findsOneWidget, reason: 'the new zone is selected');
    expect(k('zone-add-banner'), findsNothing, reason: 'back to select mode');
    await tester.pumpAndSettle();
    expect(h.zc.posts.last.single.toJson()['lat'], z.single.lat);
  });

  testWidgets('tapping an existing zone SELECTS it and adds nothing; tapping empty map adds nothing', (tester) async {
    final (h, map) = await pumpZones(tester);
    await addByTap(tester, map, 39.9612, -82.9988);
    final zone = h.state.privacyZones.zones.single;
    // Deselect, then tap inside the circle.
    await scrollTo(tester, k('zone-tile-0'));
    await tester.tap(k('zone-tile-0')); // tile toggles selection off
    await tester.pumpAndSettle();
    expect(k('zone-editor'), findsNothing);
    await tapMapAt(tester, map, zone.lat + 0.0006, zone.lon);
    expect(h.state.privacyZones.zones.length, 1, reason: 'a tap on a zone never adds one');
    expect(k('zone-editor'), findsOneWidget, reason: 'it selected the zone');
    // Empty map, in select mode.
    await tapMapAt(tester, map, zone.lat, zone.lon + 0.0049); // 1.4 radii east: on the map, outside the circle
    expect(h.state.privacyZones.zones.length, 1);
    expect(k('zone-editor'), findsNothing, reason: 'a tap on nothing selects nothing');
  });

  testWidgets('"Use my location" adds a zone at the phone\'s position, rounded', (tester) async {
    final (h, _) = await pumpZones(tester);
    await scrollTo(tester, k('zone-add-here'));
    await tester.tap(k('zone-add-here'));
    await tester.pumpAndSettle();
    final z = h.state.privacyZones.zones.single;
    expect((z.lat, z.lon), (39.9612, -82.9988));
  });

  testWidgets('"Use my location" with no fix says so and adds nothing', (tester) async {
    final (h, _) = await pumpZones(tester, withFix: false);
    await scrollTo(tester, k('zone-add-here'));
    await tester.tap(k('zone-add-here'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No location yet'), findsOneWidget);
    expect(h.state.privacyZones.zones, isEmpty);
  });

  testWidgets('limit: 10 zones, then Add is off and the limit is said', (tester) async {
    final (h, _) = await pumpZones(tester);
    await h.state.privacyZones.load();
    await h.state.privacyZones.setZones([for (var i = 0; i < kZoneMax; i++) PrivacyZone.normalized(lat: 39.9 + i / 100, lon: -83.0)]);
    await tester.pumpAndSettle();
    await scrollTo(tester, k('zone-limit'));
    expect(find.textContaining('10 of 10 zones'), findsOneWidget);
    expect(tester.widget<FilledButton>(k('zone-add')).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(k('zone-add-here')).onPressed, isNull);
  });

  testWidgets('radius slider: 50 to 5000 m, saved when released; name saved on submit', (tester) async {
    final (h, map) = await pumpZones(tester);
    await addByTap(tester, map, 39.9612, -82.9988);
    await scrollTo(tester, k('zone-radius'));
    expect(find.textContaining('Radius: 300'), findsOneWidget);
    await tester.drag(k('zone-radius'), const Offset(400, 0)); // far right = the largest
    await tester.pumpAndSettle();
    expect(h.state.privacyZones.zones.single.radiusM, 5000);
    await tester.drag(k('zone-radius'), const Offset(-800, 0));
    await tester.pumpAndSettle();
    expect(h.state.privacyZones.zones.single.radiusM, 50);
    await scrollTo(tester, k('zone-name'));
    await tester.enterText(k('zone-name'), 'Home');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(h.state.privacyZones.zones.single.label, 'Home');
    expect(find.text('Home'), findsWidgets);
  });

  testWidgets('move on map relocates the selected zone; delete removes it and Undo brings it back', (tester) async {
    final (h, map) = await pumpZones(tester);
    await addByTap(tester, map, 39.9612, -82.9988);
    await scrollTo(tester, k('zone-move'));
    await tester.tap(k('zone-move'));
    await tester.pumpAndSettle();
    expect(find.textContaining('where the zone should move'), findsOneWidget);
    await tapMapAt(tester, map, 39.9597, -82.9983); // 220 m south: clear of the pin (24 px) and the banner
    expect(h.state.privacyZones.zones.length, 1);
    expect(h.state.privacyZones.zones.single.lat, closeTo(39.9597, 0.0002));
    await scrollTo(tester, k('zone-delete'));
    await tester.tap(k('zone-delete'));
    await tester.pumpAndSettle();
    expect(h.state.privacyZones.zones, isEmpty);
    expect(find.textContaining('Deleted'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(h.state.privacyZones.zones.length, 1);
  });

  testWidgets('trim distance is a setting and is sent', (tester) async {
    final (h, _) = await pumpZones(tester);
    await scrollTo(tester, k('zone-trim'));
    await tester.drag(k('zone-trim'), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(h.state.privacyZones.trimM, kTrimMaxM);
    expect(h.zc.trim, kTrimMaxM);
  });

  group('offline and lazy key', () {
    testWidgets('offline: the zone is kept, the screen says it waits, and it goes out when the server answers', (tester) async {
      final (h, map) = await pumpZones(tester);
      h.zc.error = const CmatException('network error: down');
      await addByTap(tester, map, 39.9612, -82.9988);
      await tester.pumpAndSettle();
      expect(h.state.privacyZones.pending, isTrue);
      await scrollTop(tester);
      expect(find.textContaining('sent when the server can be reached'), findsOneWidget);
      h.zc.error = null;
      await h.state.privacyZones.sync();
      await tester.pumpAndSettle();
      expect(h.zc.server.length, 1);
      await scrollTop(tester);
      expect(find.textContaining('Saved.'), findsOneWidget);
    });

    testWidgets('no driver key yet: usable, says it waits for a key, and sends once a key exists', (tester) async {
      final (h, map) = await pumpZones(tester, withKey: false);
      await addByTap(tester, map, 39.9612, -82.9988);
      expect(h.state.privacyZones.zones.length, 1);
      await scrollTop(tester);
      expect(find.textContaining('as soon as this phone has a driver key'), findsOneWidget);
      expect(h.zc.posts, isEmpty);
      await h.state.updateSettings(h.state.settings.copyWith(driverKey: 'secretkey-abcdef-1234', keyStatus: DriverKeyStatus.approved));
      await tester.pumpAndSettle();
      expect(h.zc.server.length, 1, reason: 'the lazy key arrived, the waiting zone was sent');
    });
  });

  testWidgets('a server without driverPrivacy: a plain message, no editing, nothing sent', (tester) async {
    final (h, _) = await pumpZones(tester, capable: false);
    expect(k('zones-unsupported'), findsOneWidget);
    expect(find.textContaining('does not support privacy zones'), findsOneWidget);
    expect(k('zone-add'), findsNothing);
    expect(h.zc.posts, isEmpty);
  });

  group('layout', () {
    Future<void> checkTargets(WidgetTester tester) async {
      for (final id in ['zone-add', 'zone-add-here', 'zones-website']) {
        final f = k(id);
        if (f.evaluate().isEmpty) continue;
        await scrollTo(tester, f);
        final r = tester.getRect(f);
        expect(r.height, greaterThanOrEqualTo(47.9), reason: '$id is ${r.height} tall');
        expect(r.width, greaterThanOrEqualTo(47.9), reason: '$id is ${r.width} wide');
      }
    }

    for (final (name, size, scale, dark) in [
      ('iPhone', const Size(393, 852), 1.0, false),
      ('iPhone dark', const Size(393, 852), 1.0, true),
      ('iPhone 2.5x text', const Size(393, 852), 2.5, false),
      ('iPhone 2.5x text dark', const Size(393, 852), 2.5, true),
      ('iPad', const Size(1024, 1366), 1.0, false),
      ('iPad landscape dark', const Size(1366, 1024), 1.0, true),
      ('iPad 2.5x text', const Size(834, 1194), 2.5, false),
    ]) {
      testWidgets('$name: no overflow, targets at least 48 px, with a zone selected', (tester) async {
        final (h, map) = await pumpZones(tester, size: size, textScale: scale, brightness: dark ? Brightness.dark : Brightness.light);
        await h.state.privacyZones.load();
        await h.state.privacyZones.setZones([
          PrivacyZone.normalized(lat: 39.9612, lon: -82.9988, label: 'Home'),
          PrivacyZone.normalized(lat: 39.99, lon: -83.01, radiusM: 800),
        ]);
        await tester.pumpAndSettle();
        await scrollTo(tester, k('zone-tile-0'));
        await tester.tap(k('zone-tile-0'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await checkTargets(tester);
        for (final id in ['zone-move', 'zone-here', 'zone-delete']) {
          await scrollTo(tester, k(id));
          expect(tester.getSize(k(id)).height, greaterThanOrEqualTo(47.9), reason: id);
        }
        expect(tester.takeException(), isNull);
        // Tap the map in add mode at this size, too: nothing breaks.
        await scrollTo(tester, k('zone-add'));
        await tester.tap(k('zone-add'));
        await tester.pumpAndSettle();
        expect(tester.getRect(k('zone-add-banner')).height, lessThan(tester.getRect(k('zones-map')).height), reason: 'the banner never fills the map');
        await tapMapAt(tester, map, 39.9597, -82.9979);
        expect(h.state.privacyZones.zones.length, 3);
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('VoiceOver: the map, every zone and the sliders have spoken labels; the list edits without the map', (tester) async {
    final handle = tester.ensureSemantics();
    final (h, _) = await pumpZones(tester);
    await h.state.privacyZones.load();
    await h.state.privacyZones.setZones([PrivacyZone.normalized(lat: 39.9612, lon: -82.9988, label: 'Home', radiusM: 400)]);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'Map of your privacy zones\. 1 zone\.')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'Home, radius 400')), findsWidgets);
    await scrollTo(tester, k('zone-tile-0'));
    await tester.tap(k('zone-tile-0'));
    await tester.pumpAndSettle();
    await scrollTo(tester, k('zone-radius'));
    final tree = tester.getSemantics(find.byType(Scaffold).first).toStringDeep();
    expect(tree, contains('isSlider'));
    expect(tree, contains('value: "400 m"'), reason: 'the radius slider speaks its value');
    expect(tree, contains('increasedValue: "420 m"'));
    expect(find.bySemanticsLabel('Radius'), findsOneWidget);
    await scrollTo(tester, k('zone-trim'));
    expect(find.bySemanticsLabel('Trim distance'), findsOneWidget);
    expect(find.bySemanticsLabel('Cancel'), findsNothing, reason: 'the banner only exists in add / move mode');
    // The selected state is announced.
    final tile = tester.getSemantics(k('zone-tile-0'));
    expect(tile.flagsCollection.isSelected.name, 'isTrue');
    handle.dispose();
  });
}
