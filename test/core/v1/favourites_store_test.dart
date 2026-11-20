// The favourites and watch store (AZ-3.4): stars persist to the file and back, node keys are normalised, watches keep
// the contract's Watch shape (PUT path and body for the later sync), the 25-watch limit, events limited per kind, a
// damaged file starts empty, and My nodes matches hop prefixes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/v1/favourites_store.dart';

const k1 = '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c';
const k2 = '3cd0c95448b8566d21060bfec77f420446b1122cb903ec140fe946603dbdfbd4';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('favs'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('stars persist, are case-normalised for nodes and kept per kind', () async {
    final f = File('${dir.path}/network_favourites.json');
    final a = NetworkFavouritesStore(file: f, clock: () => DateTime.utc(2026, 11, 20));
    var calls = 0;
    a.addListener(() => calls++);
    expect(await a.toggleFavourite(FavouriteKind.node, k1.toUpperCase(), name: 'Hilltop RPT', region: 'cmh'), isTrue);
    expect(await a.toggleFavourite(FavouriteKind.observer, 'src_31:obs-1142'), isTrue);
    expect(a.isFavourite(FavouriteKind.node, k1), isTrue);
    expect(a.isFavourite(FavouriteKind.observer, k1), isFalse);
    expect(calls, greaterThanOrEqualTo(2));

    final b = NetworkFavouritesStore(file: f);
    await b.load();
    expect(b.favouriteNodeKeys, {k1});
    expect(b.favouriteObserverIds, {'src_31:obs-1142'});
    expect(b.favourites.firstWhere((e) => e.kind == FavouriteKind.node).name, 'Hilltop RPT');

    expect(await b.toggleFavourite(FavouriteKind.node, k1), isFalse);
    final c = NetworkFavouritesStore(file: f);
    await c.load();
    expect(c.favouriteNodeKeys, isEmpty);
  });

  test('a watch has the contract Watch shape and the PUT path and body for me/watches', () async {
    final f = File('${dir.path}/w.json');
    final s = NetworkFavouritesStore(file: f, clock: () => DateTime.utc(2026, 11, 20, 14));
    final w = await s.setWatch('node', k1.toUpperCase(), region: 'cmh', name: 'Hilltop RPT', events: ['silent', 'bogus']);
    expect(w.target, k1);
    expect(w.events, ['silent']);
    expect(w.channels, ['push']);
    expect(w.state, 'local');
    expect(w.putPath, 'me/watches/node/$k1');
    expect(w.putBody, {'events': ['silent'], 'channels': ['push'], 'region': 'cmh'});
    final o = await s.setWatch('observer', 'src_31:obs-1142');
    expect(o.events, ['observer_offline']);
    expect(o.putPath, 'me/watches/observer/src_31%3Aobs-1142');

    final j = jsonDecode(f.readAsStringSync()) as Map;
    final first = (j['watches'] as List).firstWhere((e) => e['kind'] == 'node') as Map;
    expect(first.keys, containsAll(['kind', 'target', 'region', 'events', 'channels', 'createdAt', 'state']));

    final t = NetworkFavouritesStore(file: f);
    await t.load();
    expect(t.isWatched('node', k1), isTrue);
    await t.removeWatch('node', k1);
    expect(t.isWatched('node', k1), isFalse);
    expect(t.isWatched('observer', 'src_31:obs-1142'), isTrue);
  });

  test('the 25-watch limit and unknown kinds', () async {
    final s = NetworkFavouritesStore();
    for (var i = 0; i < maxLocalWatches; i++) {
      await s.setWatch('region', 'r$i');
    }
    expect(() => s.setWatch('region', 'one-more'), throwsStateError);
    // replacing an existing watch is fine at the limit
    await s.setWatch('region', 'r3', events: ['pulse']);
    expect(() => s.setWatch('planet', 'x'), throwsArgumentError);
  });

  test('a damaged file starts empty', () async {
    final f = File('${dir.path}/bad.json')..writeAsStringSync('{not json');
    final s = NetworkFavouritesStore(file: f);
    await s.load();
    expect(s.favourites, isEmpty);
    expect(s.watches, isEmpty);
  });

  test('My nodes matches keys and hop prefixes of my keys', () {
    const m = MyNodes(keys: {k1, k2}, observerIds: {'x'});
    expect(m.hasKey(k1.toUpperCase()), isTrue);
    expect(m.matchesPrefix('4f'), isTrue);
    expect(m.matchesPrefix('3CD0'), isTrue);
    expect(m.matchesPrefix('a7'), isFalse);
    expect(m.matchesPrefix(''), isFalse);
    expect(MyNodes.empty.isEmpty, isTrue);
  });
}
