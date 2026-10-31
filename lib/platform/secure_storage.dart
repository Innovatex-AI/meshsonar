// Keychain / Keystore backed SecretStore for channel secrets (flutter_secure_storage). Chat never puts a secret in SQLite.
// iOS: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly (works with the screen locked after the first unlock, which a radio
// running in the background needs; does not sync to iCloud and does not migrate to a new device).
// Android: EncryptedSharedPreferences-style storage backed by the Keystore (the plugin default).
// macOS: the file-based login keychain (no keychain-access-groups entitlement is needed for it).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../chat/secret_store.dart';

class KeychainSecretStore implements SecretStore {
  static const String _prefix = 'meshsonar.chat.secret.';
  final FlutterSecureStorage _s;

  KeychainSecretStore({FlutterSecureStorage? storage})
      : _s = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
              mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock_this_device, usesDataProtectionKeychain: false),
            );

  @override
  Future<Uint8List?> read(String ref) async {
    final v = await _s.read(key: '$_prefix$ref');
    if (v == null) return null;
    try {
      return Uint8List.fromList(base64.decode(v));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String ref, Uint8List secret) => _s.write(key: '$_prefix$ref', value: base64.encode(secret));

  @override
  Future<void> delete(String ref) => _s.delete(key: '$_prefix$ref');
}
