// The MQTT login token a feed slot uses (observer-everywhere-mqtt-plan-2026-11-15.md section 3.4; the byte format is the
// MeshCore observer firmware's, docs/protocol/observer-firmware-notes.md section 3):
//   token    = base64url(header) "." base64url(payload) "." HEX(signature)   (base64url without padding)
//   header   = {"alg":"Ed25519","typ":"JWT"}
//   payload  = {"publicKey":"<64 UPPER hex>","aud":"<host>","iat":<unix s>,"exp":<unix s>}   (firmware field order)
//   signed   = the ASCII text base64url(header) "." base64url(payload), by the CONNECTED RADIO (CMD_SIGN_START/DATA/FINISH):
//              no private key ever leaves the radio.
//   signature= 64 bytes as 128 UPPERCASE hex characters (not base64).
//   username = "v1_" + the radio's public key, 64 uppercase hex; password = the token.
// No `owner`, `email` or `client` claims: nothing about the person goes in a token.
// [MqttTokenService] caches one token per (radio key, audience, lifetime), re-signs it about 5 minutes before it ends and
// runs one radio signing at a time (the radio has one signing buffer).
// Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../observer_engine.dart' show ObserverSigner;

/// The radio could not sign (busy, timed out, or firmware without CMD_SIGN_*). The slot shows "Radio can't sign".
class MqttSignException implements Exception {
  final String message;
  const MqttSignException(this.message);
  @override
  String toString() => 'MqttSignException: $message';
}

/// One signed login token.
class MqttToken {
  /// The whole token (the MQTT password).
  final String value;

  /// `v1_` + the radio's public key in uppercase hex (the MQTT username).
  final String username;
  final DateTime issuedAt;
  final DateTime expiresAt;
  const MqttToken({required this.value, required this.username, required this.issuedAt, required this.expiresAt});
}

abstract final class MqttJwt {
  static const String headerJson = '{"alg":"Ed25519","typ":"JWT"}';
  static final RegExp _key = RegExp(r'^[0-9a-fA-F]{64}$');

  /// base64url without padding.
  static String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  /// The MQTT username for [publicKeyHex].
  static String username(String publicKeyHex) => 'v1_${publicKeyHex.toUpperCase()}';

  /// The compact payload JSON, firmware field order.
  static String payloadJson({required String publicKeyHex, required String aud, required int iat, required int exp}) =>
      jsonEncode({'publicKey': publicKeyHex.toUpperCase(), 'aud': aud, 'iat': iat, 'exp': exp});

  /// The exact bytes the radio signs: ASCII `b64url(header).b64url(payload)`.
  static String signingInput(String payloadJson) => '${b64url(utf8.encode(headerJson))}.${b64url(utf8.encode(payloadJson))}';

  /// Uppercase hex of [bytes].
  static String upperHex(List<int> bytes) {
    final b = StringBuffer();
    for (final x in bytes) {
      b.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return b.toString().toUpperCase();
  }

  /// Signs a token with [sign] (the connected radio). [issuedAt] is UTC wall time; the token lives [ttlSec] seconds.
  /// Throws [MqttSignException] when the radio cannot sign or answers with anything but a 64-byte signature, and
  /// [ArgumentError] for a malformed key or audience.
  static Future<MqttToken> mint({
    required String publicKeyHex,
    required String aud,
    required DateTime issuedAt,
    required int ttlSec,
    required ObserverSigner sign,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!_key.hasMatch(publicKeyHex)) throw ArgumentError.value(publicKeyHex, 'publicKeyHex', 'not 64 hex characters');
    if (aud.isEmpty) throw ArgumentError.value(aud, 'aud', 'empty audience');
    if (ttlSec <= 0) throw ArgumentError.value(ttlSec, 'ttlSec', 'must be positive');
    final iat = issuedAt.toUtc().millisecondsSinceEpoch ~/ 1000;
    final exp = iat + ttlSec;
    final input = signingInput(payloadJson(publicKeyHex: publicKeyHex, aud: aud, iat: iat, exp: exp));
    Uint8List sig;
    try {
      sig = await sign(Uint8List.fromList(ascii.encode(input))).timeout(timeout);
    } on TimeoutException {
      throw const MqttSignException('The radio did not answer the signing request.');
    } on MqttSignException {
      rethrow;
    } catch (e) {
      throw MqttSignException('The radio could not sign: $e');
    }
    if (sig.length != 64) throw MqttSignException('The radio returned a ${sig.length}-byte signature, not 64.');
    return MqttToken(
      value: '$input.${upperHex(sig)}',
      username: username(publicKeyHex),
      issuedAt: DateTime.fromMillisecondsSinceEpoch(iat * 1000, isUtc: true),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true),
    );
  }
}

/// How long before a token ends it is re-signed: lifetime / 10, kept within 60..300 s (a 1 h token: 5 minutes), as the
/// firmware does.
Duration mqttRefreshMargin(int ttlSec) => Duration(seconds: (ttlSec ~/ 10).clamp(60, 300));

/// Tokens for every slot, one radio signing at a time, cached per (radio key, audience, lifetime).
class MqttTokenService {
  final DateTime Function() clock;
  final Duration signTimeout;
  MqttTokenService({required this.clock, this.signTimeout = const Duration(seconds: 20)});

  final Map<String, MqttToken> _cache = {};
  Future<void> _lock = Future.value();

  /// Number of radio signings done (tests and diagnostics).
  int signings = 0;

  /// A token that is valid for longer than [mqttRefreshMargin]: the cached one, or a newly signed one. [fresh] forces a
  /// new signature (after the broker refused the old one).
  Future<MqttToken> token({
    required String publicKeyHex,
    required String aud,
    required int ttlSec,
    required ObserverSigner sign,
    bool fresh = false,
  }) {
    final key = '${publicKeyHex.toUpperCase()}|$aud|$ttlSec';
    final done = Completer<MqttToken>();
    final prev = _lock;
    _lock = done.future.then((_) {}, onError: (_) {});
    prev.whenComplete(() async {
      try {
        final cached = _cache[key];
        if (!fresh && cached != null && cached.expiresAt.difference(clock()) > mqttRefreshMargin(ttlSec)) {
          done.complete(cached);
          return;
        }
        signings++;
        final t = await MqttJwt.mint(
          publicKeyHex: publicKeyHex,
          aud: aud,
          issuedAt: clock(),
          ttlSec: ttlSec,
          sign: sign,
          timeout: signTimeout,
        );
        _cache[key] = t;
        done.complete(t);
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// The radio changed or went away: no cached token outlives it.
  void clear() => _cache.clear();
}
