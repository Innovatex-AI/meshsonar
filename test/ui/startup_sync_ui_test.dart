// Stream 3 + 4 on screen: the Repeaters panel shows the synced roster with its freshness (and offline age), pull to
// refresh forces it; the Drive map opens on the phone (stale fix labelled); location states show their action on the
// Drive and Region tabs, and nothing is asked until the person taps.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/idle_region_watcher.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/repeater_sync.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/region/repeaters_panel.dart';

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
  group('Repeaters panel on the sync', () {
    late DateTime syncNow;
    late bool offline;
    late int rosterCalls;

    Harness make() {
      syncNow = DateTime.utc(2026, 10, 16, 18);
      offline = false;
      rosterCalls = 0;
      final c = MockClient((req) async {
        if (req.url.path.endsWith('/region-repeaters')) {
          rosterCalls++;
          if (offline) throw const SocketException('offline');
          return http.Response(
              jsonEncode({
                'status': {'state': 'ready', 'reason': null, 'computedAt': null},
                'rows': [
                  {'key': 'da' * 32, 'hashPrefix': 'da', 'name': 'Alpha', 'role': 'repeater', 'lat': 40.0, 'lon': -83.0, 'status': 'active'},
                  {'key': 'db' * 32, 'hashPrefix': 'db', 'name': 'Bravo', 'role': 'repeater', 'lat': 40.0, 'lon': -83.0, 'status': 'quiet'},
                ],
                'counts': {'active': 1, 'quiet': 1, 'new': 0, 'stale': 0},
              }),
              200);
        }
        return http.Response('{}', 404);
      });
      final h = Harness();
      h.repeaterSync = RepeaterSync(rosterClient: () => c, networkClient: () => c, clock: () => syncNow, parseInIsolate: false);
      h.client.regionsIndexResult = const [cmh];
      return h;
    }

    Widget host(Harness h) => AppScope(
          state: h.state,
          child: const MaterialApp(home: Scaffold(body: RepeatersPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh'))),
        );

    testWidgets('shows the synced roster with "Updated" and the count; offline it keeps it and says how old', (tester) async {
      final h = make();
      await h.state.init();
      await tester.pumpWidget(host(h));
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Updated just now · 2 repeaters'), findsOneWidget);
      final calls = rosterCalls;

      offline = true;
      syncNow = syncNow.add(const Duration(minutes: 12));
      await h.state.syncRepeaterLists(SyncTrigger.resume);
      await tester.pumpAndSettle();
      expect(rosterCalls, calls + 1);
      expect(find.text('Alpha'), findsOneWidget, reason: 'the stored roster stays on screen');
      expect(find.text('Offline - as of 12m ago · 2 repeaters'), findsOneWidget);

      // Pull to refresh forces a request (back online).
      offline = false;
      syncNow = syncNow.add(const Duration(seconds: 11)); // past the anti-loop floor for forced refreshes
      await tester.fling(find.text('Alpha'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(rosterCalls, calls + 2);
      expect(find.text('Updated just now · 2 repeaters'), findsOneWidget);
    });

    testWidgets('nothing stored and the fetch fails: the error state with a retry', (tester) async {
      final h = make();
      offline = true;
      await h.state.init();
      await tester.pumpWidget(host(h));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('repeaters-error')), findsOneWidget);
    });
  });

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
      expect(find.byKey(const Key('location-note')), findsOneWidget);
      expect(find.textContaining('Allow location so the map opens where you are.'), findsOneWidget);
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
      expect(find.byKey(const Key('location-note')), findsOneWidget);
      probe.access = LocationAccess.granted;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('location-note')), findsNothing);
    });
  });
}
