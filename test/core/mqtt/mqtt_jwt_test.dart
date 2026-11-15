// The MQTT login token: RFC 8032 signing vector, exact token bytes (golden), uppercase-hex signature, the firmware's
// header/payload, verification as the reference broker does it, caching, re-signing before expiry and one signing at a time.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/mqtt/mqtt_jwt.dart';

import 'support.dart';

String _b64urlDecode(String s) => utf8.decode(base64Url.decode(base64Url.normalize(s)));

void main() {
  final issued = DateTime.utc(2026, 11, 15, 18, 0, 0);

  test('RFC 8032 test 1: the test signer is a real Ed25519 key (signing vector)', () async {
    final sig = await TestRadioSigner().sign(Uint8List(0));
    expect(MqttJwt.upperHex(sig), rfcEmptySigHex.toUpperCase());
  });

  test('golden token: exact bytes for a fixed key, audience and time', () async {
    final t = await MqttJwt.mint(
      publicKeyHex: rfcPublicHex,
      aud: 'mqtt-us-v1.letsmesh.net',
      issuedAt: issued,
      ttlSec: 3600,
      sign: TestRadioSigner().sign,
    );
    final parts = t.value.split('.');
    expect(parts, hasLength(3));
    expect(parts[0], 'eyJhbGciOiJFZDI1NTE5IiwidHlwIjoiSldUIn0');
    expect(_b64urlDecode(parts[0]), '{"alg":"Ed25519","typ":"JWT"}');
    expect(
      _b64urlDecode(parts[1]),
      '{"publicKey":"D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A","aud":"mqtt-us-v1.letsmesh.net","iat":1794765600,"exp":1794769200}',
    );
    expect(parts[0].contains('='), isFalse);
    expect(parts[1].contains('='), isFalse);
    // Signature: 128 uppercase hex characters, never base64.
    expect(parts[2], matches(RegExp(r'^[0-9A-F]{128}$')));
    // Ed25519 is deterministic: this exact token is the golden copy.
    expect(t.value, _goldenToken);
    expect(t.username, 'v1_D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A');
    expect(t.issuedAt, issued);
    expect(t.expiresAt, issued.add(const Duration(hours: 1)));
  });

  test('the broker check passes: signature over ASCII header.payload verifies with the radio key', () async {
    final t = await MqttJwt.mint(
      publicKeyHex: rfcPublicHex,
      aud: 'a.example',
      issuedAt: issued,
      ttlSec: 600,
      sign: TestRadioSigner().sign,
    );
    final parts = t.value.split('.');
    final ok = await verifyEd25519(ascii.encode('${parts[0]}.${parts[1]}'), hexBytes(parts[2]), rfcPublicHex);
    expect(ok, isTrue);
    final tampered = await verifyEd25519(ascii.encode('${parts[0]}.${parts[1]}x'), hexBytes(parts[2]), rfcPublicHex);
    expect(tampered, isFalse);
    final payload = jsonDecode(_b64urlDecode(parts[1])) as Map<String, dynamic>;
    expect(payload.keys, ['publicKey', 'aud', 'iat', 'exp']); // no owner / email / client claims
  });

  test('the radio sees exactly the signing input bytes', () async {
    Uint8List? seen;
    await MqttJwt.mint(
      publicKeyHex: rfcPublicHex,
      aud: 'x',
      issuedAt: issued,
      ttlSec: 60,
      sign: (d) async {
        seen = d;
        return Uint8List(64);
      },
    );
    final expected = MqttJwt.signingInput(
      MqttJwt.payloadJson(publicKeyHex: rfcPublicHex, aud: 'x', iat: 1794765600, exp: 1794765660),
    );
    expect(ascii.decode(seen!), expected);
  });

  test('a radio that fails, times out or returns a short signature is "can\'t sign"', () async {
    expect(
      () => MqttJwt.mint(
        publicKeyHex: rfcPublicHex,
        aud: 'x',
        issuedAt: issued,
        ttlSec: 60,
        sign: (_) async => throw StateError('busy'),
      ),
      throwsA(isA<MqttSignException>()),
    );
    expect(
      () => MqttJwt.mint(publicKeyHex: rfcPublicHex, aud: 'x', issuedAt: issued, ttlSec: 60, sign: (_) async => Uint8List(63)),
      throwsA(isA<MqttSignException>()),
    );
    expect(
      () => MqttJwt.mint(
        publicKeyHex: rfcPublicHex,
        aud: 'x',
        issuedAt: issued,
        ttlSec: 60,
        timeout: const Duration(milliseconds: 20),
        sign: (_) => Completer<Uint8List>().future,
      ),
      throwsA(isA<MqttSignException>()),
    );
    expect(
      () => MqttJwt.mint(publicKeyHex: 'abc', aud: 'x', issuedAt: issued, ttlSec: 60, sign: TestRadioSigner().sign),
      throwsArgumentError,
    );
  });

  test('refresh margin: lifetime / 10 within 60..300 s', () {
    expect(mqttRefreshMargin(3600), const Duration(seconds: 300));
    expect(mqttRefreshMargin(86400), const Duration(seconds: 300));
    expect(mqttRefreshMargin(1200), const Duration(seconds: 120));
    expect(mqttRefreshMargin(120), const Duration(seconds: 60));
  });

  group('MqttTokenService', () {
    test('caches per audience, re-signs inside the refresh margin, fresh forces a new signature', () async {
      var now = issued;
      final s = MqttTokenService(clock: () => now);
      final r = TestRadioSigner();
      final a = await s.token(publicKeyHex: rfcPublicHex, aud: 'a', ttlSec: 3600, sign: r.sign);
      final a2 = await s.token(publicKeyHex: rfcPublicHex, aud: 'a', ttlSec: 3600, sign: r.sign);
      expect(identical(a, a2), isTrue);
      await s.token(publicKeyHex: rfcPublicHex, aud: 'b', ttlSec: 3600, sign: r.sign);
      expect(r.calls, 2);
      now = issued.add(const Duration(minutes: 54)); // 6 min left: still valid
      expect(identical(await s.token(publicKeyHex: rfcPublicHex, aud: 'a', ttlSec: 3600, sign: r.sign), a), isTrue);
      now = issued.add(const Duration(minutes: 55)); // 5 min left: re-sign
      final a3 = await s.token(publicKeyHex: rfcPublicHex, aud: 'a', ttlSec: 3600, sign: r.sign);
      expect(a3.value, isNot(a.value));
      expect(a3.expiresAt, now.add(const Duration(hours: 1)));
      expect(r.calls, 3);
      await s.token(publicKeyHex: rfcPublicHex, aud: 'a', ttlSec: 3600, sign: r.sign, fresh: true);
      expect(r.calls, 4);
      s.clear();
      await s.token(publicKeyHex: rfcPublicHex, aud: 'a', ttlSec: 3600, sign: r.sign);
      expect(r.calls, 5);
    });

    test('one radio signing at a time, even when slots ask together', () async {
      final s = MqttTokenService(clock: () => issued);
      var inFlight = 0, maxInFlight = 0;
      Future<Uint8List> sign(Uint8List d) async {
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return Uint8List(64);
      }

      await Future.wait([
        for (final aud in ['a', 'b', 'c', 'a']) s.token(publicKeyHex: rfcPublicHex, aud: aud, ttlSec: 3600, sign: sign),
      ]);
      expect(maxInFlight, 1);
      expect(s.signings, 3); // the second 'a' reuses the first
    });

    test('a failed signing does not block the next one', () async {
      final s = MqttTokenService(clock: () => issued);
      final r = TestRadioSigner()..failWith = StateError('busy');
      await expectLater(
        s.token(publicKeyHex: rfcPublicHex, aud: 'a', ttlSec: 3600, sign: r.sign),
        throwsA(isA<MqttSignException>()),
      );
      r.failWith = null;
      final t = await s.token(publicKeyHex: rfcPublicHex, aud: 'a', ttlSec: 3600, sign: r.sign);
      expect(t.value.split('.'), hasLength(3));
    });
  });
}

// Pinned Nov 15 2026 (RFC 8032 key 1, aud mqtt-us-v1.letsmesh.net, iat 2026-11-15T18:00Z, 1 h); verified above.
const _goldenToken =
    'eyJhbGciOiJFZDI1NTE5IiwidHlwIjoiSldUIn0.eyJwdWJsaWNLZXkiOiJENzVBOTgwMTgyQjEwQUI3RDU0QkZFRDNDOTY0MDczQTBFRTE3MkYzREFBNjIzMjVBRjAyMUE2OEY3MDc1MTFBIiwiYXVkIjoibXF0dC11cy12MS5sZXRzbWVzaC5uZXQiLCJpYXQiOjE3OTQ3NjU2MDAsImV4cCI6MTc5NDc2OTIwMH0.D17549E1F2ADBB7B6B7B58BD1B3D9AD967D681F3E87FF0505E209FA21828B73E9DC29423346A852261DEE7F87B383E86FD09900C71F57B94417A12630DCDAB00';
