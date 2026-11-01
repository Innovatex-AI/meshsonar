// Rx log: a bounded, live list of every packet the radio hears (PUSH_CODE_LOG_RX_DATA 0x88), decoded to its header only.
//
// Privacy, in this file and in the UI: the log keeps header fields (route, payload type, hops, path hashes, SNR, RSSI,
// length) and, for ADVERTs, the sender's public name/type/position (an advert is a public broadcast). It NEVER keeps or
// shows other people's message text. For group traffic it can label "known channel: <name>", but ONLY for a channel the
// user has joined (the caller passes those secrets) and only by checking the 2-byte MAC: no packet is decrypted, nothing
// is stored. Memory is bounded: a ring of [capacity] entries (default 500). Export writes the same header fields.
// Pure Dart.
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../crypto.dart';
import '../packet.dart';
import '../radio_api.dart' show RxPacket;
import 'advert_decode.dart';
import 'tool_state.dart';

class KnownChannel {
  final String name;
  final Uint8List secret16;
  const KnownChannel(this.name, this.secret16);
  int get hashByte => channelHash(secret16);
}

/// True when [payload] (hash byte, MAC x2, ciphertext) is a group packet of the channel with [secret16]: the hash byte
/// matches AND the MAC verifies. Nothing is decrypted.
bool groupPayloadBelongsTo(List<int> secret16, List<int> payload) {
  if (payload.length < 3 + 16 || payload[0] != channelHash(secret16)) return false;
  final ct = payload.sublist(3);
  if (ct.length % 16 != 0) return false;
  final key = Uint8List(32)..setRange(0, secret16.length.clamp(0, 32), secret16);
  final mac = hmacSha256(key, ct);
  return mac[0] == payload[1] && mac[1] == payload[2];
}

String payloadTypeName(int t) => switch (t) {
      PayloadType.req => 'Request',
      PayloadType.response => 'Response',
      PayloadType.txtMsg => 'Direct message',
      PayloadType.ack => 'Ack',
      PayloadType.advert => 'Advert',
      PayloadType.grpTxt => 'Channel message',
      PayloadType.grpData => 'Channel data',
      PayloadType.anonReq => 'Anonymous request',
      PayloadType.path => 'Path',
      PayloadType.trace => 'Trace',
      PayloadType.multipart => 'Multipart',
      PayloadType.control => 'Control',
      PayloadType.rawCustom => 'Custom',
      _ => 'Type $t',
    };

String routeName(int r) => switch (r) {
      RouteType.transportFlood => 'Scoped flood',
      RouteType.flood => 'Flood',
      RouteType.direct => 'Direct',
      RouteType.transportDirect => 'Scoped direct',
      _ => 'Route $r',
    };

class RxLogEntry {
  final int seq;
  final DateTime at;
  final double? snrDb;
  final double? rssiDbm;
  final int length;

  /// Null when the bytes are not a packet the firmware would accept.
  final MeshPacket? packet;

  /// Name of a joined channel this group packet belongs to (MAC verified); null otherwise.
  final String? knownChannel;

  /// ADVERT contents (public broadcast); null for other types.
  final AdvertInfo? advert;
  const RxLogEntry({
    required this.seq,
    required this.at,
    required this.snrDb,
    required this.rssiDbm,
    required this.length,
    required this.packet,
    this.knownChannel,
    this.advert,
  });

  int? get payloadType => packet?.payloadType;
  int? get routeType => packet?.routeType;
  int get hops => packet?.hopCount ?? 0;
  List<String> get pathHex => packet?.pathHex ?? const [];
  bool get isGroup => payloadType == PayloadType.grpTxt || payloadType == PayloadType.grpData;

  /// The channel hash byte of a group packet (hex), for "some other channel" rows.
  String? get channelHashHex => isGroup && packet!.payload.isNotEmpty ? packet!.payload[0].toRadixString(16).padLeft(2, '0') : null;

  /// One plain line: "Advert from INNO-OB-2 (repeater)", "Channel message, known channel: Public", "Ack".
  String get summary {
    final p = packet;
    if (p == null) return 'Not a valid packet ($length bytes)';
    final t = payloadTypeName(p.payloadType);
    if (advert != null) return '$t from ${advert!.name.isEmpty ? advert!.publicKeyHex.substring(0, 8) : advert!.name} (${advertTypeName(advert!.nodeType)})';
    if (isGroup) {
      return knownChannel != null ? '$t, known channel: $knownChannel' : '$t on another channel';
    }
    return t;
  }
}

String advertTypeName(int t) => switch (t) { 1 => 'chat', 2 => 'repeater', 3 => 'room', 4 => 'sensor', _ => 'type $t' };

class RxLogFilter {
  /// Payload types to show; empty = all.
  final Set<int> types;

  /// Route types to show; empty = all.
  final Set<int> routes;

  /// Only packets of a joined channel.
  final bool knownChannelsOnly;

  /// At least this many hops.
  final int minHops;
  const RxLogFilter({this.types = const {}, this.routes = const {}, this.knownChannelsOnly = false, this.minHops = 0});

  bool get isEmpty => types.isEmpty && routes.isEmpty && !knownChannelsOnly && minHops == 0;

  bool accepts(RxLogEntry e) {
    if (types.isNotEmpty && (e.payloadType == null || !types.contains(e.payloadType))) return false;
    if (routes.isNotEmpty && (e.routeType == null || !routes.contains(e.routeType))) return false;
    if (knownChannelsOnly && e.knownChannel == null) return false;
    if (e.hops < minHops) return false;
    return true;
  }

  RxLogFilter copyWith({Set<int>? types, Set<int>? routes, bool? knownChannelsOnly, int? minHops}) => RxLogFilter(
        types: types ?? this.types,
        routes: routes ?? this.routes,
        knownChannelsOnly: knownChannelsOnly ?? this.knownChannelsOnly,
        minHops: minHops ?? this.minHops,
      );
}

class RxLog with ToolChanges {
  final int capacity;
  final DateTime Function() _clock;
  final Queue<RxLogEntry> _ring = Queue();
  final Map<int, int> _byType = {};
  final Map<int, int> _byRoute = {};
  List<KnownChannel> _channels = const [];
  StreamSubscription<RxPacket>? _sub;
  int _seq = 0;
  int _total = 0;
  int _invalid = 0;
  int _missedWhilePaused = 0;
  bool _paused = false;

  RxLog({this.capacity = 500, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// Channels the user has joined (names and secrets); used only to label group packets.
  set knownChannels(List<KnownChannel> v) => _channels = List.unmodifiable(v);
  List<KnownChannel> get knownChannels => _channels;

  bool get listening => _sub != null;
  bool get paused => _paused;

  /// Packets that arrived while paused (counted, not listed).
  int get missedWhilePaused => _missedWhilePaused;

  /// Packets heard since the log started or was last cleared (not just the ones still in the ring).
  int get total => _total;
  int get invalid => _invalid;
  Map<int, int> get countsByType => Map.unmodifiable(_byType);
  Map<int, int> get countsByRoute => Map.unmodifiable(_byRoute);

  /// Newest first.
  List<RxLogEntry> entries([RxLogFilter filter = const RxLogFilter()]) =>
      [for (final e in _ring.toList().reversed) if (filter.accepts(e)) e];
  int get length => _ring.length;

  void listen(Stream<RxPacket> source) {
    _sub?.cancel();
    _sub = source.listen(_onPacket, onError: (Object _) {});
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  void _onPacket(RxPacket rx) => add(rx.raw, snrDb: rx.snrDb, rssiDbm: rx.rssiDbm, at: rx.at);

  /// Adds one heard packet (also the entry point for tests).
  RxLogEntry? add(Uint8List raw, {double? snrDb, double? rssiDbm, DateTime? at}) {
    _total++;
    final p = MeshPacket.tryParse(raw);
    if (p == null) {
      _invalid++;
    } else {
      _byType[p.payloadType] = (_byType[p.payloadType] ?? 0) + 1;
      _byRoute[p.routeType] = (_byRoute[p.routeType] ?? 0) + 1;
    }
    if (_paused) {
      _missedWhilePaused++;
      notifyChanged();
      return null;
    }
    String? known;
    AdvertInfo? advert;
    if (p != null) {
      if (p.payloadType == PayloadType.grpTxt || p.payloadType == PayloadType.grpData) {
        for (final c in _channels) {
          if (groupPayloadBelongsTo(c.secret16, p.payload)) {
            known = c.name;
            break;
          }
        }
      } else if (p.payloadType == PayloadType.advert) {
        advert = AdvertInfo.tryParse(p);
      }
    }
    final e = RxLogEntry(
        seq: ++_seq,
        at: at ?? _clock(),
        snrDb: snrDb,
        rssiDbm: rssiDbm,
        length: raw.length,
        packet: p,
        knownChannel: known,
        advert: advert);
    _ring.addLast(e);
    while (_ring.length > capacity) {
      _ring.removeFirst();
    }
    notifyChanged();
    return e;
  }

  void pause() {
    _paused = true;
    notifyChanged();
  }

  void resume() {
    _paused = false;
    notifyChanged();
  }

  /// Empties the list and the counters.
  void clear() {
    _ring.clear();
    _byType.clear();
    _byRoute.clear();
    _total = 0;
    _invalid = 0;
    _missedWhilePaused = 0;
    notifyChanged();
  }

  /// CSV of the listed packets (oldest first): header fields only, never payload bytes or message text. Adverts add the
  /// node's public name and type; positions are left out.
  String exportCsv([RxLogFilter filter = const RxLogFilter()]) {
    final sb = StringBuffer('time_utc,route,payload_type,hash_bytes,hops,path,snr_db,rssi_dbm,length,known_channel,advert_name,advert_type\n');
    for (final e in entries(filter).reversed) {
      final p = e.packet;
      sb.writeln([
        e.at.toUtc().toIso8601String(),
        p == null ? '' : routeName(p.routeType),
        p == null ? 'invalid' : payloadTypeName(p.payloadType),
        p?.pathHashSize ?? '',
        p?.hopCount ?? '',
        e.pathHex.join('>'),
        e.snrDb?.toStringAsFixed(2) ?? '',
        e.rssiDbm?.toStringAsFixed(0) ?? '',
        e.length,
        _csv(e.knownChannel ?? ''),
        _csv(e.advert?.name ?? ''),
        e.advert == null ? '' : advertTypeName(e.advert!.nodeType),
      ].join(','));
    }
    return sb.toString();
  }

  static String _csv(String s) => s.contains(RegExp(r'[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;

  Future<void> dispose() async {
    await stop();
    disposeChanges();
  }
}
