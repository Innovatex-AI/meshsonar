// Decoding of an ADVERT packet's payload (public broadcast, so its name and position are not private):
// [pub_key x32][timestamp u32][signature x64][app data]; app data = [flags][lat i32][lon i32 (flag 0x10)][feat1 u16 (0x20)]
// [feat2 u16 (0x40)][name (0x80)]; flags & 0x0F is the node type (AdvType). Layout: src/helpers/AdvertDataHelpers.cpp,
// VERIFIED against two real adverts from INNO-OB-2 (research-logs/live-run3.json repeater_adverts_raw, Nov 1 2026).
// The signature is NOT checked here (no Ed25519 in the app's pure layer): a heard advert is a hint, never proof.
// Pure Dart.
import 'dart:convert';
import 'dart:typed_data';

import '../crypto.dart' show toHex;
import '../packet.dart';

class AdvertInfo {
  final String publicKeyHex;
  final int timestamp;
  final int nodeType;
  final String name;
  final double? lat;
  final double? lon;
  const AdvertInfo({required this.publicKeyHex, required this.timestamp, required this.nodeType, required this.name, this.lat, this.lon});

  bool get hasPosition => lat != null && lon != null;

  /// The 1-byte path hash this node uses: first byte of its key.
  String get hash1 => publicKeyHex.substring(0, 2);

  static AdvertInfo? tryParse(MeshPacket p) {
    if (p.payloadType != PayloadType.advert) return null;
    return tryParsePayload(p.payload);
  }

  static AdvertInfo? tryParsePayload(Uint8List payload) {
    // pub key 32 + timestamp 4 + signature 64 + at least the flags byte.
    if (payload.length < 101) return null;
    final bd = ByteData.sublistView(payload);
    final flags = payload[100];
    var k = 101;
    double? lat, lon;
    if (flags & 0x10 != 0) {
      if (payload.length < k + 8) return null;
      final la = bd.getInt32(k, Endian.little), lo = bd.getInt32(k + 4, Endian.little);
      k += 8;
      // 0,0 is "no position" in MeshCore; out of range is garbage.
      if ((la != 0 || lo != 0) && la.abs() <= 90000000 && lo.abs() <= 180000000) {
        lat = la / 1e6;
        lon = lo / 1e6;
      }
    }
    if (flags & 0x20 != 0) k += 2;
    if (flags & 0x40 != 0) k += 2;
    if (k > payload.length) return null;
    final name = flags & 0x80 != 0 ? _cleanName(utf8.decode(payload.sublist(k), allowMalformed: true)) : '';
    return AdvertInfo(
      publicKeyHex: toHex(payload.sublist(0, 32)),
      timestamp: bd.getUint32(32, Endian.little),
      nodeType: flags & 0x0F,
      name: name,
      lat: lat,
      lon: lon,
    );
  }

  /// A name arrives from a stranger: drop control characters and cut it to a sane length.
  static String _cleanName(String s) {
    final t = s.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '').trim();
    return t.length > 40 ? t.substring(0, 40) : t;
  }
}

/// Radio side / test helper: the ADVERT payload for a node (unsigned: the signature is zero bytes).
Uint8List buildAdvertPayload(List<int> pubKey32, int timestamp, int nodeType, String name, {double? lat, double? lon}) {
  final app = BytesBuilder();
  var flags = nodeType & 0x0F;
  if (lat != null && lon != null) flags |= 0x10;
  if (name.isNotEmpty) flags |= 0x80;
  app.addByte(flags);
  if (lat != null && lon != null) {
    final b = ByteData(8)
      ..setInt32(0, (lat * 1e6).round(), Endian.little)
      ..setInt32(4, (lon * 1e6).round(), Endian.little);
    app.add(b.buffer.asUint8List());
  }
  if (name.isNotEmpty) app.add(utf8.encode(name));
  final head = ByteData(4)..setUint32(0, timestamp, Endian.little);
  return Uint8List.fromList([...pubKey32, ...head.buffer.asUint8List(), ...Uint8List(64), ...app.toBytes()]);
}
