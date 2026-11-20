// The packet shapes of the `/v1` read API (analyzer-api-contract.md 2.2, 2.3, 8.2): list rows grouped by hash,
// observations, resolved paths with per-hop confidence, the byte ranges of the inspector, and the packet detail.
// One model for every source: the `/v1` answer, today's region read while `/v1` is not live (fewer fields, the rest
// null), the phone's own radio (decoded on the phone by local_decoder.dart) and the pasted-hex decoder. Screens read
// [PacketDetail.source] and [PacketDetail.missing] to say honestly what a view lacks.
//
// Unknown enum values are kept as sent and shown as "other" (contract 7). Pure Dart: no Flutter imports.
import 'v1_client.dart' show v1Time;

/// Contract 1.5 type names by number.
const Map<int, String> packetTypeWireNames = {
  0: 'REQ',
  1: 'RESPONSE',
  2: 'TXT_MSG',
  3: 'ACK',
  4: 'ADVERT',
  5: 'GRP_TXT',
  6: 'GRP_DATA',
  7: 'ANON_REQ',
  8: 'PATH',
  9: 'TRACE',
  10: 'MULTIPART',
  11: 'CONTROL',
  15: 'RAW_CUSTOM',
};

/// Contract 1.5 route names by number.
const List<String> packetRouteWireNames = ['TRANSPORT_FLOOD', 'FLOOD', 'DIRECT', 'TRANSPORT_DIRECT'];

String packetTypeWireName(int t) => packetTypeWireNames[t] ?? 'UNKNOWN';
String packetRouteWireName(int r) => r >= 0 && r < 4 ? packetRouteWireNames[r] : 'UNKNOWN';

/// The number of a type name (`ADVERT` -> 4); null when unknown.
int? packetTypeNumber(String name) {
  final n = name.toUpperCase();
  for (final e in packetTypeWireNames.entries) {
    if (e.value == n) return e.key;
  }
  return int.tryParse(name);
}

/// The number of a route name (`FLOOD` -> 1); null when unknown.
int? packetRouteNumber(String name) {
  final i = packetRouteWireNames.indexOf(name.toUpperCase());
  return i >= 0 ? i : int.tryParse(name);
}

/// Plain words for a type, for people.
String packetTypeLabel(String typeName) => switch (typeName.toUpperCase()) {
      'REQ' => 'Request',
      'RESPONSE' => 'Response',
      'TXT_MSG' => 'Direct message',
      'ACK' => 'Ack',
      'ADVERT' => 'Advert',
      'GRP_TXT' => 'Channel message',
      'GRP_DATA' => 'Channel data',
      'ANON_REQ' => 'Anonymous request',
      'PATH' => 'Path',
      'TRACE' => 'Trace',
      'MULTIPART' => 'Multipart',
      'CONTROL' => 'Control',
      'RAW_CUSTOM' => 'Custom',
      _ => 'Other type',
    };

/// Plain words for a route.
String packetRouteLabel(String route) => switch (route.toUpperCase()) {
      'TRANSPORT_FLOOD' => 'Scoped flood',
      'FLOOD' => 'Flood',
      'DIRECT' => 'Direct',
      'TRANSPORT_DIRECT' => 'Scoped direct',
      _ => 'Other route',
    };

String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;
int? _i(Object? v) => v is num ? v.toInt() : null;
double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
List<String> _strs(Object? v) => [if (v is List) for (final e in v) if (e is String) e];

/// `NodeRef` (contract 2).
class PacketNode {
  final String key;
  final String? name;
  final String role;
  const PacketNode({required this.key, this.name, this.role = 'unknown'});
  static PacketNode? tryParse(Object? j) {
    if (j is! Map || j['key'] is! String) return null;
    return PacketNode(key: (j['key'] as String).toLowerCase(), name: _s(j['name']), role: _s(j['role']) ?? 'unknown');
  }

  String get label => name ?? '${key.substring(0, key.length.clamp(0, 8))}…';
}

/// `ObserverRef` (contract 2).
class PacketObserver {
  final String id, name, kind, src;
  const PacketObserver({required this.id, required this.name, this.kind = 'fixed', this.src = 'meshsonar'});
  static PacketObserver? tryParse(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    final id = j['id'] as String;
    return PacketObserver(id: id, name: _s(j['name']) ?? id, kind: _s(j['kind']) ?? 'fixed', src: _s(j['src']) ?? 'meshsonar');
  }
}

/// `ChannelRef` (contract 2).
class PacketChannel {
  final String id;
  final String? name;
  final String kind;
  const PacketChannel({required this.id, this.name, this.kind = 'unknown'});
  static PacketChannel? tryParse(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    return PacketChannel(id: j['id'] as String, name: _s(j['name']), kind: _s(j['kind']) ?? 'unknown');
  }

  String get label => name ?? (id.startsWith('enc:') ? 'Unknown channel (hash ${id.substring(4)})' : id);
}

/// A transport scope (contract 2.2).
class PacketScope {
  final String code;
  final String? name;

  /// `unique`, `explicit`, `ambiguous`, `none`.
  final String match;
  const PacketScope({required this.code, this.name, this.match = 'none'});
  static PacketScope? tryParse(Object? j) {
    if (j is! Map || j['code'] is! String) return null;
    return PacketScope(code: j['code'] as String, name: _s(j['name']), match: _s(j['match']) ?? 'none');
  }

  String get label => name ?? (match == 'none' ? 'Unmatched scope ($code)' : 'Scope $code');
}

/// One row of `GET /v1/packets` (contract 2.2): one packet, grouped by hash.
class PacketListRow {
  final String hash;
  final DateTime firstSeen, lastSeen;
  final int type;
  final String typeName, route;

  /// 1, 2, 3, or 0 (zero-hop direct); null when the source does not say (today's region read).
  final int? hashSize;
  final int hops;

  /// Bytes on air; null when unknown.
  final int? size;
  final int? observationCount;
  final int observerCount;
  final double? bestSnr, bestRssi;

  /// One plain line from the server; null from today's region read (the screen builds one).
  final String? summary;
  final PacketNode? origin;
  final PacketChannel? channel;
  final PacketScope? scope;

  /// Contract decode status; null when unknown.
  final String? decodeStatus;
  final List<String> src;
  const PacketListRow({
    required this.hash,
    required this.firstSeen,
    required this.lastSeen,
    required this.type,
    required this.typeName,
    required this.route,
    this.hashSize,
    this.hops = 0,
    this.size,
    this.observationCount,
    this.observerCount = 0,
    this.bestSnr,
    this.bestRssi,
    this.summary,
    this.origin,
    this.channel,
    this.scope,
    this.decodeStatus,
    this.src = const [],
  });

  static PacketListRow? tryParse(Object? j) {
    if (j is! Map || j['hash'] is! String) return null;
    final first = v1Time(j['firstSeen']);
    if (first == null) return null;
    final type = _i(j['type']) ?? -1;
    return PacketListRow(
      hash: (j['hash'] as String).toLowerCase(),
      firstSeen: first,
      lastSeen: v1Time(j['lastSeen']) ?? first,
      type: type,
      typeName: _s(j['typeName']) ?? packetTypeWireName(type),
      route: _s(j['route']) ?? 'UNKNOWN',
      hashSize: _i(j['hashSize']),
      hops: _i(j['hops']) ?? 0,
      size: _i(j['size']),
      observationCount: _i(j['observationCount']),
      observerCount: _i(j['observerCount']) ?? 0,
      bestSnr: _d(j['bestSnr']),
      bestRssi: _d(j['bestRssi']),
      summary: _s(j['summary']),
      origin: PacketNode.tryParse(j['origin']),
      channel: PacketChannel.tryParse(j['channel']),
      scope: PacketScope.tryParse(j['scope']),
      decodeStatus: _s(j['decodeStatus']),
      src: _strs(j['src']),
    );
  }

  /// "Advert: Library Room (room)", or a line built from the fields when the server sent none.
  String get title {
    if (summary != null) return summary!;
    final t = packetTypeLabel(typeName);
    if (origin?.name != null) return '$t: ${origin!.name}';
    if (channel != null) return '$t on ${channel!.label}';
    return t;
  }
}

/// One observation of a packet (contract 8.2 `Observation`).
class PacketObservation {
  final String id;
  final PacketObserver observer;
  final DateTime? at;
  final double? snr, rssi;
  final String? pathId;
  final List<String> path;
  final String src;
  const PacketObservation({required this.id, required this.observer, this.at, this.snr, this.rssi, this.pathId, this.path = const [], this.src = 'meshsonar'});

  static PacketObservation? tryParse(Object? j) {
    if (j is! Map) return null;
    final o = PacketObserver.tryParse(j['observer']);
    if (o == null) return null;
    return PacketObservation(
      id: _s(j['id']) ?? '${o.id}@${j['at']}',
      observer: o,
      at: v1Time(j['at']),
      snr: _d(j['snr']),
      rssi: _d(j['rssi']),
      pathId: _s(j['pathId']),
      path: [for (final p in _strs(j['path'])) p.toLowerCase()],
      src: _s(j['src']) ?? o.src,
    );
  }
}

/// Hop confidence (contract 2.3); [other] for a value this build does not know.
enum HopConfidence { unique, likely, ambiguous, unknown, other }

HopConfidence hopConfidenceOf(String? s) => switch (s) {
      'unique' => HopConfidence.unique,
      'likely' => HopConfidence.likely,
      'ambiguous' => HopConfidence.ambiguous,
      'unknown' => HopConfidence.unknown,
      _ => HopConfidence.other,
    };

/// A position (contract 2 `Position`).
class PacketPosition {
  final double lat, lon;
  final String precision;
  const PacketPosition(this.lat, this.lon, {this.precision = 'exact'});
  static PacketPosition? tryParse(Object? j) {
    if (j is! Map) return null;
    final la = _d(j['lat']), lo = _d(j['lon']);
    if (la == null || lo == null) return null;
    return PacketPosition(la, lo, precision: _s(j['precision']) ?? 'exact');
  }
}

class HopCandidate {
  final PacketNode node;
  final PacketPosition? position;
  final double? score, distanceKm;
  const HopCandidate({required this.node, this.position, this.score, this.distanceKm});
  static HopCandidate? tryParse(Object? j) {
    if (j is! Map) return null;
    final n = PacketNode.tryParse(j['node']);
    if (n == null) return null;
    return HopCandidate(node: n, position: PacketPosition.tryParse(j['position']), score: _d(j['score']), distanceKm: _d(j['distanceKm']));
  }
}

/// One resolved hop (contract 2.3 `Hop`).
class PacketHop {
  final int index;
  final String prefix;
  final HopConfidence confidence;
  final PacketNode? node;
  final double? score;
  final List<HopCandidate> candidates;
  final int candidatesTotal;
  final List<String> evidence;

  /// The SNR measured at this hop (TRACE only), dB.
  final double? snrDb;
  const PacketHop({
    required this.index,
    required this.prefix,
    required this.confidence,
    this.node,
    this.score,
    this.candidates = const [],
    this.candidatesTotal = 0,
    this.evidence = const [],
    this.snrDb,
  });

  static PacketHop? tryParse(Object? j) {
    if (j is! Map || j['prefix'] is! String) return null;
    return PacketHop(
      index: _i(j['index']) ?? 0,
      prefix: (j['prefix'] as String).toLowerCase(),
      confidence: hopConfidenceOf(_s(j['confidence'])),
      node: PacketNode.tryParse(j['node']),
      score: _d(j['score']),
      candidates: [if (j['candidates'] is List) for (final c in j['candidates'] as List) ?HopCandidate.tryParse(c)],
      candidatesTotal: _i(j['candidatesTotal']) ?? 0,
      evidence: _strs(j['evidence']),
      snrDb: _d(j['snrDb']),
    );
  }

  /// The position of the resolved node (unique or likely), when the server gave one among the candidates.
  PacketPosition? get position {
    if (node == null) return null;
    for (final c in candidates) {
      if (c.node.key == node!.key) return c.position;
    }
    return null;
  }
}

/// One distinct path (contract 2.3 `Path`).
class PacketPath {
  final String id;
  final List<PacketHop> hops;
  final List<String> observationIds;

  /// `travelled` (flood: hops crossed) or `remaining` (DIRECT: the route still ahead).
  final String direction;
  const PacketPath({required this.id, this.hops = const [], this.observationIds = const [], this.direction = 'travelled'});

  static PacketPath? tryParse(Object? j) {
    if (j is! Map) return null;
    return PacketPath(
      id: _s(j['id']) ?? '',
      hops: [if (j['hops'] is List) for (final h in j['hops'] as List) ?PacketHop.tryParse(h)],
      observationIds: _strs(j['observationIds']),
      direction: _s(j['direction']) ?? 'travelled',
    );
  }
}

/// The colour groups of the byte inspector (contract 8.2 `ByteRange.group`); [other] for a value this build does not know.
enum ByteGroup { header, transport, pathLen, path, payload, mac, ciphertext, signature, other }

ByteGroup byteGroupOf(String? s) => switch (s) {
      'header' => ByteGroup.header,
      'transport' => ByteGroup.transport,
      'path_len' => ByteGroup.pathLen,
      'path' => ByteGroup.path,
      'payload' => ByteGroup.payload,
      'mac' => ByteGroup.mac,
      'ciphertext' => ByteGroup.ciphertext,
      'signature' => ByteGroup.signature,
      _ => ByteGroup.other,
    };

String byteGroupWire(ByteGroup g) => switch (g) {
      ByteGroup.pathLen => 'path_len',
      ByteGroup.other => 'other',
      _ => g.name,
    };

/// One byte range of the inspector (contract 8.2 `ByteRange`): `[start, end)` into the raw packet.
class ByteRange {
  final int start, end;
  final ByteGroup group;

  /// Stable id, e.g. `advert.lat`, `grp.mac`, `path[2]`.
  final String field;
  final String label, hex;

  /// The decoded value, or a status word for ciphertext (`decrypted`, `no_key`, `encrypted`).
  final Object? value;
  const ByteRange({required this.start, required this.end, required this.group, required this.field, required this.label, required this.hex, this.value});

  int get length => end - start;
  bool contains(int i) => i >= start && i < end;

  static ByteRange? tryParse(Object? j) {
    if (j is! Map) return null;
    final s = _i(j['start']), e = _i(j['end']);
    if (s == null || e == null || e <= s) return null;
    return ByteRange(
      start: s,
      end: e,
      group: byteGroupOf(_s(j['group'])),
      field: _s(j['field']) ?? 'field$s',
      label: _s(j['label']) ?? 'Bytes $s-$e',
      hex: (_s(j['hex']) ?? '').toLowerCase(),
      value: j['value'],
    );
  }

  Map<String, Object?> toJson() => {'start': start, 'end': end, 'group': byteGroupWire(group), 'field': field, 'label': label, 'hex': hex, 'value': value};
}

/// A decoded Public or hashtag channel message (contract 8.5 `Message`). [sender] is a claim: anyone with the key can
/// write any name (the screen says "says it is").
class PacketMessage {
  final PacketChannel channel;
  final String? sender, text;
  final bool hidden;
  final DateTime? senderTime;
  const PacketMessage({required this.channel, this.sender, this.text, this.hidden = false, this.senderTime});
  static PacketMessage? tryParse(Object? j) {
    if (j is! Map) return null;
    final c = PacketChannel.tryParse(j['channel']);
    if (c == null) return null;
    return PacketMessage(channel: c, sender: _s(j['sender']), text: _s(j['text']), hidden: j['hidden'] == true, senderTime: v1Time(j['senderTime']));
  }
}

/// Where a packet detail came from.
enum PacketSource {
  /// `GET /v1/packets/{hash}`: every field.
  v1,

  /// Today's `region-packet` read while `/v1` is not live: who heard it, paths, no bytes.
  legacy,

  /// The phone's own radio, decoded on the phone (local_decoder.dart).
  myRadio,

  /// Pasted hex, decoded on the phone.
  pasted,

  /// Pasted hex the phone could not decode, decoded by `POST /v1/decode`.
  serverDecode,
}

/// `GET /v1/packets/{hash}` `data` (contract 8.2), or the same shape from another [source].
class PacketDetail {
  final PacketSource source;
  final String hash;
  final int type;
  final String typeName, route;
  final int? payloadVersion, hashSize, size;
  final DateTime? firstSeen, lastSeen;

  /// The whole packet as lowercase hex; null when the source has no bytes (today's region read).
  final String? raw;
  final String? rawSource;
  final bool rawVerified;

  /// Covers [raw] exactly, in order, no gaps (contract 13.13). Empty when there is no [raw].
  final List<ByteRange> bytes;

  /// Contract `decoded`: exactly one key by type (`advert`, `group`, `direct`, `anonReq`, `ack`, `multipart`, `trace`,
  /// `control`, `raw`). Empty when unknown.
  final Map<String, dynamic> decoded;
  final PacketNode? origin;
  final PacketChannel? channel;
  final PacketScope? scope;
  final PacketMessage? message;
  final String? anomaly;
  final int observationCount, observerCount;
  final List<PacketObservation> observations;
  final String? observationsNext;
  final bool observationsExpired;
  final List<PacketPath> paths;
  final List<String> src;
  final Uri? webLink;

  /// Plain sentences naming what this source cannot show ("This server does not send packet bytes yet").
  final List<String> missing;

  /// Set when the answer is the stored copy because the network failed.
  final DateTime? offlineAsOf;

  /// The radio's own SNR / RSSI ([PacketSource.myRadio]).
  final double? localSnr, localRssi;
  const PacketDetail({
    required this.source,
    required this.hash,
    required this.type,
    required this.typeName,
    required this.route,
    this.payloadVersion,
    this.hashSize,
    this.size,
    this.firstSeen,
    this.lastSeen,
    this.raw,
    this.rawSource,
    this.rawVerified = false,
    this.bytes = const [],
    this.decoded = const {},
    this.origin,
    this.channel,
    this.scope,
    this.message,
    this.anomaly,
    this.observationCount = 0,
    this.observerCount = 0,
    this.observations = const [],
    this.observationsNext,
    this.observationsExpired = false,
    this.paths = const [],
    this.src = const [],
    this.webLink,
    this.missing = const [],
    this.offlineAsOf,
    this.localSnr,
    this.localRssi,
  });

  /// The decoded kind (`advert`, `group`, ...), or null.
  String? get decodedKind => decoded.isEmpty ? null : decoded.keys.first;
  Map<String, dynamic> get decodedFields {
    final v = decoded.isEmpty ? null : decoded.values.first;
    return v is Map<String, dynamic> ? v : const {};
  }

  /// The longest path's hop count, the figure the list shows.
  int get hops => paths.fold<int>(0, (m, p) => p.hops.length > m ? p.hops.length : m);

  bool get hasBytes => raw != null && raw!.isNotEmpty && bytes.isNotEmpty;

  static PacketDetail fromV1(Object? data, {PacketSource source = PacketSource.v1, DateTime? offlineAsOf}) {
    if (data is! Map || data['hash'] is! String) throw const FormatException('packet detail has no hash');
    final type = _i(data['type']) ?? -1;
    final links = data['links'] is Map ? data['links'] as Map : const {};
    final decoded = data['decoded'];
    return PacketDetail(
      source: source,
      hash: (data['hash'] as String).toLowerCase(),
      type: type,
      typeName: _s(data['typeName']) ?? packetTypeWireName(type),
      route: _s(data['route']) ?? 'UNKNOWN',
      payloadVersion: _i(data['payloadVersion']),
      hashSize: _i(data['hashSize']),
      size: _i(data['size']),
      firstSeen: v1Time(data['firstSeen']),
      lastSeen: v1Time(data['lastSeen']),
      raw: _s(data['raw'])?.toLowerCase(),
      rawSource: _s(data['rawSource']),
      rawVerified: data['rawVerified'] == true,
      bytes: [if (data['bytes'] is List) for (final b in data['bytes'] as List) ?ByteRange.tryParse(b)],
      decoded: decoded is Map<String, dynamic> ? decoded : const {},
      origin: PacketNode.tryParse(data['origin']),
      channel: PacketChannel.tryParse(data['channel']),
      scope: PacketScope.tryParse(data['scope']),
      message: PacketMessage.tryParse(data['message']),
      anomaly: _s(data['anomaly']),
      observationCount: _i(data['observationCount']) ?? 0,
      observerCount: _i(data['observerCount']) ?? 0,
      observations: [if (data['observations'] is List) for (final o in data['observations'] as List) ?PacketObservation.tryParse(o)],
      observationsNext: _s(data['observationsNext']),
      observationsExpired: data['observationsExpired'] == true,
      paths: [if (data['paths'] is List) for (final p in data['paths'] as List) ?PacketPath.tryParse(p)],
      src: _strs(data['src']),
      webLink: _s(links['web']) == null ? null : Uri.tryParse(links['web'] as String),
      offlineAsOf: offlineAsOf,
    );
  }

  PacketDetail copyWith({List<PacketObservation>? observations, String? observationsNext, bool clearNext = false, List<String>? missing}) => PacketDetail(
        source: source,
        hash: hash,
        type: type,
        typeName: typeName,
        route: route,
        payloadVersion: payloadVersion,
        hashSize: hashSize,
        size: size,
        firstSeen: firstSeen,
        lastSeen: lastSeen,
        raw: raw,
        rawSource: rawSource,
        rawVerified: rawVerified,
        bytes: bytes,
        decoded: decoded,
        origin: origin,
        channel: channel,
        scope: scope,
        message: message,
        anomaly: anomaly,
        observationCount: observationCount,
        observerCount: observerCount,
        observations: observations ?? this.observations,
        observationsNext: clearNext ? null : (observationsNext ?? this.observationsNext),
        observationsExpired: observationsExpired,
        paths: paths,
        src: src,
        webLink: webLink,
        missing: missing ?? this.missing,
        offlineAsOf: offlineAsOf,
        localSnr: localSnr,
        localRssi: localRssi,
      );
}
