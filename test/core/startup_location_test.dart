// Stream 4 core: where maps open, the fix age labels, the bounded launch fix and the plain-language location states.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/radio/radio_api.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);
const day = RegionIndexEntry(code: 'DAY', slug: 'day', name: 'Dayton, US', url: 'https://day.meshsonar.com', bbox: [-84.5, 39.5, -83.6, 40.2]);
final now = DateTime.utc(2026, 10, 24, 12);
PhoneFix fixAt(double lat, double lon, {Duration age = Duration.zero, bool live = true}) =>
    PhoneFix(GeoFix(lat: lat, lon: lon, at: now.subtract(age)), live: live);

class _Src implements LocationSource {
  final Future<GeoFix?> Function() f;
  _Src(this.f);
  @override
  Future<GeoFix?> current() => f();
  @override
  Stream<GeoFix> get fixes => const Stream.empty();
  @override
  Future<bool> ensurePermission() async => true;
}

void main() {
  group('mapStartFor', () {
    test('a phone fix wins (following GPS)', () {
      final m = mapStartFor(phone: fixAt(40.0, -83.0), viewing: cmh, viewingIsManual: false, viewingRemembered: true, index: const [cmh, day]);
      expect(m.kind, MapStartKind.phone);
      expect(m.lat, 40.0);
    });

    test('a manually picked region that does not hold the phone opens on that region, not the phone', () {
      final m = mapStartFor(phone: fixAt(40.0, -83.0), viewing: day, viewingIsManual: true, viewingRemembered: true, index: const [cmh, day]);
      expect(m.kind, MapStartKind.region);
      expect(m.lon, closeTo((-84.5 + -83.6) / 2, 1e-9));
    });

    test('a manually picked region that holds the phone still opens on the phone', () {
      final m = mapStartFor(phone: fixAt(40.0, -83.0), viewing: cmh, viewingIsManual: true, viewingRemembered: true, index: const [cmh, day]);
      expect(m.kind, MapStartKind.phone);
    });

    test('no fix: the last viewed region', () {
      final m = mapStartFor(phone: null, viewing: day, viewingIsManual: false, viewingRemembered: true, index: const [cmh, day]);
      expect(m.kind, MapStartKind.region);
      expect(m.lat, closeTo((39.5 + 40.2) / 2, 1e-9));
    });

    test('no fix and no region ever viewed: the middle of every region (hub view)', () {
      final m = mapStartFor(phone: null, viewing: cmh, viewingIsManual: false, viewingRemembered: false, index: const [cmh, day]);
      expect(m.kind, MapStartKind.hub);
      expect(m.lon, closeTo((-84.5 + -82.45) / 2, 1e-9));
      expect(m.lat, closeTo((39.5 + 40.65) / 2, 1e-9));
    });

    test('nothing known at all: whole world', () {
      expect(mapStartFor(phone: null, viewing: null, viewingIsManual: false, viewingRemembered: false, index: const []).kind,
          MapStartKind.world);
    });
  });

  group('PhoneFix', () {
    test('live, cached and stale fixes are told apart and labelled', () {
      expect(phoneFixLabel(fixAt(40, -83), now), isNull);
      expect(phoneFixLabel(fixAt(40, -83, age: const Duration(hours: 3), live: false), now), 'Last known location, 3 h ago');
      final stale = fixAt(40, -83, age: const Duration(days: 2), live: false);
      expect(stale.isStale(now), isTrue);
      expect(phoneFixLabel(stale, now), 'Last known location, 2 d ago');
      // An OS-cached position handed back by a GPS call (live run, but old) is labelled too.
      expect(fixAt(40, -83, age: const Duration(hours: 1)).isLive(now), isFalse);
      expect(fixAt(40, -83, age: const Duration(hours: 23), live: false).isStale(now), isFalse);
    });
  });

  group('fixWithin', () {
    test('a fix, null, an error and a slow source', () async {
      final errors = <Object>[];
      expect((await fixWithin(_Src(() async => GeoFix(lat: 1, lon: 2, at: now)), const Duration(seconds: 1)))?.lat, 1);
      expect(await fixWithin(_Src(() async => null), const Duration(seconds: 1)), isNull);
      expect(await fixWithin(_Src(() async => throw StateError('gps')), const Duration(seconds: 1), onError: errors.add), isNull);
      final never = Completer<GeoFix?>();
      expect(await fixWithin(_Src(() => never.future), const Duration(milliseconds: 30), onError: errors.add), isNull);
      expect(errors, hasLength(2));
      expect(errors.last, isA<TimeoutException>());
    });
  });

  group('locationNoteFor', () {
    test('every state has the right action; granted and unknown say nothing', () {
      expect(locationNoteFor(LocationAccess.granted), isNull);
      expect(locationNoteFor(LocationAccess.unknown), isNull);
      expect(locationNoteFor(LocationAccess.notAsked)!.action, LocationAction.ask);
      expect(locationNoteFor(LocationAccess.denied)!.action, LocationAction.ask);
      expect(locationNoteFor(LocationAccess.deniedForever)!.action, LocationAction.openAppSettings);
      expect(locationNoteFor(LocationAccess.restricted)!.action, LocationAction.openAppSettings);
      expect(locationNoteFor(LocationAccess.servicesOff)!.action, LocationAction.openLocationSettings);
      final approx = locationNoteFor(LocationAccess.approximate)!;
      expect(approx.action, LocationAction.openAppSettings);
      expect(approx.offerRegionPicker, isFalse);
      expect(locationNoteFor(LocationAccess.deniedForever, regionName: 'Columbus, US')!.message, contains('Showing Columbus, US.'));
      for (final a in LocationAccess.values) {
        final n = locationNoteFor(a);
        if (n != null) expect(n.message, isNot(contains('null')));
      }
    });
  });
}
