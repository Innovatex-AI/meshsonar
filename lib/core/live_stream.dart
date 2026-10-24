// Native client for the website's `region-live` Server-Sent Events stream (public GET on the region host,
// meshcore-insights src/server/region/live.ts). Pure Dart. Same client pattern as the web view
// (region-page-set-spec.md section 3): exponential backoff reconnect, 65 s silence watchdog (the server sends a
// heartbeat every 15 s), and pause/resume so the app can drop the connection when backgrounded or the screen is off.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One hop the server resolved to a position (ambiguous hops are omitted by the server, never guessed).
class LiveHop {
  final String key;
  final double lat;
  final double lon;
  const LiveHop(this.key, this.lat, this.lon);
}

class LiveObservation {
  final String observer;
  final String? observerName;
  final DateTime? at;
  final double? snrDb;
  final int hops;
  const LiveObservation({required this.observer, this.observerName, this.at, this.snrDb, this.hops = 0});
}

/// One grouped packet (`LivePacket`). A late event with the same [hash] carries only new observations; merge by hash.
class LivePacket {
  final String hash;
  final int type;
  final int route;
  final DateTime at;
  final List<LiveObservation> observations;
  final List<LiveHop> hops;
  const LivePacket({
    required this.hash,
    required this.type,
    required this.route,
    required this.at,
    required this.observations,
    required this.hops,
  });

  /// Null when unusable (no hash or time).
  static LivePacket? tryParse(Object? j) {
    if (j is! Map) return null;
    final hash = j['hash'];
    final at = j['at'] is String ? DateTime.tryParse(j['at'] as String) : null;
    if (hash is! String || hash.isEmpty || at == null) return null;
    double? d(Object? v) => v is num ? v.toDouble() : null;
    final obs = <LiveObservation>[];
    if (j['observations'] is List) {
      for (final o in j['observations'] as List) {
        if (o is! Map || o['observer'] is! String) continue;
        obs.add(LiveObservation(
          observer: o['observer'] as String,
          observerName: o['observerName'] is String ? o['observerName'] as String : null,
          at: o['at'] is String ? DateTime.tryParse(o['at'] as String) : null,
          snrDb: d(o['snrDb']),
          hops: o['hops'] is num ? (o['hops'] as num).toInt() : 0,
        ));
      }
    }
    final hops = <LiveHop>[];
    if (j['hops'] is List) {
      for (final h in j['hops'] as List) {
        if (h is! Map) continue;
        final lat = d(h['lat']);
        final lon = d(h['lon']);
        if (h['key'] is! String || lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) continue;
        hops.add(LiveHop(h['key'] as String, lat, lon));
      }
    }
    return LivePacket(
      hash: hash,
      type: j['type'] is num ? (j['type'] as num).toInt() : -1,
      route: j['route'] is num ? (j['route'] as num).toInt() : 1,
      at: at,
      observations: obs,
      hops: hops,
    );
  }

  LivePacket merged(LivePacket later) => LivePacket(
        hash: hash,
        type: type,
        route: route,
        at: at,
        observations: [...observations, ...later.observations],
        hops: hops.isNotEmpty ? hops : later.hops,
      );
}

sealed class LiveEvent {
  const LiveEvent();
}

class LivePacketEvent extends LiveEvent {
  final LivePacket packet;
  const LivePacketEvent(this.packet);
}

class LiveHeartbeatEvent extends LiveEvent {
  const LiveHeartbeatEvent();
}

class LiveStatusEvent extends LiveEvent {
  final int observersOnline;
  const LiveStatusEvent(this.observersOnline);
}

enum LiveConnState { idle, connecting, live, reconnecting, paused }

/// Parses SSE text lines into events; one instance per connection.
class SseParser {
  String _event = '';
  final StringBuffer _data = StringBuffer();

  /// Feed one line (no newline). Returns an event when a blank line completes one.
  LiveEvent? line(String l) {
    if (l.isEmpty) {
      final ev = _event;
      final data = _data.toString();
      _event = '';
      _data.clear();
      if (data.isEmpty) return null;
      return decode(ev, data);
    }
    if (l.startsWith(':')) return null; // comment, e.g. ": connected"
    final i = l.indexOf(':');
    final field = i < 0 ? l : l.substring(0, i);
    var value = i < 0 ? '' : l.substring(i + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') {
      _event = value;
    } else if (field == 'data') {
      if (_data.isNotEmpty) _data.write('\n');
      _data.write(value);
    }
    return null;
  }

  static LiveEvent? decode(String event, String data) {
    Object? j;
    try {
      j = jsonDecode(data);
    } catch (_) {
      return null;
    }
    if (j is! Map) return null;
    final kind = event.isNotEmpty ? event : j['kind'];
    switch (kind) {
      case 'packet':
        final p = LivePacket.tryParse(j['packet']);
        return p == null ? null : LivePacketEvent(p);
      case 'heartbeat':
        return const LiveHeartbeatEvent();
      case 'status':
        final n = j['observersOnline'];
        return n is num ? LiveStatusEvent(n.toInt()) : null;
    }
    return null;
  }
}

typedef LiveConnect = Future<http.StreamedResponse> Function(http.Request request);

class LiveStream {
  final Uri baseUrl;
  final Duration watchdog;
  final Duration backoffMin;
  final Duration backoffMax;
  final LiveConnect _connect;

  final _events = StreamController<LiveEvent>.broadcast();
  final _state = StreamController<LiveConnState>.broadcast();
  LiveConnState _cur = LiveConnState.idle;
  bool _wanted = false; // start() called and not stopped
  bool _paused = false;
  int _gen = 0; // bumped on every (re)start so stale loops exit
  int _attempt = 0;
  Timer? _dog;
  Timer? _retry;
  StreamSubscription<String>? _sub;
  http.Client? _active;

  /// [connect] is a test seam; production opens a fresh client per connection so a pause really drops the socket.
  LiveStream(
    this.baseUrl, {
    LiveConnect? connect,
    this.watchdog = const Duration(seconds: 65),
    this.backoffMin = const Duration(seconds: 1),
    this.backoffMax = const Duration(seconds: 30),
  })  : _connect = connect ?? _defaultConnect;

  static Future<http.StreamedResponse> _defaultConnect(http.Request r) => throw StateError('replaced in open()');

  Stream<LiveEvent> get events => _events.stream;
  Stream<LiveConnState> get states => _state.stream;
  LiveConnState get state => _cur;

  Uri get endpoint {
    var path = baseUrl.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(scheme: baseUrl.scheme, host: baseUrl.host, port: baseUrl.hasPort ? baseUrl.port : null, path: '$path/api/cmh/region-live');
  }

  /// Backoff before reconnect attempt [attempt] (1-based): 1 s, 2 s, 4 s ... capped.
  Duration backoffFor(int attempt) {
    final ms = backoffMin.inMilliseconds * (1 << (attempt - 1).clamp(0, 20));
    return Duration(milliseconds: ms.clamp(backoffMin.inMilliseconds, backoffMax.inMilliseconds));
  }

  void _set(LiveConnState s) {
    if (_cur == s) return;
    _cur = s;
    if (!_state.isClosed) _state.add(s);
  }

  void start() {
    if (_wanted) return;
    _wanted = true;
    if (!_paused) _open();
  }

  /// Drop the connection (app backgrounded / screen off / tab hidden). [resume] reconnects.
  void pause() {
    if (_paused) return;
    _paused = true;
    _teardown();
    if (_wanted) _set(LiveConnState.paused);
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
    await _state.close();
  }

  void _teardown() {
    _gen++;
    _dog?.cancel();
    _retry?.cancel();
    _dog = null;
    _retry = null;
    _sub?.cancel();
    _sub = null;
    _active?.close();
    _active = null;
  }

  void _armDog(int gen) {
    _dog?.cancel();
    _dog = Timer(watchdog, () {
      if (gen == _gen) _fail(gen, null);
    });
  }

  Future<void> _open() async {
    _teardown();
    final gen = _gen;
    _set(_attempt == 0 ? LiveConnState.connecting : LiveConnState.reconnecting);
    final req = http.Request('GET', endpoint)
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Cache-Control'] = 'no-cache';
    http.Client? client;
    try {
      _armDog(gen);
      final http.StreamedResponse res;
      if (_connect == _defaultConnect) {
        client = http.Client();
        _active = client;
        res = await client.send(req);
      } else {
        res = await _connect(req);
      }
      if (gen != _gen) return;
      if (res.statusCode != 200) {
        final ra = int.tryParse(res.headers['retry-after'] ?? '');
        await res.stream.drain<void>().catchError((_) {});
        _fail(gen, ra == null ? null : Duration(seconds: ra.clamp(1, 120)));
        return;
      }
      final parser = SseParser();
      _sub = res.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (l) {
          if (gen != _gen) return;
          _armDog(gen); // any bytes (heartbeat every 15 s) prove the stream is alive
          final ev = parser.line(l);
          if (ev == null) return;
          _attempt = 0;
          _set(LiveConnState.live);
          if (!_events.isClosed) _events.add(ev);
        },
        onError: (_) => _fail(gen, null),
        onDone: () => _fail(gen, null),
        cancelOnError: true,
      );
    } catch (_) {
      if (gen == _gen) _fail(gen, null);
    }
  }

  void _fail(int gen, Duration? minWait) {
    if (gen != _gen || !_wanted || _paused) return;
    _teardown();
    _attempt++;
    _set(LiveConnState.reconnecting);
    var wait = backoffFor(_attempt);
    if (minWait != null && minWait > wait) wait = minWait;
    final g = _gen;
    _retry = Timer(wait, () {
      if (g == _gen && _wanted && !_paused) _open();
    });
  }
}
