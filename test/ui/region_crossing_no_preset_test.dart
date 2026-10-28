// Crossing into a region that has no radio preset on file: the notice says so (it never implies the radio is right for
// the new region), no preset dialog is raised (there is nothing to compare), and the radio is not touched.
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/radio/radio_api.dart';

import 'fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);
const day = RegionIndexEntry(code: 'DAY', slug: 'day', name: 'Dayton, US', url: 'https://day.meshsonar.com', bbox: [-84.5, 39.5, -83.6, 40.2]);

class _H extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => FakeCmatClient(u)..siteConfigResult = const SiteConfig(region: RegionInfo(slug: 'day', url: 'https://day.meshsonar.com'));
}

void main() {
  testWidgets('entering a region with no preset on file says so and raises no preset dialog', (tester) async {
    useTallScreen(tester);
    final h = _H();
    h.client.regionsIndexResult = const [cmh, day];
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await tester.pump(const Duration(milliseconds: 50));
    void fix(double lat, double lon) =>
        h.engines.single.setStatus(EngineStatus(EngineState.driving, lastFix: GeoFix(lat: lat, lon: lon, at: DateTime.utc(2026, 10, 16, 18))));
    fix(40.1, -83.0);
    await tester.pump(const Duration(milliseconds: 50));
    fix(39.9, -84.0);
    await tester.pump(const Duration(milliseconds: 50));
    fix(39.9, -84.01);
    await tester.pump(const Duration(milliseconds: 50));
    fix(39.9, -84.02);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(h.state.currentRegion?.code, 'DAY');
    expect(find.textContaining('Entered Dayton, US'), findsOneWidget);
    expect(find.textContaining('It has no radio preset on file'), findsOneWidget);
    expect(find.byKey(const Key('region-preset-dialog')), findsNothing);
    expect(h.state.presetPrompt, isNull);
  });
}
