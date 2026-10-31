// Passphrase encryption for chat backups: PBKDF2-HMAC-SHA256 -> AES-256-GCM (package:cryptography, pure Dart).
// The envelope is plain JSON so a future version (or another tool) can read the parameters.
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class BackupCryptoException implements Exception {
  final String message;
  const BackupCryptoException(this.message);
  @override
  String toString() => message;
}

/// Thrown for a wrong passphrase or a damaged file (AES-GCM cannot tell the two apart, and should not).
class BackupWrongPassphrase extends BackupCryptoException {
  const BackupWrongPassphrase() : super('wrong passphrase, or the file is damaged');
}

abstract final class BackupCrypto {
  static const String format = 'meshsonar-chat-backup-encrypted';
  static const int version = 1;

  /// OWASP's 2023 floor for PBKDF2-HMAC-SHA256 is 600,000.
  static const int defaultIterations = 600000;
  static const int maxIterations = 5000000;
  static const String _aad = '$format:$version';

  static bool looksEncrypted(Map<String, dynamic> json) => json['format'] == format;

  /// Encrypts [plain]. With [useIsolate] the KDF runs off the UI isolate (it takes seconds on a phone).
  static Future<Uint8List> encrypt(Uint8List plain, String passphrase, {int iterations = defaultIterations, bool useIsolate = true}) {
    if (passphrase.isEmpty) throw ArgumentError('empty passphrase');
    if (iterations < 1 || iterations > maxIterations) throw ArgumentError('iterations out of range');
    if (!useIsolate) return _encrypt(plain, passphrase, iterations);
    return Isolate.run(() => _encrypt(plain, passphrase, iterations));
  }

  static Future<Uint8List> decrypt(Map<String, dynamic> envelope, String passphrase, {bool useIsolate = true}) {
    final p = _parse(envelope);
    if (!useIsolate) return _decrypt(p, passphrase);
    return Isolate.run(() => _decrypt(p, passphrase));
  }

  static Future<Uint8List> _encrypt(Uint8List plain, String passphrase, int iterations) async {
    final salt = SecretKeyData.random(length: 16).bytes;
    final key = await _derive(passphrase, salt, iterations);
    final algo = AesGcm.with256bits();
    final box = await algo.encrypt(plain, secretKey: key, aad: utf8.encode(_aad));
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'format': format,
      'version': version,
      'kdf': {'name': 'pbkdf2-hmac-sha256', 'iterations': iterations, 'salt': base64.encode(salt)},
      'cipher': 'aes-256-gcm',
      'nonce': base64.encode(box.nonce),
      'data': base64.encode(box.cipherText),
      'mac': base64.encode(box.mac.bytes),
    })));
  }

  static ({int iterations, Uint8List salt, Uint8List nonce, Uint8List data, Uint8List mac}) _parse(Map<String, dynamic> e) {
    try {
      if (e['format'] != format) throw const BackupCryptoException('not an encrypted MeshSonar backup');
      final v = e['version'];
      if (v is! int || v > version) throw const BackupCryptoException('this backup was made by a newer MeshSonar');
      final kdf = e['kdf'] as Map<String, dynamic>;
      if (kdf['name'] != 'pbkdf2-hmac-sha256' || e['cipher'] != 'aes-256-gcm') throw const BackupCryptoException('unsupported encryption');
      final it = kdf['iterations'];
      if (it is! int || it < 1 || it > maxIterations) throw const BackupCryptoException('bad key-derivation settings');
      final salt = base64.decode(kdf['salt'] as String);
      final nonce = base64.decode(e['nonce'] as String);
      final mac = base64.decode(e['mac'] as String);
      if (salt.length < 8 || salt.length > 64 || nonce.length != 12 || mac.length != 16) throw const BackupCryptoException('damaged backup header');
      return (iterations: it, salt: Uint8List.fromList(salt), nonce: Uint8List.fromList(nonce), data: Uint8List.fromList(base64.decode(e['data'] as String)), mac: Uint8List.fromList(mac));
    } on BackupCryptoException {
      rethrow;
    } catch (_) {
      throw const BackupCryptoException('damaged backup header');
    }
  }

  static Future<Uint8List> _decrypt(({int iterations, Uint8List salt, Uint8List nonce, Uint8List data, Uint8List mac}) p, String passphrase) async {
    final key = await _derive(passphrase, p.salt, p.iterations);
    try {
      final plain = await AesGcm.with256bits().decrypt(SecretBox(p.data, nonce: p.nonce, mac: Mac(p.mac)), secretKey: key, aad: utf8.encode(_aad));
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const BackupWrongPassphrase();
    }
  }

  static Future<SecretKey> _derive(String passphrase, List<int> salt, int iterations) =>
      Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256).deriveKeyFromPassword(password: passphrase, nonce: salt);
}
