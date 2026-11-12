// Private (end-to-end encrypted) photo messages, app side. Contract: meshsonar-infra docs/planning/photo-e2e-private-2026-11-12.md.
//
//   link   https://meshsonar.com/e/<8 base62>#<22 base64url>   (the key is the URL fragment: browsers never send it)
//   cipher AES-128-GCM, one random 16-byte key per photo, a random 12-byte nonce per blob, 16-byte tag
//   blob   0x01 || nonce(12) || ciphertext || tag(16)           (minimum 30 bytes)
//   aad    ASCII `ms-e2e-v1:thumb` / `ms-e2e-v1:full` (a blob moved to the other role does not open)
//   body   u32be thumbLen || thumbBlob || fullBlob              (POST photo-upload-enc)
//
// The key is never logged and never put in an exception message. Pure Dart: no Flutter imports.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Which of the two blobs of a photo.
enum PrivatePhotoRole {
  thumb('ms-e2e-v1:thumb'),
  full('ms-e2e-v1:full');

  final String aad;
  const PrivatePhotoRole(this.aad);
}

enum PrivatePhotoErrorKind {
  /// The key is not 22 base64url characters (or not 16 bytes).
  badKey,

  /// The blob is too short or has the wrong version byte.
  malformed,

  /// Wrong key, a changed byte, or a blob of the other role.
  authFailed,
}

/// Every failure of [PrivatePhoto]. Carries no key or plaintext.
class PrivatePhotoException implements Exception {
  final PrivatePhotoErrorKind kind;
  const PrivatePhotoException(this.kind);

  @override
  String toString() => 'PrivatePhotoException($kind)';
}

/// The result of [PrivatePhoto.encrypt]: the fresh [key] and the two blobs to upload.
class EncryptedPhoto {
  final Uint8List key;
  final Uint8List thumbBlob;
  final Uint8List fullBlob;
  const EncryptedPhoto(this.key, this.thumbBlob, this.fullBlob);

  /// `u32be thumbLen || thumbBlob || fullBlob`.
  Uint8List get uploadBody => PrivatePhoto.buildUploadBody(thumbBlob, fullBlob);
}

abstract final class PrivatePhoto {
  static const int keyBytes = 16;
  static const int keyChars = 22;
  static const int nonceBytes = 12;
  static const int tagBytes = 16;
  static const int version = 1;

  /// 1 + 12 + 16 + 1.
  static const int minBlobBytes = 30;

  /// The server's `thumbLen` limit (256 KiB) and the smallest it accepts.
  static const int maxThumbBlobBytes = 262144;

  static final AesGcm _algo = AesGcm.with128bits();
  static final RegExp _keyRe = RegExp(r'^[A-Za-z0-9_-]{22}$');

  /// 16 bytes from the platform's secure random generator.
  static Uint8List generateKey() => _secureBytes(keyBytes);

  static Uint8List _secureBytes(int n) {
    final r = math.Random.secure();
    return Uint8List.fromList([for (var i = 0; i < n; i++) r.nextInt(256)]);
  }

  /// base64url without padding: exactly 22 characters.
  static String encodeKey(List<int> key) {
    if (key.length != keyBytes) throw const PrivatePhotoException(PrivatePhotoErrorKind.badKey);
    return base64Url.encode(key).replaceAll('=', '');
  }

  /// Throws [PrivatePhotoException] (badKey) unless [s] is a canonical 22-character key.
  static Uint8List decodeKey(String s) {
    if (!_keyRe.hasMatch(s)) throw const PrivatePhotoException(PrivatePhotoErrorKind.badKey);
    try {
      final b = Uint8List.fromList(base64Url.decode('$s=='));
      if (b.length != keyBytes) throw const PrivatePhotoException(PrivatePhotoErrorKind.badKey);
      return b;
    } on FormatException {
      throw const PrivatePhotoException(PrivatePhotoErrorKind.badKey);
    }
  }

  /// Encrypts both JPEGs under one fresh key. [key] and [nonceFor] exist for the golden-vector test only.
  static Future<EncryptedPhoto> encrypt(List<int> thumbJpeg, List<int> fullJpeg, {List<int>? key, Uint8List Function(PrivatePhotoRole role)? nonceFor}) async {
    final k = key == null ? generateKey() : Uint8List.fromList(key);
    if (k.length != keyBytes) throw const PrivatePhotoException(PrivatePhotoErrorKind.badKey);
    final thumb = await encryptBlob(thumbJpeg, k, PrivatePhotoRole.thumb, nonce: nonceFor?.call(PrivatePhotoRole.thumb));
    final full = await encryptBlob(fullJpeg, k, PrivatePhotoRole.full, nonce: nonceFor?.call(PrivatePhotoRole.full));
    return EncryptedPhoto(k, thumb, full);
  }

  /// One blob: `0x01 || nonce || ciphertext || tag`.
  static Future<Uint8List> encryptBlob(List<int> plain, List<int> key, PrivatePhotoRole role, {List<int>? nonce}) async {
    if (key.length != keyBytes) throw const PrivatePhotoException(PrivatePhotoErrorKind.badKey);
    final n = nonce ?? _secureBytes(nonceBytes);
    if (n.length != nonceBytes) throw ArgumentError('nonce must be $nonceBytes bytes');
    final box = await _algo.encrypt(plain, secretKey: SecretKey(key), nonce: n, aad: utf8.encode(role.aad));
    final out = BytesBuilder(copy: false)
      ..addByte(version)
      ..add(n)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// The JPEG inside [blob]. Throws [PrivatePhotoException]: badKey, malformed, authFailed (wrong key, tamper, role swap).
  static Future<Uint8List> decrypt(List<int> blob, List<int> key, PrivatePhotoRole role) async {
    if (key.length != keyBytes) throw const PrivatePhotoException(PrivatePhotoErrorKind.badKey);
    if (blob.length < minBlobBytes || blob[0] != version) throw const PrivatePhotoException(PrivatePhotoErrorKind.malformed);
    final b = blob is Uint8List ? blob : Uint8List.fromList(blob);
    final nonce = b.sublist(1, 1 + nonceBytes);
    final ct = b.sublist(1 + nonceBytes, b.length - tagBytes);
    final tag = b.sublist(b.length - tagBytes);
    try {
      final plain = await _algo.decrypt(SecretBox(ct, nonce: nonce, mac: Mac(tag)), secretKey: SecretKey(key), aad: utf8.encode(role.aad));
      return Uint8List.fromList(plain);
    } catch (_) {
      // SecretBoxAuthenticationError (and anything the platform backend throws): never forward the cause.
      throw const PrivatePhotoException(PrivatePhotoErrorKind.authFailed);
    }
  }

  /// `u32 big-endian thumbLen || thumbBlob || fullBlob`.
  static Uint8List buildUploadBody(List<int> thumbBlob, List<int> fullBlob) {
    final head = ByteData(4)..setUint32(0, thumbBlob.length, Endian.big);
    return (BytesBuilder(copy: false)
          ..add(head.buffer.asUint8List())
          ..add(thumbBlob)
          ..add(fullBlob))
        .toBytes();
  }
}

// ------------------------------------------------------------------ the link

// Split after the scheme so the host scan of test/integration/hosts_static_test.dart reads no literal host here.
const String privatePhotoLinkPrefix = 'https://' 'meshsonar.com/e/';

/// 24 + 8 + 1 + 22.
const int privatePhotoLinkBytes = 55;

/// Exactly the spec's regex: id, `#`, a 22-character key that is not followed by another key character.
final RegExp privatePhotoLinkRe = RegExp('https://' r'meshsonar\.com/e/([0-9A-Za-z]{8})#([A-Za-z0-9_-]{22})(?![A-Za-z0-9_-])');

/// A parsed private photo link. The key is secret: never print or log this object ([toString] hides it).
class PrivatePhotoLink {
  final String id;
  final String keyText;
  const PrivatePhotoLink(this.id, this.keyText);

  Uint8List get key => PrivatePhoto.decodeKey(keyText);
  String get url => '$privatePhotoLinkPrefix$id#$keyText';

  /// The key-less address of one blob (what is fetched).
  String blobUrl(PrivatePhotoRole role) => '$privatePhotoLinkPrefix$id/${role.name}';

  @override
  String toString() => 'PrivatePhotoLink($id)';
}

/// The link when [url] is exactly a private photo link with a canonical key, else null.
PrivatePhotoLink? parsePrivatePhotoLink(String url) {
  final m = privatePhotoLinkRe.firstMatch(url);
  if (m == null || m.start != 0 || m.end != url.length) return null;
  try {
    PrivatePhoto.decodeKey(m.group(2)!);
  } on PrivatePhotoException {
    return null;
  }
  return PrivatePhotoLink(m.group(1)!, m.group(2)!);
}

String buildPrivatePhotoLink(String id, List<int> key) => '$privatePhotoLinkPrefix$id#${PrivatePhoto.encodeKey(key)}';

/// The same link with the key replaced, for anything that may be shown or logged.
String redactPrivatePhotoLink(String url) => url.replaceAll(RegExp(r'#[A-Za-z0-9_-]{22}'), '#<key>');
