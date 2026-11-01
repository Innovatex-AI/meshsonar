// Frames the Tools use: trace path, self advert, node discovery, advert path, telemetry request for a contact, and the
// radio-setup writes. Encoders (app to radio) and decoders (radio to app), plus the radio-side encoders the simulator
// and the tests play back.
//
// Layouts: MeshCore firmware examples/companion_radio/MyMesh.cpp at 81dbae5 (FIRMWARE_VER_CODE 14, MIT, (c) 2025 Scott
// Powell / rippleradios.com), read in full Nov 1 2026. Each block says whether it was also seen on real hardware
// (VERIFIED = in docs/planning/research-logs, companion fw code 13) or is firmware-source only (FW).
// All integers are little endian. Pure Dart.
import 'dart:typed_data';

import '../protocol.dart' show Cmd, Push, Resp;

abstract final class ToolCmd {
  static const sendSelfAdvert = 7;
  static const setAdvertName = 8;
  static const setRadioParams = 11;
  static const setRadioTxPower = 12;
  static const setAdvertLatLon = 14;
  static const sendTracePath = 36;
  static const getAdvertPath = 42;
}

abstract final class ToolResp {
  static const advertPath = 22;
}

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v & 0xffffffff, Endian.little);
int _i8(num v) => v.round().clamp(-128, 127) & 0xff;

// ------------------------------------------------------------------ trace path

/// Hash widths a trace can use: flags & 3 is the shift, so 1, 2 or 4 bytes per hop (MyMesh.cpp 1813-1820).
const List<int> traceHashSizes = [1, 2, 4];

/// Most hops a trace path may have here. The firmware allows MAX_PATH_SIZE (64) hash bytes; eight hops is far more
/// than any real mesh route and keeps the reply inside one BLE frame.
const int maxTraceHops = 8;

int traceFlagsForHashSize(int hashSize) => switch (hashSize) {
      1 => 0,
      2 => 1,
      4 => 2,
      _ => throw ArgumentError('a trace hash is 1, 2 or 4 bytes'),
    };

/// CMD_SEND_TRACE_PATH: [36][tag u32][auth u32][flags][hash bytes...] (MyMesh.cpp 1813-1832). The path must be at least one
/// hash; a 0-byte path answers ERR 1 (VERIFIED). Answer: RESP_CODE_SENT [6][0][tag][est_timeout_ms u32], then later a
/// PUSH_CODE_TRACE_DATA (VERIFIED, 0.36-0.54 s on a 0-hop link; est_timeout 2.5-3.8 s). A path with a hop that does not
/// exist gets NO push at all (VERIFIED, 3 tests, 12 s).
Uint8List encodeSendTracePath(int tag, List<int> pathBytes, {int hashSize = 2, int auth = 0}) {
  final flags = traceFlagsForHashSize(hashSize);
  if (pathBytes.isEmpty || pathBytes.length % hashSize != 0) {
    throw ArgumentError('the path must be a whole number of $hashSize-byte hashes');
  }
  if (pathBytes.length ~/ hashSize > maxTraceHops) throw ArgumentError('a trace path has at most $maxTraceHops hops');
  return Uint8List.fromList([ToolCmd.sendTracePath, ..._u32(tag), ..._u32(auth), flags, ...pathBytes]);
}

/// PUSH_CODE_TRACE_DATA (0x89, MyMesh.cpp 855-890, VERIFIED on hardware):
/// [0x89][0][path_len bytes][flags][tag u32][auth u32][path hashes x path_len][snr i8 x4 per hop][final snr i8 x4].
/// `hops = path_len >> (flags & 3)`. Each hop's SNR is how THAT repeater heard the packet; the final SNR is how this
/// radio heard the packet coming back from the last hop.
class TraceData {
  final int tag;
  final int auth;
  final int flags;
  final Uint8List hashes;
  final List<double> hopSnrDb;
  final double? finalSnrDb;
  const TraceData({required this.tag, required this.auth, required this.flags, required this.hashes, required this.hopSnrDb, this.finalSnrDb});

  int get hashSize => 1 << (flags & 3);
  int get hops => hashes.length ~/ hashSize;
  String hopHashHex(int i) {
    final b = hashes.sublist(i * hashSize, (i + 1) * hashSize);
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  static TraceData? tryParse(Uint8List f) {
    if (f.length < 13 || f[0] != Push.traceData) return null;
    final bd = ByteData.sublistView(f);
    final pl = f[2];
    final flags = f[3];
    final sz = flags & 3;
    final n = pl >> sz;
    if (12 + pl + n > f.length) return null;
    final snrs = <double>[for (var i = 0; i < n; i++) bd.getInt8(12 + pl + i) / 4.0];
    final fin = f.length > 12 + pl + n ? bd.getInt8(12 + pl + n) / 4.0 : null;
    return TraceData(
      tag: bd.getUint32(4, Endian.little),
      auth: bd.getUint32(8, Endian.little),
      flags: flags,
      hashes: Uint8List.fromList(f.sublist(12, 12 + pl)),
      hopSnrDb: snrs,
      finalSnrDb: fin,
    );
  }
}

/// Radio side of the trace answer (simulator and tests).
Uint8List encodeTraceDataPush(int tag, List<int> hashes, List<double> hopSnrDb, double finalSnrDb, {int hashSize = 2, int auth = 0}) =>
    Uint8List.fromList([
      Push.traceData,
      0,
      hashes.length,
      traceFlagsForHashSize(hashSize),
      ..._u32(tag),
      ..._u32(auth),
      ...hashes,
      for (final s in hopSnrDb) _i8(s * 4),
      _i8(finalSnrDb * 4),
    ]);

// ------------------------------------------------------------------ self advert

/// CMD_SEND_SELF_ADVERT: [7][0 zero-hop | 1 flood] -> OK (VERIFIED, 60 ms). Zero-hop is heard by direct neighbours only; a
/// flood advert is repeated by every repeater in the radio's default scope (VERIFIED: re-flooded by the repeater and heard
/// back at hop 1). The advert carries the radio's stored position only when its advert location policy allows it.
Uint8List encodeSendSelfAdvert({required bool flood}) => Uint8List.fromList([ToolCmd.sendSelfAdvert, flood ? 1 : 0]);

// ------------------------------------------------------------------ node discovery (control data)

/// Node type bits for the discovery filter: bit n = AdvType n (src/helpers/AdvertDataHelpers.h): chat 1, repeater 2, room 3,
/// sensor 4.
int discoverFilterFor(Iterable<int> advTypes) => advTypes.fold(0, (m, t) => m | (1 << t));

/// The default ask: repeaters, rooms and sensors.
final int discoverFilterInfrastructure = discoverFilterFor(const [2, 3, 4]);

// ------------------------------------------------------------------ advert path

/// CMD_GET_ADVERT_PATH: [42][reserved 0][pub_key x32] -> RESP_CODE_ADVERT_PATH [22][recv timestamp u32][path_len][path...]
/// or ERR 2 when the radio has no path for that key (MyMesh.cpp 1893-1913; 16-entry RAM table). Only the first 7 bytes of
/// the key are compared by the firmware. FW + VERIFIED (answered with path_len byte 0x40 = 2-byte hash, 0 hops).
Uint8List encodeGetAdvertPath(List<int> pubKey32) {
  if (pubKey32.length != 32) throw ArgumentError('a MeshCore public key is 32 bytes');
  return Uint8List.fromList([ToolCmd.getAdvertPath, 0, ...pubKey32]);
}

class AdvertPathFrame {
  final int receivedAtEpoch;
  final int pathLenByte;
  final Uint8List path;
  const AdvertPathFrame(this.receivedAtEpoch, this.pathLenByte, this.path);
  int get hops => pathLenByte & 63;
  int get hashSize => (pathLenByte >> 6) + 1;

  static AdvertPathFrame? tryParse(Uint8List f) {
    if (f.length < 6 || f[0] != ToolResp.advertPath) return null;
    final bd = ByteData.sublistView(f);
    final pl = f[5];
    final n = (pl & 63) * ((pl >> 6) + 1);
    if (6 + n > f.length) return null;
    return AdvertPathFrame(bd.getUint32(1, Endian.little), pl, Uint8List.fromList(f.sublist(6, 6 + n)));
  }
}

Uint8List encodeAdvertPathResponse(int recvEpoch, int pathLenByte, List<int> path) =>
    Uint8List.fromList([ToolResp.advertPath, ..._u32(recvEpoch), pathLenByte, ...path]);

// ------------------------------------------------------------------ telemetry request for a contact

/// CMD_SEND_TELEMETRY_REQ with a key: [39][0 0 0][pub_key x32] -> SENT [6][flood][tag][est_timeout], later
/// PUSH_CODE_TELEMETRY_RESPONSE [0x8B][0][pub_key prefix x6][Cayenne LPP, big endian] (VERIFIED: 0.63-0.72 s, battery
/// 3.86 V + MCU temperature 45.0 C from a repeater). ERR 2 when the radio does not have the contact. The firmware marks
/// this command deprecated in favour of CMD_SEND_BINARY_REQ, but it still works on code 13 and 14.
Uint8List encodeTelemetryReqFor(List<int> pubKey32) {
  if (pubKey32.length != 32) throw ArgumentError('a MeshCore public key is 32 bytes');
  return Uint8List.fromList([Cmd.sendTelemetryReq, 0, 0, 0, ...pubKey32]);
}

/// The radio's own telemetry request is exactly 4 bytes (see protocol.dart encodeSelfTelemetryReq).

class TelemetryPush {
  final String prefixHex;
  final Uint8List lpp;
  const TelemetryPush(this.prefixHex, this.lpp);

  static TelemetryPush? tryParse(Uint8List f) {
    if (f.length < 8 || f[0] != Push.telemetryResponse) return null;
    final sb = StringBuffer();
    for (var i = 2; i < 8; i++) {
      sb.write(f[i].toRadixString(16).padLeft(2, '0'));
    }
    return TelemetryPush(sb.toString(), Uint8List.fromList(f.sublist(8)));
  }
}

// ------------------------------------------------------------------ radio setup writes (FW only, never run on hardware by the research)

/// CMD_SET_RADIO_PARAMS: [11][freq kHz u32][bw Hz u32][sf][cr] (MyMesh.cpp 1424-1459). OK, or ERR 6 when freq is outside
/// 150000-2500000 kHz, bw outside 7000-500000 Hz, sf outside 5-12 or cr outside 5-8. The radio RETUNES AT ONCE (no
/// reboot) and saves. With no 10th byte the client-repeat flag is written as off. Frequency is kHz here and Hz for bw,
/// the same units SELF_INFO reports.
Uint8List encodeSetRadioParams({required int freqKhz, required int bwHz, required int sf, required int cr}) =>
    Uint8List.fromList([ToolCmd.setRadioParams, ..._u32(freqKhz), ..._u32(bwHz), sf, cr]);

/// CMD_SET_RADIO_TX_POWER: [12][dBm i8] -> OK, or ERR 6 outside -9..MAX_LORA_TX_POWER (SELF_INFO byte 3). MyMesh.cpp 1460.
Uint8List encodeSetRadioTxPower(int dbm) => Uint8List.fromList([ToolCmd.setRadioTxPower, dbm & 0xff]);

/// CMD_SET_ADVERT_NAME: [8][name...] -> OK. The firmware keeps 31 bytes (MyMesh.cpp 1259-1265).
Uint8List encodeSetAdvertName(List<int> nameBytes) => Uint8List.fromList([ToolCmd.setAdvertName, ...nameBytes]);

/// CMD_SET_ADVERT_LATLON: [14][lat i32 1e-6][lon i32 1e-6] -> OK, or ERR 6 outside +-90 / +-180 (MyMesh.cpp 1266-1282).
Uint8List encodeSetAdvertLatLon(double lat, double lon) {
  final bd = ByteData(9)..setUint8(0, ToolCmd.setAdvertLatLon);
  bd.setInt32(1, (lat * 1e6).round(), Endian.little);
  bd.setInt32(5, (lon * 1e6).round(), Endian.little);
  return bd.buffer.asUint8List();
}

/// CMD_SET_OTHER_PARAMS (38) is `encodeSetOtherParams` in protocol.dart: [38][manual_add][telemetry modes][advert_loc_policy][multi_acks].

/// Limits SET_RADIO_PARAMS enforces (MyMesh.cpp 1440).
abstract final class RadioParamLimits {
  static const freqKhzMin = 150000, freqKhzMax = 2500000;
  static const bwHzMin = 7000, bwHzMax = 500000;
  static const sfMin = 5, sfMax = 12;
  static const crMin = 5, crMax = 8;
  static const txDbmMin = -9;
}

// ------------------------------------------------------------------ radio-side helpers for fakes
Uint8List encodeTelemetryResponsePush(List<int> prefix6, List<int> lpp) => Uint8List.fromList([Push.telemetryResponse, 0, ...prefix6.take(6), ...lpp]);

/// An OK reply (re-exported for fakes that only import this file).
Uint8List toolOk() => Uint8List.fromList([Resp.ok]);
