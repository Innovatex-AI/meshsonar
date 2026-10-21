// Live, local region awareness (lib/core/region_lookup.dart, AppState.refreshRegionIndex/_updateRegion): the
// Drive-screen badge and the one-shot "Entered <code>" notice on a border crossing mid-drive.
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/radio/radio_api.dart';

import 'fakes.dart';

const cmh = RegionIndexEntry(
  code: 'CMH',
  slug: 'cmh',
  name: 'Columbus, US',
  url: 'https://cmh.meshsonar.com',
  bbox: [-83.5, 39.75, -82.45, 40.65],
);

// FakeLocation.current() always answers (40.126, -82.93) — inside cmh's bbox, outside day's.
const day = RegionIndexEntry(
  code: 'DAY',
  slug: 'day',
  name: 'Dayton, US',
  url: 'https://day.meshsonar.com',
  bbox: [-84.5, 39.5, -83.6, 40.2],
);

final regionChip = find.byKey(const Key('region-chip'));

void main() {
  testWidgets('state (a): no cache and no live fetch yet — the badge shows nothing', (tester) async {
    final h = Harness();
    h.client.regionsIndexError = const CmatException('no regions-index endpoint', status: 404);
    await h.pumpApp(tester);
    await tester.pumpAndSettle(); // let init()'s unawaited refreshRegionIndex() resolve
    expect(h.state.regionIndexLoaded, isFalse);
    expect(h.state.currentRegion, isNull);
    expect(regionChip, findsNothing);
  });

  testWidgets('state (b): a fix outside every known region\'s bbox — "Outside coverage"', (tester) async {
    final h = Harness();
    h.client.regionsIndexResult = const [day]; // day's bbox excludes FakeLocation's fixed (40.126, -82.93)
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.state.regionIndexLoaded, isTrue);
    expect(h.state.regionFixKnown, isTrue);
    expect(h.state.currentRegion, isNull);
    expect(regionChip, findsOneWidget);
    expect(find.text('Outside coverage'), findsOneWidget);
  });

  testWidgets('state (c): offline on a stale cache — badge still matches, tooltip flags it', (tester) async {
    final h = Harness();
    h.regionIndexCache.items = const [cmh]; // loaded before the (failing) live fetch
    h.client.regionsIndexError = const CmatException('offline', status: null);
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.state.regionIndexLoaded, isTrue);
    expect(h.state.regionIndexStale, isTrue);
    expect(h.state.currentRegion?.code, 'CMH');
    expect(find.text('CMH'), findsOneWidget);
    await tester.longPress(regionChip);
    await tester.pumpAndSettle();
    expect(find.textContaining('offline'), findsWidgets);
  });

  testWidgets('state (d): a normal match — the region\'s code, no stale flag', (tester) async {
    final h = Harness();
    h.client.regionsIndexResult = const [cmh, day];
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.state.regionIndexStale, isFalse);
    expect(h.state.currentRegion?.code, 'CMH');
    expect(find.text('CMH'), findsOneWidget);
  });

  testWidgets('detection at startup never pops a notice — only a mid-drive crossing does', (tester) async {
    final h = Harness();
    h.client.regionsIndexResult = const [cmh, day];
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.state.currentRegion?.code, 'CMH');
    expect(h.state.pendingNotice, isNull);
  });

  testWidgets('badge updates live across a drive, and a border crossing fires the one-shot "Entered" notice',
      (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.client.regionsIndexResult = const [cmh, day];
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(find.text('CMH'), findsOneWidget); // startup detection, before any drive

    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await tester.pump(const Duration(milliseconds: 50));

    // Still inside CMH: the engine's own GPS stream reports a fix inside cmh's bbox. No change, no new notice.
    h.engines.single.setStatus(EngineStatus(EngineState.driving, lastFix: GeoFix(lat: 40.1, lon: -83.0, at: DateTime.utc(2026, 10, 16, 18, 0, 0))));
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.state.currentRegion?.code, 'CMH');
    expect(h.state.pendingNotice, isNull);

    // Crosses into Dayton's bbox mid-drive: the badge updates and the one-shot notice fires. HomeShell's own
    // listener (already mounted by pumpApp) takes pendingNotice and shows it the instant notifyListeners() runs
    // — same as any other _say() banner — so the SnackBar, not pendingNotice, is what this checks next.
    h.engines.single.setStatus(EngineStatus(EngineState.driving, lastFix: GeoFix(lat: 39.9, lon: -84.0, at: DateTime.utc(2026, 10, 16, 18, 0, 0))));
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.state.currentRegion?.code, 'DAY');
    await tester.pump();
    expect(find.text('Entered DAY'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('DAY'), findsWidgets); // the badge itself also followed the crossing

    // A second fix still inside Dayton's bbox: no repeat notice for staying in the same region.
    h.engines.single.setStatus(EngineStatus(EngineState.driving, lastFix: GeoFix(lat: 39.95, lon: -84.1, at: DateTime.utc(2026, 10, 16, 18, 0, 0))));
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.state.pendingNotice, isNull);

    await h.state.stopDrive();
    await tester.pump(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a server-URL change refetches the regions index (not cleared immediately, unlike siteConfig)',
      (tester) async {
    final h = Harness();
    h.client.regionsIndexResult = const [cmh];
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.state.currentRegion?.code, 'CMH');
    await h.state.updateSettings(h.state.settings.copyWith(serverUrl: 'https://other.example.org'));
    // The phone's physical region hasn't changed just because the server did: the old match is kept as a
    // defensible guess until the new server's index answers (unlike siteConfig, which is blanked immediately).
    expect(h.state.currentRegion?.code, 'CMH');
    await tester.pumpAndSettle();
  });
}
