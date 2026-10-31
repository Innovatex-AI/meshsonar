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
  static const sendTxtMsg = 2;
  static const sendChannelTxtMsg = 3;
  static const getContacts = 4; // optional `since` u32 (MyMesh.cpp 1238-1258)
  static const getDeviceTime = 5;
  static const getBattAndStorage = 20; // was CMD_GET_BATTERY_VOLTAGE
  static const setDeviceTime = 6;
  static const addUpdateContact = 9;
  static const syncNextMessage = 10;
  static const resetPath = 13; // MyMesh.cpp 1317
  static const removeContact = 15; // MyMesh.cpp 1349
  static const shareContact = 16; // MyMesh.cpp 1359
  static const exportContact = 17;
  static const importContact = 18; // MyMesh.cpp 1409
  static const setOtherParams = 38; // MyMesh.cpp 1488
  static const setAutoAddConfig = 58; // MyMesh.cpp 2023
  static const getAutoAddConfig = 59; // MyMesh.cpp 2030
  static const deviceQuery = 22;
  static const sendLogin = 26;
  static const sendStatusReq = 27;
  static const logout = 29;
  static const getContactByKey = 30;
  static const getChannel = 31;
  static const setChannel = 32;
  static const signStart = 33;
  static const signData = 34;
  static const signFinish = 35;
  static const setFloodScopeKey = 54; // v8+ (sub 1 = unscoped: ver 12+)
  static const sendControlData = 55; // v8+
  static const getStats = 56; // v8+
  static const sendTelemetryReq = 39; // with exactly 3 reserved bytes = the companion's own ('self') telemetry
  static const sendBinaryReq = 50; // [50][pub_key x32][request bytes]: neighbours, ACL, owner (repeater_wire.dart)
  static const sendAnonReq = 57; // [57][pub_key x32][request bytes]: clock, regions, owner without a login
}

abstract final class Resp {
  static const ok = 0;
  static const err = 1;
  static const contactsStart = 2; // first reply to GET_CONTACTS: [2][total count u32]
  static const contact = 3;
  static const endOfContacts = 4; // last reply to GET_CONTACTS: [4][most recent lastmod u32]
  static const selfInfo = 5;
  static const sent = 6;
  static const contactMsgRecv = 7;
  static const channelMsgRecv = 8;
  static const currTime = 9;
  static const noMoreMessages = 10;
  static const exportContact = 11;
  static const battAndStorage = 12;
  static const deviceInfo = 13;
  static const disabled = 15;
  static const contactMsgRecvV3 = 16;
  static const autoAddConfig = 25; // [25][config][max_hops] (MyMesh.cpp 2030-2036)
  static const channelMsgRecvV3 = 17;
  static const channelInfo = 18;
  static const signStart = 19;
  static const signature = 20;
  static const stats = 24;
  static const channelDataRecv = 27; // binary channel datagram in the offline queue (drained like a message)
}

abstract final class Push {
  static const advert = 0x80;
  static const pathUpdated = 0x81;
  static const sendConfirmed = 0x82;
  static const msgWaiting = 0x83;
  static const rawData = 0x84;
  static const loginSuccess = 0x85;
  static const loginFail = 0x86;
  static const statusResponse = 0x87;
  static const logRxData = 0x88;
  static const traceData = 0x89;
  static const newAdvert = 0x8A;
  static const controlData = 0x8E; // v8+
  static const telemetryResponse = 0x8B;
  static const binaryResponse = 0x8C; // [0x8C][0][tag u32][data...] (answers 50 and 57; research packet section B)
  static const contactDeleted = 0x8F; // [0x8F][pub_key x32]: the radio overwrote its oldest contact
  static const contactsFull = 0x90; // [0x90]
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

/// TXT_TYPE_CLI_DATA (a CLI command or its reply) and TXT_TYPE_CLI_COMMAND (src/helpers/TxtDataHelpers.h lines 7 and 9).
/// A repeater would accept both, but the COMPANION radio's CMD_SEND_TXT_MSG only passes type CLI_DATA (1) on: type 3 gets
/// ERR(1) at once (measured on a real radio, Oct 31 2026: type 3 -> ERR 1, type 1 -> SENT, MSG_WAITING, "> INNO-OB-2").
/// Always SEND commands as [txtTypeCliData]; replies also come back as CLI_DATA.
const int txtTypeCliData = 1;
const int txtTypeCliCommand = 3;

/// MeshCore advert/contact node types (src/helpers/AdvertDataHelpers.h lines 7-11).
abstract final class AdvType {
  static const none = 0;
  static const chat = 1;
  static const repeater = 2;
  static const room = 3;
  static const sensor = 4;
}

/// A repeater/room admin password is cut to 15 bytes by BaseChatMesh::sendLogin (line ~612, "max 15 chars currently").
const int maxLoginPasswordBytes = 15;

/// A node name is stored in `char node_name[32]` and copied with StrHelper::strncpy: 31 bytes at most
/// (src/helpers/CommonCLI.h line 29, CommonCLI.cpp `set name`).
const int maxNodeNameBytes = 31;

/// Longest name an ADVERT can carry: MAX_ADVERT_DATA_SIZE is 32 bytes for flags(1) + optional lat/lon(8) + name
/// (AdvertDataBuilder::encodeTo cuts the name to what is left). With a position that leaves 23 bytes.
const int maxAdvertNameBytesWithPosition = 23;

/// Characters `set name` refuses (CommonCLI.cpp isValidName).
const String invalidNodeNameChars = r'[]\:,?*';

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
Uint8List encodeGetDeviceTime() => Uint8List.fromList([Cmd.getDeviceTime]);
Uint8List encodeCurrTime(int epochSecs) => Uint8List.fromList([Resp.currTime, ..._u32(epochSecs)]);
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

/// CMD_GET_CONTACTS: [0x04] or [0x04][since u32] (MyMesh.cpp 1238-1258). Only contacts whose lastmod is NEWER than `since`
/// are sent. Replies: CONTACTS_START, N x CONTACT, END_OF_CONTACTS. A second GET_CONTACTS while one runs gets
/// ERR(BAD_STATE).
Uint8List encodeGetContacts({int since = 0}) =>
    since == 0 ? Uint8List.fromList([Cmd.getContacts]) : Uint8List.fromList([Cmd.getContacts, ..._u32(since)]);

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

// ------------------------------------------------------------------ claim commands: login, CLI, status, sign
// Verified against MeshCore examples/companion_radio/MyMesh.cpp at main (Oct 31 2026, FIRMWARE_VER_CODE 14): handlers
// at ~1132 (SEND_TXT_MSG), ~1328 (ADD_UPDATE_CONTACT), ~1371 (GET_CONTACT_BY_KEY), ~1379 (EXPORT_CONTACT), ~1577
// (SEND_LOGIN), ~1630 (SEND_STATUS_REQ), ~1748 (LOGOUT), ~1781-1810 (SIGN_START/DATA/FINISH); pushes in
// onContactResponse() ~690 and queueMessage() ~440.

List<int> _pub32(List<int> key) {
  if (key.length != 32) throw ArgumentError('a MeshCore public key is 32 bytes');
  return key;
}

/// CMD_SEND_LOGIN: [26][pub_key x32][password, NUL-terminated]. The firmware cuts the password to 15 bytes and needs the
/// repeater to be a CONTACT of this radio, else ERR(NOT_FOUND) (see [encodeAddUpdateContact]). Reply RESP_CODE_SENT
/// ([SentFrame]); the answer is a later PUSH_CODE_LOGIN_SUCCESS. A WRONG password gets no answer at all: the repeater's
/// handleLogin() returns 0 (examples/simple_repeater/MyMesh.cpp ~100), so the push never comes.
Uint8List encodeSendLogin(List<int> pubKey32, String password) =>
    Uint8List.fromList([Cmd.sendLogin, ..._pub32(pubKey32), ...utf8Truncate(password, maxLoginPasswordBytes), 0]);

/// CMD_LOGOUT: [29][pub_key x32] -> OK (stops the keep-alive connection; nothing is sent to the repeater).
Uint8List encodeLogout(List<int> pubKey32) => Uint8List.fromList([Cmd.logout, ..._pub32(pubKey32)]);

/// CMD_SEND_STATUS_REQ: [27][pub_key x32] -> SENT, later PUSH_CODE_STATUS_RESPONSE.
Uint8List encodeSendStatusReq(List<int> pubKey32) => Uint8List.fromList([Cmd.sendStatusReq, ..._pub32(pubKey32)]);

/// CMD_GET_CONTACT_BY_KEY: [30][pub_key x32] -> RESP_CODE_CONTACT or ERR(NOT_FOUND).
Uint8List encodeGetContactByKey(List<int> pubKey32) => Uint8List.fromList([Cmd.getContactByKey, ..._pub32(pubKey32)]);

/// CMD_ADD_UPDATE_CONTACT: [9][pub_key x32][type][flags][out_path_len][out_path x64][name x32][last_advert u32]
/// [lat i32][lon i32][lastmod u32 optional] (updateContactFromFrame, MyMesh.cpp 195-217). out_path_len 0xFF =
/// OUT_PATH_UNKNOWN: the first message floods and the radio learns the path. Adds the contact if the radio does not have
/// it, else updates it. [lastMod] null leaves the frame at 144 bytes (the radio stamps it).
Uint8List encodeAddUpdateContact(
  List<int> pubKey32, {
  required int type,
  required String name,
  int flags = 0,
  int outPathLen = 0xFF,
  List<int> outPath = const [],
  int lastAdvert = 0,
  double lat = 0,
  double lon = 0,
  int? lastMod,
}) {
  final out = Uint8List(1 + 32 + 3 + 64 + 32 + 4 + 8 + (lastMod == null ? 0 : 4));
  out[0] = Cmd.addUpdateContact;
  out.setRange(1, 33, _pub32(pubKey32));
  out[33] = type;
  out[34] = flags;
  out[35] = outPathLen;
  final path = outPath.length > 64 ? outPath.sublist(0, 64) : outPath;
  out.setRange(36, 36 + path.length, path);
  final nb = utf8Truncate(name, 31);
  out.setRange(36 + 64, 36 + 64 + nb.length, nb);
  final bd = ByteData.sublistView(out);
  bd.setUint32(132, lastAdvert & 0xffffffff, Endian.little);
  bd.setInt32(136, (lat * 1e6).round(), Endian.little);
  bd.setInt32(140, (lon * 1e6).round(), Endian.little);
  if (lastMod != null) bd.setUint32(144, lastMod & 0xffffffff, Endian.little);
  return out;
}

/// CMD_SEND_TXT_MSG: [2][txt_type][attempt][timestamp u32][pub_key_prefix x6][text...] (MyMesh.cpp ~1132). With
/// [txtTypeCliData] the radio expects no ack; reply RESP_CODE_SENT (type CLI_COMMAND gets ERR on a real companion).
Uint8List encodeSendTxt(int txtType, int attempt, int epochSecs, List<int> prefix6, String text) {
  if (prefix6.length < 6) throw ArgumentError('prefix must be 6 bytes');
  return Uint8List.fromList([Cmd.sendTxtMsg, txtType, attempt & 3, ..._u32(epochSecs), ...prefix6.take(6), ...utf8.encode(text)]);
}

/// CMD_SIGN_START: [33] -> RESP_CODE_SIGN_START [19][reserved][max_len u32 = 8192].
Uint8List encodeSignStart() => Uint8List.fromList([Cmd.signStart]);

/// CMD_SIGN_DATA: [34][chunk...] -> OK (ERR(BAD_STATE) without a start, ERR(TABLE_FULL) past the 8 KB limit).
Uint8List encodeSignData(List<int> chunk) => Uint8List.fromList([Cmd.signData, ...chunk]);

/// CMD_SIGN_FINISH: [35] -> RESP_CODE_SIGNATURE [20][ed25519 signature x64] over everything sent in SIGN_DATA, by the
/// radio's own identity key.
Uint8List encodeSignFinish() => Uint8List.fromList([Cmd.signFinish]);

/// CMD_EXPORT_CONTACT with no key: the radio's own advert packet -> RESP_CODE_EXPORT_CONTACT [11][packet...].
Uint8List encodeExportSelfContact() => Uint8List.fromList([Cmd.exportContact]);

// ------------------------------------------------------------------ contact management (MyMesh.cpp at 81dbae5)

/// CMD_EXPORT_CONTACT with a key: [17][pub_key x32] -> RESP_CODE_EXPORT_CONTACT [11][the last raw advert packet heard from
/// that contact] or ERR(NOT_FOUND). The packet is only stored when the radio HEARD the advert itself (BaseChatMesh.cpp
/// 189-190, putBlobByKey): a contact written with ADD_UPDATE_CONTACT has none, and the reply is NOT_FOUND (line 1406).
Uint8List encodeExportContact(List<int> pubKey32) => Uint8List.fromList([Cmd.exportContact, ..._pub32(pubKey32)]);

/// CMD_IMPORT_CONTACT: [18][advert packet...] (needs more than 2 + 32 + 64 bytes, line 1409). The radio loops the packet
/// back as if heard over the air, so the normal auto-add rules apply (BaseChatMesh.cpp 588-601): with "ask before adding"
/// on it answers OK and then pushes NEW_ADVERT instead of adding. ERR(ILLEGAL_ARG) when it is not an advert packet.
Uint8List encodeImportContact(List<int> advertPacket) => Uint8List.fromList([Cmd.importContact, ...advertPacket]);

/// CMD_REMOVE_CONTACT: [15][pub_key x32] -> OK, or ERR(NOT_FOUND) (MyMesh.cpp 1349-1358).
Uint8List encodeRemoveContact(List<int> pubKey32) => Uint8List.fromList([Cmd.removeContact, ..._pub32(pubKey32)]);

/// CMD_RESET_PATH: [13][pub_key x32] -> OK: out_path_len becomes 0xFF, so the next message to it floods (MyMesh.cpp
/// 1317-1327), ERR(NOT_FOUND) for an unknown contact.
Uint8List encodeResetPath(List<int> pubKey32) => Uint8List.fromList([Cmd.resetPath, ..._pub32(pubKey32)]);

/// CMD_SHARE_CONTACT: [16][pub_key x32] -> OK after the radio sent the stored advert packet of that contact zero-hop (to
/// radios in direct range only, transport codes {0,0}), ERR(TABLE_FULL) when it has no stored packet or no free packet
/// (MyMesh.cpp 1359-1370, BaseChatMesh.cpp 570-582).
Uint8List encodeShareContact(List<int> pubKey32) => Uint8List.fromList([Cmd.shareContact, ..._pub32(pubKey32)]);

/// CMD_SET_OTHER_PARAMS: [38][manual_add][telemetry_modes][advert_loc_policy][multi_acks] (MyMesh.cpp 1488-1503). It
/// OVERWRITES every field it carries, so always pass the values SELF_INFO reported for the ones you do not mean to change.
Uint8List encodeSetOtherParams({required int manualAdd, required int telemetryModes, required int advertLocPolicy, required int multiAcks}) =>
    Uint8List.fromList([Cmd.setOtherParams, manualAdd & 0xff, telemetryModes & 0xff, advertLocPolicy & 0xff, multiAcks & 0xff]);

/// Bits of the auto-add config byte (MyMesh.cpp 147-151). They only matter while "ask before adding" (SELF_INFO manual_add
/// bit 0) is on: then a heard node of a type whose bit is set is still added by the radio, the rest are pushed as NEW_ADVERT.
abstract final class AutoAddFlags {
  static const overwriteOldest = 1 << 0; // when full, replace the oldest NON-favourite contact (push CONTACT_DELETED)
  static const chat = 1 << 1;
  static const repeater = 1 << 2;
  static const room = 1 << 3;
  static const sensor = 1 << 4;
  static const allTypes = chat | repeater | room | sensor;
}

/// CMD_SET_AUTOADD_CONFIG: [58][config][max_hops optional] -> OK (MyMesh.cpp 2023-2029). max_hops is clamped to 64; 0 = no limit,
/// 1 = direct only, N = up to N-1 hops (BaseChatMesh.h 109). A firmware without it answers ERR(UNSUPPORTED_CMD).
Uint8List encodeSetAutoAddConfig(int config, {int? maxHops}) =>
    Uint8List.fromList([Cmd.setAutoAddConfig, config & 0xff, if (maxHops != null) maxHops.clamp(0, 64)]);

/// CMD_GET_AUTOADD_CONFIG: [59] -> RESP_CODE_AUTOADD_CONFIG [25][config][max_hops] (MyMesh.cpp 2030-2036).
Uint8List encodeGetAutoAddConfig() => Uint8List.fromList([Cmd.getAutoAddConfig]);

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

  /// Bytes 44-47 of the frame (MyMesh.cpp 1100-1104). [manualAdd] bit 0 = 1: the radio does NOT add heard nodes to its
  /// contact table by itself (see [AutoAddFlags]); the other bits are reserved. [telemetryModes] and [advertLocPolicy] and
  /// [multiAcks] must be sent back unchanged by SET_OTHER_PARAMS, which overwrites all of them.
  final int multiAcks;
  final int advertLocPolicy;
  final int telemetryModes;
  final int manualAdd;
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
    this.multiAcks = 0,
    this.advertLocPolicy = 0,
    this.telemetryModes = 0,
    this.manualAdd = 0,
  });
  bool get asksBeforeAdding => (manualAdd & 1) != 0;
  double get freqMhz => freqKhz / 1000.0;
  double get bwKhz => bwHz / 1000.0;
}

/// RESP_CODE_AUTOADD_CONFIG: [25][config][max_hops]; see [AutoAddFlags].
class AutoAddConfigFrame extends Frame {
  final int config;
  final int maxHops;
  const AutoAddConfigFrame(this.config, this.maxHops);
}

/// RESP_CODE_DEVICE_INFO (MyMesh.cpp ~1059): [13][fw_ver_code][max_contacts/2][max_channels][ble_pin u32]
/// [build_date x12][manufacturer x40][fw_version x20][repeat (v9+)][path_hash_mode (v10+)].
/// Very old firmware sends a shorter frame; fields that aren't present are null.
class DeviceInfoFrame extends Frame {
  final int firmwareVerCode;

  /// MAX_CONTACTS / 2 as sent, already doubled here (MyMesh.cpp 1061-1063).
  final int? maxContacts;
  final int? maxChannels;
  final String? buildDate;
  final String? manufacturer;
  final String? firmwareVersion;
  final int? pathHashMode;
  const DeviceInfoFrame({
    required this.firmwareVerCode,
    this.maxContacts,
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

  /// The whole frame as received (code byte included).
  final Uint8List? raw;
  const ChannelMsgFrame(
      {this.snrDb,
      required this.channelIndex,
      required this.pathLen,
      required this.txtType,
      required this.timestamp,
      required this.text,
      this.raw});
}

/// Contact (direct) messages; not used by MeshSonar beyond recognising them.
class ContactMsgFrame extends Frame {
  final Uint8List data;
  const ContactMsgFrame(this.data);
}

/// A contact (direct) message the radio queued, e.g. a repeater's CLI reply. V3 (queueMessage, MyMesh.cpp ~440):
/// [16][snr i8·4][r][r][prefix x6][path_len][txt_type][timestamp u32]([signer prefix x4] when txt_type is SIGNED)[text];
/// pre-V3: [7][prefix x6][path_len][txt_type][timestamp u32][text]. [prefixHex] is 12 hex characters.
class ContactTextFrame extends ContactMsgFrame {
  final double? snrDb;
  final String prefixHex;
  final int pathLen;
  final int txtType;
  final int timestamp;
  final String text;

  /// TXT_TYPE_SIGNED_PLAIN (2): the 4-byte signer prefix that precedes the text, 8 hex characters; null otherwise.
  final String? signerPrefixHex;
  const ContactTextFrame(super.data,
      {this.snrDb,
      required this.prefixHex,
      required this.pathLen,
      required this.txtType,
      required this.timestamp,
      required this.text,
      this.signerPrefixHex});
}

/// RESP_CODE_SENT (MyMesh.cpp ~1150): [6][is_flood][tag / expected ack u32][est_timeout_ms u32].
class SentFrame extends Frame {
  final bool flood;
  final int tag;
  final int estTimeoutMs;
  const SentFrame({required this.flood, required this.tag, required this.estTimeoutMs});
}

/// RESP_CODE_CONTACT (writeContactRespFrame, MyMesh.cpp 171-193): [3][pub_key x32][type][flags][out_path_len]
/// [out_path x64][name x32][last_advert u32][lat i32 x1e-6][lon i32 x1e-6][lastmod u32] = 148 bytes. PUSH_CODE_NEW_ADVERT
/// (0x8A) carries the same layout under its own code. Fields past the name are 0 when a short (older) frame omits them.
class ContactFrame extends Frame {
  final Uint8List publicKey;
  final int type;
  final int flags;
  final int outPathLen;
  final Uint8List outPath;
  final String name;
  final int lastAdvert;
  final double lat;
  final double lon;
  final int lastMod;
  const ContactFrame({
    required this.publicKey,
    required this.type,
    required this.outPathLen,
    required this.name,
    this.flags = 0,
    required this.outPath,
    this.lastAdvert = 0,
    this.lat = 0,
    this.lon = 0,
    this.lastMod = 0,
  });
}

/// RESP_CODE_CONTACTS_START (MyMesh.cpp 1252-1256): [2][count u32], the TOTAL number of contacts on the radio (not the
/// number the `since` filter lets through).
class ContactsStartFrame extends Frame {
  final int count;
  const ContactsStartFrame(this.count);
}

/// RESP_CODE_END_OF_CONTACTS (MyMesh.cpp 2404-2408): [4][most recent lastmod u32], the cursor for the next `since`.
class EndOfContactsFrame extends Frame {
  final int mostRecentLastMod;
  const EndOfContactsFrame(this.mostRecentLastMod);
}

/// PUSH_CODE_NEW_ADVERT (0x8A): a contact the radio did not have, as a full contact frame (onDiscoveredContact, MyMesh.cpp
/// 358-407).
class NewAdvertPush extends Frame {
  final ContactFrame contact;
  const NewAdvertPush(this.contact);
}

/// PUSH_CODE_ADVERT (0x80): [0x80][pub_key x32], a known contact advertised again.
class AdvertPush extends Frame {
  final Uint8List publicKey;
  const AdvertPush(this.publicKey);
}

/// PUSH_CODE_PATH_UPDATED (0x81, onContactPathUpdated MyMesh.cpp 409-415): [0x81][pub_key x32].
class PathUpdatedPush extends Frame {
  final Uint8List publicKey;
  const PathUpdatedPush(this.publicKey);
}

/// PUSH_CODE_SEND_CONFIRMED (0x82, processAck MyMesh.cpp 417-436): [0x82][ack u32][trip time ms u32] = 9 bytes.
class SendConfirmedPush extends Frame {
  final int ack;
  final int tripMs;
  const SendConfirmedPush(this.ack, this.tripMs);
}

/// PUSH_CODE_CONTACT_DELETED (0x8F): [0x8F][pub_key x32].
class ContactDeletedPush extends Frame {
  final Uint8List publicKey;
  const ContactDeletedPush(this.publicKey);
}

/// PUSH_CODE_CONTACTS_FULL (0x90): [0x90].
class ContactsFullPush extends Frame {
  const ContactsFullPush();
}

/// RESP_CODE_CHANNEL_DATA_RECV (27, onChannelDataRecv MyMesh.cpp ~601-632): [27][snr i8 x4][0][0][channel_idx][path_len]
/// [data_type u16][data_len u8][data...]. A binary datagram: it shares the offline queue with messages, so the drain has
/// to step over it; MeshSonar does not use it yet.
class ChannelDataFrame extends Frame {
  final int channelIndex;
  final int dataType;
  final Uint8List data;
  const ChannelDataFrame(this.channelIndex, this.dataType, this.data);
}

/// PUSH_CODE_LOGIN_SUCCESS (onContactResponse, MyMesh.cpp ~700): [0x85][is_admin][pub_key_prefix x6][server time u32]
/// [acl permissions][firmware level]. The pre-v7 form is only [0x85][0][prefix x6] and always reads as not admin
/// (the firmware says so: "legacy: is_admin = false"). A GUEST login also succeeds, with is_admin 0.
class LoginSuccessPush extends Frame {
  final bool isAdmin;
  final String prefixHex;
  final int? aclPermissions;
  final int? firmwareLevel;
  const LoginSuccessPush({required this.isAdmin, required this.prefixHex, this.aclPermissions, this.firmwareLevel});
}

/// PUSH_CODE_LOGIN_FAIL: [0x86][reserved][pub_key_prefix x6]. Only sent for a reply the radio could not read; a wrong
/// password on a repeater produces NO reply, so expect silence, not this frame.
class LoginFailPush extends Frame {
  final String prefixHex;
  const LoginFailPush(this.prefixHex);
}

/// What a repeater reports about itself (examples/simple_repeater/MyMesh.h `RepeaterStats`, little endian, 56 bytes on
/// current firmware; older builds send a prefix of it, so every later field can be null).
class RepeaterStatus {
  final int battMilliVolts;
  final int txQueueLen;
  final int noiseFloorDbm;
  final int lastRssiDbm;
  final int packetsRecv;
  final int packetsSent;
  final int airTimeSecs;
  final int upTimeSecs;
  final double? lastSnrDb;
  const RepeaterStatus({
    required this.battMilliVolts,
    required this.txQueueLen,
    required this.noiseFloorDbm,
    required this.lastRssiDbm,
    required this.packetsRecv,
    required this.packetsSent,
    required this.airTimeSecs,
    required this.upTimeSecs,
    this.lastSnrDb,
  });
}

/// PUSH_CODE_STATUS_RESPONSE (MyMesh.cpp ~732): [0x87][reserved][pub_key_prefix x6][RepeaterStats...].
class StatusResponsePush extends Frame {
  final String prefixHex;
  final RepeaterStatus status;

  /// The whole statistics block as received (56 bytes + zero padding), for the admin screens (repeater_wire.dart).
  final Uint8List? statsBytes;
  const StatusResponsePush(this.prefixHex, this.status, {this.statsBytes});
}

/// PUSH_CODE_TELEMETRY_RESPONSE (0x8B) from a REMOTE node: [0x8B][0][pub_key_prefix x6][CayenneLPP, big endian, zero padded].
class TelemetryResponsePush extends Frame {
  final String prefixHex;
  final Uint8List lpp;
  const TelemetryResponsePush(this.prefixHex, this.lpp);
}

/// PUSH_CODE_BINARY_RESPONSE (0x8C): [0x8C][0][tag u32][data...]. The tag is the one in the SENT frame of the request.
/// The data is zero padded to the cipher block size: trust the counts inside it, not its length.
class BinaryResponsePush extends Frame {
  final int tag;
  final Uint8List data;
  const BinaryResponsePush(this.tag, this.data);
}

/// RESP_CODE_SIGN_START (MyMesh.cpp ~1781): [19][reserved][max_len u32].
class SignStartFrame extends Frame {
  final int maxLen;
  const SignStartFrame(this.maxLen);
}

/// RESP_CODE_SIGNATURE: [20][signature x64].
class SignatureFrame extends Frame {
  final Uint8List signature;
  const SignatureFrame(this.signature);
}

/// RESP_CODE_EXPORT_CONTACT: [11][advert packet...].
class ExportContactFrame extends Frame {
  final Uint8List packet;
  const ExportContactFrame(this.packet);
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

String _hex(Uint8List b, int start, int n) {
  final sb = StringBuffer();
  for (var i = start; i < start + n && i < b.length; i++) {
    sb.write(b[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Frame _decodeContactText(Uint8List f) {
  final v3 = f[0] == Resp.contactMsgRecvV3;
  final start = v3 ? 4 : 1; // prefix
  if (f.length < start + 6 + 1 + 1 + 4) return ContactMsgFrame(f);
  final bd = ByteData.sublistView(f);
  final pathLen = f[start + 6];
  final txtType = f[start + 7];
  final ts = bd.getUint32(start + 8, Endian.little);
  var textAt = start + 12;
  String? signer;
  if (txtType == 2 /* TXT_TYPE_SIGNED_PLAIN carries a 4-byte signer prefix first */) {
    signer = _hex(f, textAt, 4);
    textAt += 4;
  }
  if (textAt > f.length) textAt = f.length;
  return ContactTextFrame(f,
      snrDb: v3 ? bd.getInt8(1) / 4.0 : null,
      prefixHex: _hex(f, start, 6),
      pathLen: pathLen,
      txtType: txtType,
      timestamp: ts,
      text: utf8.decode(f.sublist(textAt), allowMalformed: true),
      signerPrefixHex: signer);
}

/// Bytes of path a packet's `path_len` byte stands for: the low 6 bits are the hop count, the top 2 bits the hash size
/// minus one (src/Packet.h 79-83). 0xFF (OUT_PATH_UNKNOWN) = no path.
int pathByteLength(int pathLen) => pathLen == 0xFF ? 0 : (pathLen & 63) * ((pathLen >> 6) + 1);

ContactFrame _decodeContact(Uint8List f) {
  if (f.length < 1 + 32 + 3 + 64 + 32) throw ProtocolException('CONTACT frame too short (${f.length})');
  final bd = ByteData.sublistView(f);
  int u32(int at) => f.length >= at + 4 ? bd.getUint32(at, Endian.little) : 0;
  double deg(int at) => f.length >= at + 4 ? bd.getInt32(at, Endian.little) / 1e6 : 0;
  final pathLen = f[35];
  return ContactFrame(
    publicKey: Uint8List.fromList(f.sublist(1, 33)),
    type: f[33],
    flags: f[34],
    outPathLen: pathLen,
    outPath: Uint8List.fromList(f.sublist(36, 36 + pathByteLength(pathLen).clamp(0, 64))),
    name: _cString(f, 100, 32),
    lastAdvert: u32(132),
    lat: deg(136),
    lon: deg(140),
    lastMod: u32(144),
  );
}

RepeaterStatus _decodeRepeaterStatus(Uint8List f, int at) {
  final bd = ByteData.sublistView(f, at);
  final n = bd.lengthInBytes;
  int u32(int o) => n >= o + 4 ? bd.getUint32(o, Endian.little) : 0;
  return RepeaterStatus(
    battMilliVolts: bd.getUint16(0, Endian.little),
    txQueueLen: bd.getUint16(2, Endian.little),
    noiseFloorDbm: bd.getInt16(4, Endian.little),
    lastRssiDbm: bd.getInt16(6, Endian.little),
    packetsRecv: u32(8),
    packetsSent: u32(12),
    airTimeSecs: u32(16),
    upTimeSecs: u32(20),
    lastSnrDb: n >= 44 ? bd.getInt16(42, Endian.little) / 4.0 : null,
  );
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
        multiAcks: f[44],
        advertLocPolicy: f[45],
        telemetryModes: f[46],
        manualAdd: f[47],
        name: utf8.decode(f.sublist(58).takeWhile((b) => b != 0).toList(), allowMalformed: true),
      );
    case Resp.deviceInfo:
      need(2, 'DEVICE_INFO');
      return DeviceInfoFrame(
        firmwareVerCode: f[1],
        maxContacts: f.length > 2 ? f[2] * 2 : null,
        maxChannels: f.length > 3 ? f[3] : null,
        buildDate: f.length >= 20 ? _cString(f, 8, 12) : null,
        manufacturer: f.length >= 60 ? _cString(f, 20, 40) : null,
        firmwareVersion: f.length >= 80 ? _cString(f, 60, 20) : null,
        pathHashMode: f.length >= 82 ? f[81] : null,
      );
    case Resp.autoAddConfig:
      need(2, 'AUTOADD_CONFIG');
      return AutoAddConfigFrame(f[1], f.length > 2 ? f[2] : 0);
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
        raw: Uint8List.fromList(f),
      );
    case Resp.channelMsgRecv:
      need(8, 'CHANNEL_MSG_RECV');
      return ChannelMsgFrame(
        channelIndex: f[1],
        pathLen: f[2],
        txtType: f[3],
        timestamp: bd.getUint32(4, Endian.little),
        text: utf8.decode(f.sublist(8), allowMalformed: true),
        raw: Uint8List.fromList(f),
      );
    case Resp.contactMsgRecv:
    case Resp.contactMsgRecvV3:
      return _decodeContactText(Uint8List.fromList(f));
    case Resp.sent:
      need(10, 'SENT');
      return SentFrame(flood: f[1] != 0, tag: bd.getUint32(2, Endian.little), estTimeoutMs: bd.getUint32(6, Endian.little));
    case Resp.contactsStart:
      need(5, 'CONTACTS_START');
      return ContactsStartFrame(bd.getUint32(1, Endian.little));
    case Resp.endOfContacts:
      return EndOfContactsFrame(f.length >= 5 ? bd.getUint32(1, Endian.little) : 0);
    case Resp.contact:
      return _decodeContact(f);
    case Push.newAdvert:
      return NewAdvertPush(_decodeContact(f));
    case Push.advert:
      need(33, 'ADVERT');
      return AdvertPush(Uint8List.fromList(f.sublist(1, 33)));
    case Push.pathUpdated:
      need(33, 'PATH_UPDATED');
      return PathUpdatedPush(Uint8List.fromList(f.sublist(1, 33)));
    case Push.sendConfirmed:
      need(9, 'SEND_CONFIRMED');
      return SendConfirmedPush(bd.getUint32(1, Endian.little), bd.getUint32(5, Endian.little));
    case Push.contactDeleted:
      need(33, 'CONTACT_DELETED');
      return ContactDeletedPush(Uint8List.fromList(f.sublist(1, 33)));
    case Push.contactsFull:
      return const ContactsFullPush();
    case Resp.channelDataRecv:
      need(9, 'CHANNEL_DATA_RECV');
      final dlen = f[8];
      final end = (9 + dlen) > f.length ? f.length : 9 + dlen;
      return ChannelDataFrame(f[4], f[6] | (f[7] << 8), Uint8List.fromList(f.sublist(9, end)));
    case Push.loginSuccess:
      need(8, 'LOGIN_SUCCESS');
      final legacy = f.length < 14;
      return LoginSuccessPush(
        isAdmin: !legacy && (f[1] & 1) != 0,
        prefixHex: _hex(f, 2, 6),
        aclPermissions: legacy ? null : f[12],
        firmwareLevel: legacy ? null : f[13],
      );
    case Push.loginFail:
      need(8, 'LOGIN_FAIL');
      return LoginFailPush(_hex(f, 2, 6));
    case Push.statusResponse:
      need(8 + 20, 'STATUS_RESPONSE');
      return StatusResponsePush(_hex(f, 2, 6), _decodeRepeaterStatus(f, 8), statsBytes: Uint8List.fromList(f.sublist(8)));
    case Push.telemetryResponse:
      need(8, 'TELEMETRY_RESPONSE');
      return TelemetryResponsePush(_hex(f, 2, 6), Uint8List.fromList(f.sublist(8)));
    case Push.binaryResponse:
      need(6, 'BINARY_RESPONSE');
      return BinaryResponsePush(bd.getUint32(2, Endian.little), Uint8List.fromList(f.sublist(6)));
    case Resp.signStart:
      need(6, 'SIGN_START');
      return SignStartFrame(bd.getUint32(2, Endian.little));
    case Resp.signature:
      need(65, 'SIGNATURE');
      return SignatureFrame(Uint8List.fromList(f.sublist(1, 65)));
    case Resp.exportContact:
      return ExportContactFrame(Uint8List.fromList(f.sublist(1)));
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
  int manualAdd = 0,
  int telemetryModes = 0,
  int advertLocPolicy = 0,
  int multiAcks = 0,
}) {
  final b = BytesBuilder();
  b.add([Resp.selfInfo, advType, txPowerDbm & 0xff, maxTxPowerDbm & 0xff]);
  b.add(publicKey);
  final ll = ByteData(8)
    ..setInt32(0, (advLat * 1e6).round(), Endian.little)
    ..setInt32(4, (advLon * 1e6).round(), Endian.little);
  b.add(ll.buffer.asUint8List());
  b.add([multiAcks, advertLocPolicy, telemetryModes, manualAdd]);
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


// ------------------------------------------------------------------ radio-side encoders for the claim frames
// (the fake radio in tests plays these; layouts as documented on the decoded classes)

Uint8List encodeSent({bool flood = false, int tag = 0, int estTimeoutMs = 2000}) =>
    Uint8List.fromList([Resp.sent, flood ? 1 : 0, ..._u32(tag), ..._u32(estTimeoutMs)]);

Uint8List encodeContactFrame(
  List<int> pubKey32, {
  required int type,
  required String name,
  int outPathLen = 0xFF,
  List<int> outPath = const [],
  int flags = 0,
  int lastAdvert = 0,
  double lat = 0,
  double lon = 0,
  int lastMod = 0,
  int code = Resp.contact,
}) {
  final out = Uint8List(1 + 32 + 3 + 64 + 32 + 4 + 8 + 4);
  out[0] = code;
  out.setRange(1, 33, _pub32(pubKey32));
  out[33] = type;
  out[34] = flags;
  out[35] = outPathLen;
  final path = outPath.length > 64 ? outPath.sublist(0, 64) : outPath;
  out.setRange(36, 36 + path.length, path);
  final nb = utf8Truncate(name, 31);
  out.setRange(100, 100 + nb.length, nb);
  final bd = ByteData.sublistView(out);
  bd.setUint32(132, lastAdvert, Endian.little);
  bd.setInt32(136, (lat * 1e6).round(), Endian.little);
  bd.setInt32(140, (lon * 1e6).round(), Endian.little);
  bd.setUint32(144, lastMod, Endian.little);
  return out;
}

Uint8List encodeContactsStart(int count) => Uint8List.fromList([Resp.contactsStart, ..._u32(count)]);
Uint8List encodeEndOfContacts(int mostRecentLastMod) => Uint8List.fromList([Resp.endOfContacts, ..._u32(mostRecentLastMod)]);
Uint8List encodeSendConfirmed(int ack, int tripMs) => Uint8List.fromList([Push.sendConfirmed, ..._u32(ack), ..._u32(tripMs)]);
Uint8List encodePathUpdated(List<int> pubKey32) => Uint8List.fromList([Push.pathUpdated, ..._pub32(pubKey32)]);
Uint8List encodeAdvertPush(List<int> pubKey32) => Uint8List.fromList([Push.advert, ..._pub32(pubKey32)]);
Uint8List encodeContactDeleted(List<int> pubKey32) => Uint8List.fromList([Push.contactDeleted, ..._pub32(pubKey32)]);
Uint8List encodeContactsFull() => Uint8List.fromList([Push.contactsFull]);
Uint8List encodeAutoAddConfig(int config, int maxHops) => Uint8List.fromList([Resp.autoAddConfig, config, maxHops]);
Uint8List encodeExportContactResp(List<int> packet) => Uint8List.fromList([Resp.exportContact, ...packet]);

/// A queued channel message as the radio hands it out (onChannelMessageRecv, MyMesh.cpp 558-585): V3 unless [v3] is false.
/// [text] is the whole text including the sender's "name: " prefix, as the radio delivers it.
Uint8List encodeChannelMsg(int channelIdx, String text, {int timestamp = 0, int pathLen = 0xFF, double snrDb = 0, bool v3 = true}) {
  final b = BytesBuilder();
  if (v3) {
    b.add([Resp.channelMsgRecvV3, _i8(snrDb * 4), 0, 0]);
  } else {
    b.addByte(Resp.channelMsgRecv);
  }
  b.add([channelIdx, pathLen, txtTypePlain, ..._u32(timestamp)]);
  b.add(utf8.encode(text));
  return b.toBytes();
}

/// A binary channel datagram in the offline queue (onChannelDataRecv).
Uint8List encodeChannelDataRecv(int channelIdx, int dataType, List<int> data, {int pathLen = 0xFF, double snrDb = 0}) =>
    Uint8List.fromList([Resp.channelDataRecv, _i8(snrDb * 4), 0, 0, channelIdx, pathLen, dataType & 0xff, dataType >> 8, data.length, ...data]);

/// [legacy] writes the 8-byte pre-v7 form.
Uint8List encodeLoginSuccess(List<int> pubKey32, {required bool isAdmin, int tag = 0, int aclPermissions = 3, int firmwareLevel = 2, bool legacy = false}) =>
    Uint8List.fromList([
      Push.loginSuccess,
      legacy ? 0 : (isAdmin ? 1 : 0),
      ..._pub32(pubKey32).take(6),
      if (!legacy) ...[..._u32(tag), aclPermissions, firmwareLevel],
    ]);

Uint8List encodeLoginFail(List<int> pubKey32) => Uint8List.fromList([Push.loginFail, 0, ..._pub32(pubKey32).take(6)]);

Uint8List encodeStatusResponse(List<int> pubKey32, RepeaterStatus s) {
  final bd = ByteData(56)
    ..setUint16(0, s.battMilliVolts, Endian.little)
    ..setUint16(2, s.txQueueLen, Endian.little)
    ..setInt16(4, s.noiseFloorDbm, Endian.little)
    ..setInt16(6, s.lastRssiDbm, Endian.little)
    ..setUint32(8, s.packetsRecv, Endian.little)
    ..setUint32(12, s.packetsSent, Endian.little)
    ..setUint32(16, s.airTimeSecs, Endian.little)
    ..setUint32(20, s.upTimeSecs, Endian.little)
    ..setInt16(42, ((s.lastSnrDb ?? 0) * 4).round(), Endian.little);
  return Uint8List.fromList([Push.statusResponse, 0, ..._pub32(pubKey32).take(6), ...bd.buffer.asUint8List()]);
}

Uint8List encodeSignStartResponse(int maxLen) => Uint8List.fromList([Resp.signStart, 0, ..._u32(maxLen)]);

Uint8List encodeSignatureResponse(List<int> signature64) {
  if (signature64.length != 64) throw ArgumentError('an ed25519 signature is 64 bytes');
  return Uint8List.fromList([Resp.signature, ...signature64]);
}

/// A queued contact message as the radio hands it out (V3 form unless [v3] is false).
Uint8List encodeContactText(List<int> senderKey, String text,
    {int txtType = txtTypeCliData, int timestamp = 0, int pathLen = 0xFF, double snrDb = 0, bool v3 = true, List<int> signer4 = const [0, 0, 0, 0]}) {
  final b = BytesBuilder();
  if (v3) {
    b.add([Resp.contactMsgRecvV3, _i8(snrDb * 4), 0, 0]);
  } else {
    b.addByte(Resp.contactMsgRecv);
  }
  b.add(senderKey.take(6).toList());
  b.add([pathLen, txtType, ..._u32(timestamp)]);
  if (txtType == 2) b.add(signer4.take(4).toList());
  b.add(utf8.encode(text));
  return b.toBytes();
}
