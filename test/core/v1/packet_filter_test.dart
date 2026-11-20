// The Packets filters (AZ-3.2): the filter language (contract section 10) parses, prints back canonically and
// round-trips; mistakes carry their character position and a suggestion; every filter maps to its `/v1/packets`
// parameter; today's region read gets what it can take and names the rest; a link restores the sheet's controls;
// saved filters keep everything.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/v1/packets_api.dart';
import 'package:meshsonar/core/v1/saved_packet_filters.dart';

const key = '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c';

void main() {
  group('filter language', () {
    final catalogue = FilterCatalogue.fromJson((jsonDecode(File('test/fixtures/analyzer/filter-fields.json').readAsStringSync()) as Map)['data']);

    test('the contract catalogue parses and matches the built-in copy', () {
      expect(catalogue.maxLength, 512);
      expect(catalogue.maxClauses, 16);
      expect([for (final f in catalogue.fields) f.name], [for (final f in FilterCatalogue.builtin.fields) f.name]);
      expect(catalogue.field('type')!.aliases['msg'], 'TXT_MSG');
    });

    test('every example of the catalogue parses and round-trips', () {
      for (final ex in catalogue.examples) {
        final n = parseFilter(ex, catalogue: catalogue)!;
        final printed = n.print();
        expect(parseFilter(printed, catalogue: catalogue), n, reason: ex);
        expect(canonicalFilter(printed, catalogue: catalogue), printed, reason: 'canonical print is stable: $ex');
      }
    });

    test('precedence: and binds tighter than or; not and parentheses', () {
      final n = parseFilter('type = ADVERT or type = TRACE and hops >= 3')!;
      expect(n, isA<FilterOr>());
      expect((n as FilterOr).children.last, isA<FilterAnd>());
      expect(canonicalFilter('(type = ADVERT OR type = TRACE) AND hops >= 3'), '(type = ADVERT or type = TRACE) and hops >= 3');
      expect(canonicalFilter('not (snr < -5 or rssi < -120)'), 'not (snr < -5 or rssi < -120)');
      expect(canonicalFilter('NOT channel = public'), 'not channel = public');
      expect(canonicalFilter('route not in (DIRECT,TRANSPORT_DIRECT)'), 'route not in (DIRECT, TRANSPORT_DIRECT)');
      expect(canonicalFilter('payload.text ~ "hilltop \\"north\\""'), 'payload.text ~ "hilltop \\"north\\""');
      expect(canonicalFilter('age < 15m and snr>-5.5'), 'age < 15m and snr > -5.5');
      expect(canonicalFilter('observer = src_31:obs-1142'), 'observer = src_31:obs-1142');
      expect(parseFilter('   '), isNull);
    });

    test('mistakes say where and what', () {
      FilterError err(String s) => filterError(s)!;
      expect(err('tpye = ADVERT').suggestion, 'type');
      expect(err('tpye = ADVERT').at, 0);
      expect(err('type = ADVERT and').message, contains('missing at the end'));
      expect(err('type = ADVERT and').at, 17);
      expect(err('hops >= many').message, contains('needs a number'));
      expect(err('hops >= 2.5').message, contains('whole number'));
      expect(err('type = BOGUS').message, contains('not a value'));
      expect(err('age < 15').message, contains('duration'));
      expect(err('snr ~ 3').message, contains('"~"'));
      expect(err('(type = ADVERT').message, contains('")"'));
      expect(err('type = "open').message, contains('not closed'));
      expect(err('type = ADVERT hops = 2').message, contains('join clauses'));
      expect(err('x' * 513).message, contains('512'));
      expect(err(List.filled(17, 'hops = 1').join(' and ')).message, contains('16 clauses'));
      expect(filterError('type = msg'), isNull, reason: 'aliases are values');
      expect(filterError('TYPE = advert'), isNull, reason: 'case-insensitive');
    });

    test('suggestions follow the cursor', () {
      List<String> s(String t) => filterSuggestions(t, t.length).words;
      expect(s(''), containsAll(['type', 'route', 'hops', 'not']));
      expect(s('ty'), ['type']);
      expect(s('type '), containsAll(['=', '!=', 'in']));
      expect(s('type = '), contains('ADVERT'));
      expect(s('type = AD'), ['ADVERT']);
      expect(s('route in (FLOOD, '), contains('DIRECT'));
      expect(s('type = ADVERT '), ['and', 'or']);
      expect(s('type = ADVERT and pay'), containsAll(['payload.name', 'payload.text']));
      expect(s('channel = '), contains('public'));
      expect(filterSuggestions('type = AD', 9).partial, 'AD');
    });
  });

  group('PacketFilter -> /v1/packets parameters', () {
    test('every filter maps to its contract parameter', () {
      expect(const PacketFilter(types: {'GRP_TXT', 'ADVERT'}).toV1Query(), {'type': 'ADVERT,GRP_TXT'});
      expect(const PacketFilter(routes: {'FLOOD'}).toV1Query(), {'route': 'FLOOD'});
      expect(const PacketFilter(observers: ['src_12:7e', 'd1a7']).toV1Query(), {'observer': 'src_12:7e,d1a7'});
      expect(const PacketFilter(nodes: [key]).toV1Query(), {'node': key});
      expect(const PacketFilter(hash: 'c4b06ee8').toV1Query(), {'hash': 'c4b06ee8'});
      expect(const PacketFilter(channels: {'public', 'tag:wardriving'}).toV1Query(), {'channel': 'public,tag:wardriving'});
      expect(const PacketFilter(scope: '#cmh').toV1Query(), {'scope': '#cmh'});
      expect(const PacketFilter(source: PacketSourceFilter.ours).toV1Query(), {'source': 'meshsonar,meshsonar-phone'});
      expect(const PacketFilter(source: PacketSourceFilter.outside).toV1Query(), {'filter': 'source not in (meshsonar, meshsonar-phone)'});
      expect(const PacketFilter(hopsMin: 2).toV1Query(), {'filter': 'hops >= 2'});
      expect(const PacketFilter(hopsMax: 4).toV1Query(), {'filter': 'hops <= 4'});
      expect(const PacketFilter(hopsMin: 2, hopsMax: 4).toV1Query(), {'filter': 'hops between 2 and 4'});
      expect(const PacketFilter(snrMin: -5, snrMax: 0.5).toV1Query(), {'filter': 'snr between -5 and 0.5'});
      expect(const PacketFilter(snrMin: -5).toV1Query(), {'filter': 'snr >= -5'});
      expect(const PacketFilter(prefix: 'a7').toV1Query(), {'filter': 'hop ~ a7'});
      expect(const PacketFilter(text: 'type = ADVERT or type = TRACE', hopsMin: 1).toV1Query(), {'filter': '(type = ADVERT or type = TRACE) and hops >= 1'});
      expect(PacketFilter.none.toV1Query(), isEmpty);
      final twentyFive = List.generate(25, (i) => i.toRadixString(16).padLeft(64, '0'));
      expect(PacketFilter(nodes: twentyFive).toV1Query()['node']!.split(',').length, 20, reason: 'at most 20 (contract 8.2)');
    });

    test('a link round-trips, the sheet controls come back out of `filter`', () {
      final all = PacketFilter(
        types: const {'ADVERT', 'TRACE'},
        routes: const {'FLOOD'},
        observers: const ['src_12:7e9e'],
        nodes: const [key],
        prefix: '3cd0',
        hash: 'c4b06ee8fc',
        channels: const {'public'},
        scope: '#cmh',
        source: PacketSourceFilter.outside,
        hopsMin: 1,
        hopsMax: 5,
        snrMin: -7.5,
        snrMax: 3,
        text: 'payload.role = repeater or payload.role = room',
      );
      final back = PacketFilter.fromQuery(all.toQuery());
      expect(back, all);
      expect(PacketFilter.fromQuery(back.toQuery()), back);
      // Each single filter on its own.
      for (final f in [
        const PacketFilter(types: {'GRP_TXT'}),
        const PacketFilter(source: PacketSourceFilter.ours),
        const PacketFilter(hopsMin: 3),
        const PacketFilter(snrMax: -2),
        const PacketFilter(text: 'channel = public and age < 1h'),
      ]) {
        expect(PacketFilter.fromQuery(f.toQuery()), f, reason: '$f');
      }
    });

    test('bad link values are dropped, not trusted', () {
      final f = PacketFilter.fromQuery({'type': 'ADVERT,BOGUS', 'node': 'xyz', 'hash': 'zz', 'channel': 'nope', 'scope': 'bad scope', 'route': '1'});
      expect(f.types, {'ADVERT'});
      expect(f.nodes, isEmpty);
      expect(f.hash, isNull);
      expect(f.channels, isEmpty);
      expect(f.scope, isNull);
      expect(f.routes, {'FLOOD'}, reason: 'route numbers are read as names');
      expect(PacketFilter.fromQuery({'filter': 'tpye = x'}).text, 'tpye = x', reason: 'a broken filter string is kept as text for the person to fix');
    });

    test("today's region read: what it can take, what the phone filters, what it cannot", () {
      final one = const PacketFilter(types: {'ADVERT'}, routes: {'FLOOD'}, nodes: [key], hash: 'c4b06ee8fc39b187', observers: ['d1a761a8']).toLegacy();
      expect(one.query, {'type': '4', 'route': '1', 'node': key, 'hash': 'c4b06ee8fc39b187', 'observer': 'd1a761a8'});
      expect(one.unapplied, isEmpty);
      final many = const PacketFilter(types: {'ADVERT', 'TRACE'}, channels: {'public'}, scope: '#cmh', source: PacketSourceFilter.ours, text: 'hops > 1', observers: ['src_12:7e'], prefix: 'a7', hopsMin: 2, snrMin: 0, hash: 'c4b0').toLegacy();
      expect(many.query, isEmpty);
      expect(many.unapplied, ['observer', 'channel', 'scope', 'node prefix', 'source', 'filter text']);
      PacketListRow row(int type, {int hops = 3, double? snr = 1, String hash = 'c4b06ee8fc39b187'}) =>
          PacketListRow(hash: hash, firstSeen: DateTime.utc(2026), lastSeen: DateTime.utc(2026), type: type, typeName: packetTypeWireName(type), route: 'FLOOD', hops: hops, bestSnr: snr);
      expect(many.keep(row(4)), isTrue);
      expect(many.keep(row(5)), isFalse, reason: 'several types are filtered on the phone');
      expect(many.keep(row(4, hops: 1)), isFalse);
      expect(many.keep(row(4, snr: -3)), isFalse);
      expect(many.keep(row(4, snr: null)), isFalse);
      expect(many.keep(row(4, hash: 'ffff000000000000')), isFalse, reason: 'hash prefix on the phone');
    });

    test('chips list every active filter and remove one at a time', () {
      const f = PacketFilter(types: {'ADVERT'}, channels: {'tag:wardriving'}, hopsMin: 2, source: PacketSourceFilter.ours, text: 'age < 1h');
      expect([for (final c in f.chips) c.label], ['Advert', '#wardriving', 'Our observers', 'Hops 2+', 'age < 1h']);
      var g = f;
      for (final c in f.chips) {
        g = g.without(c.id);
      }
      expect(g.isEmpty, isTrue);
      expect(f.without('type:ADVERT').types, isEmpty);
    });

    test('saved filters keep every field and live in a file', () async {
      const f = PacketFilter(types: {'TRACE'}, snrMin: -2.5, observers: ['src_31:obs-1142'], text: 'hop ~ a7');
      expect(PacketFilter.fromJson(jsonDecode(jsonEncode(f.toJson()))), f);
      final dir = await Directory.systemTemp.createTemp('saved_filters');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/saved_packet_filters.json');
      final a = SavedPacketFilterStore(file: file);
      await a.save(SavedPacketFilter('Traces', f, window: '24h'));
      await a.save(const SavedPacketFilter('Public', PacketFilter(channels: {'public'})));
      await a.save(SavedPacketFilter('traces', f.copyWith(hopsMin: 1)));
      final b = SavedPacketFilterStore(file: file);
      final items = await b.load();
      expect([for (final s in items) s.name], ['traces', 'Public'], reason: 'same name replaces, newest first');
      expect(items.first.filter.hopsMin, 1);
      await b.remove('Public');
      expect((await SavedPacketFilterStore(file: file).load()).length, 1);
    });
  });
}
