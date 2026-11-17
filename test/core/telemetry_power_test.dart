// Battery plan I3 / A9: the background upload cadence follows the battery mode, nothing is dropped for it, and the queue
// file is rewritten at most every 30 s (immediately when the app goes behind).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/core/telemetry_uploader.dart';
import 'package:meshsonar/radio/radio_api.dart';

RxPacket _rx(DateTime at, int salt) => RxPacket(
      at: at,
      raw: Uint8List.fromList([0x15, 0x02, 0xA1, 0xB2, 0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, salt >> 8, salt & 0xff]),
      snrDb: 6.5,
      rssiDbm: -97,
    );

class _Tx implements TelemetryTransport {
  final posts = <List<int>>[];
  final results = <TelemetryHttpResult>[];
  @override
  Future<TelemetryHttpResult> postTelemetry(String driverKey, List<int> body) async {
    posts.add(body);
    return results.isEmpty ? const TelemetryHttpResult(200) : results.removeAt(0);
  }

  @override
  Future<TelemetryHttpResult> deleteTelemetry(String driverKey) async => const TelemetryHttpResult(200);
}

void main() {
  TelemetryRecord rec(DateTime at, int salt) =>
      TelemetryRecord.fromRx(_rx(at, salt), region: 'CMH', shareableChannel: (_) => true)!;

  TelemetryUploader make(_Tx tx, DateTime Function() now,
          {File? file, Duration? bg, bool auto = true, void Function()? onSent}) =>
      TelemetryUploader(
        enabled: () => true,
        driverKey: () => 'k' * 40,
        keyApproved: () => true,
        transport: () => tx,
        queueFile: file,
        config: const TelemetryConfig(holdFor: Duration.zero),
        now: now,
        autoSchedule: auto,
        backgroundGap: bg == null ? null : () => bg,
        onBatchSent: onSent,
      );

  int postsInLockedHour(Duration? bg) {
    final tx = _Tx();
    var kept = 0;
    var sentAll = false;
    fakeAsync((async) {
      final start = DateTime.utc(2026, 11, 17, 12);
      DateTime t() => start.add(async.elapsed);
      final u = make(tx, t, bg: bg);
      u.foreground = false;
      for (var i = 0; i < 360; i++) {
        if (u.add(rec(t(), i))) kept++;
        async.elapse(const Duration(seconds: 10));
      }
      async.elapse(const Duration(minutes: 16));
      sentAll = u.sent == kept && u.queued == 0;
      unawaited(u.dispose());
      async.flushMicrotasks();
    });
    expect(sentAll, isTrue, reason: 'nothing is dropped, the queue only batches');
    return tx.posts.length;
  }

  test('locked hour, a packet every 10 s: 60 s cadence by default, 5 min Balanced, 15 min Saver', () {
    expect(postsInLockedHour(null), inInclusiveRange(55, 62));
    expect(postsInLockedHour(const Duration(minutes: 5)), inInclusiveRange(11, 14));
    expect(postsInLockedHour(const Duration(minutes: 15)), inInclusiveRange(4, 6));
  });

  test('the foreground cadence is unchanged by the background setting', () {
    final tx = _Tx();
    fakeAsync((async) {
      final start = DateTime.utc(2026, 11, 17, 12);
      DateTime t() => start.add(async.elapsed);
      final u = make(tx, t, bg: const Duration(minutes: 15));
      u.add(rec(t(), 1));
      async.elapse(const Duration(seconds: 6));
      expect(tx.posts, hasLength(1));
      unawaited(u.dispose());
      async.flushMicrotasks();
    });
  });

  test('onBatchSent runs after every accepted batch and lastSuccessAt is set', () async {
    final tx = _Tx();
    var n = 0;
    final at = DateTime.utc(2026, 11, 17, 12);
    final u = make(tx, () => at, auto: false, onSent: () => n++);
    u.add(rec(at.subtract(const Duration(seconds: 2)), 1));
    await u.flush();
    expect(n, 1);
    expect(u.lastSuccessAt, at);
    tx.results.add(const TelemetryHttpResult(503));
    u.add(rec(at.subtract(const Duration(seconds: 1)), 2));
    await u.flush();
    expect(n, 1, reason: 'a refused batch is not a sent one');
  });

  group('A9 queue file', () {
    late Directory dir;
    late File qf;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('telemetry_save');
      qf = File('${dir.path}/q.json');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    int onDisk() => (jsonDecode(qf.readAsStringSync())['records'] as List).length;

    test('rewritten at most every 30 s; written at once on going behind and on dispose', () async {
      final tx = _Tx();
      var clock = DateTime.utc(2026, 11, 17, 12);
      final u = make(tx, () => clock, file: qf, auto: false);
      tx.results.addAll(List.filled(10, const TelemetryHttpResult(503)));
      u.add(rec(clock.subtract(const Duration(seconds: 1)), 1));
      await u.flush(); // fails: the first save writes at once
      expect(onDisk(), 1);
      clock = clock.add(const Duration(seconds: 5));
      u.add(rec(clock, 2));
      await u.flush();
      expect(onDisk(), 1, reason: 'within 30 s of the last write: deferred');
      clock = clock.add(const Duration(seconds: 26));
      u.add(rec(clock, 3));
      await u.flush();
      expect(onDisk(), 3, reason: '30 s passed: written');
      clock = clock.add(const Duration(seconds: 2));
      u.add(rec(clock, 4));
      await u.flush();
      expect(onDisk(), 3);
      u.foreground = false;
      // The write is async: wait for it (up to 2 s, so a loaded full-suite run cannot fail it on timing).
      for (var i = 0; i < 40 && onDisk() != 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(onDisk(), 4, reason: 'going behind writes at once');
      u.add(rec(clock, 5));
      await u.flush();
      await u.dispose();
      expect(onDisk(), 5, reason: 'dispose writes what waits');
    });

    test('an emptied queue removes the file at once', () async {
      final tx = _Tx();
      var clock = DateTime.utc(2026, 11, 17, 12);
      final u = make(tx, () => clock, file: qf, auto: false);
      tx.results.add(const TelemetryHttpResult(503));
      u.add(rec(clock.subtract(const Duration(seconds: 1)), 1));
      await u.flush();
      expect(qf.existsSync(), isTrue);
      clock = clock.add(const Duration(minutes: 2)); // past the backoff, but well inside nothing else
      await u.flush();
      expect(u.queued, 0);
      expect(qf.existsSync(), isFalse);
      await u.dispose();
    });
  });
}
