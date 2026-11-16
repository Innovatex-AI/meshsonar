// MQTT feeds (observer-everywhere-mqtt-plan-2026-11-15.md sections 3.3, 3.4 and 6), the shared types:
//   * [MqttSlotSettings]: one of the 10 "MQTT feed" slots in Settings > Observer, as kept in settings.json. Credentials
//     (a password-auth broker's password) are NEVER here: they live in the Keychain/Keystore under [MqttSlotSettings.secretRef].
//   * [MqttPreset] / [MqttPresetList]: the broker presets, bundled with the app and refreshed from
//     `GET <base>/api/cmh/mqtt-presets` (public read, ETag). All presets ship OFF.
// The engine (lib/core/mqtt/) and the Observer settings page read these; neither owns the shape.
// Pure Dart: no Flutter imports.

/// How a slot authenticates. `jwt` = a token the connected radio signs (username `v1_<PUBKEY>`, password = token);
/// `password` = a username/password the person typed (password in the Keychain); `none` = anonymous.
enum MqttAuth {
  jwt('jwt'),
  password('password'),
  none('none');

  final String wire;
  const MqttAuth(this.wire);
  static MqttAuth parse(Object? v) => values.firstWhere((a) => a.wire == v, orElse: () => MqttAuth.jwt);
}

/// One MQTT feed slot. Off unless the person turned it on.
class MqttSlotSettings {
  /// Stable per slot (`slot-1` ...), also the Keychain reference of its credentials.
  final String id;

  /// The bundled/server preset it was made from; null = Custom.
  final String? presetId;
  final String name;
  final String host;
  final int port;

  /// WebSocket path (`/`, `/mqtt`, `/ws`). Only `wss` is ever used (no plain tcp).
  final String wsPath;
  final bool tls;

  /// JWT audience; null = [host].
  final String? aud;

  /// Topic region code (`meshcore/{IATA}/{PUBKEY}/...`); null = the nearest region's airport code.
  final String? iata;
  final MqttAuth auth;

  /// Username for [MqttAuth.password] slots (the password is in the Keychain, never here).
  final String? username;

  /// JWT lifetime, seconds (default 3600, re-signed about 5 minutes before it ends).
  final int ttlSec;
  final bool retainStatus;
  final bool enabled;

  const MqttSlotSettings({
    required this.id,
    this.presetId,
    required this.name,
    required this.host,
    this.port = 443,
    this.wsPath = '/',
    this.tls = true,
    this.aud,
    this.iata,
    this.auth = MqttAuth.jwt,
    this.username,
    this.ttlSec = defaultTtlSec,
    this.retainStatus = true,
    this.enabled = false,
  });

  static const int defaultTtlSec = 3600;

  /// The Keychain reference that holds this slot's password (password-auth slots only).
  String get secretRef => 'mqtt.$id';

  MqttSlotSettings copyWith({
    String? presetId,
    bool clearPreset = false,
    String? name,
    String? host,
    int? port,
    String? wsPath,
    bool? tls,
    String? aud,
    bool clearAud = false,
    String? iata,
    bool clearIata = false,
    MqttAuth? auth,
    String? username,
    bool clearUsername = false,
    int? ttlSec,
    bool? retainStatus,
    bool? enabled,
  }) =>
      MqttSlotSettings(
        id: id,
        presetId: clearPreset ? null : (presetId ?? this.presetId),
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        wsPath: wsPath ?? this.wsPath,
        tls: tls ?? this.tls,
        aud: clearAud ? null : (aud ?? this.aud),
        iata: clearIata ? null : (iata ?? this.iata),
        auth: auth ?? this.auth,
        username: clearUsername ? null : (username ?? this.username),
        ttlSec: ttlSec ?? this.ttlSec,
        retainStatus: retainStatus ?? this.retainStatus,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (presetId != null) 'preset': presetId,
        'name': name,
        'host': host,
        'port': port,
        'path': wsPath,
        if (!tls) 'tls': false,
        if (aud != null) 'aud': aud,
        if (iata != null) 'iata': iata,
        'auth': auth.wire,
        if (username != null) 'username': username,
        if (ttlSec != defaultTtlSec) 'ttl_sec': ttlSec,
        if (!retainStatus) 'retain_status': false,
        if (enabled) 'enabled': true,
      };

  /// A slot from settings.json; null when it lacks an id or a host (dropped on its own, the rest of the file still loads).
  static MqttSlotSettings? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], host = raw['host'];
    if (id is! String || id.isEmpty || host is! String || host.isEmpty) return null;
    final port = raw['port'];
    final ttl = raw['ttl_sec'];
    return MqttSlotSettings(
      id: id,
      presetId: raw['preset'] is String ? raw['preset'] as String : null,
      name: raw['name'] is String && (raw['name'] as String).isNotEmpty ? raw['name'] as String : host,
      host: host,
      port: port is num && port >= 1 && port <= 65535 ? port.round() : 443,
      wsPath: raw['path'] is String && (raw['path'] as String).startsWith('/') ? raw['path'] as String : '/',
      tls: raw['tls'] != false,
      aud: raw['aud'] is String ? raw['aud'] as String : null,
      iata: raw['iata'] is String ? raw['iata'] as String : null,
      auth: MqttAuth.parse(raw['auth']),
      username: raw['username'] is String ? raw['username'] as String : null,
      ttlSec: ttl is num && ttl >= 60 && ttl <= 86400 ? ttl.round() : defaultTtlSec,
      retainStatus: raw['retain_status'] != false,
      enabled: raw['enabled'] == true,
    );
  }

  @override
  bool operator ==(Object other) => other is MqttSlotSettings && _eq(toJson(), other.toJson());
  @override
  int get hashCode => Object.hashAll(toJson().entries.map((e) => '${e.key}=${e.value}'));
}

bool _eq(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// One broker preset (section 6 table). Advisory: an operator's acceptance of phone publishers is not implied.
class MqttPreset {
  final String id, name, host;
  final int port;
  final String wsPath;
  final MqttAuth auth;

  /// JWT audience; null = [host].
  final String? aud;

  /// Where it is meaningful (`US`, `CA`, `EU`, a region name) for the picker's search and the regional list.
  final String? region;

  /// The broker drops publishes without a real `[A-Z]{3}` airport code.
  final bool needsRealIata;

  /// Operator outreach record (OE6): true once an operator said yes, with [verifiedNote] (date and who).
  final bool verified;
  final String? verifiedNote;
  const MqttPreset({
    required this.id,
    required this.name,
    required this.host,
    this.port = 443,
    this.wsPath = '/',
    this.auth = MqttAuth.jwt,
    this.aud,
    this.region,
    this.needsRealIata = false,
    this.verified = false,
    this.verifiedNote,
  });

  static MqttPreset? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], name = raw['name'], host = raw['host'];
    if (id is! String || id.isEmpty || host is! String || host.isEmpty) return null;
    final port = raw['port'];
    String? s(String k) => raw[k] is String && (raw[k] as String).isNotEmpty ? raw[k] as String : null;
    return MqttPreset(
      id: id,
      name: name is String && name.isNotEmpty ? name : host,
      host: host,
      port: port is num && port >= 1 && port <= 65535 ? port.round() : 443,
      wsPath: s('path') != null && s('path')!.startsWith('/') ? s('path')! : '/',
      auth: MqttAuth.parse(raw['auth']),
      aud: s('aud'),
      region: s('region'),
      needsRealIata: raw['needsRealIata'] == true,
      verified: raw['verified'] == true,
      verifiedNote: s('verifiedNote'),
    );
  }

  /// A new, OFF slot from this preset.
  MqttSlotSettings toSlot(String slotId, {String? iata}) => MqttSlotSettings(
        id: slotId,
        presetId: id,
        name: name,
        host: host,
        port: port,
        wsPath: wsPath,
        aud: aud,
        iata: iata,
        auth: auth,
      );
}

/// The preset file: `{v, asOf, presets: [...]}`. Presets that do not parse are skipped one by one.
class MqttPresetList {
  final int version;
  final DateTime? asOf;
  final List<MqttPreset> presets;
  const MqttPresetList({this.version = 1, this.asOf, this.presets = const []});

  static MqttPresetList parse(Map<String, dynamic> j) {
    final list = j['presets'];
    if (list is! List) throw const FormatException('mqtt-presets');
    final v = j['v'];
    return MqttPresetList(
      version: v is num ? v.round() : 1,
      asOf: j['asOf'] is String ? DateTime.tryParse(j['asOf'] as String)?.toUtc() : null,
      presets: [for (final p in list) ?MqttPreset.tryParse(p)],
    );
  }
}

/// The answer to a conditional `GET mqtt-presets`: a fresh list with its ETag, or "not modified" (keep the copy you have).
class MqttPresetFetch {
  final MqttPresetList? list;
  final String? etag;
  bool get notModified => list == null;
  const MqttPresetFetch.fresh(MqttPresetList this.list, {this.etag});
  const MqttPresetFetch.notModified({this.etag}) : list = null;
}
