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
    expect(s.writes.where((r) => r.startsWith('admin.pw.v2.')), hasLength(1));
    final stored = await s.read('admin.pw.v2.unknown.$key');
    expect(utf8.decode(stored!), 'secret1');
    final next = AdminPasswordVault(store: s);
    expect(await next.remembering(), isTrue);
    expect(await next.recall(key), 'secret1');
    await next.setRemember(false, knownKeys: [key]);
    expect(await s.read('admin.pw.v2.unknown.$key'), isNull);
    expect(await s.read('admin.remember'), isNull);
    expect(await AdminPasswordVault(store: s).recall(key), isNull);
  });

  group('WP9 key scheme', () {
    const node = 'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12';

    test('keys carry the radio id and the node key; guest passwords have their own slot', () async {
      final s = _SpyStore();
      final v = AdminPasswordVault(store: s, radioId: 'aaaaaaaaaaaa');
      await v.setRemember(true);
      await v.keep(node, 'adminpw');
      await v.keep(node, 'guestpw', guest: true);
      expect(await s.read('admin.pw.v2.aaaaaaaaaaaa.$node'), isNotNull);
      expect(await s.read('admin.gpw.v2.aaaaaaaaaaaa.$node'), isNotNull);
      // another radio on the same phone does not see them
      final other = AdminPasswordVault(store: s, radioId: 'bbbbbbbbbbbb');
      expect(await other.recall(node), isNull);
      expect(await AdminPasswordVault(store: s, radioId: 'aaaaaaaaaaaa').recall(node, guest: true), 'guestpw');
    });

    test('first-scheme keys are migrated on first read and the old entry is deleted', () async {
      final s = _SpyStore();
      await s.write('admin.remember', Uint8List.fromList([1]));
      await s.write('admin.pw.$node', Uint8List.fromList(utf8.encode('oldpw')));
      final v = AdminPasswordVault(store: s, radioId: 'aaaaaaaaaaaa');
      expect(await v.hasSaved(node), isTrue);
      expect(await v.recall(node), 'oldpw');
      expect(await s.read('admin.pw.$node'), isNull, reason: 'legacy entry removed');
      expect(utf8.decode((await s.read('admin.pw.v2.aaaaaaaaaaaa.$node'))!), 'oldpw');
      // and a later wipe finds it through the index
      await v.wipe();
      expect(await s.read('admin.pw.v2.aaaaaaaaaaaa.$node'), isNull);
      expect(s.length, 0);
    });

    test('wipe removes passwords, choices and the index, even for another radio id', () async {
      final s = _SpyStore();
      final v = AdminPasswordVault(store: s, radioId: 'aaaaaaaaaaaa', authenticate: () async => true);
      await v.setRemember(true);
      await v.setFaceId(true);
      await v.keep(node, 'adminpw');
      await v.keep(node, 'guestpw', guest: true);
      v.radioId = 'bbbbbbbbbbbb';
      await v.keep(node, 'other');
      expect(s.length, greaterThan(4));
      await v.wipe();
      expect(s.length, 0, reason: 'nothing left in the keychain');
      expect(await v.remembering(), isFalse);
      expect(await v.faceIdOn(), isFalse);
    });

    test('Face ID guards a password that comes from the keychain, not one typed in this run', () async {
      final s = _SpyStore();
      var asked = 0;
      var pass = false;
      Future<bool> auth() async {
        asked++;
        return pass;
      }

      final v = AdminPasswordVault(store: s, radioId: 'aaaaaaaaaaaa', authenticate: auth);
      await v.setRemember(true);
      await v.setFaceId(true);
      await v.keep(node, 'adminpw');
      expect(await v.recall(node), 'adminpw', reason: 'typed this run: no prompt');
      expect(asked, 0);
      final next = AdminPasswordVault(store: s, radioId: 'aaaaaaaaaaaa', authenticate: auth);
      expect(await next.faceIdOn(), isTrue);
      expect(await next.recall(node), isNull, reason: 'Face ID refused');
      expect(asked, 1);
      pass = true;
      expect(await next.recall(node), 'adminpw');
      expect(asked, 2);
    });

    test('no plaintext password in toString, the index, or any ref name', () async {
      final s = _SpyStore();
      final v = AdminPasswordVault(store: s, radioId: 'aaaaaaaaaaaa');
      await v.setRemember(true);
      await v.keep(node, 'hunter2-secret');
      expect(v.toString(), isNot(contains('hunter2')));
      expect(s.writes.join(' '), isNot(contains('hunter2')));
      expect(utf8.decode((await s.read('admin.index'))!), isNot(contains('hunter2')));
    });
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
