// App telemetry uploader STUB (Andy, Oct 21 2026: ingest ON by default with opt-out; headers/metadata only).
// Defines the ONLY shape that may ever leave the phone for the live packet feed, and a no-op sink until the server
// endpoint exists. Pure Dart.
//
// Guarantees, pinned by test/core/telemetry_test.dart:
//  * [TelemetryRecord] has no field that can hold a payload (no bytes, no text, no raw packet, no names, no GPS).
//  * [TelemetryRecord.fromRx] reads the packet header, path hashes and radio metrics only; the payload is dropped.
//  * [TelemetryUploader] hands nothing to the sink while telemetry is off (the Settings opt-out).
//  * The default sink does nothing: no network call exists yet.
import '../radio/packet.dart';
import '../radio/radio_api.dart';

/// Header-level metadata for one received packet. Deliberately small; adding a field means updating the disclosure
/// sheet, the website ingest contract and the test that pins [toJson]'s keys.
class TelemetryRecord {
  final DateTime at;

  /// Region code the phone was viewing/in (e.g. "CMH"); null when unknown.
  final String? region;

  /// MeshCore payload type (0..15) and route type (0..3) from the packet header byte.
  final int payloadType;
  final int routeType;

  /// One lower-case hex string per hop (repeater path hashes).
  final List<String> pathHashes;

  final double? snrDb;
  final double? rssiDbm;

  /// Packet hash (a digest, not content), used server-side to dedupe against observers.
  final String? packetHash;

  TelemetryRecord({
    required this.at,
    this.region,
    required this.payloadType,
    required this.routeType,
    List<String> pathHashes = const [],
    this.snrDb,
    this.rssiDbm,
    this.packetHash,
  }) : pathHashes = List.unmodifiable(pathHashes);

  /// Keys of [toJson], in order. The privacy contract: nothing else is ever sent.
  static const List<String> wireKeys = [
    'at', 'region', 'payload_type', 'route_type', 'path', 'snr_db', 'rssi_dbm', 'packet_hash',
  ];

  /// Builds a record from a received packet, keeping header/metadata only. Null if the bytes are not a packet.
  static TelemetryRecord? fromRx(RxPacket rx, {String? region}) {
    final p = MeshPacket.tryParse(rx.raw);
    if (p == null) return null;
    return TelemetryRecord(
      at: rx.at.toUtc(),
      region: region,
      payloadType: p.payloadType,
      routeType: p.routeType,
      pathHashes: p.pathHex,
      snrDb: rx.snrDb,
      rssiDbm: rx.rssiDbm,
      packetHash: p.hashHex,
    );
  }

  Map<String, dynamic> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'region': region,
        'payload_type': payloadType,
        'route_type': routeType,
        'path': pathHashes,
        'snr_db': snrDb,
        'rssi_dbm': rssiDbm,
        'packet_hash': packetHash,
      };
}

/// Where records go. The real HTTP sink lands with the server endpoint.
abstract class TelemetrySink {
  Future<void> send(List<TelemetryRecord> batch);
}

/// Does nothing. The default until the ingest endpoint exists.
class NoopTelemetrySink implements TelemetrySink {
  const NoopTelemetrySink();
  @override
  Future<void> send(List<TelemetryRecord> batch) async {}
}

/// Gates records on the user's opt-out, then batches them to the [sink]. [enabled] is read on every call, so the
/// Settings toggle takes effect at once and anything queued while on is discarded when turned off.
class TelemetryUploader {
  final TelemetrySink sink;
  final bool Function() enabled;
  final int batchSize;
  final List<TelemetryRecord> _queue = [];

  TelemetryUploader({this.sink = const NoopTelemetrySink(), required this.enabled, this.batchSize = 50});

  int get queued => _queue.length;

  /// Queues [r] if telemetry is on; returns whether it was kept.
  bool add(TelemetryRecord r) {
    if (!enabled()) {
      _queue.clear();
      return false;
    }
    _queue.add(r);
    return true;
  }

  /// Sends what is queued (only while on). Returns how many records went to the sink.
  Future<int> flush() async {
    if (!enabled()) {
      _queue.clear();
      return 0;
    }
    var sent = 0;
    while (_queue.isNotEmpty) {
      final n = _queue.length < batchSize ? _queue.length : batchSize;
      final batch = List<TelemetryRecord>.unmodifiable(_queue.sublist(0, n));
      await sink.send(batch);
      _queue.removeRange(0, n);
      sent += n;
    }
    return sent;
  }
}
