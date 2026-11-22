// The driver key in the Keychain (ID step 2, "Keychain token"). Only used while the server advertises `radioProof`; without it
// the app never touches the Keychain for the key and `settings.json` stays the only copy, exactly as before.
// With it: the settings.json copy is KEPT (old reads, step 7 removes it later) and the Keychain gets a copy, so an install that
// lost settings.json (delete and reinstall: iOS keeps Keychain items) gets its key, and so its person, back.
import 'dart:convert';
import 'dart:typed_data';

import '../chat/secret_store.dart';
import '../core/driver_account.dart' show isDriverKeyShape;

class DriverKeyVault {
  final SecretStore store;
  const DriverKeyVault(this.store);

  /// One entry per server host: a key only works on the server that issued it.
  static String refFor(String host) => 'driver-key.${host.toLowerCase()}';

  Future<String?> read(String host) async {
    try {
      final b = await store.read(refFor(host));
      if (b == null) return null;
      final k = utf8.decode(b, allowMalformed: false);
      return isDriverKeyShape(k) ? k : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String host, String key) async {
    try {
      await store.write(refFor(host), Uint8List.fromList(utf8.encode(key)));
    } catch (_) {
      // a copy we cannot save only costs the reinstall recovery
    }
  }

  Future<void> delete(String host) async {
    try {
      await store.delete(refFor(host));
    } catch (_) {}
  }

  /// Which key to use for [host]: the settings.json key when there is one (the Keychain copy is made or refreshed to match),
  /// else the Keychain's (the install lost settings.json: [adopted] is true so the caller saves it back and checks it).
  Future<({String? key, bool adopted})> reconcile(String host, String? settingsKey) async {
    final s = settingsKey == null || settingsKey.isEmpty ? null : settingsKey;
    final v = await read(host);
    if (s != null) {
      if (v != s && isDriverKeyShape(s)) await write(host, s);
      return (key: s, adopted: false);
    }
    return v == null ? (key: null, adopted: false) : (key: v, adopted: true);
  }
}
