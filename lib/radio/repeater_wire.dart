// Binary requests to a repeater and the parsers for what comes back. Every layout here was measured on a real repeater
// (INNO-OB-2, observer firmware v1.17.1.5, Oct 31 2026) and is pinned by test/radio/repeater_wire_test.dart against the
// hex captured in meshsonar-infra/docs/planning/research-logs. Source: repeater-observer-live-research-2026-11-01.md
// section B, firmware examples/simple_repeater/MyMesh.cpp. Pure Dart.
//
// Binary answers beat CLI text for status data: they are structured, have no 160-character cap, and do not touch the
// CLI replay rule. Every answer is zero padded to 16-byte blocks, so these parsers trust the counts inside the data.
import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart' show fromHex, toHex;
import 'protocol.dart';

// ------------------------------------------------------------------ request encoders

/// Request type bytes inside CMD_SEND_BINARY_REQ (50).
abstract final class BinaryReqType {
  static const accessList = 0x05;
  static const neighbours = 0x06;
  static const owner = 0x07;
}

/// Request type bytes inside CMD_SEND_ANON_REQ (57). These work with NO login, direct route only.
abstract final class AnonReqType {
  static const regions = 0x01;
  static const owner = 0x02;
  static const basic = 0x03; // clock + feature flags
}

List<int> _key32(List<int> k) {
  if (k.length != 32) throw ArgumentError('a MeshCore public key is 32 bytes');
  return k;
}

/// [50][pub_key x32][request...] -> SENT, later PUSH_CODE_BINARY_RESPONSE with the SENT tag.
Uint8List encodeSendBinaryReq(List<int> pubKey32, List<int> request) =>
    Uint8List.fromList([Cmd.sendBinaryReq, ..._key32(pubKey32), ...request]);

/// [57][pub_key x32][request...] -> SENT, later PUSH_CODE_BINARY_RESPONSE.
Uint8List encodeSendAnonReq(List<int> pubKey32, List<int> request) =>
    Uint8List.fromList([Cmd.sendAnonReq, ..._key32(pubKey32), ...request]);

/// [39][0 0 0][pub_key x32] -> SENT, later PUSH_CODE_TELEMETRY_RESPONSE from that node (the 4-byte form is the radio's own).
Uint8List encodeSendRemoteTelemetryReq(List<int> pubKey32) =>
    Uint8List.fromList([Cmd.sendTelemetryReq, 0, 0, 0, ..._key32(pubKey32)]);

/// Neighbour list request: [6][version 0][count][offset u16][order][prefix length][random x4]. [order]: 0 newest first,
/// 1 oldest first, 2 strongest first, 3 weakest first (measured: 0 returns newest first). [prefixLen] 1..32 bytes of each
/// neighbour's key; the reply buffer is about 130 bytes, so 4-byte prefixes give at most 14 entries per page.
List<int> neighboursRequest({int count = 8, int offset = 0, int order = 0, int prefixLen = 4, List<int> random = const [1, 2, 3, 4]}) => [
      BinaryReqType.neighbours,
      0,
      count & 0xff,
      offset & 0xff,
      (offset >> 8) & 0xff,
      order & 0xff,
      prefixLen & 0xff,
      ...random.take(4),
    ];

const List<int> accessListRequest = [BinaryReqType.accessList, 0, 0];
const List<int> ownerRequest = [BinaryReqType.owner];
const List<int> anonBasicRequest = [AnonReqType.basic, 0];
const List<int> anonRegionsRequest = [AnonReqType.regions, 0];
const List<int> anonOwnerRequest = [AnonReqType.owner, 0];

// ------------------------------------------------------------------ status block

/// The whole RepeaterStats struct (MyMesh.h, little endian, 56 bytes), as measured. [RepeaterStatus] in protocol.dart
/// keeps only the first fields; this has all of them.
class RepeaterStats {
  final int battMilliVolts;
  final int txQueueLen;
  final int noiseFloorDbm;
  final int lastRssiDbm;
  final int packetsRecv;
  final int packetsSent;
  final int airTimeSecs;
  final int upTimeSecs;
  final int sentFlood;
  final int sentDirect;
  final int recvFlood;
  final int recvDirect;
  final int errEvents;
  final double lastSnrDb;
  final int directDups;
  final int floodDups;
  final int rxAirTimeSecs;
  final int recvErrors;

  const RepeaterStats({
    required this.battMilliVolts,
    required this.txQueueLen,
    required this.noiseFloorDbm,
    required this.lastRssiDbm,
    required this.packetsRecv,
    required this.packetsSent,
    required this.airTimeSecs,
    required this.upTimeSecs,
    this.sentFlood = 0,
    this.sentDirect = 0,
    this.recvFlood = 0,
    this.recvDirect = 0,
    this.errEvents = 0,
    this.lastSnrDb = 0,
    this.directDups = 0,
    this.floodDups = 0,
    this.rxAirTimeSecs = 0,
    this.recvErrors = 0,
  });

  /// Parses the 56-byte block (extra zero padding is fine). Older builds send a prefix of it: later fields read 0. Null
  /// when fewer than the first 24 bytes (battery .. uptime) are there.
  static RepeaterStats? parse(Uint8List b) {
    if (b.length < 24) return null;
    final bd = ByteData.sublistView(b);
    int u32(int o) => b.length >= o + 4 ? bd.getUint32(o, Endian.little) : 0;
    int u16(int o) => b.length >= o + 2 ? bd.getUint16(o, Endian.little) : 0;
    return RepeaterStats(
      battMilliVolts: bd.getUint16(0, Endian.little),
      txQueueLen: bd.getUint16(2, Endian.little),
      noiseFloorDbm: bd.getInt16(4, Endian.little),
      lastRssiDbm: bd.getInt16(6, Endian.little),
      packetsRecv: u32(8),
      packetsSent: u32(12),
      airTimeSecs: u32(16),
      upTimeSecs: u32(20),
      sentFlood: u32(24),
      sentDirect: u32(28),
      recvFlood: u32(32),
      recvDirect: u32(36),
      errEvents: u16(40),
      lastSnrDb: b.length >= 44 ? bd.getInt16(42, Endian.little) / 4.0 : 0,
      directDups: u16(44),
      floodDups: u16(46),
      rxAirTimeSecs: u32(48),
      recvErrors: u32(52),
    );
  }

  /// Radio-side encoder (tests, simulator): the 56 bytes.
  Uint8List encode() {
    final bd = ByteData(56)
      ..setUint16(0, battMilliVolts, Endian.little)
      ..setUint16(2, txQueueLen, Endian.little)
      ..setInt16(4, noiseFloorDbm, Endian.little)
      ..setInt16(6, lastRssiDbm, Endian.little)
      ..setUint32(8, packetsRecv, Endian.little)
      ..setUint32(12, packetsSent, Endian.little)
      ..setUint32(16, airTimeSecs, Endian.little)
      ..setUint32(20, upTimeSecs, Endian.little)
      ..setUint32(24, sentFlood, Endian.little)
      ..setUint32(28, sentDirect, Endian.little)
      ..setUint32(32, recvFlood, Endian.little)
      ..setUint32(36, recvDirect, Endian.little)
      ..setUint16(40, errEvents, Endian.little)
      ..setInt16(42, (lastSnrDb * 4).round(), Endian.little)
      ..setUint16(44, directDups, Endian.little)
      ..setUint16(46, floodDups, Endian.little)
      ..setUint32(48, rxAirTimeSecs, Endian.little)
      ..setUint32(52, recvErrors, Endian.little);
    return bd.buffer.asUint8List();
  }

  /// Battery in volts.
  double get batteryV => battMilliVolts / 1000.0;
}

// ------------------------------------------------------------------ telemetry (Cayenne LPP, BIG endian)

/// One Cayenne LPP value from a repeater's telemetry answer.
class LppValue {
  final int channel;
  final int type;
  final double value;
  const LppValue(this.channel, this.type, this.value);

  static const int typeVoltage = 116; // 0.01 V, u16
  static const int typeTemperature = 103; // 0.1 C, i16
  static const int typeHumidity = 104; // 0.5 %, u8
  static const int typePressure = 115; // 0.1 hPa, u16
  static const int typeAnalog = 2; // 0.01, i16
}

/// What a repeater's telemetry answer holds. Measured: [01 74 01 82][01 67 01 C2] = 3.86 V, 45.0 C, then zero padding.
class RepeaterTelemetry {
  final double? voltageV;
  final double? temperatureC;
  final List<LppValue> values;
  const RepeaterTelemetry({this.voltageV, this.temperatureC, this.values = const []});

  /// Parses a CayenneLPP block. Stops at padding (channel 0, type 0, only zeros after) or an unknown type. Never throws.
  static RepeaterTelemetry parse(Uint8List lpp) {
    final bd = ByteData.sublistView(lpp);
    final out = <LppValue>[];
    double? volt, temp;
    var i = 0;
    while (i + 2 <= lpp.length) {
      final ch = lpp[i], type = lpp[i + 1];
      if (ch == 0 && type == 0) break; // zero padding
      final size = _lppSizes[type];
      if (size == null || i + 2 + size > lpp.length) break;
      final at = i + 2;
      double? v;
      switch (type) {
        case LppValue.typeVoltage:
          v = bd.getUint16(at, Endian.big) / 100.0;
        case LppValue.typeTemperature:
          v = bd.getInt16(at, Endian.big) / 10.0;
        case LppValue.typeHumidity:
          v = lpp[at] / 2.0;
        case LppValue.typePressure:
          v = bd.getUint16(at, Endian.big) / 10.0;
        case LppValue.typeAnalog:
          v = bd.getInt16(at, Endian.big) / 100.0;
      }
      if (v != null) {
        out.add(LppValue(ch, type, v));
        if (ch == 1 && type == LppValue.typeVoltage) volt ??= v;
        if (ch == 1 && type == LppValue.typeTemperature) temp ??= v;
      }
      i += 2 + size;
    }
    return RepeaterTelemetry(voltageV: volt, temperatureC: temp, values: out);
  }

  /// Radio-side encoder (tests).
  static Uint8List encodeLpp({double? voltageV, double? temperatureC, int pad = 4}) {
    final b = BytesBuilder();
    if (voltageV != null) {
      final v = (voltageV * 100).round();
      b.add([1, LppValue.typeVoltage, (v >> 8) & 0xff, v & 0xff]);
    }
    if (temperatureC != null) {
      final t = (temperatureC * 10).round() & 0xffff;
      b.add([1, LppValue.typeTemperature, (t >> 8) & 0xff, t & 0xff]);
    }
    b.add(List<int>.filled(pad, 0));
    return b.toBytes();
  }
}

const Map<int, int> _lppSizes = {
  0: 1, 1: 1, 2: 2, 3: 2, 100: 4, 101: 2, 102: 1, 103: 2, 104: 1, 113: 6, 115: 2, 116: 2, 117: 2, 118: 4, 120: 1,
  121: 2, 125: 2, 128: 2, 130: 4, 131: 4, 132: 2, 133: 4, 134: 6, 135: 3, 136: 9, 142: 1,
};

// ------------------------------------------------------------------ neighbours

class RepeaterNeighbour {
  /// First bytes of the neighbour's key, lower-case hex (8 characters for a 4-byte prefix).
  final String prefixHex;
  final int secondsAgo;

  /// dB; the wire carries it times four.
  final double snrDb;
  const RepeaterNeighbour(this.prefixHex, this.secondsAgo, this.snrDb);
}

class NeighbourPage {
  /// How many neighbours the repeater has in all.
  final int total;
  final List<RepeaterNeighbour> entries;
  const NeighbourPage(this.total, this.entries);

  /// [data]: [total u16][returned u16][entries: prefix x [prefixLen], seconds ago u32, snr i8]. Measured: 6 entries of 9
  /// bytes, then padding. Null when the data is too short for its own counts.
  static NeighbourPage? parse(Uint8List data, {int prefixLen = 4}) {
    if (data.length < 4) return null;
    final bd = ByteData.sublistView(data);
    final total = bd.getUint16(0, Endian.little);
    final n = bd.getUint16(2, Endian.little);
    final each = prefixLen + 5;
    if (data.length < 4 + n * each) return null;
    final out = <RepeaterNeighbour>[];
    for (var i = 0; i < n; i++) {
      final o = 4 + i * each;
      out.add(RepeaterNeighbour(toHex(data.sublist(o, o + prefixLen)), bd.getUint32(o + prefixLen, Endian.little), bd.getInt8(o + prefixLen + 4) / 4.0));
    }
    return NeighbourPage(total, out);
  }

  static Uint8List encode(int total, List<RepeaterNeighbour> e, {int prefixLen = 4}) {
    final b = BytesBuilder()..add([total & 0xff, total >> 8, e.length & 0xff, e.length >> 8]);
    for (final n in e) {
      b.add(fromHex(n.prefixHex).take(prefixLen).toList());
      b.add([n.secondsAgo & 0xff, (n.secondsAgo >> 8) & 0xff, (n.secondsAgo >> 16) & 0xff, (n.secondsAgo >> 24) & 0xff]);
      b.add([(n.snrDb * 4).round() & 0xff]);
    }
    return b.toBytes();
  }
}

// ------------------------------------------------------------------ access list

/// ACL roles as the repeater stores them (low two bits of the permission byte).
enum AclRole {
  guest(0, 'Guest'),
  readOnly(1, 'Read only'),
  readWrite(2, 'Read and write'),
  admin(3, 'Admin');

  final int value;
  final String label;
  const AclRole(this.value, this.label);
  static AclRole of(int perm) => AclRole.values[perm & 3];
}

class AclEntry {
  /// 12 hex characters (6 bytes) of the client's key.
  final String prefixHex;
  final AclRole role;
  const AclEntry(this.prefixHex, this.role);
}

/// Parses the access-list answer: 7-byte entries [pub6][perm]; guests (perm 0) and the all-zero padding are skipped.
/// Measured: 2 admins then 14 zero bytes.
List<AclEntry> parseAclList(Uint8List data) {
  final out = <AclEntry>[];
  for (var o = 0; o + 7 <= data.length; o += 7) {
    final perm = data[o + 6];
    var zero = true;
    for (var i = 0; i < 6; i++) {
      if (data[o + i] != 0) zero = false;
    }
    if (zero || perm == 0) continue;
    out.add(AclEntry(toHex(data.sublist(o, o + 6)), AclRole.of(perm)));
  }
  return out;
}

// ------------------------------------------------------------------ owner / anonymous answers

/// Strips the trailing zero padding and decodes UTF-8.
String textOf(Uint8List b) {
  var end = b.length;
  while (end > 0 && b[end - 1] == 0) {
    end--;
  }
  return utf8.decode(b.sublist(0, end), allowMalformed: true);
}

class OwnerInfo {
  final String firmware;
  final String name;
  final String owner;
  const OwnerInfo(this.firmware, this.name, this.owner);

  /// Binary owner request: "version\nname\nowner" (measured: "v1.17.1.5-observer-7403067\nINNO-OB-2\n"). The anonymous
  /// owner request has a 4-byte clock in front and no version line: use [parseAnon].
  static OwnerInfo parse(Uint8List data) {
    final lines = textOf(data).split('\n');
    return OwnerInfo(lines.isNotEmpty ? lines[0] : '', lines.length > 1 ? lines[1] : '', lines.length > 2 ? lines.sublist(2).join('\n') : '');
  }

  /// Anonymous owner answer: [clock u32]["name\nowner"].
  static OwnerInfo parseAnon(Uint8List data) {
    final lines = textOf(data.length > 4 ? data.sublist(4) : Uint8List(0)).split('\n');
    return OwnerInfo('', lines.isNotEmpty ? lines[0] : '', lines.length > 1 ? lines.sublist(1).join('\n') : '');
  }
}

/// Answer to the anonymous basic request: [clock u32][features u8]. Features: 0x80 repeat disabled, 0x01 / 0x03 bridge.
class AnonClock {
  /// The repeater's clock, epoch seconds.
  final int epochSecs;
  final int features;
  const AnonClock(this.epochSecs, this.features);
  bool get repeatDisabled => (features & 0x80) != 0;

  static AnonClock? parse(Uint8List data) {
    if (data.length < 4) return null;
    return AnonClock(ByteData.sublistView(data).getUint32(0, Endian.little), data.length > 4 ? data[4] : 0);
  }
}

/// Anonymous regions answer: [clock u32]["*,cmh"] = the regions that are not denied, comma separated.
List<String> parseAnonRegions(Uint8List data) {
  if (data.length <= 4) return const [];
  return textOf(data.sublist(4)).split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}
