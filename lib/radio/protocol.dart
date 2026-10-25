// MeshCore companion-radio protocol: frame codes, command encoders and response/push decoders.
//
// Source of truth: MeshCore firmware (MIT, © 2025 Scott Powell / rippleradios.com),
// examples/companion_radio/MyMesh.cpp (stats/battery layouts re-read Oct 24 2026 at main b204f9a, FIRMWARE_VER_CODE 14) — code tables at lines 9–140, command handling in handleCmdFrame()
// (line ~1055 onward), logRxRaw() at line ~291, onControlDataRecv() at line ~810.
// Cross-checked against MeshCore Open lib/connector/meshcore_protocol.dart (MIT, © 2025 zjs81) and the
// MeshMapper web client content/mc/connection/connection.js (MIT, © 2025 MrAlders0n). Where they differ the
// firmware wins; differences are noted inline.
//
// Over BLE every frame is exactly one write (app → radio, RX characteristic) or one notification
// (radio → app, TX characteristic). All integers are little-endian.
import 'dart:convert';
import 'dart:typed_data';

// ------------------------------------------------------------------ codes (MyMesh.cpp lines 9–140)

abstract final class Cmd {
  static const appStart = 1;
  static const sendChannelTxtMsg = 3;
  static const getDeviceTime = 5;
  static const getBattAndStorage = 20; // was CMD_GET_BATTERY_VOLTAGE
  static const setDeviceTime = 6;
  static const syncNextMessage = 10;
  static const deviceQuery = 22;
  static const getChannel = 31;
  static const setChannel = 32;
  static const sendControlData = 55; // v8+
  static const getStats = 56; // v8+
  static const sendTelemetryReq = 39; // with exactly 3 reserved bytes = the companion's own ('self') telemetry
}

abstract final class Resp {
  static const ok = 0;
  static const err = 1;
  static const selfInfo = 5;
  static const sent = 6;
  static const contactMsgRecv = 7;
  static const channelMsgRecv = 8;
  static const currTime = 9;
  static const noMoreMessages = 10;
  static const battAndStorage = 12;
  static const deviceInfo = 13;
  static const disabled = 15;
  static const contactMsgRecvV3 = 16;
  static const channelMsgRecvV3 = 17;
  static const channelInfo = 18;
  static const stats = 24;
}

abstract final class Push {
  static const advert = 0x80;
  static const pathUpdated = 0x81;
  static const sendConfirmed = 0x82;
  static const msgWaiting = 0x83;
  static const rawData = 0x84;
  static const logRxData = 0x88;
  static const traceData = 0x89;
  static const newAdvert = 0x8A;
  static const controlData = 0x8E; // v8+
  static const telemetryResponse = 0x8B;
}

abstract final class ErrCode {
  static const unsupportedCmd = 1;
  static const notFound = 2;
  static const tableFull = 3;
  static const badState = 4;
  static const fileIoError = 5;
  static const illegalArg = 6;
}

abstract final class StatsType {
  static const core = 0;
  static const radio = 1;
  static const packets = 2;
}

/// TXT_TYPE_PLAIN (src/helpers/TxtDataHelpers.h line 6).
const int txtTypePlain = 0;

/// Protocol version we tell the radio we understand in CMD_DEVICE_QUERY. ≥3 selects the *_V3 message formats
/// (MyMesh.cpp line ~562). MeshCore Open sends 4; the firmware only branches on ≥3.
const int appTargetVersion = 3;

/// Codes ≥ 0x80 are unsolicited pushes; anything below is a reply to the current command.
bool isPushCode(int code) => code >= 0x80;

// ------------------------------------------------------------------ helpers

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v & 0xffffffff, Endian.little);

String _cString(Uint8List b, int start, int maxLen) {
  if (start >= b.length) return '';
  var end = start;
  final limit = (start + maxLen).clamp(0, b.length);
  while (end < limit && b[end] != 0) {
    end++;
  }
  return utf8.decode(b.sublist(start, end), allowMalformed: true);
}

/// UTF-8 bytes of [s], cut at a character boundary so it fits in [maxBytes].
Uint8List utf8Truncate(String s, int maxBytes) {
  final bytes = utf8.encode(s);
  if (bytes.length <= maxBytes) return Uint8List.fromList(bytes);
  var n = maxBytes;
  while (n > 0 && (bytes[n] & 0xC0) == 0x80) {
    n--;
  }
  return Uint8List.fromList(bytes.sublist(0, n));
}

class ProtocolException implements Exception {
  final String message;
  ProtocolException(this.message);
  @override
  String toString() => 'ProtocolException: $message';
}

// ------------------------------------------------------------------ command encoders

/// CMD_APP_START: [0x01][app_ver][reserved x6][app_name...]. Firmware needs len ≥ 8 and ignores bytes 1–7
/// (MyMesh.cpp ~1076). MeshCore Open and MeshMapper put app_ver=1 in byte 1; we do the same.
Uint8List encodeAppStart(String appName) =>
    Uint8List.fromList([Cmd.appStart, 1, 0, 0, 0, 0, 0, 0, ...utf8Truncate(appName, 64)]);

/// CMD_DEVICE_QUERY: [0x16][app_target_ver] (MyMesh.cpp ~1056).
Uint8List encodeDeviceQuery([int appVersion = appTargetVersion]) => Uint8List.fromList([Cmd.deviceQuery, appVersion]);

/// CMD_SET_DEVICE_TIME: [0x06][epoch_secs u32]. Firmware answers ERR(ILLEGAL_ARG) if this would move the clock
/// backwards (MyMesh.cpp ~1287).
Uint8List encodeSetDeviceTime(int epochSecs) => Uint8List.fromList([Cmd.setDeviceTime, ..._u32(epochSecs)]);

/// CMD_GET_CHANNEL: [0x1F][idx] (MyMesh.cpp ~1752).
Uint8List encodeGetChannel(int idx) => Uint8List.fromList([Cmd.getChannel, idx]);

/// CMD_SET_CHANNEL: [0x20][idx][name x32, NUL padded][secret x16] = 50 bytes (MyMesh.cpp ~1769). The 32-byte
/// secret variant (66 bytes) is rejected by the firmware. The name is cut to 31 bytes so it stays NUL-terminated.
Uint8List encodeSetChannel(int idx, String name, List<int> secret16) {
  if (secret16.length != 16) throw ArgumentError('channel secret must be 16 bytes');
  final out = Uint8List(50);
  out[0] = Cmd.setChannel;
  out[1] = idx;
  final nb = utf8Truncate(name, 31);
  out.setRange(2, 2 + nb.length, nb);
  out.setRange(34, 50, secret16);
  return out;
}

/// CMD_SEND_CHANNEL_TXT_MSG: [0x03][txt_type=0][channel_idx][timestamp u32][text...] (MyMesh.cpp ~1178).
/// Text runs to the end of the frame (no NUL). The firmware replies RESP_CODE_OK — not RESP_CODE_SENT as
/// docs/companion_protocol.md says; the code (writeOKFrame) wins.
Uint8List encodeSendChannelText(int channelIdx, int epochSecs, String text) =>
    Uint8List.fromList([Cmd.sendChannelTxtMsg, txtTypePlain, channelIdx, ..._u32(epochSecs), ...utf8.encode(text)]);

/// CMD_SYNC_NEXT_MESSAGE: [0x0A] (MyMesh.cpp ~1415).
Uint8List encodeSyncNextMessage() => Uint8List.fromList([Cmd.syncNextMessage]);

/// CMD_GET_BATT_AND_STORAGE: [0x14] (MyMesh.cpp ~1517). Answered by every firmware that has it, no version gate.
Uint8List encodeGetBattAndStorage() => Uint8List.fromList([Cmd.getBattAndStorage]);

/// CMD_GET_STATS: [0x38][stats_type] (MyMesh.cpp ~1914, firmware v8+).
Uint8List encodeGetStats(int statsType) => Uint8List.fromList([Cmd.getStats, statsType]);

/// CMD_SEND_CONTROL_DATA: [0x37][payload...]; payload[0] must have bit 7 set. Sent zero-hop (MyMesh.cpp ~2015).
Uint8List encodeSendControlData(List<int> payload) {
  if (payload.isEmpty || (payload[0] & 0x80) == 0) throw ArgumentError('control payload must start with a byte ≥ 0x80');
  return Uint8List.fromList([Cmd.sendControlData, ...payload]);
}

/// NODE_DISCOVER_REQ control payload, as repeaters parse it (examples/simple_repeater/MyMesh.cpp ~786–857):
/// [0x80 | prefix_only][type_filter][tag u32][since u32]. Filter bit (1 << ADV_TYPE_REPEATER=2) asks repeaters.
Uint8List encodeDiscoverRequestPayload(int tag, {int typeFilter = 1 << 2, bool prefixOnly = false, int since = 0}) =>
    Uint8List.fromList([0x80 | (prefixOnly ? 1 : 0), typeFilter, ..._u32(tag), ..._u32(since)]);

// ------------------------------------------------------------------ decoded frames

sealed class Frame {
  const Frame();
}

class OkFrame extends Frame {
  const OkFrame();
}

class ErrFrame extends Frame {
  final int? code;
  const ErrFrame(this.code);
}

class DisabledFrame extends Frame {
  const DisabledFrame();
}

/// RESP_CODE_SELF_INFO (MyMesh.cpp ~1084): [5][adv_type][tx_power_dbm][max_tx_power][pub_key x32][lat i32][lon i32]
/// [multi_acks][advert_loc_policy][telemetry_modes][manual_add][freq u32][bw u32][sf][cr][name...].
/// freq = prefs.freq(MHz)·1000 → kHz; bw = prefs.bw(kHz)·1000 → Hz. (MeshCore Open names these freqHz/bwHz, but
/// divides freq by 1000 to show MHz, i.e. the value really is kHz.)
class SelfInfoFrame extends Frame {
  final int advType;
  final int txPowerDbm;
  final int maxTxPowerDbm;
  final Uint8List publicKey;
  final double advLat;
  final double advLon;
  final int freqKhz;
  final int bwHz;
  final int sf;
  final int cr;
  final String name;
  const SelfInfoFrame({
    required this.advType,
    required this.txPowerDbm,
    required this.maxTxPowerDbm,
    required this.publicKey,
    required this.advLat,
    required this.advLon,
    required this.freqKhz,
    required this.bwHz,
    required this.sf,
    required this.cr,
    required this.name,
  });
  double get freqMhz => freqKhz / 1000.0;
  double get bwKhz => bwHz / 1000.0;
}

/// RESP_CODE_DEVICE_INFO (MyMesh.cpp ~1059): [13][fw_ver_code][max_contacts/2][max_channels][ble_pin u32]
/// [build_date x12][manufacturer x40][fw_version x20][repeat (v9+)][path_hash_mode (v10+)].
/// Very old firmware sends a shorter frame; fields that aren't present are null.
class DeviceInfoFrame extends Frame {
  final int firmwareVerCode;
  final int? maxChannels;
  final String? buildDate;
  final String? manufacturer;
  final String? firmwareVersion;
  final int? pathHashMode;
  const DeviceInfoFrame({
    required this.firmwareVerCode,
    this.maxChannels,
    this.buildDate,
    this.manufacturer,
    this.firmwareVersion,
    this.pathHashMode,
  });
}

/// RESP_CODE_CHANNEL_INFO (MyMesh.cpp ~1756): [18][idx][name x32][secret x16].
class ChannelInfoFrame extends Frame {
  final int index;
  final String name;
  final Uint8List secret;
  const ChannelInfoFrame(this.index, this.name, this.secret);
  bool get isEmpty => name.isEmpty && secret.every((b) => b == 0);
}

/// RESP_CODE_STATS / STATS_TYPE_RADIO (MyMesh.cpp ~1928): [24][1][noise_floor i16][last_rssi i8][last_snr i8 (×4)]
/// [tx_air_secs u32][rx_air_secs u32].
class RadioStatsFrame extends Frame {
  final int noiseFloorDbm;
  final int lastRssiDbm;
  final double lastSnrDb;
  final int txAirSecs;
  final int rxAirSecs;
  const RadioStatsFrame(this.noiseFloorDbm, this.lastRssiDbm, this.lastSnrDb, this.txAirSecs, this.rxAirSecs);
}

/// RESP_CODE_BATT_AND_STORAGE (MyMesh.cpp ~1517-1527): [12][battery_mv u16][used_kb u32][total_kb u32] = 11 bytes.
/// battery_mv is board.getBattMilliVolts(): 0 on boards without battery sensing (treat as unmeasured). Firmware from
/// before storage was added (the command was CMD_GET_BATTERY_VOLTAGE) sends only the first 3 bytes: storage is null.
class BattAndStorageFrame extends Frame {
  final int batteryMv;
  final int? storageUsedKb;
  final int? storageTotalKb;
  const BattAndStorageFrame({required this.batteryMv, this.storageUsedKb, this.storageTotalKb});
}

/// RESP_CODE_STATS / STATS_TYPE_CORE (MyMesh.cpp ~1916-1927): [24][0][battery_mv u16][uptime_secs u32]
/// [err_flags u16][queue_len u8] = 11 bytes. err_flags is the Dispatcher's `_err_flags` BITMASK (src/Dispatcher.h
/// ~110: bit 0 ERR_EVENT_FULL, bit 1 ERR_EVENT_CAD_TIMEOUT, bit 2 ERR_EVENT_STARTRX_TIMEOUT), sticky until
/// resetStats(); it is not an error counter. queue_len = outbound packets queued.
class CoreStatsFrame extends Frame {
  final int batteryMv;
  final int uptimeSecs;
  final int errFlags;
  final int queueLen;
  const CoreStatsFrame({required this.batteryMv, required this.uptimeSecs, required this.errFlags, required this.queueLen});
}

/// err_flags bits (src/Dispatcher.h ~110-112).
abstract final class RadioErrFlag {
  static const queueFull = 1 << 0;
  static const cadTimeout = 1 << 1;
  static const startRxTimeout = 1 << 2;
}

/// RESP_CODE_STATS / STATS_TYPE_PACKETS (MyMesh.cpp ~1943-1962): [24][2] then u32 recv, sent, n_sent_flood,
/// n_sent_direct, n_recv_flood, n_recv_direct, n_recv_errors = 30 bytes. Cumulative since boot, wrap at 2^32. The
/// 26-byte form without recv_errors (older firmware, per the radio plan doc) is accepted: recvErrors is then null.
class PacketStatsFrame extends Frame {
  final int recv;
  final int sent;
  final int floodTx;
  final int directTx;
  final int floodRx;
  final int directRx;
  final int? recvErrors;
  const PacketStatsFrame({
    required this.recv,
    required this.sent,
    required this.floodTx,
    required this.directTx,
    required this.floodRx,
    required this.directRx,
    this.recvErrors,
  });
}

/// Any other RESP_CODE_STATS sub-type (kept raw).
class OtherStatsFrame extends Frame {
  final int statsType;
  final Uint8List data;
  const OtherStatsFrame(this.statsType, this.data);
}

class CurrTimeFrame extends Frame {
  final int epochSecs;
  const CurrTimeFrame(this.epochSecs);
}

class NoMoreMessagesFrame extends Frame {
  const NoMoreMessagesFrame();
}

/// RESP_CODE_CHANNEL_MSG_RECV(_V3) (MyMesh.cpp ~560): V3 = [17][snr i8 ×4][res][res][ch_idx][path_len][txt_type]
/// [ts u32][text...]; legacy = [8][ch_idx][path_len][txt_type][ts u32][text...]. path_len 0xFF = came direct.
class ChannelMsgFrame extends Frame {
  final double? snrDb;
  final int channelIndex;
  final int pathLen;
  final int txtType;
  final int timestamp;
  final String text;
  const ChannelMsgFrame(
      {this.snrDb,
      required this.channelIndex,
      required this.pathLen,
      required this.txtType,
      required this.timestamp,
      required this.text});
}

/// Contact (direct) messages; not used by MeshSonar beyond recognising them.
class ContactMsgFrame extends Frame {
  final Uint8List data;
  const ContactMsgFrame(this.data);
}

class MsgWaitingPush extends Frame {
  const MsgWaitingPush();
}

/// PUSH_CODE_LOG_RX_DATA (MyMesh.cpp ~291 logRxRaw): [0x88][snr i8 = snr·4][rssi i8][raw packet...].
/// Emitted for every packet the radio's Dispatcher receives (src/Dispatcher.cpp ~199), before any filtering.
class LogRxDataPush extends Frame {
  final double snrDb;
  final int rssiDbm;
  final Uint8List raw;
  const LogRxDataPush(this.snrDb, this.rssiDbm, this.raw);
}

/// PUSH_CODE_CONTROL_DATA (MyMesh.cpp ~810): [0x8E][snr i8 ·4][rssi i8][path_len][control payload...].
/// Only zero-hop control packets with payload[0] & 0x80 reach the app (src/Mesh.cpp ~70).
class ControlDataPush extends Frame {
  final double snrDb;
  final int rssiDbm;
  final int pathLen;
  final Uint8List payload;
  const ControlDataPush(this.snrDb, this.rssiDbm, this.pathLen, this.payload);
}

/// A NODE_DISCOVER_RESP control payload (examples/simple_repeater/MyMesh.cpp ~809):
/// [0x90 | node_type][snr_in i8 ·4 — how the responder heard our request][tag u32][pub_key x32 (or x8 prefix)].
class DiscoverResponse {
  final int nodeType;
  final double remoteSnrDb;
  final int tag;
  final Uint8List publicKey;
  const DiscoverResponse(this.nodeType, this.remoteSnrDb, this.tag, this.publicKey);

  static DiscoverResponse? tryParse(Uint8List p) {
    if (p.length < 6 + 8 || (p[0] & 0xF0) != 0x90) return null;
    final bd = ByteData.sublistView(p);
    return DiscoverResponse(p[0] & 0x0F, bd.getInt8(1) / 4.0, bd.getUint32(2, Endian.little), p.sublist(6));
  }
}

class UnknownFrame extends Frame {
  final int code;
  final Uint8List data;
  const UnknownFrame(this.code, this.data);
}

/// Decodes one frame from the radio. Throws [ProtocolException] for an empty or truncated known frame.
Frame decodeFrame(Uint8List f) {
  if (f.isEmpty) throw ProtocolException('empty frame');
  final bd = ByteData.sublistView(f);
  void need(int n, String what) {
    if (f.length < n) throw ProtocolException('$what frame too short (${f.length} < $n)');
  }

  switch (f[0]) {
    case Resp.ok:
      return const OkFrame();
    case Resp.err:
      return ErrFrame(f.length > 1 ? f[1] : null);
    case Resp.disabled:
      return const DisabledFrame();
    case Resp.selfInfo:
      need(58, 'SELF_INFO');
      return SelfInfoFrame(
        advType: f[1],
        txPowerDbm: bd.getInt8(2),
        maxTxPowerDbm: bd.getInt8(3),
        publicKey: Uint8List.fromList(f.sublist(4, 36)),
        advLat: bd.getInt32(36, Endian.little) / 1e6,
        advLon: bd.getInt32(40, Endian.little) / 1e6,
        freqKhz: bd.getUint32(48, Endian.little),
        bwHz: bd.getUint32(52, Endian.little),
        sf: f[56],
        cr: f[57],
        name: utf8.decode(f.sublist(58).takeWhile((b) => b != 0).toList(), allowMalformed: true),
      );
    case Resp.deviceInfo:
      need(2, 'DEVICE_INFO');
      return DeviceInfoFrame(
        firmwareVerCode: f[1],
        maxChannels: f.length > 3 ? f[3] : null,
        buildDate: f.length >= 20 ? _cString(f, 8, 12) : null,
        manufacturer: f.length >= 60 ? _cString(f, 20, 40) : null,
        firmwareVersion: f.length >= 80 ? _cString(f, 60, 20) : null,
        pathHashMode: f.length >= 82 ? f[81] : null,
      );
    case Resp.channelInfo:
      need(50, 'CHANNEL_INFO');
      return ChannelInfoFrame(f[1], _cString(f, 2, 32), Uint8List.fromList(f.sublist(34, 50)));
    case Resp.stats:
      need(2, 'STATS');
      if (f[1] == StatsType.radio) {
        need(14, 'STATS/RADIO');
        return RadioStatsFrame(
          bd.getInt16(2, Endian.little),
          bd.getInt8(4),
          bd.getInt8(5) / 4.0,
          bd.getUint32(6, Endian.little),
          bd.getUint32(10, Endian.little),
        );
      }
      if (f[1] == StatsType.core) {
        need(11, 'STATS/CORE');
        return CoreStatsFrame(
          batteryMv: bd.getUint16(2, Endian.little),
          uptimeSecs: bd.getUint32(4, Endian.little),
          errFlags: bd.getUint16(8, Endian.little),
          queueLen: f[10],
        );
      }
      if (f[1] == StatsType.packets) {
        need(26, 'STATS/PACKETS');
        int u(int at) => bd.getUint32(at, Endian.little);
        return PacketStatsFrame(
          recv: u(2),
          sent: u(6),
          floodTx: u(10),
          directTx: u(14),
          floodRx: u(18),
          directRx: u(22),
          recvErrors: f.length >= 30 ? u(26) : null,
        );
      }
      return OtherStatsFrame(f[1], Uint8List.fromList(f.sublist(2)));
    case Resp.battAndStorage:
      need(3, 'BATT_AND_STORAGE');
      final full = f.length >= 11;
      return BattAndStorageFrame(
        batteryMv: bd.getUint16(1, Endian.little),
        storageUsedKb: full ? bd.getUint32(3, Endian.little) : null,
        storageTotalKb: full ? bd.getUint32(7, Endian.little) : null,
      );
    case Resp.currTime:
      need(5, 'CURR_TIME');
      return CurrTimeFrame(bd.getUint32(1, Endian.little));
    case Resp.noMoreMessages:
      return const NoMoreMessagesFrame();
    case Resp.channelMsgRecvV3:
      need(11, 'CHANNEL_MSG_RECV_V3');
      return ChannelMsgFrame(
        snrDb: bd.getInt8(1) / 4.0,
        channelIndex: f[4],
        pathLen: f[5],
        txtType: f[6],
        timestamp: bd.getUint32(7, Endian.little),
        text: utf8.decode(f.sublist(11), allowMalformed: true),
      );
    case Resp.channelMsgRecv:
      need(8, 'CHANNEL_MSG_RECV');
      return ChannelMsgFrame(
        channelIndex: f[1],
        pathLen: f[2],
        txtType: f[3],
        timestamp: bd.getUint32(4, Endian.little),
        text: utf8.decode(f.sublist(8), allowMalformed: true),
      );
    case Resp.contactMsgRecv:
    case Resp.contactMsgRecvV3:
      return ContactMsgFrame(Uint8List.fromList(f));
    case Push.msgWaiting:
      return const MsgWaitingPush();
    case Push.logRxData:
      need(3, 'LOG_RX_DATA');
      return LogRxDataPush(bd.getInt8(1) / 4.0, bd.getInt8(2), Uint8List.fromList(f.sublist(3)));
    case Push.controlData:
      need(4, 'CONTROL_DATA');
      return ControlDataPush(bd.getInt8(1) / 4.0, bd.getInt8(2), f[3], Uint8List.fromList(f.sublist(4)));
    default:
      return UnknownFrame(f[0], Uint8List.fromList(f.sublist(1)));
  }
}

// ------------------------------------------------------------------ radio-side encoders
// The inverse direction: used by the simulator (which plays the radio) and by tests. Layouts mirror the firmware
// lines cited on each decoded class above.

Uint8List encodeOk() => Uint8List.fromList([Resp.ok]);
Uint8List encodeErr(int code) => Uint8List.fromList([Resp.err, code]);

Uint8List encodeSelfInfo({
  int advType = 1,
  required int txPowerDbm,
  required int maxTxPowerDbm,
  required List<int> publicKey,
  double advLat = 0,
  double advLon = 0,
  required int freqKhz,
  required int bwHz,
  required int sf,
  required int cr,
  required String name,
}) {
  final b = BytesBuilder();
  b.add([Resp.selfInfo, advType, txPowerDbm & 0xff, maxTxPowerDbm & 0xff]);
  b.add(publicKey);
  final ll = ByteData(8)
    ..setInt32(0, (advLat * 1e6).round(), Endian.little)
    ..setInt32(4, (advLon * 1e6).round(), Endian.little);
  b.add(ll.buffer.asUint8List());
  b.add([0, 0, 0, 0]); // multi_acks, advert_loc_policy, telemetry modes, manual_add_contacts
  b.add(_u32(freqKhz));
  b.add(_u32(bwHz));
  b.add([sf, cr]);
  b.add(utf8.encode(name));
  return b.toBytes();
}

Uint8List encodeDeviceInfo({
  required int firmwareVerCode,
  int maxContactsHalf = 50,
  required int maxChannels,
  required String buildDate,
  required String manufacturer,
  required String firmwareVersion,
  int pathHashMode = 0,
}) {
  final out = Uint8List(82);
  out[0] = Resp.deviceInfo;
  out[1] = firmwareVerCode;
  out[2] = maxContactsHalf;
  out[3] = maxChannels;
  // 4..7 ble pin = 0
  void put(int at, String s, int max) {
    final b = utf8Truncate(s, max - 1);
    out.setRange(at, at + b.length, b);
  }

  put(8, buildDate, 12);
  put(20, manufacturer, 40);
  put(60, firmwareVersion, 20);
  out[80] = 0; // repeat
  out[81] = pathHashMode;
  return out;
}

Uint8List encodeChannelInfo(int idx, String name, List<int> secret16) {
  final out = Uint8List(50);
  out[0] = Resp.channelInfo;
  out[1] = idx;
  final nb = utf8Truncate(name, 31);
  out.setRange(2, 2 + nb.length, nb);
  out.setRange(34, 50, secret16);
  return out;
}

Uint8List encodeRadioStats({required int noiseFloorDbm, int lastRssiDbm = 0, double lastSnrDb = 0, int txAirSecs = 0, int rxAirSecs = 0}) {
  final bd = ByteData(14)
    ..setUint8(0, Resp.stats)
    ..setUint8(1, StatsType.radio)
    ..setInt16(2, noiseFloorDbm, Endian.little)
    ..setInt8(4, lastRssiDbm)
    ..setInt8(5, (lastSnrDb * 4).round())
    ..setUint32(6, txAirSecs, Endian.little)
    ..setUint32(10, rxAirSecs, Endian.little);
  return bd.buffer.asUint8List();
}

Uint8List encodeCoreStats({required int batteryMv, required int uptimeSecs, int errFlags = 0, int queueLen = 0}) {
  final bd = ByteData(11)
    ..setUint8(0, Resp.stats)
    ..setUint8(1, StatsType.core)
    ..setUint16(2, batteryMv, Endian.little)
    ..setUint32(4, uptimeSecs & 0xffffffff, Endian.little)
    ..setUint16(8, errFlags, Endian.little)
    ..setUint8(10, queueLen);
  return bd.buffer.asUint8List();
}

/// [recvErrors] null writes the 26-byte older form.
Uint8List encodePacketStats({
  required int recv,
  required int sent,
  required int floodTx,
  required int directTx,
  required int floodRx,
  required int directRx,
  int? recvErrors = 0,
}) {
  final vals = [recv, sent, floodTx, directTx, floodRx, directRx, ?recvErrors];
  final bd = ByteData(2 + 4 * vals.length)
    ..setUint8(0, Resp.stats)
    ..setUint8(1, StatsType.packets);
  for (var i = 0; i < vals.length; i++) {
    bd.setUint32(2 + 4 * i, vals[i] & 0xffffffff, Endian.little);
  }
  return bd.buffer.asUint8List();
}

Uint8List encodeBattAndStorage({required int batteryMv, int usedKb = 0, int totalKb = 0}) {
  final bd = ByteData(11)
    ..setUint8(0, Resp.battAndStorage)
    ..setUint16(1, batteryMv, Endian.little)
    ..setUint32(3, usedKb, Endian.little)
    ..setUint32(7, totalKb, Endian.little);
  return bd.buffer.asUint8List();
}

int _i8(num v) => v.round().clamp(-128, 127) & 0xff;

Uint8List encodeLogRxData(double snrDb, int rssiDbm, List<int> raw) =>
    Uint8List.fromList([Push.logRxData, _i8(snrDb * 4), _i8(rssiDbm), ...raw]);

Uint8List encodeControlDataPush(double snrDb, int rssiDbm, int pathLen, List<int> payload) =>
    Uint8List.fromList([Push.controlData, _i8(snrDb * 4), _i8(rssiDbm), pathLen, ...payload]);

Uint8List encodeMsgWaiting() => Uint8List.fromList([Push.msgWaiting]);
Uint8List encodeNoMoreMessages() => Uint8List.fromList([Resp.noMoreMessages]);

// ------------------------------------------------------------------ self telemetry (radio temperature)
//
// MeshCore companion firmware (examples/companion_radio/MyMesh.cpp ~1700-1718 at commit 81dbae5, 2026-10-15, v1.18.0):
// CMD_SEND_TELEMETRY_REQ (39) with len == 4 ([39][3 reserved]) is the "self" telemetry request. The firmware answers
// with ONE frame, PUSH_CODE_TELEMETRY_RESPONSE (0x8B): [0x8B][reserved 0][own pub key prefix, 6 B][CayenneLPP bytes].
// The LPP holds, on channel TELEM_CHANNEL_SELF (1, src/helpers/SensorManager.h:10): LPP_VOLTAGE (battery) and, on
// boards whose MCU has a sensor, LPP_TEMPERATURE = board.getMCUTemperature() (ESP32: temperatureRead(), ESP32Board.h
// ~58; nRF52: sd_temp_get / NRF_TEMP, NRF52Board.cpp ~298; base MainBoard returns NAN = not sent, MeshCore.h:48).
// After that, sensors.querySensors(0xFF, ...) may append environment sensors AND the board's GPS position on other
// entries: MeshSonar reads ONLY the channel-1 temperature and voltage and never keeps anything else (no position).
// The temperature is the radio's chip (MCU) temperature, not air temperature.

/// CayenneLPP data sizes (electroniccats/CayenneLPP 1.6.1, used by the firmware). Unknown type = stop parsing.
const Map<int, int> _lppSize = {
  0: 1, 1: 1, 2: 2, 3: 2, 100: 4, 101: 2, 102: 1, 103: 2, 104: 1, 113: 6, 115: 2, 116: 2, 117: 2, 118: 4, 120: 1,
  121: 2, 125: 2, 128: 2, 130: 4, 131: 4, 132: 2, 133: 4, 134: 6, 135: 3, 136: 9, 142: 1,
};

/// What MeshSonar keeps from the radio's self telemetry.
class SelfTelemetry {
  /// MCU (chip) temperature, °C (LPP 0.1 °C signed); null when the board does not report one.
  final double? mcuTempC;

  /// Battery voltage, volts (LPP 0.01 V).
  final double? voltageV;
  const SelfTelemetry({this.mcuTempC, this.voltageV});
}

Uint8List encodeSelfTelemetryReq() => Uint8List.fromList([Cmd.sendTelemetryReq, 0, 0, 0]);

/// Decodes a PUSH_CODE_TELEMETRY_RESPONSE frame. Returns null when it is not one, is too short, or (with
/// [selfPrefix]) answers for another node. Only channel-1 temperature and voltage are read.
SelfTelemetry? decodeSelfTelemetryPush(Uint8List f, {List<int>? selfPrefix}) {
  if (f.length < 8 || f[0] != Push.telemetryResponse) return null;
  if (selfPrefix != null && selfPrefix.length >= 6) {
    for (var i = 0; i < 6; i++) {
      if (f[2 + i] != selfPrefix[i]) return null;
    }
  }
  final bd = ByteData.sublistView(f);
  double? temp, volt;
  var i = 8;
  while (i + 2 <= f.length) {
    final ch = f[i], type = f[i + 1];
    final size = _lppSize[type];
    if (size == null || i + 2 + size > f.length) break;
    if (ch == 1 && type == 103 && temp == null) temp = bd.getInt16(i + 2, Endian.big) / 10;
    if (ch == 1 && type == 116 && volt == null) volt = bd.getUint16(i + 2, Endian.big) / 100;
    i += 2 + size;
  }
  return SelfTelemetry(mcuTempC: temp, voltageV: volt);
}

/// Radio side of the self telemetry answer (simulator and tests).
Uint8List encodeSelfTelemetryPush({required List<int> prefix6, double? voltageV, double? mcuTempC, List<int> extraLpp = const []}) {
  final b = BytesBuilder()
    ..addByte(Push.telemetryResponse)
    ..addByte(0)
    ..add(prefix6.take(6).toList());
  if (voltageV != null) {
    final v = (voltageV * 100).round().clamp(0, 0xffff);
    b.add([1, 116, (v >> 8) & 0xff, v & 0xff]);
  }
  if (mcuTempC != null) {
    final t = (mcuTempC * 10).round().clamp(-32768, 32767) & 0xffff;
    b.add([1, 103, (t >> 8) & 0xff, t & 0xff]);
  }
  b.add(extraLpp);
  return b.toBytes();
}
