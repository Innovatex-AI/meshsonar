// Stream 4 through AppState.init: the last-known fix is used at once, a fresh fix wins later (with no fake "you crossed
// a border"), a stale fix is labelled and centres the map but never prompts, a slow / failing / empty GPS falls back,
// no fix opens on the last region and nothing at all on the hub. Permission states and their actions.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/idle_region_watcher.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../ui/fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);
const day = RegionIndexEntry(code: 'DAY', slug: 'day', name: 'Dayton, US', url: 'https://day.meshsonar.com', bbox: [-84.5, 39.5, -83.6, 40.2]);

class MemLastKnown extends LastKnownStore {
  GeoFix? stored;
  final List<GeoFix> saves = [];
  MemLastKnown([this.stored]) : super(File('/nonexistent/last.json'));
  @override
  Future<GeoFix?> load() async => stored;
  @override
  Future<void> save(GeoFix fix) async {
    saves.add(fix);
    stored = fix;
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late Harness h;
  late MemLastKnown last;
  DateTime now() => h.clockNow;

  Harness make({GeoFix? stored, List<RegionIndexEntry> index = const [cmh, day], Settings? settings, LocationAccessProbe? probe}) {
    h = Harness();
    last = MemLastKnown(stored);
    h.lastKnownStore = last;
    h.locationAccess = probe;
    if (settings != null) h.settings.saved = settings;
    h.client.regionsIndexResult = index; // the first client; later clients copy nothing, so set it on every build
    return h;
  }

  test('the last-known fix is used at once; the fresh fix wins later with no border notice or prompt', () async {
    make(stored: GeoFix(lat: 39.9, lon: -84.0, at: DateTime.utc(2026, 10, 16, 16))); // Dayton, 2 h before "now"
    final gate = Completer<void>();
    h.location
      ..currentGate = gate
      ..currentFix = () => GeoFix(lat: 40.0, lon: -83.0, at: now()); // Columbus, live
    await h.state.init();
    await settle();
    // GPS has not answered yet: the map and the region already follow the last-known fix.
    expect(h.state.phoneFix?.live, isFalse);
    expect(h.state.currentRegion?.code, 'DAY');
    expect(h.state.viewingRegion?.code, 'DAY');
    expect(h.state.mapStart.kind, MapStartKind.phone);
    expect(h.state.mapStart.lon, -84.0);
    expect(h.state.phoneFixNote, 'Last known location, 2 h ago');
    gate.complete();
    await settle();
    expect(h.state.phoneFix?.live, isTrue);
    expect(h.state.phoneFixNote, isNull);
    expect(h.state.currentRegion?.code, 'CMH', reason: 'one fresh fix re-seeds: no 3-fix border hysteresis at launch');
    expect(h.state.viewingRegion?.code, 'CMH');
    expect(h.state.mapStart.lon, -83.0);
    expect(h.state.presetPrompt, isNull);
    expect(h.state.pendingNotice ?? '', isNot(contains('Entered')));
    expect(last.saves.last.lon, -83.0, reason: 'fresh fixes are saved as the next launch\'s last-known');
  });

  test('a stale fix (3 days) is labelled and centres the map, but never prompts; no GPS answer keeps it', () async {
    make(stored: GeoFix(lat: 39.9, lon: -84.0, at: DateTime.utc(2026, 10, 13, 18)));
    h.location.currentFix = () => null;
    await h.state.init();
    await settle();
    expect(h.state.phoneFix!.isStale(now()), isTrue);
    expect(h.state.phoneFixNote, 'Last known location, 3 d ago');
    expect(h.state.mapStart.kind, MapStartKind.phone);
    expect(h.state.viewingRegion?.code, 'DAY');
    expect(h.state.presetPrompt, isNull);
    expect(h.state.pendingNotice, isNull);
    expect(h.state.diagnostics.lines.join('\n'), isNot(contains('No GPS fix at launch')),
        reason: 'only said when there is nothing at all to show');
  });

  test('a GPS error falls back to the last-known fix and is logged', () async {
    make(stored: GeoFix(lat: 39.9, lon: -84.0, at: DateTime.utc(2026, 10, 16, 17)));
    h.location.currentError = StateError('kCLErrorDomain');
    await h.state.init();
    await settle();
    expect(h.state.phoneFix?.fix.lon, -84.0);
    expect(h.state.diagnostics.lines.join('\n'), contains('Getting a GPS fix at launch failed'));
  });

  test('a slow GPS: the last-known fix shows, launch gives up after the timeout, the fix is not waited on', () async {
    make(stored: GeoFix(lat: 39.9, lon: -84.0, at: DateTime.utc(2026, 10, 16, 17)));
    h.state.launchFixWait = const Duration(milliseconds: 40);
    h.location.currentGate = Completer<void>(); // never answers
    await h.state.init();
    await settle();
    expect(h.state.currentRegion?.code, 'DAY');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(h.state.diagnostics.lines.join('\n'), contains('TimeoutException'));
    expect(h.state.phoneFix?.live, isFalse);
  });

  test('no fix at all: the map opens on the last viewed region', () async {
    make(settings: const Settings(regionLast: 'DAY'));
    h.location.currentFix = () => null;
    await h.state.init();
    await settle();
    expect(h.state.phoneFix, isNull);
    expect(h.state.regionFixKnown, isFalse);
    expect(h.state.viewingRegion?.code, 'DAY');
    final m = h.state.mapStart;
    expect(m.kind, MapStartKind.region);
    expect(m.lat, closeTo((39.5 + 40.2) / 2, 1e-9));
    expect(h.state.diagnostics.lines.join('\n'), contains('No GPS fix at launch'));
  });

  test('nothing known (no fix, no region ever viewed): the hub view; no index either: the world', () async {
    make();
    h.location.currentFix = () => null;
    await h.state.init();
    await settle();
    expect(h.state.mapStart.kind, MapStartKind.hub);

    make(index: const []);
    h.location.currentFix = () => null;
    await h.state.init();
    await settle();
    expect(h.state.mapStart.kind, MapStartKind.world);
  });

  group('permission', () {
    test('not asked: a note with "Allow location"; nothing is asked until the person taps; then it locates', () async {
      final probe = FakeLocationAccess(LocationAccess.notAsked);
      make(probe: probe);
      h.location.currentFix = () => null;
      await h.state.init();
      await settle();
      expect(probe.requests, 0, reason: 'never a prompt on launch');
      final note = h.state.locationNote!;
      expect(note.action, LocationAction.ask);
      expect(note.actionLabel, 'Allow location');
      h.location.currentFix = () => GeoFix(lat: 40.0, lon: -83.0, at: now());
      final calls = h.location.currentCalls;
      await h.state.resolveLocationNote();
      await settle();
      expect(probe.requests, 1);
      expect(h.state.locationNote, isNull);
      expect(h.location.currentCalls, greaterThan(calls), reason: 'granted: the phone is located at once');
      expect(h.state.currentRegion?.code, 'CMH');
    });

    test('denied forever / restricted / services off open Settings; approximate says why; the region still shows', () async {
      for (final (access, settingsKind) in [
        (LocationAccess.deniedForever, 'app'),
        (LocationAccess.restricted, 'app'),
        (LocationAccess.servicesOff, 'location'),
        (LocationAccess.approximate, 'app'),
      ]) {
        final probe = FakeLocationAccess(access);
        make(settings: const Settings(regionLast: 'CMH'), probe: probe);
        h.location.currentFix = () => null;
        await h.state.init();
        await settle();
        final note = h.state.locationNote!;
        expect(note.access, access);
        expect(h.state.viewingRegion?.code, 'CMH', reason: '$access: the app still opens on the last region');
        await h.state.resolveLocationNote();
        expect(probe.requests, 0);
        expect(settingsKind == 'app' ? probe.appSettingsOpened : probe.locationSettingsOpened, 1, reason: '$access');
      }
    });

    test('granted: no note; a change made in Settings is picked up on the next read', () async {
      final probe = FakeLocationAccess(LocationAccess.deniedForever);
      make(probe: probe);
      await h.state.init();
      await settle();
      expect(h.state.locationNote, isNotNull);
      probe.access = LocationAccess.granted;
      await h.state.refreshLocationAccess();
      expect(h.state.locationNote, isNull);
    });
  });
}
