// Settings > Data & storage accounting (lib/core/storage_usage.dart) and the clear hooks it relies on.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/region_cache.dart';
import 'package:meshsonar/core/repeater_directory.dart';
import 'package:meshsonar/core/storage_usage.dart';

SessionSummary sum(String id,
        {bool ended = true, int pings = 3, int synced = 3, int rejected = 0, bool resend = false}) =>
    SessionSummary(
      session: DriveSession(
          id: id, startedAt: DateTime.utc(2026, 10, 1), endedAt: ended ? DateTime.utc(2026, 10, 1, 1) : null),
      pingCount: pings,
      heardCount: 0,
      syncedCount: synced,
      rejectedCount: rejected,
      sessionResendPending: resend,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ms_storage_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('driveSafeToRemove: only drives the server fully has', () {
    test('fully uploaded and ended: safe', () => expect(driveSafeToRemove(sum('a')), isTrue));
    test('empty ended drive: safe (nothing to lose)', () => expect(driveSafeToRemove(sum('a', pings: 0, synced: 0)), isTrue));
    test('pings waiting: kept', () => expect(driveSafeToRemove(sum('a', synced: 2)), isFalse));
    test('rejected pings exist only here: kept', () => expect(driveSafeToRemove(sum('a', synced: 2, rejected: 1)), isFalse));
    test('a rename not yet sent: kept', () => expect(driveSafeToRemove(sum('a', resend: true)), isFalse));
    test('not ended (crash or still open): kept', () => expect(driveSafeToRemove(sum('a', ended: false)), isFalse));
    test('the drive being recorded: kept', () => expect(driveSafeToRemove(sum('a'), recordingId: 'a'), isFalse));
  });

  test('splitDrives counts the kept drives and the pings the server lacks', () {
    final s = splitDrives([sum('up'), sum('wait', synced: 1), sum('rej', synced: 2, rejected: 1), sum('empty', pings: 0, synced: 0)]);
    expect(s.removable, ['up', 'empty']);
    expect(s.kept, 2);
    expect(s.keptUnsentPings, 2 + 1);
    expect(s.total, 4);
  });

  test('formatStorageBytes', () {
    expect(formatStorageBytes(0), '0 B');
    expect(formatStorageBytes(1023), '1023 B');
    expect(formatStorageBytes(2048), '2 KB');
    expect(formatStorageBytes(3 * 1024 * 1024 + 400 * 1024), '3.4 MB');
    expect(formatStorageBytes(250 * 1024 * 1024), '250 MB');
    expect(formatStorageBytes(5 * 1024 * 1024 * 1024 ~/ 4), '1.25 GB');
  });

  test('bytesOnDisk: files, folders, filters, and missing paths never throw', () async {
    File('${tmp.path}/a.json').writeAsStringSync('x' * 100);
    Directory('${tmp.path}/sub').createSync();
    File('${tmp.path}/sub/b.txt').writeAsStringSync('y' * 50);
    expect(await bytesOnDisk(tmp), 150);
    expect(await bytesOnDisk(tmp, where: (p) => p.endsWith('.json')), 100);
    expect(await bytesOnDisk(File('${tmp.path}/a.json')), 100);
    expect(await bytesOnDisk(File('${tmp.path}/missing')), 0);
    expect(await bytesOnDisk(Directory('${tmp.path}/missing')), 0);
  });

  test('JsonlDriveStore reports the bytes its drives use', () async {
    final store = await JsonlDriveStore.open(tmp);
    expect(await store.bytesUsed(), 0);
    await store.startSession(DriveSession(id: 's1', startedAt: DateTime.utc(2026, 10, 1)));
    await store.appendPing('s1', DrivePing(id: 'p1', ts: DateTime.utc(2026, 10, 1), lat: 40, lon: -83));
    expect(await store.bytesUsed(), greaterThan(0));
    expect(store, isA<StorageSized>());
  });

  test('RegionCache: bytesUsed counts only its entries; clear removes them and the next fetch downloads again', () async {
    final c = RegionCache(tmp);
    File('${tmp.path}/unrelated.bin').writeAsStringSync('z' * 500);
    await c.put('cmh/site-config', '{"a":1}', etag: 'e1');
    await c.put('day/coverage', '{"b":2}');
    final used = await c.bytesUsed();
    expect(used, greaterThan(0));
    expect(used, lessThan(500), reason: 'files that are not cache entries are not counted');
    expect(await c.clear(), 2);
    expect(await c.bytesUsed(), 0);
    expect(File('${tmp.path}/unrelated.bin').existsSync(), isTrue, reason: 'clear touches only its own files');
    String? sentEtag = 'unset';
    final got = await c.fetch('cmh/site-config', (etag) async {
      sentEtag = etag;
      return const CacheFetch.fresh('{"a":2}', etag: 'e2');
    });
    expect(sentEtag, isNull, reason: 'no ETag after a clear: a full download');
    expect(got!.body, '{"a":2}');
    expect(await RegionCache(Directory('${tmp.path}/none')).clear(), 0);
  });

  test('RepeaterDirectory.clear forgets the snapshot and deletes the file', () async {
    final f = File('${tmp.path}/node_directory.json')..writeAsStringSync('{}');
    final d = RepeaterDirectory(cacheFile: f);
    await d.clear();
    expect(f.existsSync(), isFalse);
    expect(d.snapshot, isNull);
    await d.clear(); // twice is fine
  });
}
