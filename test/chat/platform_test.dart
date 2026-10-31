import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/platform/chat_database.dart';
import 'package:meshsonar/platform/secure_storage.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('KeychainSecretStore round trip, overwrite, delete, missing and damaged values', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final s = KeychainSecretStore();
    expect(await s.read('a'), isNull);
    await s.write('a', Uint8List.fromList(List.generate(16, (i) => i)));
    expect(await s.read('a'), List.generate(16, (i) => i));
    await s.write('a', Uint8List.fromList(List.filled(16, 9)));
    expect(await s.read('a'), List.filled(16, 9));
    await s.delete('a');
    expect(await s.read('a'), isNull);
    FlutterSecureStorage.setMockInitialValues({'meshsonar.chat.secret.bad': '!!!not base64!!!'});
    expect(await KeychainSecretStore().read('bad'), isNull);
  });

  test('openChatStore creates a WAL database file and reopens it with data intact', () async {
    final dir = Directory.systemTemp.createTempSync('chat_open');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/sub/chat.db';
    Directory('${dir.path}/sub').createSync();
    final secrets = InMemorySecretStore();
    var store = await openChatStore(secrets, path: path);
    store.contacts.upsert(Contact(radioId: radioA, publicKey: bobKey, type: ContactType.companion, name: 'Bob'));
    expect(store.db.raw.select('PRAGMA journal_mode').first.values.first, 'wal');
    store.close();
    store = await openChatStore(secrets, path: path);
    expect(store.contacts.get(radioA, bobKey)!.name, 'Bob');
    store.close();
  });
}
