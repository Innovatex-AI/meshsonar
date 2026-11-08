// Saved radios store (CR6): migration from the single last_radio.json of 0.27, add/update on connect, forget, nickname,
// star (follows the most recent radio unless pinned), the deliberate-release hold, ordering, and the file surviving a restart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/saved_radios_store.dart';

void main() {
  late Directory dir;
  var now = DateTime(2026, 11, 7, 12);
  DateTime clock() => now;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('savedradios');
    now = DateTime(2026, 11, 7, 12);
  });
  tearDown(() => dir.delete(recursive: true));

  File f(String name) => File('${dir.path}/$name');
  SavedRadiosStore open() => SavedRadiosStore(file: f('saved_radios.json'), legacyFile: f('last_radio.json'), clock: clock);

  group('migration from last_radio.json', () {
    test('the remembered radio becomes the first entry, starred, with the file time; the old file stays', () async {
      final old = f('last_radio.json')..writeAsStringSync(jsonEncode({'id': 'aa:bb', 'name': 'Truck', 'key': 'ABCDEF'}));
      final t = DateTime(2026, 11, 1, 8, 30);
      old.setLastModifiedSync(t);
      final s = open();
      await s.load();
      expect(s.radios, hasLength(1));
      final r = s.radios.single;
      expect(r.id, 'aa:bb');
      expect(r.name, 'Truck');
      expect(r.publicKeyHex, 'abcdef');
      expect(r.lastConnected?.difference(t).inSeconds.abs(), lessThan(2));
      expect(s.starredId, 'aa:bb');
      expect(s.starPinned, isFalse);
      expect(s.autoConnectTarget?.id, 'aa:bb', reason: 'auto-connect keeps working across the update');
      expect(old.existsSync(), isTrue, reason: 'kept, read only: no data loss');
      expect(jsonDecode(old.readAsStringSync())['id'], 'aa:bb');
      expect(f('saved_radios.json').existsSync(), isTrue);
    });

    test('runs once: a migrated radio that was forgotten does not come back on the next launch', () async {
      f('last_radio.json').writeAsStringSync(jsonEncode({'id': 'aa:bb', 'name': 'Truck'}));
      final a = open();
      await a.load();
      await a.forget('aa:bb');
      final b = open();
      await b.load();
      expect(b.radios, isEmpty);
    });

    test('no old file, or a damaged one: an empty list and no crash', () async {
      final a = open();
      await a.load();
      expect(a.radios, isEmpty);
      f('last_radio.json').writeAsStringSync('{broken');
      final b = SavedRadiosStore(file: f('other.json'), legacyFile: f('last_radio.json'));
      await b.load();
      expect(b.radios, isEmpty);
    });
  });

  group('connect, update, forget', () {
    test('a connect adds the radio with model, key and time; a second connect updates instead of duplicating', () async {
      final s = open();
      await s.recordConnect(id: 'aa:bb', name: 'Truck', publicKeyHex: 'AB12', model: 'Heltec V3');
      now = now.add(const Duration(hours: 2));
      await s.recordConnect(id: 'aa:bb', name: 'Truck 2', publicKeyHex: 'ab12');
      expect(s.radios, hasLength(1));
      final r = s.radios.single;
      expect(r.name, 'Truck 2');
      expect(r.model, 'Heltec V3', reason: 'a connect that does not report the model keeps the known one');
      expect(r.lastConnected, now);
    });

    test('the same public key at a new Bluetooth id is the same radio (nickname and star kept)', () async {
      final s = open();
      await s.recordConnect(id: 'old-uuid', name: 'Truck', publicKeyHex: 'ab12');
      await s.setNickname('old-uuid', 'My truck');
      await s.pinStar('old-uuid');
      await s.recordConnect(id: 'new-uuid', name: 'Truck', publicKeyHex: 'ab12');
      expect(s.radios.single.id, 'new-uuid');
      expect(s.radios.single.nickname, 'My truck');
      expect(s.starredId, 'new-uuid');
      expect(s.starPinned, isTrue);
    });

    test('the same Bluetooth id with another public key is a different radio: it replaces the old entry', () async {
      final s = open();
      await s.recordConnect(id: 'aa:bb', name: 'Old', publicKeyHex: '1111');
      await s.setNickname('aa:bb', 'Old one');
      await s.recordConnect(id: 'aa:bb', name: 'New', publicKeyHex: '2222');
      expect(s.radios, hasLength(1));
      expect(s.radios.single.name, 'New');
      expect(s.radios.single.nickname, isNull);
    });

    test('forget removes only that radio; a forgotten star moves to the most recent radio, unpinned', () async {
      final s = open();
      await s.recordConnect(id: 'a', name: 'A');
      now = now.add(const Duration(minutes: 1));
      await s.recordConnect(id: 'b', name: 'B');
      now = now.add(const Duration(minutes: 1));
      await s.recordConnect(id: 'c', name: 'C');
      await s.pinStar('a');
      await s.forget('a');
      expect(s.radios.map((r) => r.id), ['c', 'b']);
      expect(s.starredId, 'c');
      expect(s.starPinned, isFalse);
      await s.forget('missing');
      expect(s.radios, hasLength(2));
    });

    test('nickname: set, shown as the display name, cleared with an empty value', () async {
      final s = open();
      await s.recordConnect(id: 'a', name: 'MeshCore-1234');
      await s.setNickname('a', '  Truck  ');
      expect(s.radios.single.nickname, 'Truck');
      expect(s.radios.single.displayName, 'Truck');
      await s.setNickname('a', '');
      expect(s.radios.single.nickname, isNull);
      expect(s.radios.single.displayName, 'MeshCore-1234');
    });
  });

  group('star (auto-connect target)', () {
    test('by default it follows the most recently connected radio', () async {
      final s = open();
      await s.recordConnect(id: 'a', name: 'A');
      expect(s.starredId, 'a');
      now = now.add(const Duration(minutes: 1));
      await s.recordConnect(id: 'b', name: 'B');
      expect(s.starredId, 'b');
      expect(s.starPinned, isFalse);
    });

    test('a star the person chose stays put on later connects until they follow the most recent again', () async {
      final s = open();
      await s.recordConnect(id: 'a', name: 'A');
      now = now.add(const Duration(minutes: 1));
      await s.recordConnect(id: 'b', name: 'B');
      await s.pinStar('a');
      now = now.add(const Duration(minutes: 1));
      await s.recordConnect(id: 'b', name: 'B');
      expect(s.starredId, 'a');
      expect(s.autoConnectTarget?.id, 'a');
      await s.followMostRecent();
      expect(s.starredId, 'b');
      expect(s.starPinned, isFalse);
    });

    test('a deliberate release holds auto-connect without removing anything; the next connect lifts it', () async {
      final s = open();
      await s.recordConnect(id: 'a', name: 'A');
      await s.holdAutoConnect();
      expect(s.autoConnectHeld, isTrue);
      expect(s.autoConnectTarget, isNull);
      expect(s.starred?.id, 'a');
      expect(s.radios, hasLength(1));
      await s.recordConnect(id: 'a', name: 'A');
      expect(s.autoConnectHeld, isFalse);
      expect(s.autoConnectTarget?.id, 'a');
    });
  });

  test('ordering: starred first, then most recently connected, unknown times last by name', () async {
    final s = SavedRadiosStore(initial: [
      SavedRadio(id: 'old', name: 'Old', lastConnected: DateTime(2026, 1, 1)),
      const SavedRadio(id: 'z', name: 'Zed'),
      const SavedRadio(id: 'y', name: 'Yak'),
      SavedRadio(id: 'new', name: 'New', lastConnected: DateTime(2026, 11, 1)),
      SavedRadio(id: 'mid', name: 'Mid', lastConnected: DateTime(2026, 6, 1)),
    ]);
    expect(s.starredId, 'new', reason: 'without a saved star, the most recent radio');
    expect(s.radios.map((r) => r.id), ['new', 'mid', 'old', 'y', 'z']);
    await s.pinStar('old');
    expect(s.radios.map((r) => r.id), ['old', 'new', 'mid', 'y', 'z']);
  });

  test('everything survives a restart (list, nickname, model, pinned star, hold)', () async {
    final a = open();
    await a.recordConnect(id: 'a', name: 'A', publicKeyHex: 'aa', model: 'RAK4631');
    now = now.add(const Duration(minutes: 1));
    await a.recordConnect(id: 'b', name: 'B');
    await a.setNickname('a', 'Truck');
    await a.pinStar('a');
    await a.holdAutoConnect();
    final b = open();
    await b.load();
    expect(b.radios.map((r) => r.id), ['a', 'b']);
    expect(b.radios.first.nickname, 'Truck');
    expect(b.radios.first.model, 'RAK4631');
    expect(b.radios.first.publicKeyHex, 'aa');
    expect(b.radios.first.lastConnected, DateTime(2026, 11, 7, 12));
    expect(b.starredId, 'a');
    expect(b.starPinned, isTrue);
    expect(b.autoConnectHeld, isTrue);
    final j = jsonDecode(f('saved_radios.json').readAsStringSync()) as Map;
    expect(j['version'], 1);
    expect((j['radios'] as List).first, containsPair('nickname', 'Truck'));
  });

  test('a damaged saved_radios.json costs the list, not the app, and is not re-migrated', () async {
    f('saved_radios.json').writeAsStringSync('{nope');
    f('last_radio.json').writeAsStringSync(jsonEncode({'id': 'aa:bb', 'name': 'Truck'}));
    final s = open();
    await s.load();
    expect(s.radios, isEmpty);
    await s.recordConnect(id: 'c', name: 'C');
    expect(s.radios.single.id, 'c');
  });
}
