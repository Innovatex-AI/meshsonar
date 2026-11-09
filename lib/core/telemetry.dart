// App telemetry record (Andy, Oct 21 2026: ingest ON by default with opt-out). Defines the ONLY shape that may ever leave
// the phone for the live packet feed. Pure Dart. The uploader is lib/core/telemetry_uploader.dart; the server contracts are
// meshcore-insights docs/TELEMETRY_INGEST.md (`meshsonar-telemetry/1`, headers only) and meshsonar-infra
// docs/planning/phone-observer-contract-v2-2026-11-08.md (`meshsonar-telemetry/2`, the phone observer, Nov 8 2026).
//
// v2 (phone observer O2, Andy's decisions Nov 8 2026 Q1/Q2) adds three optional fields per packet:
//  * `raw`: the full packet bytes, ONLY for public types: ADVERT, PATH, TRACE, and GRP_TXT / GRP_DATA whose channel was
//    proven (MAC) to be Public or a # channel; then `channel` says which ("public" / "#name"). Never for anything else.
//  * `cell`: the H3 resolution-7 cell (~5 km) the phone was in when it heard the packet; never latitude/longitude. Left
//    out when the person chose "Region only", when there is no recent fix, and always in Home observer mode.
//
// Guarantees, pinned by test/core/telemetry_test.dart and test/core/telemetry_uploader_test.dart:
//  * [TelemetryRecord] has no field that can hold a payload (no bytes, no text, no raw packet, no names, no GPS).
//  * [TelemetryRecord.fromRx] reads the packet header, path hashes and radio metrics only; the payload is dropped.
//  * Private point-to-point packet types (REQ, RESPONSE, TXT_MSG, ANON_REQ) never become a record at all.
//  * Group packets (GRP_TXT, GRP_DATA) become a record only when their channel is one anyone may read: the well-known
//    Public channel, or a # channel this phone holds (its key comes from the name). A private channel, or a channel the
//    phone cannot identify (it might be private), never becomes a record (fail closed; fixed Nov 8 2026: before that the
//    headers of private-channel packets were recorded although the disclosure promised they were not).
import '../radio/crypto.dart' show channelHash, meshMacThenDecrypt;
import '../radio/packet.dart';
import '../radio/radio_api.dart';

/// Payload types that are private, point-to-point traffic. Same list the server drops; the phone never even builds a record.
const Set<int> telemetryPrivateTypes = {PayloadType.req, PayloadType.response, PayloadType.txtMsg, PayloadType.anonReq};

/// Group payload types: their first payload byte is the channel hash. Recorded only for a channel anyone may read.
const Set<int> telemetryGroupTypes = {PayloadType.grpTxt, PayloadType.grpData};

/// Payload types whose full bytes may be shared (v2 `raw`) without a channel check: adverts, path returns and traces.
/// Group types join them only with a proven Public / # channel ([telemetryGroupTypes] + `channel`).
const Set<int> telemetryRawTypes = {PayloadType.advert, PayloadType.path, PayloadType.trace};

/// Longest `raw` the contract allows: 256 bytes (512 hex chars). A longer packet goes header-only.
const int telemetryMaxRawBytes = 256;

/// Answers whether a group packet's payload belongs to a channel anyone may read (Public, a # channel).
typedef ShareableChannel = bool Function(List<int> payload);

/// Proves a group packet's channel: `"public"` or `"#name"` when the MAC verifies under that channel's key, `""` when it
/// verifies under a key anyone may know but whose name is not known here (header only, no `raw`), null when not proven.
typedef ChannelMatch = String? Function(List<int> payload);

/// The `channel` value the contract accepts: `public` or `#` + 1..31 of `[a-z0-9_-]`.
final RegExp telemetryChannelRe = RegExp(r'^(public|#[a-z0-9_-]{1,31})$');

/// An H3 cell as the contract sends it: 15 lower-case hex characters (resolution 7 starts with `87`).
final RegExp telemetryCellRe = RegExp(r'^87[0-9a-f]{13}$');

final RegExp _rawRe = RegExp(r'^[0-9a-f]+$');

/// Where the phone was when it heard packets: `background` (in a pocket, moving, the default) or `home` (a fixed home
/// observer at a registered position, contract section 4).
enum ObserverMode {
  background('background'),
  home('home');

  final String wire;
  const ObserverMode(this.wire);
}

/// [ShareableChannel] by proof, not by guess: the one-byte channel hash narrows the candidates, then the packet's MAC must
/// verify under that channel's key (a private channel that happens to share the hash byte fails the MAC). [keys] are the
/// keys anyone may know: the well-known Public key and the # channel keys (derived from the names) this phone holds.
///
/// [named] adds keys with their channel name (`public`, `#name`): a packet proven under one of them may also carry its raw
/// bytes in v2 ([match] returns the name). Keys in [keys] prove the channel for the header only.
class ShareableChannels {
  final List<List<int>> Function() keys;
  final List<({String name, List<int> key})> Function()? named;
  const ShareableChannels(this.keys, {this.named});

  bool call(List<int> payload) => match(payload) != null;

  /// The proven channel's name (`public`, `#name`), `""` when proven under an unnamed key, null when not proven.
  String? match(List<int> payload) {
    if (payload.length < 3) return null;
    final hash = payload[0];
    bool proves(List<int> k) => k.length >= 16 && channelHash(k) == hash && meshMacThenDecrypt(k, payload.sublist(1)) != null;
    for (final c in named?.call() ?? const <({String name, List<int> key})>[]) {
      if (telemetryChannelRe.hasMatch(c.name) && proves(c.key)) return c.name;
    }
    for (final k in keys()) {
      if (proves(k)) return '';
    }
    return null;
  }
}

/// Lower-case hex of [bytes].
String _hex(List<int> bytes) {
  final b = StringBuffer();
  for (final x in bytes) {
    b.write((x & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// Header-level metadata for one received packet. Deliberately small; adding a field means updating the disclosure
/// sheet, the website ingest contract and the test that pins [toJson]'s keys.
class TelemetryRecord {
  final DateTime at;

  /// Region code the phone was in (3 uppercase letters, e.g. "CMH"); null when unknown. A claim, never a position.
  final String? region;

  /// MeshCore payload type (0..15) and route type (0..3) from the packet header byte.
  final int payloadType;
  final int routeType;

  /// Bytes per path hash (1..3).
  final int hashSize;

  /// One lower-case hex string per hop (repeater path hashes).
  final List<String> pathHashes;

  final double? snrDb;
  final double? rssiDbm;

  /// Packet hash (a digest, not content), used server-side to dedupe against observers.
  final String? packetHash;

  /// For a group packet: its channel was checked and anyone may read it. Never sent (not a wire key); kept in the phone's
  /// queue so a group record queued before the check existed is dropped instead of sent.
  final bool channelChecked;

  /// v2: the full packet bytes as lower hex, only for a public type (see [rawAllowedFor]); null = header only.
  final String? raw;

  /// v2: for a group packet with [raw], the proven channel (`public` / `#name`); null otherwise.
  final String? channel;

  /// v2: the H3 resolution-7 cell (15 hex) the phone was in; null when not shared. Never in [ObserverMode.home].
  final String? cell;

  /// Background (moving phone) or home observer. Batches are sent per mode (the batch's `observer.mode`).
  final ObserverMode mode;

  /// A group packet that was not checked must never be queued or sent.
  bool get mayLeavePhone => !telemetryPrivateTypes.contains(payloadType) && (!telemetryGroupTypes.contains(payloadType) || channelChecked);

  /// Whether [raw] may be sent for [type] with [channel]: ADVERT / PATH / TRACE always, a group type only with a proven
  /// Public or # channel, nothing else ever.
  static bool rawAllowedFor(int type, String? channel) =>
      telemetryRawTypes.contains(type) ||
      (telemetryGroupTypes.contains(type) && channel != null && telemetryChannelRe.hasMatch(channel));

  TelemetryRecord({
    required this.at,
    this.region,
    required this.payloadType,
    required this.routeType,
    this.hashSize = 1,
    List<String> pathHashes = const [],
    this.snrDb,
    this.rssiDbm,
    this.packetHash,
    this.channelChecked = false,
    String? raw,
    String? channel,
    String? cell,
    this.mode = ObserverMode.background,
  })  : pathHashes = List.unmodifiable(pathHashes),
        // The privacy rules hold whatever a caller passes: raw only for a public type (a group one only with its proven
        // channel), the channel only with raw, the cell only as an H3 res-7 index and never for a home observer.
        raw = (raw != null && raw.length <= telemetryMaxRawBytes * 2 && raw.length.isEven && _rawRe.hasMatch(raw) &&
                rawAllowedFor(payloadType, channel) && (!telemetryGroupTypes.contains(payloadType) || channelChecked))
            ? raw
            : null,
        channel = (raw != null && telemetryGroupTypes.contains(payloadType) && channelChecked && channel != null &&
                telemetryChannelRe.hasMatch(channel) && raw.length <= telemetryMaxRawBytes * 2 && _rawRe.hasMatch(raw))
            ? channel
            : null,
        cell = (mode == ObserverMode.background && cell != null && telemetryCellRe.hasMatch(cell)) ? cell : null;

  /// Keys of [toJson], in order: the packet object of `meshsonar-telemetry/1`. The privacy contract: nothing else is sent.
  static const List<String> wireKeys = ['rx_ts', 'type', 'route', 'hash_size', 'path', 'snr', 'rssi', 'pkt_hash'];

  /// Every key [toJsonV2] may write (`meshsonar-telemetry/2`): the v1 keys plus the three optional ones. Nothing else.
  static const List<String> wireKeysV2 = [...wireKeys, 'raw', 'channel', 'cell'];

  /// Builds a record from a received packet, keeping header/metadata only. Null if the bytes are not a packet or it is
  /// a private packet type.
  ///
  /// A group packet needs [shareableChannel] to say its channel may be shared; without it (or for a private or unknown
  /// channel) there is no record.
  ///
  /// v2: [channelMatch] (instead of [shareableChannel]) also names the channel, so a Public / # packet may carry its raw
  /// bytes. [cell] is the phone's H3 res-7 cell (the caller applies the person's location choice). [ownPublicKey] (hex):
  /// an advert of the connected radio itself, heard back through a repeater, is never shared (it would carry the radio's
  /// public key and name), the same rule as the phone's own pings.
  static TelemetryRecord? fromRx(
    RxPacket rx, {
    String? region,
    ShareableChannel? shareableChannel,
    ChannelMatch? channelMatch,
    String? cell,
    ObserverMode mode = ObserverMode.background,
    String? ownPublicKey,
  }) {
    final p = MeshPacket.tryParse(rx.raw);
    if (p == null) return null;
    if (telemetryPrivateTypes.contains(p.payloadType)) return null;
    final group = telemetryGroupTypes.contains(p.payloadType);
    String? channel;
    if (group) {
      if (p.payload.isEmpty) return null;
      if (channelMatch != null) {
        final m = channelMatch(p.payload);
        if (m == null) return null;
        channel = telemetryChannelRe.hasMatch(m) ? m : null;
      } else if (shareableChannel == null || !shareableChannel(p.payload)) {
        return null;
      }
    }
    if (p.payloadType == PayloadType.advert && ownPublicKey != null && ownPublicKey.length == 64 && p.payload.length >= 32 &&
        _hex(p.payload.sublist(0, 32)) == ownPublicKey.toLowerCase()) {
      return null;
    }
    final rawOk = rx.raw.length <= telemetryMaxRawBytes && rawAllowedFor(p.payloadType, channel);
    return TelemetryRecord(
      at: rx.at.toUtc(),
      region: region,
      payloadType: p.payloadType,
      routeType: p.routeType,
      hashSize: p.pathHashSize,
      pathHashes: p.pathHex,
      snrDb: _within(rx.snrDb, -60, 60),
      rssiDbm: _within(rx.rssiDbm, -200, 0)?.roundToDouble(),
      packetHash: p.hashHex,
      channelChecked: group,
      raw: rawOk ? _hex(rx.raw) : null,
      channel: rawOk ? channel : null,
      cell: cell,
      mode: mode,
    );
  }

  static double? _within(double? v, double lo, double hi) => v != null && v.isFinite && v >= lo && v <= hi ? v : null;

  Map<String, dynamic> toJson() => {
        'rx_ts': at.toUtc().toIso8601String(),
        'type': payloadType,
        'route': routeType,
        'hash_size': hashSize,
        'path': pathHashes,
        'snr': snrDb,
        'rssi': rssiDbm?.round(),
        'pkt_hash': packetHash,
      };

  /// The packet object of `meshsonar-telemetry/2`: [toJson] plus `raw` / `channel` / `cell` when present. Never lat/lon.
  Map<String, dynamic> toJsonV2() => {
        ...toJson(),
        if (raw != null) 'raw': raw,
        if (raw != null && channel != null) 'channel': channel,
        if (cell != null && mode == ObserverMode.background) 'cell': cell,
      };

  /// Reads a record back from the on-disk queue (the region rides beside the packet there). Null if malformed.
  static TelemetryRecord? tryFromJson(Object? j, {String? region}) {
    if (j is! Map) return null;
    final ts = j['rx_ts'] is String ? DateTime.tryParse(j['rx_ts'] as String) : null;
    final type = j['type'], route = j['route'], hs = j['hash_size'];
    if (ts == null || type is! int || route is! int || hs is! int) return null;
    if (type < 0 || type > 15 || route < 0 || route > 3 || hs < 1 || hs > 3) return null;
    if (telemetryPrivateTypes.contains(type)) return null;
    // A group record queued before channels were checked (no mark) is dropped, never sent.
    final checked = j['channel_checked'] == true;
    if (telemetryGroupTypes.contains(type) && !checked) return null;
    final path = j['path'];
    if (path is! List || path.any((e) => e is! String)) return null;
    return TelemetryRecord(
      at: ts.toUtc(),
      region: region,
      payloadType: type,
      routeType: route,
      hashSize: hs,
      pathHashes: path.cast<String>(),
      snrDb: j['snr'] is num ? (j['snr'] as num).toDouble() : null,
      rssiDbm: j['rssi'] is num ? (j['rssi'] as num).toDouble() : null,
      packetHash: j['pkt_hash'] is String ? j['pkt_hash'] as String : null,
      channelChecked: checked,
      // The constructor re-applies every v2 rule, so a hand-edited queue cannot widen what is sent.
      raw: j['raw'] is String ? j['raw'] as String : null,
      channel: j['channel'] is String ? j['channel'] as String : null,
      cell: j['cell'] is String ? j['cell'] as String : null,
      mode: j['mode'] == ObserverMode.home.wire ? ObserverMode.home : ObserverMode.background,
    );
  }

  /// The form kept in the phone's queue: the v2 wire keys plus the queue-only mark, region and mode (never sent per packet).
  Map<String, dynamic> toQueueJson() => {
        ...toJsonV2(),
        'region': region,
        if (channelChecked) 'channel_checked': true,
        if (mode != ObserverMode.background) 'mode': mode.wire,
      };
}
