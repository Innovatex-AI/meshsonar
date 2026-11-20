// AZ-3.3: the live stream client (resume, missed, reset, fallback), the SSE parser on the contract's sample session,
// replay and density reads with their fallbacks. Fixtures: test/fixtures/analyzer (copied from meshsonar-infra
// docs/planning/analyzer-fixtures).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/live_stream.dart' as legacy;
import 'package:meshsonar/core/v1/live_api.dart';
import 'package:meshsonar/core/v1/network_api.dart' show NetworkReadSource;
import 'package:meshsonar/core/v1/packet_models.dart';

String fixture(String name) => File('test/fixtures/analyzer/$name').readAsStringSync();

List<NetLiveEvent> parseSession(String text) {
  final p = SseFrameParser();
  final out = <NetLiveEvent>[];
  for (final l in const LineSplitter().convert(text)) {
    final f = p.line(l);
    if (f == null) continue;
    final e = decodeLiveFrame(f);
    if (e != null) out.add(e);
  }
  return out;
}

/// A fake SSE server: each connect gets its own controller; [requests] records what the client sent.
class FakeSse {
  final List<http.Request> requests = [];
  final List<StreamController<List<int>>> conns = [];
  int status = 200;
  String contentType = 'text/event-stream';

  Future<http.StreamedResponse> connect(http.Request r) async {
    requests.add(r);
    final c = StreamController<List<int>>();
    conns.add(c);
    return http.StreamedResponse(c.stream, status, headers: {'content-type': contentType}, request: r);
  }

  void send(String text, [int conn = -1]) => (conn < 0 ? conns.last : conns[conn]).add(utf8.encode(text));
}

void main() {
  group('SSE sample session (contract 9)', () {
    test('every event of stream-events.txt decodes in order', () {
      final ev = parseSession(fixture('stream-events.txt'));
      expect(ev.map((e) => e.runtimeType.toString()).toList(), [
        'NetHello', 'NetStatus', 'NetPacket', 'NetMessage', 'NetPacketUpdate', 'NetPacket', 'NetMessageHidden', //
        'NetHeartbeat', 'NetMissed', 'NetPulse', 'NetReset',
      ]);
      final p = (ev[2] as NetPacket).packet;
      expect(p.hash, 'c4b06ee8fc39b187');
      expect(p.paths.single.hops.map((h) => h.confidence).toList(),
          [HopConfidence.unknown, HopConfidence.ambiguous, HopConfidence.likely, HopConfidence.unique]);
      expect(p.unknownHops, ['e2']);
      expect(p.message?.text, 'anyone hearing Hilltop this morning?');
      final missed = ev[8] as NetMissed;
      expect(missed.count, 37);
      expect(missed.refetch, startsWith('/v1/replay?'));
      final reset = ev[10] as NetReset;
      expect(reset.reason, 'resume_too_old');
      expect(reset.refetch, contains('from=2026-11-20T13:50:00.000Z'));
      expect((ev[1] as NetStatus).observersOnline, 26);
    });

    test('a packet.update merges by observation id, a repeated packet is counted once', () {
      final ev = parseSession(fixture('stream-events.txt'));
      final p = (ev[2] as NetPacket).packet;
      final u = ev[4] as NetPacketUpdate;
      final m = p.merged(obs: u.observations, newPaths: u.paths, settled: u.settled);
      expect(m.observations.map((o) => o.id), ['o1', 'o2']);
      expect(m.paths.map((x) => x.id), ['p1', 'p2']);
      expect(m.settled, isTrue);
      // After a resume the server may repeat the packet: same ids, nothing doubles.
      final again = m.mergedWith(p);
      expect(again.observations.length, 2);
      expect(again.paths.length, 2);
    });

    test('retry and comment lines', () {
      final p = SseFrameParser();
      for (final l in ['retry: 3000', ': keep-alive', 'id: 5-1', 'event: heartbeat', 'data: {"lastEventId":"5-0"}', '']) {
        p.line(l);
      }
      expect(p.retry, const Duration(seconds: 3));
    });
  });

  group('NetworkLiveStream', () {
    test('tracks ids and resumes with Last-Event-ID (header and query) after a drop', () async {
      final fake = FakeSse();
      final s = NetworkLiveStream('https://cmh.meshsonar.com', const LiveSubscription(region: 'cmh'),
          connect: fake.connect, backoffMin: const Duration(milliseconds: 10), backoffMax: const Duration(milliseconds: 20));
      final got = <NetLiveEvent>[];
      s.events.listen(got.add);
      s.start();
      await Future<void>.delayed(Duration.zero);
      expect(fake.requests.single.url.queryParameters['region'], 'cmh');
      expect(fake.requests.single.headers.containsKey('Last-Event-ID'), isFalse);
      fake.send('id: 100-0\nevent: hello\ndata: {"apiVersion":"1.0","resumed":false}\n\n');
      fake.send('id: 100-1\nevent: heartbeat\ndata: {"at":"2026-11-20T14:00:00.000Z"}\n\n');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(s.state, NetLiveState.live);
      expect(s.lastEventId, '100-1');
      await fake.conns.last.close(); // the server drops the connection
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fake.requests.length, 2);
      expect(fake.requests.last.headers['Last-Event-ID'], '100-1');
      expect(fake.requests.last.url.queryParameters['lastEventId'], '100-1');
      fake.send('id: 101-0\nevent: hello\ndata: {"apiVersion":"1.0","resumed":true}\n\n');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect((got.whereType<NetHello>().last).resumed, isTrue);
      await s.dispose();
    });

    test('pause drops the connection, resume reconnects with the last id', () async {
      final fake = FakeSse();
      final s = NetworkLiveStream('https://cmh.meshsonar.com', const LiveSubscription(region: 'cmh'), connect: fake.connect);
      s.start();
      await Future<void>.delayed(Duration.zero);
      fake.send('id: 7-0\nevent: heartbeat\ndata: {}\n\n');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      s.pause();
      expect(s.state, NetLiveState.paused);
      s.resume();
      await Future<void>.delayed(Duration.zero);
      expect(fake.requests.length, 2);
      expect(fake.requests.last.headers['Last-Event-ID'], '7-0');
      await s.dispose();
    });

    test('missed and reset reach the caller with their refetch path', () async {
      final fake = FakeSse();
      final s = NetworkLiveStream('https://cmh.meshsonar.com', const LiveSubscription(region: 'cmh'), connect: fake.connect);
      final got = <NetLiveEvent>[];
      s.events.listen(got.add);
      s.start();
      await Future<void>.delayed(Duration.zero);
      fake.send(fixture('stream-events.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(got.whereType<NetMissed>().single.refetch, contains('/v1/replay'));
      expect(got.whereType<NetReset>().single.reason, 'resume_too_old');
      expect(s.lastEventId, '1795184050000-0');
      await s.dispose();
    });

    test('a new subscription forgets the old id (the server would answer reset)', () async {
      final fake = FakeSse();
      final s = NetworkLiveStream('https://cmh.meshsonar.com', const LiveSubscription(region: 'cmh'), connect: fake.connect);
      s.start();
      await Future<void>.delayed(Duration.zero);
      fake.send('id: 9-0\nevent: heartbeat\ndata: {}\n\n');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      s.resubscribe(const LiveSubscription(region: 'cmh', types: {4}));
      await Future<void>.delayed(Duration.zero);
      expect(fake.requests.last.url.queryParameters['type'], '4');
      expect(fake.requests.last.headers.containsKey('Last-Event-ID'), isFalse);
      await s.dispose();
    });

    test('falls back to today\'s region feed when /v1/stream is not live (404)', () async {
      final fake = FakeSse()..status = 404;
      final legacyRequests = <Uri>[];
      final feed = StreamController<List<int>>();
      final s = NetworkLiveStream('https://cmh.meshsonar.com', const LiveSubscription(region: 'cmh'),
          connect: fake.connect,
          legacyFactory: (b) => legacy.LiveStream(b, connect: (r) async {
                legacyRequests.add(r.url);
                return http.StreamedResponse(feed.stream, 200, headers: {'content-type': 'text/event-stream'});
              }));
      final got = <NetLiveEvent>[];
      s.events.listen(got.add);
      s.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(s.mode, NetworkReadSource.legacy);
      expect(legacyRequests.single.path, '/api/cmh/region-live');
      feed.add(utf8.encode('event: packet\ndata: {"packet":{"hash":"ABCD000011112222","type":4,"route":1,"at":"2026-11-20T14:00:00.000Z",'
          '"observations":[{"observer":"obs1","snrDb":5.5,"hops":1}],"hops":[{"key":"4f19aa","lat":39.9,"lon":-83.0}]}}\n\n'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final p = got.whereType<NetPacket>().single.packet;
      expect(p.hash, 'abcd000011112222');
      expect(p.source, NetworkReadSource.legacy);
      expect(p.paths.single.hops.single.confidence, HopConfidence.unique);
      expect(p.legacyPositions['4f19aa'], (39.9, -83.0));
      await s.dispose();
      await feed.close();
    });

    test('a 200 that is not an event stream (the site shell) counts as not live', () async {
      final fake = FakeSse()..contentType = 'text/html';
      var legacyUsed = false;
      final s = NetworkLiveStream('https://cmh.meshsonar.com', const LiveSubscription(region: 'cmh'),
          connect: fake.connect,
          legacyFactory: (b) {
            legacyUsed = true;
            return legacy.LiveStream(b, connect: (r) async => http.StreamedResponse(const Stream.empty(), 503));
          });
      s.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(legacyUsed, isTrue);
      await s.dispose();
    });

    test('back-off: 3 s doubling to 60 s with at most 20 % jitter', () {
      final s = NetworkLiveStream('https://x.meshsonar.com', const LiveSubscription(region: 'x'));
      for (final (a, base) in [(1, 3000), (2, 6000), (3, 12000), (5, 48000), (6, 60000), (10, 60000)]) {
        final ms = s.backoffFor(a).inMilliseconds;
        expect(ms, inInclusiveRange(base, (base * 1.2).round()), reason: 'attempt $a');
      }
    });
  });

  group('LiveReplayApi', () {
    http.Response j(String body, [int code = 200]) => http.Response(body, code, headers: {'content-type': 'application/json'});

    test('/v1/replay pages and the density read', () async {
      final seen = <Uri>[];
      final api = LiveReplayApi('https://cmh.meshsonar.com', client: MockClient((r) async {
        seen.add(r.url);
        if (r.url.path == '/v1/replay') return j(fixture('replay.json'));
        if (r.url.path == '/v1/packets/density') return j(fixture('packets-density.json'));
        return j('{}', 404);
      }));
      final page = await api.replay(DateTime.utc(2026, 11, 20, 14), types: {4, 5});
      expect(page.source, NetworkReadSource.v1);
      expect(page.packets.first.hash, '1add53ffce368256');
      expect(seen.first.queryParameters['type'], '4,5');
      expect(seen.first.queryParameters['to'], '2026-11-20T15:00:00.000Z');
      final d = await api.density('1h');
      expect(d!.counts.length, 10);
      expect(d.max, 52);
      expect(d.bucket, const Duration(minutes: 1));
      expect(d.estimated, isFalse);
    });

    test('falls back to region-replay; density is null (the phone counts)', () async {
      resetV1NotLive();
      final api = LiveReplayApi('https://cmh.meshsonar.com', client: MockClient((r) async {
        if (r.url.path == '/api/cmh/region-replay') {
          return j(jsonEncode({
            'packets': [
              {'hash': 'bbbb000011112222', 'type': 5, 'route': 1, 'at': '2026-11-20T14:00:30.000Z', 'observations': [], 'hops': []},
              {'hash': 'aaaa000011112222', 'type': 4, 'route': 1, 'at': '2026-11-20T14:00:10.000Z', 'observations': [], 'hops': []},
            ],
            'from': '2026-11-20T14:00:00.000Z',
            'to': '2026-11-20T15:00:00.000Z',
            'nextFrom': '2026-11-20T15:00:00.000Z',
          }));
        }
        return http.Response('<html>', 404);
      }));
      final page = await api.replay(DateTime.utc(2026, 11, 20, 14), types: {4});
      expect(page.source, NetworkReadSource.legacy);
      expect(page.packets.map((p) => p.hash), ['aaaa000011112222']);
      expect(page.next, '2026-11-20T15:00:00.000Z');
      expect(await api.density('1h'), isNull);
      resetV1NotLive();
    });

    test('refetch reads every page of a missed/reset refetch path', () async {
      var calls = 0;
      final api = LiveReplayApi('https://cmh.meshsonar.com', client: MockClient((r) async {
        calls++;
        expect(r.url.path, '/v1/replay');
        expect(r.url.queryParameters['region'], 'cmh');
        final body = jsonDecode(fixture('replay.json')) as Map<String, dynamic>;
        body['page'] = {'limit': 500, 'next': calls == 1 ? 'c2' : null};
        return j(jsonEncode(body));
      }));
      final ps = await api.refetch('/v1/replay?from=2026-11-20T14:13:58.000Z&to=2026-11-20T14:14:00.000Z&region=cmh');
      expect(calls, 2);
      expect(ps, isNotEmpty);
    });

    test('density counted on the phone', () {
      final from = DateTime.utc(2026, 11, 20, 14);
      final d = DensityRead.count([from.add(const Duration(seconds: 30)), from.add(const Duration(seconds: 50)), from.add(const Duration(minutes: 3))],
          from, from.add(const Duration(minutes: 5)), const Duration(minutes: 1));
      expect(d.counts.map((c) => c.$2), [2, 0, 0, 1, 0]);
      expect(d.estimated, isTrue);
    });
  });
}
