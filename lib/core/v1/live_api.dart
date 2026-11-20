// The live map's data (AZ-3.3): the `/v1/stream` Server-Sent Events client, `/v1/replay` and `/v1/packets/density`
// (analyzer-api-contract.md section 9 and 8.2), each with a quiet fallback to today's endpoints while `/v1` is not live:
//   stream  -> /api/cmh/region-live (lib/core/live_stream.dart): resolved hops with positions only (the old server
//              leaves out the hops it cannot place, so that mode has no ghost hops), no resume, no missed/reset.
//   replay  -> /api/cmh/region-replay?from&to&limit (30-day horizon, one page at most 1 hour, `nextFrom` to continue).
//   density -> counted on the phone from the replay pages it has (the old server has no density read).
//
// Stream rules from the contract (9.2 to 9.6): one `packet` per hash then `packet.update`s (merged here by observation
// id, so a packet seen twice after a resume is one packet); resume with the `Last-Event-ID` header (and `lastEventId`
// in the query, for the case the header is lost); `missed` and `reset` come with a `refetch` path the caller reads
// through [LiveReplayApi.refetch]; reconnect with back-off 3 s doubling to 60 s with jitter; 45 s without any byte is a
// dead connection. [NetworkLiveStream.pause] drops the socket (background, off screen, Saver), [resume] reconnects with
// the last id.
//
// Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../etag_client.dart';
import '../live_stream.dart' as legacy;
import '../region_dataset_fetch.dart' show regionDatasetUri;
import 'network_api.dart' show NetworkReadSource;
import 'packet_models.dart';
import 'v1_client.dart';

export 'v1_client.dart';

// ---------------------------------------------------------------- models

/// One observation of a live packet (contract 9.4).
class LiveObs {
  final String id;
  final PacketObserver observer;
  final DateTime? at;
  final double? snr, rssi;
  final String? pathId;
  final String src;
  const LiveObs({required this.id, required this.observer, this.at, this.snr, this.rssi, this.pathId, this.src = 'meshsonar'});

  static LiveObs? tryParse(Object? j) {
    if (j is! Map) return null;
    final o = PacketObserver.tryParse(j['observer']);
    if (o == null) return null;
    double? d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    return LiveObs(
      id: j['id'] is String ? j['id'] as String : '${o.id}@${j['at']}',
      observer: o,
      at: v1Time(j['at']),
      snr: d(j['snr']),
      rssi: d(j['rssi']),
      pathId: j['pathId'] is String ? j['pathId'] as String : null,
      src: j['src'] is String ? j['src'] as String : o.src,
    );
  }
}

/// A decoded Public or hashtag message riding with its packet (contract 8.5, only what the map shows).
class LiveMessage {
  final String id;
  final String? sender, text;
  final bool hidden;
  const LiveMessage({required this.id, this.sender, this.text, this.hidden = false});

  static LiveMessage? tryParse(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    final hidden = j['hidden'] == true;
    return LiveMessage(
      id: j['id'] as String,
      sender: j['sender'] is String ? j['sender'] as String : null,
      text: hidden || j['text'] is! String ? null : j['text'] as String,
      hidden: hidden,
    );
  }

  LiveMessage hide() => LiveMessage(id: id, sender: sender, hidden: true);
}

/// One packet of the live map (contract 9.4 `LivePacket`), from the stream, a replay page, or today's region feed.
class LiveV2Packet {
  final String hash;
  final int type;
  final String typeName, route;
  final int? hashSize;
  final DateTime firstSeen;
  final PacketNode? origin;
  final PacketChannel? channel;
  final LiveMessage? message;
  final List<LiveObs> observations;
  final List<PacketPath> paths;

  /// Distinct prefixes the server could not place (drawn as ghost hops).
  final List<String> unknownHops;
  final bool settled;
  final List<String> src;

  /// Where it came from: the `/v1` stream or replay, or today's region feed (positions of resolved hops only).
  final NetworkReadSource source;

  /// Positions the old feed sent with each resolved hop (key -> lat, lon); empty for `/v1` packets.
  final Map<String, (double, double)> legacyPositions;

  const LiveV2Packet({
    required this.hash,
    required this.type,
    required this.typeName,
    required this.route,
    this.hashSize,
    required this.firstSeen,
    this.origin,
    this.channel,
    this.message,
    this.observations = const [],
    this.paths = const [],
    this.unknownHops = const [],
    this.settled = false,
    this.src = const [],
    this.source = NetworkReadSource.v1,
    this.legacyPositions = const {},
  });

  static LiveV2Packet? tryParse(Object? j) {
    if (j is! Map || j['hash'] is! String) return null;
    final first = v1Time(j['firstSeen']);
    if (first == null) return null;
    final type = j['type'] is num ? (j['type'] as num).toInt() : -1;
    List<String> strs(Object? v) => [if (v is List) for (final e in v) if (e is String) e];
    return LiveV2Packet(
      hash: (j['hash'] as String).toLowerCase(),
      type: type,
      typeName: j['typeName'] is String ? j['typeName'] as String : packetTypeWireName(type),
      route: j['route'] is String ? j['route'] as String : 'UNKNOWN',
      hashSize: j['hashSize'] is num ? (j['hashSize'] as num).toInt() : null,
      firstSeen: first,
      origin: PacketNode.tryParse(j['origin']),
      channel: PacketChannel.tryParse(j['channel']),
      message: LiveMessage.tryParse(j['message']),
      observations: [if (j['observations'] is List) for (final o in j['observations'] as List) ?LiveObs.tryParse(o)],
      paths: [if (j['paths'] is List) for (final p in j['paths'] as List) ?PacketPath.tryParse(p)],
      unknownHops: [for (final s in strs(j['unknownHops'])) s.toLowerCase()],
      settled: j['settled'] == true,
      src: strs(j['src']),
    );
  }

  /// Today's `region-live` / `region-replay` packet in this shape: its resolved hops as one travelled path of unique
  /// hops (the old server only sends hops it could place), its observers at the end of that path.
  factory LiveV2Packet.fromLegacy(legacy.LivePacket p) {
    final hops = [
      for (var i = 0; i < p.hops.length; i++)
        PacketHop(
          index: i,
          prefix: p.hops[i].key.length >= 2 ? p.hops[i].key.substring(0, 2).toLowerCase() : p.hops[i].key.toLowerCase(),
          confidence: HopConfidence.unique,
          node: PacketNode(key: p.hops[i].key.toLowerCase(), role: 'repeater'),
          score: 1,
          evidence: const ['unique_prefix'],
        ),
    ];
    final obs = [
      for (final o in p.observations)
        LiveObs(
          id: '${o.observer}@${o.at?.toIso8601String() ?? ''}',
          observer: PacketObserver(id: o.observer.toLowerCase(), name: o.observerName ?? o.observer),
          at: o.at,
          snr: o.snrDb,
          pathId: 'p1',
        ),
    ];
    return LiveV2Packet(
      hash: p.hash.toLowerCase(),
      type: p.type,
      typeName: packetTypeWireName(p.type),
      route: packetRouteWireName(p.route),
      firstSeen: p.at.toUtc(),
      observations: obs,
      paths: hops.isEmpty && obs.isEmpty ? const [] : [PacketPath(id: 'p1', hops: hops, observationIds: [for (final o in obs) o.id])],
      settled: true,
      source: NetworkReadSource.legacy,
      legacyPositions: {for (final h in p.hops) h.key.toLowerCase(): (h.lat, h.lon)},
    );
  }

  /// A packet detail (`/v1/packets/{hash}` or today's region read) as a live packet, for "Show on map".
  factory LiveV2Packet.fromDetail(PacketDetail d, {DateTime? fallbackTime}) => LiveV2Packet(
        hash: d.hash,
        type: d.type,
        typeName: d.typeName,
        route: d.route,
        hashSize: d.hashSize,
        firstSeen: (d.firstSeen ?? fallbackTime ?? DateTime.now()).toUtc(),
        origin: d.origin,
        channel: d.channel,
        observations: [
          for (final o in d.observations) LiveObs(id: o.id, observer: o.observer, at: o.at, snr: o.snr, rssi: o.rssi, pathId: o.pathId, src: o.src)
        ],
        paths: d.paths,
        unknownHops: {
          for (final p in d.paths)
            for (final h in p.hops)
              if (h.confidence == HopConfidence.unknown) h.prefix
        }.toList(),
        settled: true,
        src: d.src,
        source: d.source == PacketSource.legacy ? NetworkReadSource.legacy : NetworkReadSource.v1,
      );

  /// This packet with [obs] and [newPaths] added (by observation id and path id; nothing is counted twice).
  LiveV2Packet merged({List<LiveObs> obs = const [], List<PacketPath> newPaths = const [], bool? settled, Map<String, (double, double)>? positions}) {
    final ids = {for (final o in observations) o.id};
    final pids = {for (final p in paths) p.id};
    return LiveV2Packet(
      hash: hash,
      type: type,
      typeName: typeName,
      route: route,
      hashSize: hashSize,
      firstSeen: firstSeen,
      origin: origin,
      channel: channel,
      message: message,
      observations: [...observations, for (final o in obs) if (!ids.contains(o.id)) o],
      paths: [...paths, for (final p in newPaths) if (!pids.contains(p.id)) p],
      unknownHops: unknownHops,
      settled: settled ?? this.settled,
      src: src,
      source: source,
      legacyPositions: {...legacyPositions, ...?positions},
    );
  }

  /// Merges a second sighting of the same hash (a resume can repeat one).
  LiveV2Packet mergedWith(LiveV2Packet other) =>
      merged(obs: other.observations, newPaths: other.paths, settled: settled || other.settled, positions: other.legacyPositions);

  LiveV2Packet withMessage(LiveMessage? m) => LiveV2Packet(
      hash: hash,
      type: type,
      typeName: typeName,
      route: route,
      hashSize: hashSize,
      firstSeen: firstSeen,
      origin: origin,
      channel: channel,
      message: m,
      observations: observations,
      paths: paths,
      unknownHops: unknownHops,
      settled: settled,
      src: src,
      source: source,
      legacyPositions: legacyPositions);

  /// Hops of the longest path.
  int get hops => paths.fold(0, (m, p) => math.max(m, p.hops.length));

  double? get bestSnr {
    double? b;
    for (final o in observations) {
      if (o.snr != null && (b == null || o.snr! > b)) b = o.snr;
    }
    return b;
  }
}

// ---------------------------------------------------------------- events

sealed class NetLiveEvent {
  const NetLiveEvent();
}

class NetHello extends NetLiveEvent {
  final bool resumed;
  final int resumeWindowS, heartbeatS;
  const NetHello({this.resumed = false, this.resumeWindowS = 600, this.heartbeatS = 15});
}

class NetStatus extends NetLiveEvent {
  final int? observersOnline;
  final bool? nodeListTrusted;
  final String? nodeListReason;
  const NetStatus({this.observersOnline, this.nodeListTrusted, this.nodeListReason});
}

class NetPacket extends NetLiveEvent {
  final LiveV2Packet packet;
  const NetPacket(this.packet);
}

class NetPacketUpdate extends NetLiveEvent {
  final String hash;
  final List<LiveObs> observations;
  final List<PacketPath> paths;
  final bool settled;
  const NetPacketUpdate({required this.hash, this.observations = const [], this.paths = const [], this.settled = false});
}

class NetMessage extends NetLiveEvent {
  final LiveMessage message;
  const NetMessage(this.message);
}

class NetMessageHidden extends NetLiveEvent {
  final String id;
  const NetMessageHidden(this.id);
}

class NetPulse extends NetLiveEvent {
  final String id, kind, severity, state, title;
  const NetPulse({required this.id, required this.kind, required this.severity, required this.state, required this.title});
}

class NetHeartbeat extends NetLiveEvent {
  final String? lastEventId;
  const NetHeartbeat([this.lastEventId]);
}

/// The server dropped [count] events for this client (9.6); [refetch] reads them back.
class NetMissed extends NetLiveEvent {
  final int count;
  final DateTime? from, to;
  final String? refetch;
  const NetMissed({required this.count, this.from, this.to, this.refetch});
}

/// Resume was not possible (9.5); [refetch] is the gap to read back.
class NetReset extends NetLiveEvent {
  final String reason;
  final String? refetch;
  const NetReset({required this.reason, this.refetch});
}

/// One SSE frame (9.2).
class SseFrame {
  final String? id;
  final String event;
  final String data;
  const SseFrame({this.id, required this.event, required this.data});
}

/// Parses SSE lines into frames: `id`, `event`, `data` (several data lines are joined), `retry`, comment lines.
class SseFrameParser {
  String? _id;
  String _event = '';
  final StringBuffer _data = StringBuffer();
  bool _hasData = false;

  /// The last `retry:` value the server sent.
  Duration? retry;

  SseFrame? line(String l) {
    if (l.isEmpty) {
      final f = _hasData ? SseFrame(id: _id, event: _event.isEmpty ? 'message' : _event, data: _data.toString()) : null;
      _id = null;
      _event = '';
      _data.clear();
      _hasData = false;
      return f;
    }
    if (l.startsWith(':')) return null;
    final i = l.indexOf(':');
    final field = i < 0 ? l : l.substring(0, i);
    var value = i < 0 ? '' : l.substring(i + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'id':
        _id = value;
      case 'event':
        _event = value;
      case 'data':
        if (_hasData) _data.write('\n');
        _data.write(value);
        _hasData = true;
      case 'retry':
        final ms = int.tryParse(value);
        if (ms != null && ms >= 0) retry = Duration(milliseconds: ms);
    }
    return null;
  }
}

/// A frame as an event; null for kinds this build does not know (kept quiet, contract 7).
NetLiveEvent? decodeLiveFrame(SseFrame f) {
  Object? j;
  try {
    j = jsonDecode(f.data);
  } catch (_) {
    return null;
  }
  if (j is! Map) return null;
  int? i(Object? v) => v is num ? v.toInt() : null;
  String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
  switch (f.event) {
    case 'hello':
      return NetHello(resumed: j['resumed'] == true, resumeWindowS: i(j['resumeWindowS']) ?? 600, heartbeatS: i(j['heartbeatS']) ?? 15);
    case 'status':
      final nl = j['nodeList'] is Map ? j['nodeList'] as Map : const {};
      return NetStatus(
          observersOnline: i(j['observersOnline']),
          nodeListTrusted: nl['trusted'] is bool ? nl['trusted'] as bool : null,
          nodeListReason: s(nl['reason']));
    case 'packet':
      final p = LiveV2Packet.tryParse(j);
      return p == null ? null : NetPacket(p);
    case 'packet.update':
      if (j['hash'] is! String) return null;
      return NetPacketUpdate(
        hash: (j['hash'] as String).toLowerCase(),
        observations: [if (j['observations'] is List) for (final o in j['observations'] as List) ?LiveObs.tryParse(o)],
        paths: [if (j['paths'] is List) for (final p in j['paths'] as List) ?PacketPath.tryParse(p)],
        settled: j['settled'] == true,
      );
    case 'message':
      final m = LiveMessage.tryParse(j);
      return m == null ? null : NetMessage(m);
    case 'message.hidden':
      return j['id'] is String ? NetMessageHidden(j['id'] as String) : null;
    case 'pulse':
      if (j['id'] is! String) return null;
      return NetPulse(id: j['id'] as String, kind: s(j['kind']) ?? 'other', severity: s(j['severity']) ?? 'info', state: s(j['state']) ?? 'open', title: s(j['title']) ?? '');
    case 'heartbeat':
      return NetHeartbeat(s(j['lastEventId']));
    case 'missed':
      return NetMissed(count: i(j['count']) ?? 0, from: v1Time(j['from']), to: v1Time(j['to']), refetch: s(j['refetch']));
    case 'reset':
      return NetReset(reason: s(j['reason']) ?? 'unknown', refetch: s(j['refetch']));
  }
  return null;
}

// ---------------------------------------------------------------- stream client

/// What the live map subscribes to (contract 9.1). The region is required (no network-wide firehose).
class LiveSubscription {
  final String region;
  final Set<int> types;
  final Set<String> nodes, observers;
  const LiveSubscription({required this.region, this.types = const {}, this.nodes = const {}, this.observers = const {}});

  Map<String, String> toQuery() => {
        'region': region,
        if (types.isNotEmpty) 'type': (types.toList()..sort()).join(','),
        if (nodes.isNotEmpty) 'node': (nodes.take(20).toList()..sort()).join(','),
        if (observers.isNotEmpty) 'observer': (observers.take(20).toList()..sort()).join(','),
      };

  @override
  bool operator ==(Object other) => other is LiveSubscription && other.toQuery().toString() == toQuery().toString();
  @override
  int get hashCode => toQuery().toString().hashCode;
}

enum NetLiveState { idle, connecting, live, reconnecting, paused }

typedef NetLiveConnect = Future<http.StreamedResponse> Function(http.Request request);

class NetworkLiveStream {
  final String baseUrl;
  LiveSubscription _sub;
  /// Test seams: how a connection is opened, and how the fallback region feed is made.
  final NetLiveConnect? connect;
  final legacy.LiveStream Function(Uri base)? legacyFactory;
  final Duration watchdog, backoffMin, backoffMax;
  final math.Random _rand;
  final DateTime Function() clock;

  final _events = StreamController<NetLiveEvent>.broadcast();
  final _states = StreamController<NetLiveState>.broadcast();
  NetLiveState _state = NetLiveState.idle;
  NetworkReadSource _mode = NetworkReadSource.v1;
  bool _wanted = false, _paused = false;
  int _gen = 0, _attempt = 0;
  String? _lastEventId;
  Timer? _dog, _retry;
  StreamSubscription<String>? _lines;
  http.Client? _client;
  legacy.LiveStream? _legacy;
  StreamSubscription<legacy.LiveEvent>? _legacyEv;
  StreamSubscription<legacy.LiveConnState>? _legacySt;

  NetworkLiveStream(
    this.baseUrl,
    LiveSubscription subscription, {
    this.connect,
    this.legacyFactory,
    this.watchdog = const Duration(seconds: 45),
    this.backoffMin = const Duration(seconds: 3),
    this.backoffMax = const Duration(seconds: 60),
    math.Random? random,
    DateTime Function()? clock,
  })  : _sub = subscription,
        _rand = random ?? math.Random(),
        clock = clock ?? DateTime.now;

  Stream<NetLiveEvent> get events => _events.stream;
  Stream<NetLiveState> get states => _states.stream;
  NetLiveState get state => _state;

  /// `v1` while the new stream answers, `legacy` once it fell back to today's region feed.
  NetworkReadSource get mode => _mode;
  String? get lastEventId => _lastEventId;
  LiveSubscription get subscription => _sub;

  Uri get endpoint {
    final b = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$b/v1/stream').replace(queryParameters: {..._sub.toQuery(), 'lastEventId': ?_lastEventId});
  }

  /// Back-off before attempt [attempt] (1-based): 3 s doubling to 60 s, plus up to 20 % jitter.
  Duration backoffFor(int attempt) {
    final base = backoffMin.inMilliseconds * (1 << (attempt - 1).clamp(0, 16));
    final ms = base.clamp(backoffMin.inMilliseconds, backoffMax.inMilliseconds);
    return Duration(milliseconds: ms + (ms * 0.2 * _rand.nextDouble()).round());
  }

  void _set(NetLiveState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  void _emit(NetLiveEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void start() {
    if (_wanted) return;
    _wanted = true;
    if (!_paused) _open();
  }

  /// A new subscription (filters changed): the server sends `reset` (`subscription_changed`) if the old id is reused,
  /// so the id is dropped and the caller reloads.
  void resubscribe(LiveSubscription s) {
    if (s == _sub) return;
    _sub = s;
    _lastEventId = null;
    if (_wanted && !_paused) {
      _attempt = 0;
      _open();
    }
  }

  void pause() {
    if (_paused) return;
    _paused = true;
    _teardown();
    if (_wanted) _set(NetLiveState.paused);
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    if (_wanted) {
      _attempt = 0;
      _open();
    }
  }

  Future<void> dispose() async {
    _wanted = false;
    _teardown();
    await _events.close();
    await _states.close();
  }

  void _teardown() {
    _gen++;
    _dog?.cancel();
    _retry?.cancel();
    _dog = null;
    _retry = null;
    _lines?.cancel();
    _lines = null;
    _client?.close();
    _client = null;
    _legacyEv?.cancel();
    _legacySt?.cancel();
    _legacyEv = null;
    _legacySt = null;
    final l = _legacy;
    _legacy = null;
    if (l != null) unawaited(l.dispose());
  }

  void _armDog(int gen) {
    _dog?.cancel();
    _dog = Timer(watchdog, () {
      if (gen == _gen) _fail(gen);
    });
  }

  Future<void> _open() async {
    _teardown();
    if (_mode == NetworkReadSource.legacy) {
      _openLegacy();
      return;
    }
    final gen = _gen;
    _set(_attempt == 0 ? NetLiveState.connecting : NetLiveState.reconnecting);
    final req = http.Request('GET', endpoint)
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Cache-Control'] = 'no-cache';
    if (_lastEventId != null) req.headers['Last-Event-ID'] = _lastEventId!;
    try {
      _armDog(gen);
      final http.StreamedResponse res;
      final seam = connect;
      if (seam != null) {
        res = await seam(req);
      } else {
        final c = http.Client();
        _client = c;
        res = await c.send(req);
      }
      if (gen != _gen) return;
      final ct = res.headers['content-type'] ?? '';
      if (res.statusCode == 404 || res.statusCode == 405 || res.statusCode == 501 || (res.statusCode == 200 && !ct.contains('text/event-stream'))) {
        // No `/v1` stream on this host yet: today's region feed instead, quietly. The body is not read.
        unawaited(res.stream.listen(null, onError: (_) {}).cancel());
        _mode = NetworkReadSource.legacy;
        _openLegacy();
        return;
      }
      if (res.statusCode != 200) {
        final ra = int.tryParse(res.headers['retry-after'] ?? '');
        unawaited(res.stream.listen(null, onError: (_) {}).cancel());
        _fail(gen, ra == null ? null : Duration(seconds: ra.clamp(1, 300)));
        return;
      }
      final parser = SseFrameParser();
      _lines = res.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (l) {
          if (gen != _gen) return;
          _armDog(gen); // any byte, comments included, proves the stream is alive
          final f = parser.line(l);
          if (f == null) return;
          if (f.id != null && f.id!.isNotEmpty) _lastEventId = f.id;
          final e = decodeLiveFrame(f);
          if (e == null) return;
          _attempt = 0;
          _set(NetLiveState.live);
          _emit(e);
        },
        onError: (_) => _fail(gen),
        onDone: () => _fail(gen),
        cancelOnError: true,
      );
    } catch (_) {
      if (gen == _gen) _fail(gen);
    }
  }

  void _openLegacy() {
    final make = legacyFactory ?? (Uri b) => legacy.LiveStream(b);
    final l = make(Uri.parse(baseUrl));
    _legacy = l;
    _legacySt = l.states.listen((s) => _set(switch (s) {
          legacy.LiveConnState.live => NetLiveState.live,
          legacy.LiveConnState.connecting => NetLiveState.connecting,
          legacy.LiveConnState.reconnecting => NetLiveState.reconnecting,
          legacy.LiveConnState.paused => NetLiveState.paused,
          legacy.LiveConnState.idle => NetLiveState.idle,
        }));
    _legacyEv = l.events.listen((e) {
      switch (e) {
        case legacy.LivePacketEvent(:final packet):
          _emit(NetPacket(LiveV2Packet.fromLegacy(packet)));
        case legacy.LiveStatusEvent(:final observersOnline):
          _emit(NetStatus(observersOnline: observersOnline));
        case legacy.LiveHeartbeatEvent():
          _emit(const NetHeartbeat());
      }
    });
    l.start();
  }

  void _fail(int gen, [Duration? minWait]) {
    if (gen != _gen || !_wanted || _paused) return;
    _teardown();
    _attempt++;
    _set(NetLiveState.reconnecting);
    var wait = backoffFor(_attempt);
    if (minWait != null && minWait > wait) wait = minWait;
    final g = _gen;
    _retry = Timer(wait, () {
      if (g == _gen && _wanted && !_paused) _open();
    });
  }
}

// ---------------------------------------------------------------- replay and density

/// One page of replay, oldest first.
class ReplayPage {
  final List<LiveV2Packet> packets;

  /// Where to continue: an opaque `/v1` cursor, or (old server) the `nextFrom` time; null at the end.
  final String? next;
  final DateTime? to;
  final NetworkReadSource source;
  final DateTime? offlineAsOf;
  const ReplayPage({required this.packets, this.next, this.to, this.source = NetworkReadSource.v1, this.offlineAsOf});
}

/// Packet counts per bucket for the scrubber.
class DensityRead {
  final Duration bucket;
  final List<(DateTime, int)> counts;

  /// True when the phone counted it from replay pages (old server).
  final bool estimated;
  const DensityRead({required this.bucket, required this.counts, this.estimated = false});

  int get max => counts.fold(0, (m, c) => math.max(m, c.$2));

  /// Counts the packets [ps] into buckets of [bucket] between [from] and [to].
  factory DensityRead.count(Iterable<DateTime> ps, DateTime from, DateTime to, Duration bucket) {
    final n = math.max(1, (to.difference(from).inMilliseconds / bucket.inMilliseconds).ceil());
    final c = List<int>.filled(n, 0);
    for (final t in ps) {
      final i = t.difference(from).inMilliseconds ~/ bucket.inMilliseconds;
      if (i >= 0 && i < n) c[i]++;
    }
    return DensityRead(bucket: bucket, counts: [for (var i = 0; i < n; i++) (from.add(bucket * i), c[i])], estimated: true);
  }
}

/// The scrubber's windows and their density bucket (contract 8.2: `1m` up to 6 h, then `5m`, `1h`, `1d`).
const Map<String, (Duration, String)> liveWindows = {
  '1h': (Duration(hours: 1), '1m'),
  '6h': (Duration(hours: 6), '5m'),
  '24h': (Duration(hours: 24), '1h'),
  '7d': (Duration(days: 7), '1h'),
  '30d': (Duration(days: 30), '1d'),
};

Duration bucketDuration(String b) => switch (b) {
      '1m' => const Duration(minutes: 1),
      '5m' => const Duration(minutes: 5),
      '1h' => const Duration(hours: 1),
      '1d' => const Duration(days: 1),
      _ => const Duration(minutes: 1),
    };

/// How far back replay reaches: 90 days on `/v1` (contract 3.3), 30 days on today's server.
Duration replayHorizon(NetworkReadSource s) => s == NetworkReadSource.v1 ? const Duration(days: 90) : const Duration(days: 30);

class LiveReplayApi {
  final String baseUrl;
  final V1Client v1;
  final http.Client _legacy;
  LiveReplayApi(this.baseUrl, {http.Client? client, DateTime Function()? clock})
      : v1 = V1Client(baseUrl, client: client, clock: clock),
        _legacy = client ?? newRegionWireClient();

  /// One replay page from [from] (at most one hour), `/v1/replay` else today's `region-replay`. [cursor] continues a
  /// page; pass the [ReplayPage.source] it came from. Throws [V1Error].
  Future<ReplayPage> replay(DateTime from,
      {DateTime? to, Set<int> types = const {}, String? node, String? observer, String? cursor, NetworkReadSource? cursorSource, int limit = 500}) async {
    final until = to ?? from.add(const Duration(hours: 1));
    if (cursorSource != NetworkReadSource.legacy) {
      try {
        final env = await v1.getPage('replay', LiveV2Packet.tryParse,
            query: {
              'from': from.toUtc().toIso8601String(),
              'to': until.toUtc().toIso8601String(),
              if (types.isNotEmpty) 'type': (types.toList()..sort()).join(','),
              'node': node,
              'observer': observer,
            },
            cursor: cursor,
            limit: limit);
        return ReplayPage(packets: env.data, next: env.page?.next, to: until, offlineAsOf: env.offlineAsOf);
      } on V1NotLive {
        // today's read below
      }
    }
    final start = cursorSource == NetworkReadSource.legacy && cursor != null ? (DateTime.tryParse(cursor)?.toUtc() ?? from) : from;
    return _legacyReplay(start, until, types: types, limit: limit);
  }

  Future<ReplayPage> _legacyReplay(DateTime from, DateTime to, {Set<int> types = const {}, int limit = 300}) async {
    final http.Response res;
    try {
      res = await _legacy.get(
          regionDatasetUri(baseUrl, 'region-replay', {'from': from.toUtc().toIso8601String(), 'to': to.toUtc().toIso8601String(), 'limit': '${limit.clamp(1, 300)}'}),
          headers: const {'accept': 'application/json'}).timeout(v1.timeout);
    } catch (e) {
      throw V1Error(code: 'offline', message: 'No connection to the server.', offline: isNetworkFailure(e));
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      body = null;
    }
    if (res.statusCode != 200 || body is! Map) {
      throw V1Error(status: res.statusCode, code: res.statusCode == 429 ? 'rate_limited' : 'http_${res.statusCode}', message: 'Replay did not load (the server answered ${res.statusCode}).');
    }
    final list = [
      if (body['packets'] is List)
        for (final p in body['packets'] as List)
          if (legacy.LivePacket.tryParse(p) case final lp?) LiveV2Packet.fromLegacy(lp)
    ].where((p) => types.isEmpty || types.contains(p.type)).toList()
      ..sort((a, b) => a.firstSeen.compareTo(b.firstSeen));
    final next = body['nextFrom'] is String ? body['nextFrom'] as String : null;
    return ReplayPage(packets: list, next: next, to: to, source: NetworkReadSource.legacy, offlineAsOf: offlineAsOfOf(res));
  }

  /// Reads a `refetch` path from a `missed` or `reset` event (`/v1/replay?...`): every page of it, oldest first.
  Future<List<LiveV2Packet>> refetch(String refetchPath, {int maxPages = 4}) async {
    final u = Uri.parse(refetchPath);
    final path = u.path.replaceFirst(RegExp(r'^/?v1/'), '');
    final out = <LiveV2Packet>[];
    String? cursor;
    for (var i = 0; i < maxPages; i++) {
      final env = await v1.getPage(path, LiveV2Packet.tryParse, query: u.queryParameters, cursor: cursor);
      out.addAll(env.data);
      cursor = env.page?.next;
      if (cursor == null) break;
    }
    return out;
  }

  /// `/v1/packets/density` for the scrubber; null when `/v1` is not live (the caller counts its replay pages).
  Future<DensityRead?> density(String window, {Set<int> types = const {}}) async {
    final w = liveWindows[window] ?? liveWindows['1h']!;
    try {
      final env = await v1.get('packets/density', (d) {
        if (d is! Map) throw const FormatException('density is not an object');
        final b = d['bucket'] is String ? d['bucket'] as String : w.$2;
        return DensityRead(bucket: bucketDuration(b), counts: [
          if (d['counts'] is List)
            for (final r in d['counts'] as List)
              if (r is List && r.length >= 2 && v1Time(r[0]) != null && r[1] is num) (v1Time(r[0])!, (r[1] as num).toInt())
        ]);
      }, query: {'window': window, 'bucket': w.$2, if (types.isNotEmpty) 'type': (types.toList()..sort()).join(',')});
      return env.data;
    } on V1NotLive {
      return null;
    }
  }

  void close() {
    v1.close();
    _legacy.close();
  }
}

/// Tests replace these to inject fakes.
LiveReplayApi Function(String baseUrl) liveReplayApiFactory = (b) => LiveReplayApi(b);
NetworkLiveStream Function(String baseUrl, LiveSubscription sub) networkLiveStreamFactory = (b, s) => NetworkLiveStream(b, s);
