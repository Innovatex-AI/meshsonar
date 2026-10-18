// MeshSonar data model — MeshSonar Drive Format v1 with the v1.1 per-ping fields (pkt_hash, tx_epoch_s, tx_dbm).
//
// Source of truth for the wire format: CMAT docs/MESHSONAR_DRIVE_FORMAT.md and src/lib/drive/validate.ts
// (Innovatex-AI/meshcore-insights). toJson() here must produce exactly what that validator accepts.
// Pure Dart: no Flutter imports, so it runs in plain `dart test`.
//
// Rules carried from the spec:
//  - Unmeasured values are null, never guessed.
//  - A tx ping with an empty echoes list means "pinged here, heard nothing".
//  - Every ping and session has a UUID made on the phone, so re-sending is harmless.

/// The `format` id on the wire. Still `meshsonar.drive.v1`: live CMAT accepts only that id exactly
/// (src/lib/drive/validate.ts readDriveUpload) and ignores fields it doesn't know, so the v1.1 ping fields ride on the
/// v1 id until the site accepts `meshsonar.drive.v1.1` everywhere; then this flips (Drive Format v1.1, plan M1).
const String driveFormat = 'meshsonar.drive.v1';

class AppInfo {
  final String? name;
  final String? version;

  /// Build number (pubspec `+N`). Sent with problem reports only: it is not part of the Drive Format v1 `app` object.
  final String? build;
  final String? platform;
  const AppInfo({this.name, this.version, this.build, this.platform});

  /// The Drive Format v1 `app` object (uploads and exports).
  Map<String, dynamic> toJson() => {'name': name, 'version': version, 'platform': platform};
  factory AppInfo.fromJson(Map<String, dynamic> j) =>
      AppInfo(name: j['name'] as String?, version: j['version'] as String?, platform: j['platform'] as String?);
}

class Radio {
  final double? freqMhz;
  final double? bwKhz;
  final int? sf;
  final int? cr;
  final double? txDbm;
  const Radio({this.freqMhz, this.bwKhz, this.sf, this.cr, this.txDbm});
  Map<String, dynamic> toJson() => {'freq_mhz': freqMhz, 'bw_khz': bwKhz, 'sf': sf, 'cr': cr, 'tx_dbm': txDbm};
  factory Radio.fromJson(Map<String, dynamic> j) => Radio(
        freqMhz: (j['freq_mhz'] as num?)?.toDouble(),
        bwKhz: (j['bw_khz'] as num?)?.toDouble(),
        sf: (j['sf'] as num?)?.toInt(),
        cr: (j['cr'] as num?)?.toInt(),
        txDbm: (j['tx_dbm'] as num?)?.toDouble(),
      );
}

class Antenna {
  /// e.g. "stock", "external", "mag-mount"; null if unknown.
  final String? type;
  final double? gainDbi;
  final double? heightM;
  const Antenna({this.type, this.gainDbi, this.heightM});
  Map<String, dynamic> toJson() => {'type': type, 'gain_dbi': gainDbi, 'height_m': heightM};
  factory Antenna.fromJson(Map<String, dynamic> j) => Antenna(
        type: j['type'] as String?,
        gainDbi: (j['gain_dbi'] as num?)?.toDouble(),
        heightM: (j['height_m'] as num?)?.toDouble(),
      );
}

class Companion {
  /// Hex public key of the companion radio, lower case.
  final String? publicKey;
  final String? name;
  final String? firmware;
  const Companion({this.publicKey, this.name, this.firmware});
  Map<String, dynamic> toJson() => {'public_key': publicKey, 'name': name, 'firmware': firmware};
  factory Companion.fromJson(Map<String, dynamic> j) =>
      Companion(publicKey: j['public_key'] as String?, name: j['name'] as String?, firmware: j['firmware'] as String?);
}

class DriveSession {
  final String id; // UUID v4
  final DateTime startedAt; // UTC
  final DateTime? endedAt; // UTC; null while driving
  final String? label;
  final String? channel;
  final Radio radio;
  final Antenna antenna;
  final Companion companion;
  const DriveSession({
    required this.id,
    required this.startedAt,
    this.endedAt,
    this.label,
    this.channel,
    this.radio = const Radio(),
    this.antenna = const Antenna(),
    this.companion = const Companion(),
  });

  DriveSession copyWith({DateTime? endedAt, String? label}) => DriveSession(
        id: id,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        label: label ?? this.label,
        channel: channel,
        radio: radio,
        antenna: antenna,
        companion: companion,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'started_at': startedAt.toUtc().toIso8601String(),
        'ended_at': endedAt?.toUtc().toIso8601String(),
        'label': label,
        'channel': channel,
        'radio': radio.toJson(),
        'antenna': antenna.toJson(),
        'companion': companion.toJson(),
      };
  factory DriveSession.fromJson(Map<String, dynamic> j) => DriveSession(
        id: j['id'] as String,
        startedAt: DateTime.parse(j['started_at'] as String).toUtc(),
        endedAt: j['ended_at'] == null ? null : DateTime.parse(j['ended_at'] as String).toUtc(),
        label: j['label'] as String?,
        channel: j['channel'] as String?,
        radio: Radio.fromJson((j['radio'] as Map?)?.cast<String, dynamic>() ?? const {}),
        antenna: Antenna.fromJson((j['antenna'] as Map?)?.cast<String, dynamic>() ?? const {}),
        companion: Companion.fromJson((j['companion'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}

class Echo {
  /// Hex key or prefix of the repeater heard, lower case, whole bytes.
  final String repeater;
  final double? snrDb;
  final double? rssiDbm;

  /// 1 = heard the repeater directly (the only echoes that measure a phone↔repeater link).
  final int? hops;
  final List<String>? path;
  final int? delayMs;
  const Echo({required this.repeater, this.snrDb, this.rssiDbm, this.hops, this.path, this.delayMs});
  Map<String, dynamic> toJson() =>
      {'repeater': repeater, 'snr_db': snrDb, 'rssi_dbm': rssiDbm, 'hops': hops, 'path': path, 'delay_ms': delayMs};
  factory Echo.fromJson(Map<String, dynamic> j) => Echo(
        repeater: j['repeater'] as String,
        snrDb: (j['snr_db'] as num?)?.toDouble(),
        rssiDbm: (j['rssi_dbm'] as num?)?.toDouble(),
        hops: (j['hops'] as num?)?.toInt(),
        path: (j['path'] as List?)?.cast<String>(),
        delayMs: (j['delay_ms'] as num?)?.toInt(),
      );
}

class Neighbor {
  final String repeater;
  final double? localSnrDb;
  final double? localRssiDbm;
  final double? remoteSnrDb;
  const Neighbor({required this.repeater, this.localSnrDb, this.localRssiDbm, this.remoteSnrDb});
  Map<String, dynamic> toJson() => {
        'repeater': repeater,
        'local_snr_db': localSnrDb,
        'local_rssi_dbm': localRssiDbm,
        'remote_snr_db': remoteSnrDb,
      };
  factory Neighbor.fromJson(Map<String, dynamic> j) => Neighbor(
        repeater: j['repeater'] as String,
        localSnrDb: (j['local_snr_db'] as num?)?.toDouble(),
        localRssiDbm: (j['local_rssi_dbm'] as num?)?.toDouble(),
        remoteSnrDb: (j['remote_snr_db'] as num?)?.toDouble(),
      );
}

enum PingKind { tx, rx }

class DrivePing {
  final String id; // UUID v4
  final DateTime ts; // UTC, when the ping was sent (tx) or the packet heard (rx)
  final double lat;
  final double lon;
  final double? gpsAccuracyM;
  final double? speedMps;
  final PingKind kind;
  final double? noiseFloorDbm;

  /// Empty on a tx ping = pinged here, heard nothing.
  final List<Echo> echoes;
  final Neighbor? neighbor;

  /// v1.1: MeshCore packet hash of the transmission (Packet::calculatePacketHash, 8 bytes as 16 lower-case hex), the
  /// key the server joins observer receptions on. From a heard repeat when there is one, else computed from the
  /// exact GRP_TXT payload the companion builds. Null when unknown (rx pings, or the channel key/name is unknown).
  final String? pktHash;

  /// v1.1: the epoch second inside the sent packet (the timestamp in CMD_SEND_CHANNEL_TXT_MSG). Can be a second
  /// after [ts] because sends keep it strictly increasing. Null when unknown.
  final int? txEpochS;

  /// v1.1: the random tag in the ping's text on the channel ("MS:" plus the tag), so a heard repeat matches exactly this ping.
  /// Random per ping, never derived from position or time. Null for pings made before 0.7.3 and for rx pings.
  final String? wireTag;

  /// v1.1: the radio's TX power for this ping in dBm (power can change mid-drive). Null when unknown.
  final double? txDbm;
  const DrivePing({
    required this.id,
    required this.ts,
    required this.lat,
    required this.lon,
    this.gpsAccuracyM,
    this.speedMps,
    this.kind = PingKind.tx,
    this.noiseFloorDbm,
    this.echoes = const [],
    this.neighbor,
    this.pktHash,
    this.txEpochS,
    this.wireTag,
    this.txDbm,
  });

  bool get heardNothing => kind == PingKind.tx && echoes.isEmpty && neighbor == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ts': ts.toUtc().toIso8601String(),
        'lat': lat,
        'lon': lon,
        'gps_accuracy_m': gpsAccuracyM,
        'speed_mps': speedMps,
        'kind': kind.name,
        'noise_floor_dbm': noiseFloorDbm,
        'echoes': echoes.map((e) => e.toJson()).toList(),
        'neighbor': neighbor?.toJson(),
        'pkt_hash': pktHash,
        'tx_epoch_s': txEpochS,
        'wire_tag': wireTag,
        'tx_dbm': txDbm,
      };
  factory DrivePing.fromJson(Map<String, dynamic> j) => DrivePing(
        id: j['id'] as String,
        ts: DateTime.parse(j['ts'] as String).toUtc(),
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        gpsAccuracyM: (j['gps_accuracy_m'] as num?)?.toDouble(),
        speedMps: (j['speed_mps'] as num?)?.toDouble(),
        kind: j['kind'] == 'rx' ? PingKind.rx : PingKind.tx,
        noiseFloorDbm: (j['noise_floor_dbm'] as num?)?.toDouble(),
        echoes: ((j['echoes'] as List?) ?? const []).map((e) => Echo.fromJson((e as Map).cast<String, dynamic>())).toList(),
        neighbor: j['neighbor'] == null ? null : Neighbor.fromJson((j['neighbor'] as Map).cast<String, dynamic>()),
        pktHash: _hash16(j['pkt_hash']),
        txEpochS: (j['tx_epoch_s'] as num?)?.toInt(),
        wireTag: j['wire_tag'] as String?,
        txDbm: (j['tx_dbm'] as num?)?.toDouble(),
      );

  static final _hex16 = RegExp(r'^[0-9a-f]{16}$');
  static String? _hash16(Object? v) {
    if (v is! String) return null;
    final s = v.trim().toLowerCase();
    return _hex16.hasMatch(s) ? s : null;
  }
}

/// One upload / one export file: { format, app, session, pings }.
class DriveBatch {
  final AppInfo app;
  final DriveSession session;
  final List<DrivePing> pings;
  const DriveBatch({required this.app, required this.session, required this.pings});
  Map<String, dynamic> toJson() =>
      {'format': driveFormat, 'app': app.toJson(), 'session': session.toJson(), 'pings': pings.map((p) => p.toJson()).toList()};
}

/// A repeater from CMAT's drive-repeaters endpoint, for offline names.
class RepeaterRef {
  final String key; // full hex public key, lower case
  final String name;
  final double lat;
  final double lon;
  const RepeaterRef({required this.key, required this.name, required this.lat, required this.lon});
  Map<String, dynamic> toJson() => {'key': key, 'name': name, 'lat': lat, 'lon': lon};
  factory RepeaterRef.fromJson(Map<String, dynamic> j) => RepeaterRef(
        key: (j['key'] as String).toLowerCase(),
        name: j['name'] as String? ?? '',
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
      );
}
