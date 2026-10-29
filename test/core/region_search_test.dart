import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_search.dart';

import '../support/regions_559.dart';

RegionIndexEntry r(String code, String name) => RegionIndexEntry(code: code, slug: code.toLowerCase(), name: name, url: 'https://x');

void main() {
  test('foldForSearch drops accents and case, joins dashes, keeps plain text', () {
    expect(foldForSearch('Düsseldorf'), 'dusseldorf');
    expect(foldForSearch('Chișinău'), 'chisinau');
    expect(foldForSearch('Gävleborgs län'), 'gavleborgs lan');
    expect(foldForSearch('Ottawa–Gatineau'), 'ottawa gatineau');
    expect(foldForSearch('São Paulo'), 'sao paulo');
    expect(foldForSearch('Łódź'), 'lodz');
    expect(foldForSearch('Åre'), 'are');
    expect(foldForSearch('Straße'), 'strasse');
    expect(foldForSearch('Lillestrøm'), 'lillestrom');
    expect(foldForSearch('  Columbus  '), 'columbus');
  });

  test('country code and short name come from the part after the last comma', () {
    expect(countryCodeOf(r('AAH', 'Aachen, DE')), 'DE');
    expect(countryCodeOf(r('X', 'Cebu & Bohol, PH')), 'PH');
    expect(countryCodeOf(r('X', 'Nowhere')), isNull);
    expect(countryCodeOf(r('X', 'Primorsko-goranska županija & Istarska županija, HR')), 'HR');
    expect(shortNameOf(r('AAH', 'Aachen, DE')), 'Aachen');
    expect(countryLabel('DE'), 'Germany');
    expect(countryLabel('ZZ'), 'ZZ', reason: 'an unknown code is shown, not guessed');
    expect(countryLabel(null), 'Other');
  });

  test('the server\'s country wins; only a server that says nothing falls back to the name suffix', () {
    // stated: code and English name from the server, the suffix is cut only when it is that code
    const de = RegionIndexEntry(code: 'AAH', slug: 'aah', name: 'Aachen, DE', url: 'https://x', country: 'Germany', countryCode: 'DE');
    expect(countryCodeOf(de), 'DE');
    expect(countryLabelOf(de), 'Germany');
    expect(shortNameOf(de), 'Aachen');
    // the server says a different country than the name's tail: the server is believed, the name is left whole
    const odd = RegionIndexEntry(code: 'ZBE', slug: 'zbe', name: 'Zabreh, PL', url: 'https://x', country: 'Czechia', countryCode: 'CZ');
    expect(countryCodeOf(odd), 'CZ');
    expect(shortNameOf(odd), 'Zabreh, PL');
    // a country the fallback table does not know: the server's name is shown
    const tw = RegionIndexEntry(code: 'TPE', slug: 'tpe', name: 'Taipei, TW', url: 'https://x', country: 'Taiwan', countryCode: 'TW');
    expect(countryLabelOf(tw), 'Taiwan');
    // the server knows nothing about the country: no country, not the name's tail
    const none = RegionIndexEntry(code: 'NEW', slug: 'new', name: 'Somewhere, DE', url: 'https://x', countryReported: true);
    expect(countryCodeOf(none), isNull);
    expect(countryLabelOf(none), 'Other');
    expect(shortNameOf(none), 'Somewhere, DE');
    // an older server: the name's tail, as before
    expect(countryCodeOf(r('AAH', 'Aachen, DE')), 'DE');
    expect(countryLabelOf(r('AAH', 'Aachen, DE')), 'Germany');
  });

  test('grouping and search use the stated country', () {
    const list = [
      RegionIndexEntry(code: 'TPE', slug: 'tpe', name: 'Taipei, TW', url: 'https://x', country: 'Taiwan', countryCode: 'TW'),
      RegionIndexEntry(code: 'AAH', slug: 'aah', name: 'Aachen, DE', url: 'https://x', country: 'Germany', countryCode: 'DE'),
      RegionIndexEntry(code: 'NEW', slug: 'new', name: 'Somewhere', url: 'https://x', countryReported: true),
    ];
    final g = groupByCountry(list);
    expect(g.map((c) => c.label), ['Germany', 'Taiwan', 'Other']);
    expect(RegionSearchIndex.of(list).search('taiwan').map((x) => x.code), ['TPE']);
    expect(RegionSearchIndex.of(list).search('germany').map((x) => x.code), ['AAH']);
  });

  final idx = [
    r('DUS', 'Düsseldorf, DE'),
    r('AAH', 'Aachen, DE'),
    r('CMH', 'Columbus, US'),
    r('CVG', 'Cincinnati, US'),
    r('KIV', 'Chișinău, MD'),
    r('GVL', 'Gävleborgs län, SE'),
    r('SAO', 'São Paulo, BR'),
    r('YOW', 'Ottawa–Gatineau, CA'),
    r('COL', 'Colorado Springs, US'),
  ];

  test('search finds accented names from plain letters and the other way round', () {
    final s = RegionSearchIndex.of(idx);
    expect(s.search('dusseldorf').map((x) => x.code), ['DUS']);
    expect(s.search('DÜSS').map((x) => x.code), ['DUS']);
    expect(s.search('chisinau').map((x) => x.code), ['KIV']);
    expect(s.search('gavle').map((x) => x.code), ['GVL']);
    expect(s.search('sao paulo').map((x) => x.code), ['SAO']);
    expect(s.search('ottawa gatineau').map((x) => x.code), ['YOW']);
    expect(s.search('gatineau').map((x) => x.code), ['YOW']);
  });

  test('ranking: exact code first, then name prefix, then word prefix; ties by name', () {
    final s = RegionSearchIndex.of(idx);
    expect(s.search('cmh').first.code, 'CMH');
    expect(s.search('col').map((x) => x.code).take(2), ['COL', 'CMH'], reason: 'COL is an exact code, Columbus a name prefix');
    expect(s.search('c').map((x) => x.code), containsAll(['CMH', 'CVG', 'KIV', 'COL']));
    expect(s.search('paulo').map((x) => x.code), ['SAO'], reason: 'a word of the name');
  });

  test('country name and code match; every term must match', () {
    final s = RegionSearchIndex.of(idx);
    expect(s.search('germany').map((x) => x.code).toSet(), {'DUS', 'AAH'});
    expect(s.search('de').map((x) => x.code), contains('AAH'));
    expect(s.search('columbus us').map((x) => x.code), ['CMH']);
    expect(s.search('columbus de'), isEmpty);
    expect(s.search('zzzz'), isEmpty);
    expect(s.search('   ').length, idx.length, reason: 'a blank query lists everything in the original order');
  });

  test('groupByCountry: countries by name, regions kept in the order given, no-country last', () {
    final g = groupByCountry([...idx, r('NOW', 'Nowhere')]);
    expect(g.map((x) => x.label), ['Brazil', 'Canada', 'Germany', 'Moldova', 'Sweden', 'United States', 'Other']);
    expect(g.firstWhere((x) => x.code == 'US').regions.map((x) => x.code), ['CMH', 'CVG', 'COL']);
  });

  test('559 regions: building the search index and 100 queries are fast, the index is remembered per list', () {
    final big = syntheticIndex559();
    final sw = Stopwatch()..start();
    final s = RegionSearchIndex.of(big);
    expect(identical(s, RegionSearchIndex.of(big)), isTrue);
    for (final q in ['du', 'sao', 'columbus', 'germany', 'zz', 'a', 'ottawa gat', 'lodz', 'us', 'ber']) {
      for (var i = 0; i < 10; i++) {
        s.search(q);
      }
    }
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(1500), reason: '${sw.elapsedMilliseconds} ms');
    expect(s.search('düsseldorf').isNotEmpty, isTrue);
    expect(s.search('dusseldorf').length, s.search('DÜSSELDORF').length);
  });
}
