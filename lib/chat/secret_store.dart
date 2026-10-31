// Where channel secrets live. NEVER SQLite (design section 5 item 1). The Keychain/Keystore implementation is
// lib/platform/secure_storage.dart; tests and tools use InMemorySecretStore.
import 'dart:typed_data';

abstract interface class SecretStore {
  Future<Uint8List?> read(String ref);
  Future<void> write(String ref, Uint8List secret);
  Future<void> delete(String ref);
}

class InMemorySecretStore implements SecretStore {
  final Map<String, Uint8List> _m = {};
  int get length => _m.length;
  @override
  Future<Uint8List?> read(String ref) async => _m[ref] == null ? null : Uint8List.fromList(_m[ref]!);
  @override
  Future<void> write(String ref, Uint8List secret) async => _m[ref] = Uint8List.fromList(secret);
  @override
  Future<void> delete(String ref) async => _m.remove(ref);
}
