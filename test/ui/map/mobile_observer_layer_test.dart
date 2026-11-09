// Contract section 8.4: online moving MeshSonar phones on the app's Observers layer (parity with the website): distinct
// marker, fading out over 10 minutes after last seen, gone after; fixed observers unchanged.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/ui/map/layers/observer_layer.dart';
import 'package:meshsonar/ui/theme.dart';

final _now = DateTime.utc(2026, 11, 9, 12);

RegionObserver _mobile(String key, Duration ago) => RegionObserver.tryParse({
      'key': key,
      'name': 'MeshSonar phone ${key.substring(0, 6)}',
      'kind': 'mobile',
      'online': true,
      'lat': 39.96,
      'lon': -83.0,
      'lastSeenAt': _now.subtract(ago).toIso8601String(),
      'phone': true,
      'packets10m': 12,
    })!;

void main() {
  test('rows parse kind and packets in 10 min; older rows without kind are fixed', () {
    final m = _mobile('abcdef123456', const Duration(minutes: 1));
    expect(m.mobile, isTrue);
    expect(m.packets10m, 12);
    expect(m.lastSeen, _now.subtract(const Duration(minutes: 1)));
    expect(RegionObserver.tryParse({'key': 'x', 'online': true})!.mobile, isFalse);
  });

  test('fade: full when just seen, dimmer later, gone after 10 minutes; fixed always full', () {
    expect(observerOpacity(_mobile('a' * 12, Duration.zero), _now), 1);
    final mid = observerOpacity(_mobile('a' * 12, const Duration(minutes: 5)), _now);
    expect(mid, lessThan(1));
    expect(mid, greaterThan(0.2));
    expect(observerOpacity(_mobile('a' * 12, const Duration(minutes: 10)), _now), 0);
    expect(observerOpacity(RegionObserver.tryParse({'key': 'f', 'online': false})!, _now), 1);
  });

  testWidgets('draws a moving-phone marker for a fresh one, none for a stale one, triangles for fixed', (tester) async {
    final rows = [
      _mobile('fresh0000000', const Duration(minutes: 2)),
      _mobile('stale0000000', const Duration(minutes: 11)),
      RegionObserver.tryParse({'key': 'fixed1', 'online': true, 'lat': 39.9, 'lon': -83.1})!,
    ];
    await tester.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.light),
      home: FlutterMap(
        options: const MapOptions(initialCenter: LatLng(39.93, -83.05), initialZoom: 10),
        children: [ObserverLayer(observers: rows, now: () => _now)],
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('map-observer-fresh0000000-mobile')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-observer-stale0000000')), findsNothing);
    expect(find.byKey(const ValueKey('map-observer-fixed1-online')), findsOneWidget);
  });
}
