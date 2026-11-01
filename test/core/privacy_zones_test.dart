// Privacy zone rules (lib/core/privacy_zones.dart): rounding to 4 decimals, longitude wrap, limits, select-not-add hit test,
// the wire body, and the on-disk state.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/privacy_zones.dart';

void main() {
  group('rounding', () {
    test('coordinates are rounded to 4 decimals (the website rejected 5 decimals in a form, the app never sends them)', () {
      expect(roundCoord(39.96123), 39.9612);
      expect(roundCoord(-82.99876), -82.9988);
      expect(roundCoord(39.96125), 39.9613, reason: 'a tie goes up, like JavaScript Math.round');
      expect(roundCoord(-0.00004), 0.0);
      final z = PrivacyZone.normalized(lat: 39.961234567, lon: -82.998765432, radiusM: 300);
      expect(z.lat, 39.9612);
      expect(z.lon, -82.9988);
      final j = z.toJson();
      for (final k in ['lat', 'lon']) {
        final s = '${j[k]}';
        expect(s.contains('.') ? s.split('.')[1].length : 0, lessThanOrEqualTo(4), reason: s);
      }
    });

    test('toJson re-normalises, so a zone built with the raw constructor still goes out at 4 decimals', () {
      const raw = PrivacyZone(lat: 40.123456, lon: -83.654321, radiusM: 120.4);
      final j = raw.toJson();
      expect(j, {'lat': 40.1235, 'lon': -83.6543, 'radiusM': 120, 'label': null});
    });
  });

  group('longitude and latitude', () {
    test('a tap on the second world copy wraps to the same place', () {
      expect(wrapLon(190), -170);
      expect(wrapLon(-190), 170);
      expect(wrapLon(540), 180, reason: '540 is one and a half turns: the antimeridian, kept positive');
      expect(wrapLon(-180), -180);
      expect(wrapLon(180), 180);
      expect(wrapLon(12.5), 12.5);
      expect(PrivacyZone.normalized(lat: 10, lon: 190.00004).lon, -170.0);
    });
    test('latitude is clamped to the poles', () {
      expect(PrivacyZone.normalized(lat: 95, lon: 0).lat, 90);
      expect(PrivacyZone.normalized(lat: -95, lon: 0).lat, -90);
    });
  });

  group('limits', () {
    test('radius is held to 50..5000 m in whole metres', () {
      expect(PrivacyZone.normalized(lat: 1, lon: 1, radiusM: 10).radiusM, 50);
      expect(PrivacyZone.normalized(lat: 1, lon: 1, radiusM: 99999).radiusM, 5000);
      expect(PrivacyZone.normalized(lat: 1, lon: 1, radiusM: 123.6).radiusM, 124);
      expect(PrivacyZone.normalized(lat: 1, lon: 1, radiusM: double.nan).radiusM, kZoneDefaultRadiusM);
      expect(zoneRadiusProblem(20), 'Radius must be 50 to 5000 m.');
      expect(zoneRadiusProblem(300), isNull);
    });
    test('label: control characters stripped, trimmed, 40 characters, empty is null', () {
      expect(cleanLabel('  Home\n'), 'Home');
      expect(cleanLabel('   '), isNull);
      expect(cleanLabel(null), isNull);
      expect(cleanLabel('x' * 60)!.length, kZoneLabelMax);
    });
    test('at most $kZoneMax zones survive a load', () {
      final j = {'zones': [for (var i = 0; i < 14; i++) {'lat': 1.0 + i / 100, 'lon': 2.0, 'radiusM': 100}]};
      expect(PrivacyZoneState.fromJson(j).zones.length, kZoneMax);
    });
    test('a damaged entry is dropped, the rest kept; a damaged state is the empty one', () {
      final s = PrivacyZoneState.fromJson({
        'zones': [
          {'lat': 'x', 'lon': 1, 'radiusM': 100},
          {'lat': 95, 'lon': 1, 'radiusM': 100},
          {'lat': 1, 'lon': 1, 'radiusM': 100, 'label': 'Home'},
        ],
        'trimM': 99999,
      });
      expect(s.zones.single.label, 'Home');
      expect(s.trimM, kTrimMaxM);
      expect(PrivacyZoneState.fromJson('nonsense').zones, isEmpty);
    });
    test('field problems say what is allowed', () {
      expect(zoneLatProblem(91), contains('-90 to 90'));
      expect(zoneLonProblem(181), contains('-180 to 180'));
      expect(zoneLatProblem(45), isNull);
    });
  });

  group('selecting (tapping a zone never adds one)', () {
    const home = PrivacyZone(lat: 39.9612, lon: -82.9988, radiusM: 300);
    const work = PrivacyZone(lat: 39.9712, lon: -82.9988, radiusM: 500);
    test('a tap inside a zone picks it; the same tap on empty map picks nothing', () {
      expect(pickZone([home, work], 39.9613, -82.9987, 14), 0);
      expect(pickZone([home, work], 39.9712, -82.9988, 14), 1);
      expect(pickZone([home, work], 40.5, -83.5, 14), isNull);
    });
    test('overlapping zones: the smaller one wins', () {
      const big = PrivacyZone(lat: 39.9612, lon: -82.9988, radiusM: 2000);
      expect(pickZone([big, home], 39.9612, -82.9988, 14), 1);
    });
    test('a zone too small to hit on screen still counts as 24 px wide', () {
      const tiny = PrivacyZone(lat: 39.9612, lon: -82.9988, radiusM: 50);
      // At zoom 10 one pixel is ~ 120 m, so 24 px ~ 2.9 km: a tap 1 km away still selects it.
      final lat = 39.9612 + 1000 / 111320;
      expect(pickZone([tiny], lat, -82.9988, 10), 0);
      expect(pickZone([tiny], lat, -82.9988, 18), isNull);
    });
    test('the resize handle sits east of the centre by the radius', () {
      final h = eastOf(39.9612, -82.9988, 300);
      expect(distanceM(39.9612, -82.9988, h.lat, h.lon), closeTo(300, 2));
    });
  });

  group('server answer and disk state', () {
    test('DriverPrivacy parses the answer and the scope', () {
      final p = DriverPrivacy.tryParse({
        'privacy': {
          'trimM': 500,
          'scope': 'account',
          'privacyZones': [
            {'lat': 39.9612, 'lon': -82.9988, 'radiusM': 300, 'label': 'Home'},
            {'lat': 1, 'lon': 500, 'radiusM': 300},
          ],
        },
      })!;
      expect(p.scope, ZoneScope.account);
      expect(p.zones.single.label, 'Home');
      expect(DriverPrivacy.tryParse({'privacy': 'x'}), isNull);
      expect(DriverPrivacy.tryParse({'error': 'x'}), isNull);
    });
    test('state round-trips through JSON', () {
      final s = PrivacyZoneState(
        zones: const [PrivacyZone(lat: 1.5, lon: 2.5, radiusM: 100, label: 'A')],
        trimM: 750,
        pending: true,
        scope: ZoneScope.driver,
        syncedAt: DateTime.utc(2026, 11, 2),
      );
      final r = PrivacyZoneState.fromJson(s.toJson());
      expect(r.zones, s.zones);
      expect(r.trimM, 750);
      expect(r.pending, isTrue);
      expect(r.scope, ZoneScope.driver);
      expect(r.syncedAt, DateTime.utc(2026, 11, 2));
    });
  });
}
