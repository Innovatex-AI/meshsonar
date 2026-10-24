import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/core/live_stream.dart';

const _pkt = 'event: packet\ndata: {"kind":"packet","packet":{"hash":"ab12","type":5,"route":1,"at":"2026-10-24T02:00:00Z",'
    '"observations":[{"observer":"o1","observerName":"Obs","at":"2026-10-24T02:00:00Z","snrDb":7.5,"rssiDbm":-90,"hops":2,"path":["aa","bb"]}],'
    '"hops":[{"key":"k1","lat":39.9,"lon":-83.0}]}}\n\n';

http.StreamedResponse _res(Stream<String> body, [int code = 200]) =>
    http.StreamedResponse(body.map(utf8.encode), code, headers: {});

void main() {
  test('parses comments, heartbeat, status and packet events', () {
    final p = SseParser();
    final out = <LiveEvent>[];
    for (final l in ': connected\nretry: 3000\n\nevent: heartbeat\ndata: {"kind":"heartbeat","at":"x"}\n\nevent: status\ndata: {"kind":"status","observersOnline":3}\n\n$_pkt'.split('\n')) {
      final e = p.line(l);
      if (e != null) out.add(e);
    }
    expect(out[0], isA<LiveHeartbeatEvent>());
    expect((out[1] as LiveStatusEvent).observersOnline, 3);
    final pk = (out[2] as LivePacketEvent).packet;
    expect(pk.hash, 'ab12');
    expect(pk.observations.single.snrDb, 7.5);
    expect(pk.hops.single.lat, 39.9);
  });

  test('endpoint and backoff', () {
    final s = LiveStream(Uri.parse('https://cmh.meshsonar.com/'));
    expect(s.endpoint.toString(), 'https://cmh.meshsonar.com/api/cmh/region-live');
    expect([1, 2, 3, 6, 20].map((a) => s.backoffFor(a).inSeconds), [1, 2, 4, 30, 30]);
  });

  test('delivers events, reconnects after the stream ends, and pause drops the connection', () async {
    var opens = 0;
    final s = LiveStream(Uri.parse('https://x.test'), backoffMin: const Duration(milliseconds: 10), connect: (r) async {
      opens++;
      return _res(Stream.fromIterable([_pkt]));
    });
    final got = <LiveEvent>[];
    s.events.listen(got.add);
    s.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(got, isNotEmpty);
    expect(opens, greaterThan(1));
    s.pause();
    final n = opens;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(opens, n);
    expect(s.state, LiveConnState.paused);
    s.resume();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(opens, greaterThan(n));
    await s.dispose();
  });

  test('watchdog reconnects a silent stream', () async {
    var opens = 0;
    final keep = <StreamController<String>>[];
    final s = LiveStream(Uri.parse('https://x.test'),
        watchdog: const Duration(milliseconds: 50), backoffMin: const Duration(milliseconds: 5), connect: (r) async {
      opens++;
      final c = StreamController<String>();
      keep.add(c);
      return _res(c.stream);
    });
    s.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(opens, greaterThan(1));
    await s.dispose();
    for (final c in keep) {
      c.close();
    }
  });

  test('non-200 retries', () async {
    var opens = 0;
    final s = LiveStream(Uri.parse('https://x.test'), backoffMin: const Duration(milliseconds: 5), connect: (r) async {
      opens++;
      return _res(const Stream.empty(), 503);
    });
    s.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(opens, greaterThan(1));
    await s.dispose();
  });
}
