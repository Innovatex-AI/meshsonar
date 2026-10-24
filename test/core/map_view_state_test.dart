import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_view_state.dart';

MapViewState? p(String s) => MapViewState.fromUri(Uri.parse(s));

void main() {
  group('website coverage links (validateCoverageAreaSearch parity)', () {
    test('a full website link parses every field and the host gives the region', () {
      final s = p('https://cmh.meshsonar.com/coverage?show=measured,repeaters,observers&color=noise&since=7d&src=meshsonar&res=9&lat=39.96&lon=-82.99&label=Home&from=map')!;
      expect(s.region, 'cmh');
      expect(s.show, ['measured', 'repeaters', 'observers']);
      expect(s.color, 'noise');
      expect(s.since, '7d');
      expect(s.src, 'meshsonar');
      expect(s.res, 9);
      expect(s.lat, 39.96);
      expect(s.lon, -82.99);
      expect(s.label, 'Home');
      expect(s.from, 'map');
      expect(s.z, isNull);
      expect(s.effectiveZoom, MapViewState.defaultZoom);
    });

    test('the hub, www and a trailing slash', () {
      expect(p('https://meshsonar.com/coverage')!.region, isNull);
      expect(p('https://www.meshsonar.com/coverage/')!.region, isNull);
      expect(p('https://DAY.meshsonar.com/coverage?show=network')!.region, 'day');
    });

    test('links that are not a coverage view are null', () {
      expect(p('https://cmh.meshsonar.com/repeaters'), isNull);
      expect(p('https://evil.example/coverage?show=measured'), isNull);
      expect(p('https://meshsonar.com.evil.example/coverage'), isNull);
      expect(p('https://a.b.meshsonar.com/coverage'), isNull);
      expect(p('https://tiles.meshsonar.com/coverage'), isNull);
      expect(p('ftp://meshsonar.com/coverage'), isNull);
      expect(p('meshsonar://settings'), isNull);
      expect(p('mailto:x@meshsonar.com'), isNull);
    });

    test('show: unknown keys dropped, order canonical, empty kept, all-unknown dropped', () {
      expect(p('https://meshsonar.com/coverage?show=observers,bogus,measured,measured')!.show, ['measured', 'observers']);
      expect(p('https://meshsonar.com/coverage?show=')!.show, isEmpty);
      expect(p('https://meshsonar.com/coverage?show=bogus,zzz')!.show, isNull, reason: 'website: nothing valid and not empty');
      expect(p('https://meshsonar.com/coverage')!.show, isNull);
      expect(p('https://meshsonar.com/coverage?show=network,model,reach')!.show, ['model', 'reach', 'network']);
      expect(p('meshsonar://map?show=pings,measured,hexes')!.show, ['measured', 'hexes', 'pings']);
    });

    test('color: observer reads as snr, garbage dropped', () {
      expect(p('https://meshsonar.com/coverage?color=observer')!.color, 'snr');
      expect(p('https://meshsonar.com/coverage?color=heard')!.color, 'heard');
      expect(p('https://meshsonar.com/coverage?color=red')!.color, isNull);
    });

    test('since, src, res, from: only the website values', () {
      final bad = p('https://meshsonar.com/coverage?since=2d&src=corescope&res=12&from=gps')!;
      expect([bad.since, bad.src, bad.res, bad.from], [null, null, null, null]);
      expect(p('https://meshsonar.com/coverage?res=7')!.res, 7);
      expect(p('https://meshsonar.com/coverage?res=11')!.res, 11);
      expect(p('https://meshsonar.com/coverage?res=6')!.res, isNull);
      expect(p('https://meshsonar.com/coverage?res=9.5')!.res, isNull);
      expect(p('https://meshsonar.com/coverage?res=%20')!.res, isNull);
      expect(p('https://meshsonar.com/coverage?since=1h&src=meshmapper')!.src, 'meshmapper');
    });

    test('lat/lon: both or neither, in range, finite', () {
      expect(p('https://meshsonar.com/coverage?lat=39.9')!.hasPosition, isFalse);
      expect(p('https://meshsonar.com/coverage?lon=-83')!.hasPosition, isFalse);
      expect(p('https://meshsonar.com/coverage?lat=91&lon=0')!.hasPosition, isFalse);
      expect(p('https://meshsonar.com/coverage?lat=0&lon=-181')!.hasPosition, isFalse);
      expect(p('https://meshsonar.com/coverage?lat=NaN&lon=1')!.hasPosition, isFalse);
      expect(p('https://meshsonar.com/coverage?lat=Infinity&lon=1')!.hasPosition, isFalse);
      expect(p('https://meshsonar.com/coverage?lat=abc&lon=1')!.hasPosition, isFalse);
      final ok = p('https://meshsonar.com/coverage?lat=%2039.123456789%20&lon=-82.987654321')!;
      expect(ok.lat, 39.12346, reason: 'rounded to 5 decimals');
      expect(ok.lon, -82.98765);
    });

    test('label: trimmed, 1..160 chars', () {
      expect(p('https://meshsonar.com/coverage?label=%20%20Tower%20%20')!.label, 'Tower');
      expect(p('https://meshsonar.com/coverage?label=%20')!.label, isNull);
      expect(p('https://meshsonar.com/coverage?label=${'x' * 161}')!.label, isNull);
      expect(p('https://meshsonar.com/coverage?label=${'x' * 160}')!.label, hasLength(160));
    });
  });

  group('app additions', () {
    test('z is clamped to 3..18 and rounded; non-numbers dropped', () {
      expect(p('meshsonar://map?z=1')!.z, 3);
      expect(p('meshsonar://map?z=25')!.z, 18);
      expect(p('meshsonar://map?z=12.3456')!.z, 12.35);
      expect(p('meshsonar://map?z=far')!.z, isNull);
      expect(p('meshsonar://map?z=12')!.effectiveZoom, 12);
      expect(p('meshsonar://map')!.effectiveZoom, isNull);
    });

    test('until: a real YYYY-MM-DD date only', () {
      expect(p('meshsonar://map?until=2026-10-21')!.until, DateTime.utc(2026, 10, 21));
      expect(p('meshsonar://map?until=2026-02-30')!.until, isNull);
      expect(p('meshsonar://map?until=2026-13-01')!.until, isNull);
      expect(p('meshsonar://map?until=21-10-2026')!.until, isNull);
      expect(p('meshsonar://map?until=2026-10-21T00:00:00Z')!.until, isNull);
      expect(p('meshsonar://map?until=2024-02-29')!.until, DateTime.utc(2024, 2, 29));
    });

    test('meshsonar:// takes region= (validated); https ignores region= (the host says)', () {
      expect(p('meshsonar://map?region=CMH')!.region, 'cmh');
      expect(p('meshsonar://map?region=../etc')!.region, isNull);
      expect(p('meshsonar://map?region=www')!.region, isNull);
      expect(p('https://meshsonar.com/coverage?region=cmh')!.region, isNull);
      expect(p('meshsonar:/map?region=cmh')!.region, 'cmh', reason: 'path form');
      expect(p('MESHSONAR://MAP?z=4')!.z, 4);
    });
  });

  group('round trips', () {
    final full = MapViewState(
      region: 'cmh',
      show: const ['measured', 'repeaters', 'network', 'hexes', 'pings'],
      color: 'heard',
      since: '24h',
      src: 'meshmapper',
      res: 10,
      lat: 39.96805,
      lon: -82.99626,
      z: 11.5,
      until: DateTime.utc(2026, 10, 21),
      label: 'Downtown & river',
      from: 'rep',
    );

    test('app link: fromUri(toUri(s)) == s', () {
      final u = full.toUri(web: false);
      expect(u.scheme, 'meshsonar');
      expect(u.host, 'map');
      expect(MapViewState.fromUri(u), full);
      expect(MapViewState.fromUri(Uri.parse(u.toString())), full, reason: 'through text');
    });

    test('web link: region from the host, app-only layers left out, the rest equal', () {
      final u = full.toUri(web: true);
      expect(u.toString(), startsWith('https://cmh.meshsonar.com/coverage?'));
      expect(u.queryParameters['show'], 'measured,repeaters,network');
      expect(u.queryParameters.containsKey('region'), isFalse);
      final back = MapViewState.fromUri(Uri.parse(u.toString()))!;
      expect(back, full.copyWith(show: const ['measured', 'repeaters', 'network']));
    });

    test('the two transports carry the same view', () {
      final web = MapViewState.fromUri(full.toUri(web: true))!;
      final app = MapViewState.fromUri(full.copyWith(show: const ['measured', 'repeaters', 'network']).toUri(web: false))!;
      expect(web, app);
    });

    test('empty state round-trips, and the hub link has no query', () {
      expect(MapViewState.empty.toUri(web: true).toString(), 'https://meshsonar.com/coverage');
      expect(MapViewState.empty.toUri(web: false).toString(), 'meshsonar://map');
      expect(MapViewState.fromUri(MapViewState.empty.toUri(web: false)), MapViewState.empty);
      expect(MapViewState.fromUri(MapViewState.empty.toUri(web: true)), MapViewState.empty);
    });

    test('explicitly empty show survives', () {
      const s = MapViewState(show: []);
      expect(s.toUri(web: true).query, 'show=');
      expect(MapViewState.fromUri(s.toUri(web: true)), s);
    });

    test('numbers are written short: trailing zeros trimmed', () {
      const s = MapViewState(lat: 40, lon: -83.5, z: 12);
      expect(s.toUri(web: false).query, 'lat=40&lon=-83.5&z=12');
    });

    test('fromCamera rounds so the link text is stable, and re-parsing changes nothing', () {
      final s = MapViewState.fromCamera(lat: 39.968051234, lon: -82.996261234, zoom: 12.34567, region: 'cmh', show: const ['measured']);
      expect(s.lat, 39.96805);
      expect(s.lon, -82.99626);
      expect(s.z, 12.35);
      expect(MapViewState.fromUri(s.toUri(web: false)), s);
      final again = MapViewState.fromUri(s.toUri(web: false))!.toUri(web: false);
      expect(again, s.toUri(web: false));
    });

    test('website-produced links survive app -> web unchanged in meaning', () {
      const link = 'https://cmh.meshsonar.com/coverage?show=measured,observers&color=snr&since=1h&res=8&lat=39.9&lon=-83';
      final s = p(link)!;
      final out = s.toUri(web: true);
      expect(out.queryParameters, Uri.parse(link).queryParameters);
    });
  });

  group('garbage input never throws', () {
    test('odd and hostile query strings', () {
      for (final u in [
        'meshsonar://map?show=%00&color=%ff&z=--1',
        'meshsonar://map?lat=1e400&lon=1e400',
        'meshsonar://map?res=9&res=10',
        'meshsonar://map?show=${List.filled(5000, 'measured').join(',')}',
        'meshsonar://map?until=9999-99-99&since=&src=&from=',
        'https://meshsonar.com/coverage?&&&=&show',
        'meshsonar://map#fragment',
      ]) {
        expect(() => MapViewState.fromUri(Uri.parse(u)), returnsNormally, reason: u);
      }
      expect(p('meshsonar://map?lat=1e400&lon=1e400')!.hasPosition, isFalse);
      expect(p('meshsonar://map?res=9&res=10')!.res, 9, reason: 'first value wins, like URLSearchParams.get');
      expect(p('meshsonar://map?show=%00&color=%ff&z=--1'), MapViewState.empty);
      expect(p('meshsonar://map?label=%zz&z=5')!.z, 5, reason: 'a bad escape loses only its own parameter');
      expect(p('meshsonar://map?show=${List.filled(5000, 'measured').join(',')}')!.show, ['measured']);
    });

    test('fromParameters with an empty map is the empty state', () {
      expect(MapViewState.fromParameters(const {}), MapViewState.empty);
    });

    test('equality and hashCode', () {
      final a = p('meshsonar://map?show=measured&z=4')!, b = p('meshsonar://map?z=4&show=measured')!;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(p('meshsonar://map?show=measured&z=5')));
    });
  });
}
