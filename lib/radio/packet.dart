// MeshCore over-the-air packet parsing (the raw bytes carried in PUSH_CODE_LOG_RX_DATA), and recognition of
// echoes of our own channel ping.
//
// Source of truth: MeshCore firmware (MIT, © 2025 Scott Powell / rippleradios.com):
//  - src/Packet.h — header bit layout (PH_ROUTE_MASK, PH_TYPE_SHIFT/MASK, PH_VER_SHIFT/MASK), route and payload types,
//    path_len encoding getPathHashSize()/getPathHashCount() (bits 6–7 = hash size − 1, bits 0–5 = hop count).
//  - src/Packet.cpp readFrom()/isValidPathLen() — wire order [header][transport x4 if TRANSPORT_*][path_len][path][payload],
//    hash size 4 is reserved/invalid, path bytes ≤ 64 (MAX_PATH_SIZE).
//  - src/Mesh.cpp routeRecvPacket() (~line 344) — each repeater APPENDS its own hash (prefix of its public key) to
//    the path of a flood packet before retransmitting. So path[0] is the repeater that first heard the sender, and
//    the number of path entries is the number of repeats.
//  - src/Mesh.cpp createGroupDatagram() (~line 540) + src/helpers/BaseChatMesh.cpp sendGroupMessage() (~line 518) —
//    GRP_TXT payload = [channel_hash x1][MAC x2][AES-128-ECB("ts u32" "flags=0" "<sender>: <text>")].
//
// Echo recognition is adapted from the MeshMapper web client (MIT, © 2025 MrAlders0n), content/wardrive.js
// parseRxPacketMetadata() / handleTxLogging() / decryptGroupTextPayload(): GRP_TXT with our channel hash, decrypts
// with the channel key, the decrypted text contains the ping text we sent, and path length > 0; repeater id = first
// path hop. Differences from MeshMapper (firmware wins):
//  - MeshMapper only accepts header == 0x15 (FLOOD + GRP_TXT + v1). The companion firmware sends channel text with
//    sendFloodScoped(), which uses ROUTE_TYPE_TRANSPORT_FLOOD (header 0x14, 4 transport-code bytes) when a flood
//    scope/region is set. We accept both flood route types.
//  - MeshMapper treats every path byte as one hop. Firmware ≥ 1.12 supports 2- and 3-byte path hashes (path_len bits
//    6–7). We decode the hash size, so hops and repeater prefixes stay right on multi-byte-hash meshes.
//  - We also verify the MAC and (when known) the 4-byte timestamp we put in the send command, so a later ping with the
//    same text can't claim an earlier ping's echoes.
import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';

abstract final class RouteType {
  static const transportFlood = 0;
  static const flood = 1;
  static const direct = 2;
  static const transportDirect = 3;
}

abstract final class PayloadType {
  static const req = 0x00;
  static const response = 0x01;
  static const txtMsg = 0x02;
  static const ack = 0x03;
  static const advert = 0x04;
  static const grpTxt = 0x05;
  static const grpData = 0x06;
  static const anonReq = 0x07;
  static const path = 0x08;
  static const trace = 0x09;
  static const multipart = 0x0A;
  static const control = 0x0B;
  static const rawCustom = 0x0F;
}

/// MAX_PATH_SIZE (src/MeshCore.h line 22).
const int maxPathBytes = 64;

class MeshPacket {
  final int header;
  final int? transportCode1;
  final int? transportCode2;

  /// Raw encoded path_len byte.
  final int pathLenByte;

  /// One entry per hop, each [pathHashSize] bytes.
  final List<Uint8List> path;
  final Uint8List payload;

  const MeshPacket({
    required this.header,
    this.transportCode1,
    this.transportCode2,
    required this.pathLenByte,
    required this.path,
    required this.payload,
  });

  int get routeType => header & 0x03;
  int get payloadType => (header >> 2) & 0x0F;
  int get payloadVersion => (header >> 6) & 0x03;
  bool get isFlood => routeType == RouteType.flood || routeType == RouteType.transportFlood;
  bool get hasTransportCodes => routeType == RouteType.transportFlood || routeType == RouteType.transportDirect;
  int get pathHashSize => (pathLenByte >> 6) + 1;
  int get hopCount => pathLenByte & 63;

  /// Path as lower-case hex, one string per hop.
  List<String> get pathHex => path.map(toHex).toList();

  /// Parses a raw packet. Returns null for anything the firmware itself would reject (Packet::readFrom).
  static MeshPacket? tryParse(List<int> raw) {
    if (raw.length < 2) return null;
    var i = 0;
    final header = raw[i++];
    int? tc1, tc2;
    final rt = header & 0x03;
    if (rt == RouteType.transportFlood || rt == RouteType.transportDirect) {
      if (raw.length < i + 4) return null;
      tc1 = raw[i] | (raw[i + 1] << 8);
      tc2 = raw[i + 2] | (raw[i + 3] << 8);
      i += 4;
    }
    if (i >= raw.length) return null;
    final pl = raw[i++];
    final size = (pl >> 6) + 1;
    final count = pl & 63;
    if (size == 4) return null; // reserved
    final pathBytes = size * count;
    if (pathBytes > maxPathBytes) return null;
    if (i + pathBytes >= raw.length) return null; // firmware requires a non-empty payload
    final path = <Uint8List>[
      for (var h = 0; h < count; h++) Uint8List.fromList(raw.sublist(i + h * size, i + (h + 1) * size)),
    ];
    i += pathBytes;
    return MeshPacket(
      header: header,
      transportCode1: tc1,
      transportCode2: tc2,
      pathLenByte: pl,
      path: path,
      payload: Uint8List.fromList(raw.sublist(i)),
    );
  }

  /// Serialises like Packet::writeTo (src/Packet.cpp).
  Uint8List toBytes() {
    final b = BytesBuilder()..addByte(header);
    if (hasTransportCodes) {
      final t1 = transportCode1 ?? 0, t2 = transportCode2 ?? 0;
      b.add([t1 & 0xff, t1 >> 8, t2 & 0xff, t2 >> 8]);
    }
    b.addByte(pathLenByte);
    for (final p in path) {
      b.add(p);
    }
    b.add(payload);
    return b.toBytes();
  }
}

/// Encodes a path_len byte (Packet::setPathHashSizeAndCount).
int encodePathLen(int hashSize, int count) => ((hashSize - 1) << 6) | (count & 63);

/// Header byte: version bits 6–7, payload type bits 2–5, route type bits 0–1.
int makeHeader(int routeType, int payloadType, [int version = 0]) =>
    ((version & 3) << 6) | ((payloadType & 0x0F) << 2) | (routeType & 3);

/// Decrypted GRP_TXT contents: timestamp (u32), flags, then text of the form `<sender>: <message>`.
class GroupText {
  final int timestamp;
  final int flags;
  final String text;
  const GroupText(this.timestamp, this.flags, this.text);
}

/// Builds the GRP_TXT payload a companion produces for [text] from [senderName] (BaseChatMesh::sendGroupMessage +
/// Mesh::createGroupDatagram). Used by the simulator and tests.
Uint8List buildGroupTextPayload(List<int> secret16, int timestamp, String senderName, String text) {
  final body = utf8.encode('$senderName: $text');
  final plain = Uint8List(5 + body.length);
  ByteData.sublistView(plain).setUint32(0, timestamp, Endian.little);
  plain[4] = 0; // TXT_TYPE_PLAIN
  plain.setRange(5, plain.length, body);
  return Uint8List.fromList([channelHash(secret16), ...meshEncryptThenMac(secret16, plain)]);
}

/// Decrypts a GRP_TXT payload if it belongs to the channel with [secret16]; null otherwise.
GroupText? decryptGroupText(List<int> secret16, List<int> payload) {
  if (payload.length < 3 || payload[0] != channelHash(secret16)) return null;
  final plain = meshMacThenDecrypt(secret16, payload.sublist(1));
  if (plain == null || plain.length < 5) return null;
  var end = plain.length;
  while (end > 5 && plain[end - 1] == 0) {
    end--;
  }
  final text = utf8.decode(plain.sublist(5, end), allowMalformed: true);
  return GroupText(ByteData.sublistView(plain).getUint32(0, Endian.little), plain[4], text);
}

/// What we learn from one heard repeat of our ping.
class EchoMatch {
  /// First path hop: the repeater that heard our transmission directly.
  final String repeater;
  final int hops;
  final List<String> path;
  const EchoMatch(this.repeater, this.hops, this.path);
}

/// Recognises a heard packet as a repeat of the ping we sent.
///
/// [secret16] is the channel secret, [pingText] the exact text passed to CMD_SEND_CHANNEL_TXT_MSG, and
/// [timestamp] the timestamp we put in that command (null = don't check). Returns null if it's anything else,
/// including our own transmission heard with an empty path (not a repeat).
EchoMatch? matchEcho(MeshPacket pkt, List<int> secret16, String pingText, {int? timestamp}) {
  if (pkt.payloadType != PayloadType.grpTxt || !pkt.isFlood) return null;
  if (pkt.path.isEmpty) return null;
  final gt = decryptGroupText(secret16, pkt.payload);
  if (gt == null) return null;
  if (timestamp != null && gt.timestamp != timestamp) return null;
  // Text is "<sender name>: <ping text>" (BaseChatMesh::sendGroupMessage).
  if (!(gt.text == pingText || gt.text.endsWith(': $pingText'))) return null;
  final hex = pkt.pathHex;
  return EchoMatch(hex.first, pkt.hopCount, hex);
}
