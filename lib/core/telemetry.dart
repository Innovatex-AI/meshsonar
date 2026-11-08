// App telemetry record (Andy, Oct 21 2026: ingest ON by default with opt-out; headers/metadata only). Defines the ONLY
// shape that may ever leave the phone for the live packet feed. Pure Dart. The uploader is lib/core/telemetry_uploader.dart;
// the server contract is meshcore-insights docs/TELEMETRY_INGEST.md (`meshsonar-telemetry/1`).
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

/// Answers whether a group packet's payload belongs to a channel anyone may read (Public, a # channel).
typedef ShareableChannel = bool Function(List<int> payload);

/// [ShareableChannel] by proof, not by guess: the one-byte channel hash narrows the candidates, then the packet's MAC must
/// verify under that channel's key (a private channel that happens to share the hash byte fails the MAC). [keys] are the
/// keys anyone may know: the well-known Public key and the # channel keys (derived from the names) this phone holds.
class ShareableChannels {
  final List<List<int>> Function() keys;
  const ShareableChannels(this.keys);

  bool call(List<int> payload) {
    if (payload.length < 3) return false;
    final hash = payload[0];
    for (final k in keys()) {
      if (k.length < 16 || channelHash(k) != hash) continue;
      if (meshMacThenDecrypt(k, payload.sublist(1)) != null) return true;
    }
    return false;
  }
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

  /// A group packet that was not checked must never be queued or sent.
  bool get mayLeavePhone => !telemetryPrivateTypes.contains(payloadType) && (!telemetryGroupTypes.contains(payloadType) || channelChecked);

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
  }) : pathHashes = List.unmodifiable(pathHashes);

  /// Keys of [toJson], in order: the packet object of `meshsonar-telemetry/1`. The privacy contract: nothing else is sent.
  static const List<String> wireKeys = ['rx_ts', 'type', 'route', 'hash_size', 'path', 'snr', 'rssi', 'pkt_hash'];

  /// Builds a record from a received packet, keeping header/metadata only. Null if the bytes are not a packet or it is
  /// a private packet type.
  ///
  /// A group packet needs [shareableChannel] to say its channel may be shared; without it (or for a private or unknown
  /// channel) there is no record.
  static TelemetryRecord? fromRx(RxPacket rx, {String? region, ShareableChannel? shareableChannel}) {
    final p = MeshPacket.tryParse(rx.raw);
    if (p == null) return null;
    if (telemetryPrivateTypes.contains(p.payloadType)) return null;
    final group = telemetryGroupTypes.contains(p.payloadType);
    if (group && (shareableChannel == null || p.payload.isEmpty || !shareableChannel(p.payload))) return null;
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
    );
  }

  /// The form kept in the phone's queue: the wire keys plus the queue-only mark and region (never sent).
  Map<String, dynamic> toQueueJson() => {...toJson(), 'region': region, if (channelChecked) 'channel_checked': true};
}
