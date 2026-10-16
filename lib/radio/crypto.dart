// Minimal pure-Dart crypto needed to recognise MeshCore group-text echoes:
// SHA-256, HMAC-SHA256 and single-block AES-128 (ECB, as MeshCore uses it).
//
// Why not package:crypto / pointycastle? Neither is a direct dependency of MeshSonar, and AES is not in
// package:crypto at all. These are textbook implementations (FIPS 180-4, RFC 2104, FIPS 197), verified in
// test/radio/crypto_test.dart against published test vectors.
//
// MeshCore usage (firmware src/Utils.cpp encrypt / encryptThenMAC / MACThenDecrypt):
//  - AES-128-ECB with the first 16 bytes of the channel secret; last partial block zero-padded.
//  - MAC = first 2 bytes of HMAC-SHA256(key = 32-byte secret buffer (16 key bytes + 16 zeros), ciphertext).
import 'dart:convert';
import 'dart:typed_data';

// ---------------------------------------------------------------- SHA-256

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

/// SHA-256 digest (32 bytes).
Uint8List sha256(List<int> data) {
  final h = <int>[0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  final bitLen = data.length * 8;
  final padLen = ((data.length + 9 + 63) ~/ 64) * 64;
  final msg = Uint8List(padLen)..setRange(0, data.length, data);
  msg[data.length] = 0x80;
  final bd = ByteData.sublistView(msg);
  bd.setUint32(padLen - 8, (bitLen ~/ 0x100000000) & 0xffffffff);
  bd.setUint32(padLen - 4, bitLen & 0xffffffff);
  final w = List<int>.filled(64, 0);
  for (var off = 0; off < padLen; off += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = bd.getUint32(off + t * 4);
    }
    for (var t = 16; t < 64; t++) {
      final s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (hh + s1 + ch + _k[t] + w[t]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  final out = Uint8List(32);
  final od = ByteData.sublistView(out);
  for (var i = 0; i < 8; i++) {
    od.setUint32(i * 4, h[i]);
  }
  return out;
}

/// HMAC-SHA256 (RFC 2104).
Uint8List hmacSha256(List<int> key, List<int> data) {
  var k = key.length > 64 ? sha256(key) : Uint8List.fromList(key);
  final kp = Uint8List(64)..setRange(0, k.length, k);
  final ipad = Uint8List(64 + data.length);
  final opad = Uint8List(64 + 32);
  for (var i = 0; i < 64; i++) {
    ipad[i] = kp[i] ^ 0x36;
    opad[i] = kp[i] ^ 0x5c;
  }
  ipad.setRange(64, ipad.length, data);
  opad.setRange(64, 96, sha256(ipad));
  return sha256(opad);
}

// ---------------------------------------------------------------- AES-128

final Uint8List _sbox = _buildSbox();
final Uint8List _invSbox = () {
  final inv = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    inv[_sbox[i]] = i;
  }
  return inv;
}();

int _xtime(int a) => ((a << 1) ^ ((a & 0x80) != 0 ? 0x1b : 0)) & 0xff;

int _gmul(int a, int b) {
  var p = 0;
  while (b != 0) {
    if ((b & 1) != 0) p ^= a;
    a = _xtime(a);
    b >>= 1;
  }
  return p;
}

Uint8List _buildSbox() {
  final s = Uint8List(256);
  // Multiplicative inverse in GF(2^8) followed by the affine transform.
  for (var i = 0; i < 256; i++) {
    var inv = 0;
    if (i != 0) {
      for (var j = 1; j < 256; j++) {
        if (_gmul(i, j) == 1) {
          inv = j;
          break;
        }
      }
    }
    var x = inv;
    var r = inv;
    for (var k = 0; k < 4; k++) {
      x = ((x << 1) | (x >> 7)) & 0xff;
      r ^= x;
    }
    s[i] = r ^ 0x63;
  }
  return s;
}

/// AES-128 with an expanded key; encrypts/decrypts single 16-byte blocks.
class Aes128 {
  final Uint8List _rk = Uint8List(176);

  Aes128(List<int> key) {
    if (key.length != 16) throw ArgumentError('AES-128 key must be 16 bytes');
    _rk.setRange(0, 16, key);
    var rcon = 1;
    for (var i = 16; i < 176; i += 4) {
      var t0 = _rk[i - 4], t1 = _rk[i - 3], t2 = _rk[i - 2], t3 = _rk[i - 1];
      if (i % 16 == 0) {
        final tmp = t0;
        t0 = _sbox[t1] ^ rcon;
        t1 = _sbox[t2];
        t2 = _sbox[t3];
        t3 = _sbox[tmp];
        rcon = _xtime(rcon);
      }
      _rk[i] = _rk[i - 16] ^ t0;
      _rk[i + 1] = _rk[i - 15] ^ t1;
      _rk[i + 2] = _rk[i - 14] ^ t2;
      _rk[i + 3] = _rk[i - 13] ^ t3;
    }
  }

  void _addRoundKey(Uint8List s, int round) {
    for (var i = 0; i < 16; i++) {
      s[i] ^= _rk[round * 16 + i];
    }
  }

  // State is column-major: s[r + 4c].
  static void _shiftRows(Uint8List s) {
    var t = s[1];
    s[1] = s[5];
    s[5] = s[9];
    s[9] = s[13];
    s[13] = t;
    t = s[2];
    s[2] = s[10];
    s[10] = t;
    t = s[6];
    s[6] = s[14];
    s[14] = t;
    t = s[15];
    s[15] = s[11];
    s[11] = s[7];
    s[7] = s[3];
    s[3] = t;
  }

  static void _invShiftRows(Uint8List s) {
    var t = s[13];
    s[13] = s[9];
    s[9] = s[5];
    s[5] = s[1];
    s[1] = t;
    t = s[2];
    s[2] = s[10];
    s[10] = t;
    t = s[6];
    s[6] = s[14];
    s[14] = t;
    t = s[3];
    s[3] = s[7];
    s[7] = s[11];
    s[11] = s[15];
    s[15] = t;
  }

  static void _mixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3];
      s[4 * c] = _xtime(a0) ^ (_xtime(a1) ^ a1) ^ a2 ^ a3;
      s[4 * c + 1] = a0 ^ _xtime(a1) ^ (_xtime(a2) ^ a2) ^ a3;
      s[4 * c + 2] = a0 ^ a1 ^ _xtime(a2) ^ (_xtime(a3) ^ a3);
      s[4 * c + 3] = (_xtime(a0) ^ a0) ^ a1 ^ a2 ^ _xtime(a3);
    }
  }

  static void _invMixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3];
      s[4 * c] = _gmul(a0, 14) ^ _gmul(a1, 11) ^ _gmul(a2, 13) ^ _gmul(a3, 9);
      s[4 * c + 1] = _gmul(a0, 9) ^ _gmul(a1, 14) ^ _gmul(a2, 11) ^ _gmul(a3, 13);
      s[4 * c + 2] = _gmul(a0, 13) ^ _gmul(a1, 9) ^ _gmul(a2, 14) ^ _gmul(a3, 11);
      s[4 * c + 3] = _gmul(a0, 11) ^ _gmul(a1, 13) ^ _gmul(a2, 9) ^ _gmul(a3, 14);
    }
  }

  Uint8List encryptBlock(List<int> input) {
    final s = Uint8List.fromList(input);
    _addRoundKey(s, 0);
    for (var round = 1; round < 10; round++) {
      for (var i = 0; i < 16; i++) {
        s[i] = _sbox[s[i]];
      }
      _shiftRows(s);
      _mixColumns(s);
      _addRoundKey(s, round);
    }
    for (var i = 0; i < 16; i++) {
      s[i] = _sbox[s[i]];
    }
    _shiftRows(s);
    _addRoundKey(s, 10);
    return s;
  }

  Uint8List decryptBlock(List<int> input) {
    final s = Uint8List.fromList(input);
    _addRoundKey(s, 10);
    for (var round = 9; round > 0; round--) {
      _invShiftRows(s);
      for (var i = 0; i < 16; i++) {
        s[i] = _invSbox[s[i]];
      }
      _addRoundKey(s, round);
      _invMixColumns(s);
    }
    _invShiftRows(s);
    for (var i = 0; i < 16; i++) {
      s[i] = _invSbox[s[i]];
    }
    _addRoundKey(s, 0);
    return s;
  }
}

// ---------------------------------------------------------------- MeshCore helpers

/// MeshCore's well-known key for the default "Public" channel
/// (firmware docs/companion_protocol.md "Channel Types"; MeshMapper PUBLIC_CHANNEL_FIXED_KEY).
final Uint8List publicChannelSecret = Uint8List.fromList(
    [0x8b, 0x33, 0x87, 0xe9, 0xc5, 0xcd, 0xea, 0x6a, 0xc9, 0xe5, 0xed, 0xba, 0xa1, 0x15, 0xcd, 0x72]);

/// Hashtag channel secret: first 16 bytes of SHA-256 of the name including '#'.
/// Firmware docs/companion_protocol.md ("first 16 bytes of sha256("#test")"); MeshMapper wardrive.js
/// deriveChannelKey (lower-cases the name first); MeshCore Open models/channel.dart derivePskFromHashtag.
/// We lower-case like MeshMapper so "#Wardriving" and "#wardriving" land on the same community channel.
Uint8List hashtagChannelSecret(String name) {
  var n = name.trim().toLowerCase();
  if (!n.startsWith('#')) n = '#$n';
  return Uint8List.sublistView(sha256(utf8.encode(n)), 0, 16);
}

/// Channel secret for a channel name when it can be derived without asking the radio, else null.
Uint8List? wellKnownChannelSecret(String name) {
  final t = name.trim();
  if (t.startsWith('#')) return hashtagChannelSecret(t);
  if (t.toLowerCase() == 'public') return publicChannelSecret;
  return null;
}

/// One-byte channel hash carried in GRP_TXT payloads: SHA-256(secret)[0], over 16 bytes for a 128-bit key
/// (firmware BaseChatMesh::setChannel, src/helpers/BaseChatMesh.cpp ~line 939).
int channelHash(List<int> secret16) => sha256(secret16.sublist(0, 16))[0];

Uint8List _hmacKey(List<int> secret) => Uint8List(32)..setRange(0, secret.length.clamp(0, 32), secret);

/// MeshCore Utils::encryptThenMAC: [mac x2][AES-128-ECB(zero-padded plaintext)].
Uint8List meshEncryptThenMac(List<int> secret, List<int> plaintext) {
  final aes = Aes128(secret.sublist(0, 16));
  final blocks = (plaintext.length + 15) ~/ 16;
  final ct = Uint8List(blocks * 16);
  for (var b = 0; b < blocks; b++) {
    final blk = Uint8List(16);
    final end = (b * 16 + 16).clamp(0, plaintext.length);
    blk.setRange(0, end - b * 16, plaintext.sublist(b * 16, end));
    ct.setRange(b * 16, b * 16 + 16, aes.encryptBlock(blk));
  }
  final mac = hmacSha256(_hmacKey(secret), ct);
  return Uint8List(2 + ct.length)
    ..[0] = mac[0]
    ..[1] = mac[1]
    ..setRange(2, 2 + ct.length, ct);
}

/// MeshCore Utils::MACThenDecrypt. Returns null when the MAC doesn't verify or the length is wrong.
/// The returned plaintext includes any zero padding.
Uint8List? meshMacThenDecrypt(List<int> secret, List<int> data) {
  if (data.length <= 2) return null;
  final ct = data.sublist(2);
  if (ct.length % 16 != 0) return null;
  final mac = hmacSha256(_hmacKey(secret), ct);
  if (mac[0] != data[0] || mac[1] != data[1]) return null;
  final aes = Aes128(secret.sublist(0, 16));
  final out = Uint8List(ct.length);
  for (var i = 0; i < ct.length; i += 16) {
    out.setRange(i, i + 16, aes.decryptBlock(ct.sublist(i, i + 16)));
  }
  return out;
}

String toHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHex(String hex) {
  final h = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
