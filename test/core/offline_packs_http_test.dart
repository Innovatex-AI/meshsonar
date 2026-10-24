// OfflinePackManager against a REAL local HTTP server (dart:io HttpServer, Range support) serving the REAL CMH pack:
// full download + SHA-256, connection killed mid-way then resumed from .part, a server that ignores Range, checksum
// mismatch, full disk, stalled transfer, Wi-Fi-only pause/resume, resume after a restart, manifest ETag/304 cache.
// Skips when the 53 MB pack is not on this machine (test/support/real_pack.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/core/offline_packs.dart';
import 'package:meshsonar/core/pmtiles_reader.dart';

import '../support/real_pack.dart';

/// Serves one file at /pack.pmtiles and a manifest at /manifest.json.
class PackServer {
  final Uint8List data;
  late HttpServer _s;
  bool honorRange = true;
  int? killAfter; // close the connection after this many body bytes (once)
  int? stallAfter; // send this many body bytes, then go silent (once)
  final ranges = <String?>[];
  final manifestIfNoneMatch = <String?>[];
  String manifestBody = '{"packs":[]}';
  String manifestEtag = '"m1"';
  PackServer(this.data);

  Uri get packUri => Uri.parse('http://127.0.0.1:${_s.port}/pack.pmtiles');
  Uri get manifestUri => Uri.parse('http://127.0.0.1:${_s.port}/manifest.json');

  Future<void> start() async {
    _s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _s.listen(_handle);
  }

  Future<void> close() => _s.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (req.uri.path == '/manifest.json') {
      final inm = req.headers.value('if-none-match');
      manifestIfNoneMatch.add(inm);
      if (inm == manifestEtag) {
        res.statusCode = 304;
        await res.close();
        return;
      }
      res.headers.set('etag', manifestEtag);
      res.write(manifestBody);
      await res.close();
      return;
    }
    final range = req.headers.value('range');
    ranges.add(range);
    var start = 0;
    final m = range == null ? null : RegExp(r'bytes=(\d+)-').firstMatch(range);
    if (honorRange && m != null) {
      start = int.parse(m.group(1)!);
      res.statusCode = 206;
      res.headers.set('content-range', 'bytes $start-${data.length - 1}/${data.length}');
    }
    res.headers.set('accept-ranges', 'bytes');
    res.contentLength = data.length - start;
    final kill = killAfter, stall = stallAfter;
    if (kill != null || stall != null) {
      killAfter = null;
      stallAfter = null;
      final sock = await res.detachSocket();
      final n = (kill ?? stall)!;
      sock.add(data.sublist(start, start + n));
      await sock.flush();
      if (kill != null) {
        sock.destroy();
      } else {
        await Future<void>.delayed(const Duration(seconds: 5));
        sock.destroy();
      }
      return;
    }
    res.add(data.sublist(start));
    await res.close();
  }
}

/// An IOSink that writes to [inner] until [limit] bytes, then fails like a full disk (ENOSPC).
class FullDiskSink implements IOSink {
  final IOSink inner;
  int left;
  FullDiskSink(this.inner, this.left);
  @override
  void add(List<int> data) {
    if (data.length > left) {
      inner.add(data.sublist(0, left));
      left = 0;
      throw const FileSystemException('write failed', '/x', OSError('No space left on device', 28));
    }
    left -= data.length;
    inner.add(data);
  }

  @override
  Future<void> flush() => inner.flush();
  @override
  Future<void> close() => inner.close();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  final skip = realPackSkip;
  late Uint8List data;
  late PackServer server;
  late Directory tmp;
  late http.Client client;

  setUpAll(() {
    if (skip == false) data = realPackFile()!.readAsBytesSync();
  });
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('packhttp');
    client = http.Client();
    if (skip != false) return;
    server = PackServer(data);
    await server.start();
  });
  tearDown(() async {
    client.close();
    if (skip == false) await server.close();
    tmp.deleteSync(recursive: true);
  });

  PackManifestEntry entry({String sha = realPackSha256, int version = 261024}) => PackManifestEntry(
    code: 'CMH',
    name: 'CMH',
    version: version,
    bytes: realPackBytes,
    sha256: sha,
    url: server.packUri,
    bbox: realPackBbox,
    minZoom: 0,
    maxZoom: 14,
  );

  OfflinePackManager mgr({IOSink Function(File, FileMode)? openSink, Duration idle = const Duration(seconds: 30)}) =>
      OfflinePackManager(root: Directory('${tmp.path}/p'), client: client, manifestUri: server.manifestUri, openSink: openSink, idleTimeout: idle);

  File part() => File('${tmp.path}/p/CMH.pmtiles.part');

  test('full download: size + SHA-256 verified, installed, and the installed file reads as PMTiles', () async {
    final m = mgr();
    await m.load();
    await m.download(entry());
    expect(m.active, isEmpty);
    expect(m.installed['CMH']!.version, 261024);
    expect(m.pending, isEmpty);
    expect(part().existsSync(), isFalse);
    expect(sha256.convert(await m.packFile('CMH').readAsBytes()).toString(), realPackSha256);
    final r = await PmtilesReader.open(m.packFile('CMH'));
    expect(await r.tile(14, 4414, 6205), isNotNull);
    await r.close();
    expect(server.ranges, [null]);
  }, skip: skip);

  test('connection killed mid-way: .part kept, retryable; resume sends Range from the kept size and verifies', () async {
    server.killAfter = 20 * 1024 * 1024;
    final m = mgr();
    await m.load();
    await m.download(entry());
    final p = m.active['CMH']!;
    expect(p.phase, PackPhase.failed);
    expect(p.error, contains('kept'));
    final kept = part().lengthSync();
    expect(kept, 20 * 1024 * 1024);
    expect(m.pending.keys, ['CMH']); // the user still wants it
    // What OfflineBasemap does on return to the foreground / network change:
    expect(await m.resumePending(NetworkKind.wifi), 1);
    for (var i = 0; i < 200 && m.installed.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(server.ranges.last, 'bytes=$kept-');
    expect(m.installed['CMH'], isNotNull);
    expect(sha256.convert(await m.packFile('CMH').readAsBytes()).toString(), realPackSha256);
  }, skip: skip);

  test('a server that ignores Range (200 to a Range request) restarts from zero and still verifies', () async {
    server.killAfter = 5 * 1024 * 1024;
    final m = mgr();
    await m.load();
    await m.download(entry());
    expect(part().lengthSync(), 5 * 1024 * 1024);
    server.honorRange = false;
    await m.download(entry());
    expect(server.ranges.last, 'bytes=${5 * 1024 * 1024}-'); // asked to resume...
    expect(m.installed['CMH'], isNotNull); // ...got the whole file and did not append it to the part
    expect(sha256.convert(await m.packFile('CMH').readAsBytes()).toString(), realPackSha256);
  }, skip: skip);

  test('checksum mismatch: nothing installed, .part deleted, not retried automatically', () async {
    final m = mgr();
    await m.load();
    await m.download(entry(sha: 'f' * 64));
    expect(m.installed, isEmpty);
    expect(m.active['CMH']!.phase, PackPhase.failed);
    expect(m.active['CMH']!.error, contains('checksum'));
    expect(part().existsSync(), isFalse);
    expect(m.pending, isEmpty);
    expect(await m.resumePending(NetworkKind.wifi), 0);
  }, skip: skip);

  test('full disk (ENOSPC): honest message, .part kept for a Retry, not retried automatically', () async {
    final m = mgr(openSink: (f, mode) => FullDiskSink(f.openWrite(mode: mode), 3 * 1024 * 1024));
    await m.load();
    await m.download(entry());
    final p = m.active['CMH']!;
    expect(p.phase, PackPhase.failed);
    expect(p.error, startsWith('Not enough free space on this device'));
    expect(part().lengthSync(), 3 * 1024 * 1024);
    expect(await m.resumePending(NetworkKind.wifi), 0);
    // Space freed: Retry resumes.
    final ok = mgr();
    await ok.load();
    await ok.download(entry());
    expect(server.ranges.last, 'bytes=${3 * 1024 * 1024}-');
    expect(ok.installed['CMH'], isNotNull);
  }, skip: skip);

  test('a stalled transfer fails after the idle timeout instead of spinning forever', () async {
    server.stallAfter = 1024 * 1024;
    final m = mgr(idle: const Duration(milliseconds: 800));
    await m.load();
    await m.download(entry());
    expect(m.active['CMH']!.phase, PackPhase.failed);
    expect(m.active['CMH']!.error, contains('stalled'));
    expect(part().lengthSync(), 1024 * 1024);
  }, skip: skip);

  test('a .part left by another version is discarded, never appended to', () async {
    server.killAfter = 2 * 1024 * 1024;
    final m = mgr();
    await m.load();
    await m.download(entry(version: 1, sha: 'a' * 64)); // an older version's partial download
    expect(part().lengthSync(), 2 * 1024 * 1024);
    await m.download(entry());
    expect(server.ranges.last, isNull); // fresh request, no Range
    expect(m.installed['CMH']!.version, 261024);
  }, skip: skip);

  test('Wi-Fi only: dropping to cellular pauses (waiting, .part kept); Wi-Fi again resumes and finishes', () async {
    final m = mgr();
    await m.load();
    expect(await m.start(entry(), NetworkKind.cellular), StartResult.needsCellularConsent);
    expect(m.active, isEmpty);
    expect(await m.start(entry(), NetworkKind.wifi), StartResult.started);
    for (var i = 0; i < 400 && (m.active['CMH']?.received ?? 0) < 4 * 1024 * 1024; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await m.onNetwork(NetworkKind.cellular);
    for (var i = 0; i < 200 && m.active['CMH']?.phase != PackPhase.waiting && m.installed.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (m.installed.isNotEmpty) {
      markTestSkipped('localhost finished the 53 MB before the network flip landed');
      return;
    }
    expect(m.active['CMH']!.phase, PackPhase.waiting);
    final kept = part().lengthSync();
    expect(kept, greaterThan(0));
    await m.onNetwork(NetworkKind.wifi);
    for (var i = 0; i < 400 && m.installed.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(server.ranges.last, 'bytes=$kept-');
    expect(m.installed['CMH'], isNotNull);
  }, skip: skip);

  test('a download interrupted by quitting the app resumes after a restart (pending is persisted)', () async {
    server.killAfter = 8 * 1024 * 1024;
    final m = mgr();
    await m.load();
    await m.download(entry());
    m.dispose();
    final relaunched = mgr();
    await relaunched.load();
    expect(relaunched.pending.keys, ['CMH']);
    expect(relaunched.active['CMH']!.phase, PackPhase.waiting);
    expect(relaunched.active['CMH']!.received, 8 * 1024 * 1024);
    expect(await relaunched.resumePending(NetworkKind.cellular), 0); // Wi-Fi only: waits
    expect(await relaunched.resumePending(NetworkKind.wifi), 1);
    for (var i = 0; i < 400 && relaunched.installed.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(server.ranges.last, 'bytes=${8 * 1024 * 1024}-');
    expect(relaunched.installed['CMH'], isNotNull);
  }, skip: skip);

  test('user pause is not resumed automatically', () async {
    final m = mgr();
    await m.load();
    unawaited(m.download(entry()));
    for (var i = 0; i < 400 && (m.active['CMH']?.received ?? 0) < 2 * 1024 * 1024; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await m.cancel('CMH');
    for (var i = 0; i < 200 && m.active.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (m.installed.isNotEmpty) {
      markTestSkipped('localhost finished before the pause landed');
      return;
    }
    expect(m.pending, isEmpty);
    expect(await m.resumePending(NetworkKind.wifi), 0);
  }, skip: skip);

  test('manifest: ETag sent back as If-None-Match, 304 reuses the saved copy, offline serves it marked fromCache', () async {
    // (Pack entries need an https URL on the manifest host, which a loopback server cannot be; the attribution proves
    // which body came back. Entry parsing is covered in offline_packs_test.dart.)
    server.manifestBody = jsonEncode({'attribution': '(c) OpenStreetMap contributors [local]', 'packs': []});
    final m = mgr();
    await m.load();
    final first = await m.fetchManifest();
    expect(server.manifestIfNoneMatch, [null]);
    expect(first.fromCache, isFalse);
    final second = await m.fetchManifest();
    expect(server.manifestIfNoneMatch.last, '"m1"');
    expect(second.fromCache, isFalse);
    expect(second.attribution, '(c) OpenStreetMap contributors [local]');
    await server.close();
    final offline = await m.fetchManifest();
    expect(offline.fromCache, isTrue);
    expect(offline.fetchedAt, isNotNull);
    expect(offline.attribution, '(c) OpenStreetMap contributors [local]');
    await server.start(); // tearDown closes it again
  }, skip: skip);
}
