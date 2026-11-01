import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/frame_stats.dart';
import 'package:meshsonar/core/map_health.dart';

import 'helpers.dart';

DateTime t(num s) => DateTime.utc(2026, 11, 1, 12).add(Duration(milliseconds: (s * 1000).round()));

void main() {
  group('frame stats', () {
    test('percentiles, jank counts and stalls', () {
      final w = FrameStatsWindow();
      for (var i = 0; i < 95; i++) {
        w.add(const FrameSample(4, 2, 6));
      }
      for (var i = 0; i < 4; i++) {
        w.add(const FrameSample(20, 3, 24)); // over 16.7
      }
      w.add(const FrameSample(3, 90, 95)); // a raster stall
      final s = w.snapshot();
      expect(s.frames, 100);
      expect(s.p50Ms, 4);
      expect(s.worstMs, 90);
      expect(s.janky60, 5);
      expect(s.janky120, 5);
      expect(s.stalls, 1);
      expect(s.p95Ms, 4, reason: '95th of 100 is still a good frame');
      expect(s.toJson()['worst_ms'], 90);
    });

    test('empty window is all zeros and the cap holds', () {
      expect(FrameStatsWindow().snapshot().frames, 0);
      final w = FrameStatsWindow(maxFrames: 3);
      for (var i = 0; i < 10; i++) {
        w.add(const FrameSample(1, 1, 1));
      }
      expect(w.length, 3);
    });
  });

  group('recorder', () {
    test('writes one sample per interval with the frame stats and each provider section, then resets', () {
      final sink = MemoryHealthSink();
      final r = MapHealthRecorder(sink: sink);
      var puckCalls = 0;
      r.providers['puck'] = (w) => {'puck_updates_hz': ++puckCalls};
      r.start(); // window starts at the real now: use maybeSample with explicit times relative to it
      final t0 = DateTime.now();
      r.onFrame(const FrameSample(5, 1, 6));
      r.onFrame(const FrameSample(40, 2, 45));
      expect(r.maybeSample(t0.add(const Duration(seconds: 3))), isFalse, reason: 'window not full');
      expect(r.maybeSample(t0.add(const Duration(seconds: 11))), isTrue);
      expect(sink.records, hasLength(1));
      final rec = sink.records.single;
      expect(rec['kind'], 'map_health');
      expect((rec['frames'] as Map)['frames'], 2);
      expect((rec['frames'] as Map)['worst_ms'], 40);
      expect(rec['puck'], {'puck_updates_hz': 1});
      // next window starts empty
      r.onFrame(const FrameSample(2, 1, 3));
      expect(r.maybeSample(t0.add(const Duration(seconds: 22))), isTrue);
      expect(((sink.records[1])['frames'] as Map)['frames'], 1);
      expect(r.samples, 2);
      expect(r.last, same(sink.records[1]));
    });

    test('a failing provider does not lose the sample; stop flushes; stopped recorder is silent', () {
      final sink = MemoryHealthSink();
      final r = MapHealthRecorder(sink: sink, clock: () => t(0));
      r.providers['bad'] = (w) => throw StateError('x');
      r.start();
      expect(r.maybeSample(t(20)), isTrue);
      expect(sink.records.single['bad'], {'error': true});
      r.stop(flush: false);
      expect(r.maybeSample(t(40)), isFalse);
      r.onFrame(const FrameSample(1, 1, 1)); // ignored while stopped
    });
  });

  group('drive store', () {
    late Directory dir;
    late JsonlDriveStore store;
    setUp(() async {
      dir = Directory.systemTemp.createTempSync('mh');
      store = await JsonlDriveStore.open(dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('map_health.jsonl is written beside the drive, one line per sample, and shareable', () async {
      final s = makeSession();
      await store.startSession(s);
      expect(await store.mapHealthFile(s.id), isNull);
      final sink = DriveStoreHealthSink(store, () => s.id);
      sink.write({'kind': 'map_health', 'n': 1});
      sink.write({'kind': 'map_health', 'n': 2});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final f = (await store.mapHealthFile(s.id))!;
      final lines = f.readAsLinesSync();
      expect(lines, hasLength(2));
      expect(jsonDecode(lines[1]), {'kind': 'map_health', 'n': 2});
      expect(f.path.endsWith('map_health.jsonl'), isTrue);
    });

    test('a drive that does not exist, or no running drive, writes nothing', () async {
      await store.appendMapHealth('ghost', {'a': 1});
      expect(await store.mapHealthFile('ghost'), isNull);
      DriveStoreHealthSink(store, () => null).write({'a': 1}); // no drive recording: silently nothing
    });

    test('the file stops growing at the cap', () async {
      final s = makeSession();
      await store.startSession(s);
      final big = {'pad': 'x' * 200000};
      for (var i = 0; i < 40; i++) {
        await store.appendMapHealth(s.id, big);
      }
      final len = (await store.mapHealthFile(s.id))!.lengthSync();
      expect(len, lessThan(JsonlDriveStore.mapHealthMaxBytes + 300000));
      expect(len, greaterThan(JsonlDriveStore.mapHealthMaxBytes ~/ 2));
    });
  });
}
