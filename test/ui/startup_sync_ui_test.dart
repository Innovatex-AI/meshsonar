// Stream 4 on screen (the old Repeaters panel was retired in build 71): the Drive map opens on the phone (stale fix labelled); location states show their action on the
// Drive and Region tabs, and nothing is asked until the person taps.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/idle_region_watcher.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/radio/radio_api.dart';

import 'fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);

class _MemLastKnown extends LastKnownStore {
  GeoFix? stored;
  _MemLastKnown(this.stored) : super(File('/nonexistent/last.json'));
  @override
  Future<GeoFix?> load() async => stored;
  @override
  Future<void> save(GeoFix fix) async => stored = fix;
}

void main() {

  group('Drive and Region tabs open on the phone', () {
    testWidgets('the Drive map shows the phone at once when idle; a stale fix is labelled', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.lastKnownStore = _MemLastKnown(GeoFix(lat: 40.0, lon: -83.0, at: DateTime.utc(2026, 10, 13, 18)));
      h.location.currentFix = () => null;
      h.client.regionsIndexResult = const [cmh];
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('map-position')), findsOneWidget);
      expect(find.text('Last known location, 3 d ago'), findsOneWidget);
    });

    testWidgets('a fix older than 72 h: the Drive map still centres on it, labelled "4 d ago"; no region switch',
        (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.lastKnownStore = _MemLastKnown(GeoFix(lat: 40.0, lon: -83.0, at: DateTime.utc(2026, 10, 12, 18)));
      h.location.currentFix = () => null;
      h.client.regionsIndexResult = const [cmh];
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('map-position')), findsOneWidget);
      expect(find.text('Last known location, 4 d ago'), findsOneWidget);
      expect(h.state.currentRegion, isNull);
    });

    testWidgets('location not asked: a note with "Allow location" on Drive and Region; asked only on tap', (tester) async {
      useTallScreen(tester);
      final probe = FakeLocationAccess(LocationAccess.notAsked);
      final h = Harness()..locationAccess = probe;
      h.client.regionsIndexResult = const [cmh];
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      await openDrivePanel(tester); // the note is a row of the Medium panel
      expect(find.byKey(const Key('location-note')), findsOneWidget);
      // Build 77 (round 1 F6): the location message is said once, in the Drive strip.
      expect(find.descendant(of: find.byKey(const Key('dock-strip-text')), matching: find.textContaining('location')).evaluate().isNotEmpty || find.textContaining('Allow location').evaluate().isNotEmpty, isTrue);
      expect(probe.requests, 0);

      await openRegionTab(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('location-note')), findsOneWidget);
      expect(find.byKey(const Key('location-note-pick-region')), findsOneWidget);

      await tester.tap(find.byKey(const Key('location-note-action')));
      await tester.pumpAndSettle();
      expect(probe.requests, 1);
      expect(find.byKey(const Key('location-note')), findsNothing);
    });

    testWidgets('denied for good: "Open Settings" opens the app settings page', (tester) async {
      useTallScreen(tester);
      final probe = FakeLocationAccess(LocationAccess.deniedForever);
      final h = Harness()..locationAccess = probe;
      h.client.regionsIndexResult = const [cmh];
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      expect(find.text('Open Settings'), findsOneWidget);
      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      expect(probe.appSettingsOpened, 1);
      expect(probe.requests, 0);
    });

    testWidgets('back from Settings (app resumed): the new permission is read and the note goes', (tester) async {
      useTallScreen(tester);
      final probe = FakeLocationAccess(LocationAccess.deniedForever);
      final h = Harness()..locationAccess = probe;
      h.client.regionsIndexResult = const [cmh];
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      await openDrivePanel(tester);
      expect(find.byKey(const Key('location-note')), findsOneWidget);
      probe.access = LocationAccess.granted;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('location-note')), findsNothing);
    });
  });
}
