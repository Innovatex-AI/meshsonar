// Drive WP4: the map inspector (opens on a tap and stays; nothing locks it since build 76) and the Nearby repeaters list.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';
import 'package:meshsonar/ui/drive/panel/panel_medium.dart';
import 'package:meshsonar/ui/map/map_info_panel.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: child)));

RegionRepeater rr(String key, String? name, double? lat, double? lon, {String role = 'repeater'}) =>
    RegionRepeater(key: key, hashPrefix: key.substring(0, 2), name: name, role: role, lat: lat, lon: lon);

void main() {
  testWidgets('idle: the panel expands to its body on tap and stays until closed', (tester) async {
    var closed = 0;
    await tester.pumpWidget(host(MapInfoPanel(title: 'Otterbein Hill', summary: 'Heard in 3 cells', busy: false, body: const Text('BODY'), onClose: () => closed++)));
    expect(find.text('BODY'), findsNothing);
    await tester.tap(find.byKey(const Key('info-panel-header')));
    await tester.pump();
    expect(find.text('BODY'), findsOneWidget);
    await tester.pump(const Duration(seconds: 60));
    expect(closed, 0);
  });

  testWidgets('nothing locks the inspector: it opens on a tap whatever the caller passes, and never says "Open when stopped"', (tester) async {
    // `locked` is still accepted (coverage_map.dart passes it) and ignored.
    await tester.pumpWidget(host(MapInfoPanel(title: 'Otterbein Hill', summary: 's', busy: false, body: const Text('BODY'), onClose: () {}, locked: true)));
    expect(find.text('Open when stopped'), findsNothing);
    expect(find.byKey(const Key('info-panel-summary')), findsOneWidget);
    await tester.tap(find.byKey(const Key('info-panel-header')));
    await tester.pump();
    expect(find.text('BODY'), findsOneWidget);
    // Close stays a 48 pt target.
    expect(tester.getSize(find.byKey(const Key('link-clear'))).height, greaterThanOrEqualTo(48));
  });

  testWidgets('autoClear (no caller in the app since build 76): clears 12 s after the last touch; a touch resets the timer', (tester) async {
    var closed = 0;
    await tester.pumpWidget(host(MapInfoPanel(title: 't', summary: 's', busy: false, body: const Text('B'), onClose: () => closed++, autoClear: const Duration(seconds: 12))));
    await tester.pump(const Duration(seconds: 8));
    await tester.tap(find.byKey(const Key('info-panel-header')));
    await tester.pump(const Duration(seconds: 8));
    expect(closed, 0, reason: 'the touch at 8 s restarted the 12 s');
    await tester.pump(const Duration(seconds: 5));
    expect(closed, 1);
  });

  test('nearestRepeaters: nearest first, only placed repeaters and rooms, three at most', () {
    final list = nearestRepeaters([
      rr('aa11', 'Far', 40.5, -83.0),
      rr('bb22', 'Near', 39.9625, -82.9988),
      rr('cc33', 'Unplaced', null, null),
      rr('dd44', 'Companion', 39.9626, -82.9989, role: 'companion'),
      rr('ee55', 'Room', 39.97, -83.0, role: 'room'),
      rr('ff66', 'Mid', 40.0, -83.0),
    ], 39.9612, -82.9988);
    expect([for (final n in list) n.name], ['Near', 'Room', 'Mid']);
    expect(list.first.distanceM, lessThan(list[1].distanceM));
    expect(list.length, 3);
  });
}
