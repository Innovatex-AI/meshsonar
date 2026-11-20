// AZ-3.3: the replay clock (gaps, speeds, paging) and the ghost-hop rendering decision of the live map.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/v1/live_api.dart';
import 'package:meshsonar/core/v1/live_geometry.dart';
import 'package:meshsonar/core/v1/live_replay.dart';
import 'package:meshsonar/core/v1/packet_models.dart';

LiveV2Packet pk(String hash, DateTime at) => LiveV2Packet(hash: hash, type: 4, typeName: 'ADVERT', route: 'FLOOD', firstSeen: at);

PacketHop hop(int i, String prefix, HopConfidence c, {String? key, (double, double)? pos}) => PacketHop(
      index: i,
      prefix: prefix,
      confidence: c,
      node: key == null ? null : PacketNode(key: key, name: key),
      candidates: key == null || pos == null ? const [] : [HopCandidate(node: PacketNode(key: key), position: PacketPosition(pos.$1, pos.$2))],
    );

void main() {
  final t0 = DateTime.utc(2026, 11, 20, 14);

  group('ReplayClock', () {
    test('plays in time order, gaps clamped to 100 ms .. 2 s', () {
      final c = ReplayClock(start: t0)
        ..add([
          pk('c', t0.add(const Duration(minutes: 10))), // 10 min after b: plays 2 s after it
          pk('a', t0.add(const Duration(milliseconds: 20))), // 20 ms after start: waits the 100 ms floor
          pk('b', t0.add(const Duration(seconds: 1))),
        ]);
      expect(c.tick(const Duration(milliseconds: 99)), isEmpty);
      expect(c.tick(const Duration(milliseconds: 1)).map((p) => p.hash), ['a']);
      expect(c.tick(const Duration(milliseconds: 979)), isEmpty); // a -> b is 980 ms
      expect(c.tick(const Duration(milliseconds: 1)).map((p) => p.hash), ['b']);
      expect(c.tick(const Duration(milliseconds: 1999)), isEmpty);
      expect(c.tick(const Duration(milliseconds: 1)).map((p) => p.hash), ['c']);
      expect(c.playhead, t0.add(const Duration(minutes: 10)));
      expect(c.exhausted, isTrue);
    });

    test('speed divides the wait; 0.25x to 8x only', () {
      final c = ReplayClock(start: t0, speed: 8)..add([pk('a', t0.add(const Duration(seconds: 2)))]);
      expect(c.tick(const Duration(milliseconds: 249)), isEmpty);
      expect(c.tick(const Duration(milliseconds: 1)), hasLength(1));
      expect(ReplayClock(start: t0, speed: 16).speed, 1);
      expect(replaySpeeds, [0.25, 0.5, 1, 2, 4, 8]);
      expect(replaySpeedLabel(0.25), '¼×');
      expect(replaySpeedLabel(8), '8×');
    });

    test('changing speed mid-wait keeps the next packet in place', () {
      final c = ReplayClock(start: t0)..add([pk('a', t0.add(const Duration(seconds: 2)))]);
      c.tick(const Duration(seconds: 1)); // 1 s of 2 s left at 1x
      c.setSpeed(2); // 0.5 s left
      expect(c.tick(const Duration(milliseconds: 499)), isEmpty);
      expect(c.tick(const Duration(milliseconds: 1)), hasLength(1));
    });

    test('later pages append; a hash already played or before the playhead is skipped', () {
      final c = ReplayClock(start: t0)..add([pk('a', t0.add(const Duration(seconds: 1)))]);
      c.tick(const Duration(seconds: 2));
      c.add([pk('a', t0.add(const Duration(seconds: 1))), pk('old', t0.subtract(const Duration(seconds: 5))), pk('b', t0.add(const Duration(seconds: 3)))]);
      expect(c.pending, 1);
      expect(c.tick(const Duration(seconds: 3)).map((p) => p.hash), ['b']);
    });
  });

  group('ghost-hop rendering decision', () {
    const hilltop = '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c';
    const obsId = 'src_12:7e9e8fe0a052ad046b73e9724234241a5f3b8cbad107bdfc18bcf6a27255877d';

    test('the fixture packet: two leading ghosts unplaced, likely hop dashed, unique solid to the observer', () {
      final ev = File('test/fixtures/analyzer/stream-events.txt').readAsStringSync();
      final line = const LineSplitter().convert(ev).firstWhere((l) => l.startsWith('data: {"hash":"c4b06ee8fc39b187"'));
      final p = LiveV2Packet.tryParse(jsonDecode(line.substring(6)))!;
      final d = drawLivePacket(
          p,
          LivePositions(
            node: (k) => k == hilltop ? const GeoPoint(40.05, -83.02) : null,
            observer: (id) => id == obsId ? const GeoPoint(39.99, -83.01) : null,
          ));
      // e2 (unknown) and a7 (ambiguous) come before anything placed: they are never drawn as lines.
      expect(d.unplaced, 2);
      final styles = {for (final s in d.segments) '${s.a}>${s.b}': s.style};
      expect(styles['${const GeoPoint(39.99655, -83.10279)}>${const GeoPoint(40.05, -83.02)}'], SegmentStyle.dashed); // 3c likely -> 4f
      expect(styles['${const GeoPoint(40.05, -83.02)}>${const GeoPoint(39.99, -83.01)}'], SegmentStyle.solid); // 4f -> observer
      expect(d.segments.where((s) => s.style == SegmentStyle.solid), hasLength(1));
      // The ambiguous hop's candidates are never used as a position.
      expect(d.points.any((g) => g == const GeoPoint(39.9612, -83.0041) || g == const GeoPoint(40.08803, -82.95911)), isFalse);
      expect(d.marks.where((m) => m.kind == MarkKind.likelyHop), hasLength(1));
    });

    test('an unplaced hop between two placed ones is a ghost segment with one ghost mark, never a solid line', () {
      final p = LiveV2Packet(
        hash: 'h1',
        type: 5,
        typeName: 'GRP_TXT',
        route: 'FLOOD',
        firstSeen: t0,
        observations: [const LiveObs(id: 'o1', observer: PacketObserver(id: 'obs', name: 'Obs'), pathId: 'p1')],
        paths: [
          PacketPath(id: 'p1', hops: [
            hop(0, 'aa', HopConfidence.unique, key: 'aa11', pos: (40, -83)),
            hop(1, 'bb', HopConfidence.unknown),
            hop(2, 'cc', HopConfidence.ambiguous),
            hop(3, 'dd', HopConfidence.unique, key: 'dd11', pos: (40, -82)),
          ]),
        ],
      );
      final d = drawLivePacket(p, LivePositions(node: (_) => null, observer: (id) => id == 'obs' ? const GeoPoint(41, -82) : null));
      final ghost = d.segments.singleWhere((s) => s.style == SegmentStyle.ghost);
      expect(ghost.a, const GeoPoint(40, -83));
      expect(ghost.b, const GeoPoint(40, -82));
      expect(ghost.ghosts, 2);
      expect(d.marks.where((m) => m.kind == MarkKind.ghost), hasLength(2));
      expect(d.segments.where((s) => s.style == SegmentStyle.solid).single.b, const GeoPoint(41, -82));
      expect(d.unplaced, 0);
      expect(d.steps, 2);
    });

    test('a unique hop whose node has no position is a ghost too', () {
      final p = LiveV2Packet(hash: 'h2', type: 4, typeName: 'ADVERT', route: 'FLOOD', firstSeen: t0, paths: [
        PacketPath(id: 'p1', hops: [
          hop(0, 'aa', HopConfidence.unique, key: 'aa11', pos: (40, -83)),
          hop(1, 'ee', HopConfidence.unique, key: 'ee11'),
          hop(2, 'dd', HopConfidence.unique, key: 'dd11', pos: (40, -82)),
        ]),
      ]);
      final d = drawLivePacket(p, LivePositions.none);
      expect(d.segments.single.style, SegmentStyle.ghost);
      expect(d.segments.single.ghosts, 1);
    });

    test('a DIRECT path is the route still ahead: drawn from the observer, never as travelled lines', () {
      final p = LiveV2Packet(
        hash: 'h3',
        type: 2,
        typeName: 'TXT_MSG',
        route: 'DIRECT',
        firstSeen: t0,
        observations: [const LiveObs(id: 'o1', observer: PacketObserver(id: 'obs', name: 'Obs'), pathId: 'p1')],
        paths: [
          PacketPath(id: 'p1', direction: 'remaining', hops: [hop(0, 'aa', HopConfidence.unique, key: 'aa11', pos: (40, -83))]),
        ],
      );
      final d = drawLivePacket(p, LivePositions(node: (_) => null, observer: (_) => const GeoPoint(41, -83)));
      expect(d.segments.single.style, SegmentStyle.ahead);
      expect(d.segments.single.a, const GeoPoint(41, -83));
    });

    test('an advert origin starts the path', () {
      final p = LiveV2Packet(
        hash: 'h4',
        type: 4,
        typeName: 'ADVERT',
        route: 'FLOOD',
        firstSeen: t0,
        origin: const PacketNode(key: 'origin1', name: 'Library Room'),
        paths: [PacketPath(id: 'p1', hops: [hop(0, 'aa', HopConfidence.unique, key: 'aa11', pos: (40, -83))])],
      );
      final d = drawLivePacket(p, LivePositions(node: (k) => k == 'origin1' ? const GeoPoint(39, -83) : null, observer: (_) => null));
      expect(d.segments.single.style, SegmentStyle.solid);
      expect(d.segments.single.a, const GeoPoint(39, -83));
      expect(d.marks.any((m) => m.kind == MarkKind.origin), isTrue);
    });
  });
}
