// Phone observer id (contract section 2): 32 lower hex, random per install, stable across launches, kept in the secure
// store, new after an erase, never derived from the person, the key or the radio.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/observer_identity.dart';

void main() {
  test('made once, stored, and the same on the next launch', () async {
    Uint8List? store;
    final writes = <Uint8List>[];
    ObserverIdentity launch() => ObserverIdentity(read: () async => store, write: (b) async {
          store = b;
          writes.add(b);
        });
    final a = await launch().load();
    expect(a, matches(observerIdRe));
    final b = await launch().load();
    expect(b, a, reason: 'stable across launches');
    expect(writes, hasLength(1));
  });

  test('two installs get different ids (random, not derived)', () async {
    final ids = {for (var i = 0; i < 20; i++) await ObserverIdentity.memory().load()};
    expect(ids, hasLength(20));
  });

  test('rotate makes a new id and stores it', () async {
    Uint8List? store;
    final id = ObserverIdentity(read: () async => store, write: (b) async => store = b);
    final a = await id.load();
    final b = await id.rotate();
    expect(b, isNot(a));
    expect(b, matches(observerIdRe));
    expect(await ObserverIdentity(read: () async => store, write: (_) async {}).load(), b);
  });

  test('a broken secure store still gives a random id for the run', () async {
    final id = ObserverIdentity(read: () async => throw StateError('locked'), write: (_) async => throw StateError('locked'));
    final a = await id.load();
    expect(a, matches(observerIdRe));
    expect(await id.load(), a);
  });

  test('a malformed stored value is replaced', () async {
    Uint8List? store = Uint8List.fromList([1, 2, 3]);
    final a = await ObserverIdentity(read: () async => store, write: (b) async => store = b).load();
    expect(a, matches(observerIdRe));
    expect(store, hasLength(16));
  });
}
