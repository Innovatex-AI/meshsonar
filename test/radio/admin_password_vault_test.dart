import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/radio/admin_password_vault.dart';

class _SpyStore extends InMemorySecretStore {
  final List<String> writes = [];
  @override
  Future<void> write(String ref, Uint8List secret) {
    writes.add(ref);
    return super.write(ref, secret);
  }
}

void main() {
  const key = 'ab';
  test('by default a password lives in memory only and there is no remember option without a store', () async {
    final v = AdminPasswordVault();
    expect(v.canRemember, isFalse);
    expect(await v.remembering(), isFalse);
    await v.keep(key, 'secret1');
    expect(await v.recall(key), 'secret1');
    expect(v.toString(), isNot(contains('secret1')));
    final fresh = AdminPasswordVault();
    expect(await fresh.recall(key), isNull, reason: 'a new run knows nothing');
  });

  test('with a store but the switch off (the default) nothing is written to it', () async {
    final s = _SpyStore();
    final v = AdminPasswordVault(store: s);
    expect(v.canRemember, isTrue);
    expect(await v.remembering(), isFalse);
    await v.keep(key, 'secret1');
    expect(s.writes, isEmpty);
    expect(s.length, 0);
  });

  test('turning remember on stores what is held and later runs recall it; turning it off deletes everything', () async {
    final s = _SpyStore();
    final v = AdminPasswordVault(store: s);
    await v.keep(key, 'secret1');
    await v.setRemember(true);
    expect(await v.remembering(), isTrue);
    expect(s.writes.where((r) => r.startsWith('admin.pw.')), hasLength(1));
    final stored = await s.read('admin.pw.$key');
    expect(utf8.decode(stored!), 'secret1');
    final next = AdminPasswordVault(store: s);
    expect(await next.remembering(), isTrue);
    expect(await next.recall(key), 'secret1');
    await next.setRemember(false, knownKeys: [key]);
    expect(await s.read('admin.pw.$key'), isNull);
    expect(await s.read('admin.remember'), isNull);
    expect(await AdminPasswordVault(store: s).recall(key), isNull);
  });

  test('forget removes one password everywhere', () async {
    final s = _SpyStore();
    final v = AdminPasswordVault(store: s);
    await v.setRemember(true);
    await v.keep(key, 'a');
    await v.keep('cd', 'b');
    await v.forget(key);
    expect(await v.recall(key), isNull);
    expect(await v.recall('cd'), 'b');
  });

  test('a store that throws never loses the in-memory password and never throws to the screen', () async {
    final v = AdminPasswordVault(store: _Broken());
    await v.keep(key, 'secret1');
    expect(await v.recall(key), 'secret1');
    await v.setRemember(true);
    await v.forget(key);
  });
}

class _Broken implements SecretStore {
  @override
  Future<Uint8List?> read(String ref) => throw StateError('no keychain');
  @override
  Future<void> write(String ref, Uint8List secret) => throw StateError('no keychain');
  @override
  Future<void> delete(String ref) => throw StateError('no keychain');
}
