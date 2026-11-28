// Where the MeshSonar radio pairing tokens and the last good radio addresses live, keyed by the radio's public key.
// Tokens go ONLY into secure storage (Keychain / Keystore: lib/platform/secure_storage.dart KeychainMsSecretKv); they are
// never logged, never shown and never in a diagnostics export (lib/core/redact.dart R3/R6 also scrub `Bearer <token>` and
// `"token":...`). Tests use InMemoryMsSecretKv. Pure Dart.

/// The secure key-value seam (strings).
abstract interface class MsSecretKv {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class InMemoryMsSecretKv implements MsSecretKv {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

final RegExp _token = RegExp(r'^[0-9a-f]{32}$');
final RegExp _radioKey = RegExp(r'^[0-9a-f]{64}$');

String _norm(String radioKey) {
  final k = radioKey.toLowerCase();
  if (!_radioKey.hasMatch(k)) throw ArgumentError('not a radio key');
  return k;
}

/// The pairing token of each radio.
class MsTokenStore {
  final MsSecretKv _kv;
  const MsTokenStore(this._kv);

  static String _k(String radioKey) => 'token.${_norm(radioKey)}';

  Future<String?> read(String radioKey) async {
    final t = await _kv.read(_k(radioKey));
    return t != null && _token.hasMatch(t) ? t : null;
  }

  /// Keeps [token] (32 hex) for [radioKey].
  Future<void> save(String radioKey, String token) {
    final t = token.toLowerCase();
    if (!_token.hasMatch(t)) throw ArgumentError('not a token');
    return _kv.write(_k(radioKey), t);
  }

  /// Forgets the token (after a 401, "Forget this radio" or a revoke).
  Future<void> drop(String radioKey) => _kv.delete(_k(radioKey));
}

/// The last address that worked for each radio (discovery step 1). Not secret.
abstract interface class MsAddressStore {
  Future<String?> lastGood(String radioKey);
  Future<void> saveGood(String radioKey, String address);
  Future<void> forget(String radioKey);
}

class InMemoryMsAddressStore implements MsAddressStore {
  final Map<String, String> values = {};
  @override
  Future<String?> lastGood(String radioKey) async => values[radioKey.toLowerCase()];
  @override
  Future<void> saveGood(String radioKey, String address) async => values[radioKey.toLowerCase()] = address;
  @override
  Future<void> forget(String radioKey) async => values.remove(radioKey.toLowerCase());
}

/// [MsAddressStore] in the same key-value storage as the tokens (`addr.<key>`).
class KvMsAddressStore implements MsAddressStore {
  final MsSecretKv _kv;
  const KvMsAddressStore(this._kv);
  static String _k(String radioKey) => 'addr.${_norm(radioKey)}';
  @override
  Future<String?> lastGood(String radioKey) => _kv.read(_k(radioKey));
  @override
  Future<void> saveGood(String radioKey, String address) => _kv.write(_k(radioKey), address);
  @override
  Future<void> forget(String radioKey) => _kv.delete(_k(radioKey));
}
