import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/offline_packs.dart';

final manifestUri = Uri.parse('https://tiles.meshsonar.com/manifest.json');
final body = Uint8List.fromList(List.generate(5000, (i) => i % 251));
final goodSha = sha256.convert(body).toString();

Map<String, dynamic> entryJson({String? sha, String url = 'cmh-v1.pmtiles', int version = 1}) => {
  'code': 'cmh',
  'name': 'Columbus',
  'version': version,
  'bytes': body.length,
  'sha256': sha ?? goodSha,
  'url': url,
  'bbox': [-83.65, 39.36, -82.02, 40.71],
  'min_zoom': 0,
  'max_zoom': 14,
};

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('packs'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('manifest with the new style fields (style_version, styles, glyphs, fonts) parses exactly like before', () {
    final m = PackManifest.parse(
      jsonEncode({
        'attribution': '(c) OpenStreetMap contributors',
        'packs': [entryJson()],
        'style_version': 4,
        'styles': {'light': 'https://tiles.meshsonar.com/styles/v4/light.json', 'dark': 'https://tiles.meshsonar.com/styles/v4/dark.json'},
        'glyphs': 'https://tiles.meshsonar.com/fonts/{fontstack}/{range}.pbf',
        'fonts': ['Barlow-Regular', 'Barlow-Medium', 'BarlowSemiCondensed-SemiBold'],
      }),
      manifestUri,
    );
    expect(m.packs.single.code, 'CMH');
    expect(m.attribution, '(c) OpenStreetMap contributors');
  });

  test('manifest keeps good entries and drops foreign-host, http and malformed ones', () {
    final m = PackManifest.parse(
      jsonEncode({
        'packs': [
          entryJson(),
          entryJson(url: 'https://evil.example/x.pmtiles'),
          entryJson(url: 'http://meshsonar.com/x.pmtiles'),
          entryJson(sha: 'nothex'),
          {'code': 'x'},
        ],
      }),
      manifestUri,
    );
    expect(m.packs.map((p) => p.code), ['CMH']);
    expect(m.packs.single.url.toString(), 'https://tiles.meshsonar.com/cmh-v1.pmtiles');
    expect(m.packs.single.covers(39.96, -83.0), isTrue);
  });

  PackManifestEntry entry({String? sha, int version = 1}) => PackManifestEntry.fromJson(entryJson(sha: sha, version: version), manifestUri);

  OfflinePackManager mgr(http.Client c) => OfflinePackManager(root: Directory('${tmp.path}/p'), client: c);

  test('download verifies, installs, persists, and delete reclaims', () async {
    final m = mgr(MockClient.streaming((req, _) async => http.StreamedResponse(Stream.value(body), 200)));
    await m.load();
    await m.download(entry());
    expect(m.active, isEmpty);
    expect(m.installed['CMH']!.bytes, body.length);
    expect(await m.usedBytes(), body.length);
    expect(m.packCovering(39.96, -83.0)?.code, 'CMH');
    expect(m.packCovering(0, 0), isNull);
    final again = mgr(MockClient((_) async => http.Response('', 500)));
    await again.load();
    expect(again.installed.keys, ['CMH']); // survives restart
    await again.delete('CMH');
    expect(await again.usedBytes(), 0);
    expect(again.installed, isEmpty);
  });

  test('checksum mismatch discards the file and reports failure', () async {
    final m = mgr(MockClient.streaming((req, _) async => http.StreamedResponse(Stream.value(body), 200)));
    await m.load();
    await m.download(entry(sha: '0' * 64));
    expect(m.installed, isEmpty);
    expect(m.active['CMH']!.phase, PackPhase.failed);
    expect(await m.usedBytes(), 0);
  });

  test('cancel keeps the partial file and the next download resumes with a Range request', () async {
    final ranges = <String?>[];
    late OfflinePackManager m;
    var first = true;
    final c = MockClient.streaming((req, _) async {
      ranges.add(req.headers['range']);
      if (first) {
        first = false;
        Stream<List<int>> gen() async* {
          yield body.sublist(0, 2000);
          m.cancel('CMH'); // user pauses after the first chunk
          yield body.sublist(2000, 2500);
          yield body.sublist(2500);
        }

        return http.StreamedResponse(gen(), 200);
      }
      final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(req.headers['range']!)!.group(1)!);
      return http.StreamedResponse(Stream.value(body.sublist(start)), 206);
    });
    m = mgr(c);
    await m.load();
    final e = entry();
    await m.download(e);
    expect(m.installed, isEmpty);
    expect(m.active, isEmpty);
    expect(await m.usedBytes(), 2000); // partial kept
    await m.download(e);
    expect(ranges.last, 'bytes=2000-');
    expect(m.installed['CMH'], isNotNull);
    expect(sha256.convert(await m.packFile('CMH').readAsBytes()).toString(), goodSha);
  });

  test('a server that ignores Range (200) restarts cleanly', () async {
    final m = mgr(MockClient.streaming((req, _) async => http.StreamedResponse(Stream.value(body), 200)));
    await m.load();
    File('${tmp.path}/p/CMH.pmtiles.part').writeAsBytesSync(Uint8List.fromList([7, 7, 7]));
    await m.download(entry());
    expect(m.installed['CMH'], isNotNull);
  });

  test('HTTP error is a failure state, not an exception; update detection', () async {
    final m = mgr(MockClient.streaming((req, _) async => http.StreamedResponse(const Stream.empty(), 404)));
    await m.load();
    await m.download(entry());
    expect(m.active['CMH']!.phase, PackPhase.failed);
    m.dismissError('CMH');
    expect(m.active, isEmpty);
    final ok = mgr(MockClient.streaming((req, _) async => http.StreamedResponse(Stream.value(body), 200)));
    await ok.load();
    await ok.download(entry());
    expect(ok.updateAvailable(entry(version: 2)), isTrue);
    expect(ok.updateAvailable(entry(version: 1)), isFalse);
  });

  test('manifest: ETag round trip, 304 reuses the saved copy, offline returns it marked fromCache, nothing saved throws', () async {
    final seen = <String?>[];
    var down = false;
    final body = jsonEncode({
      'packs': [entryJson()],
    });
    final c = MockClient((req) async {
      if (down) throw const SocketException('offline');
      seen.add(req.headers['if-none-match']);
      if (req.headers['if-none-match'] == '"v1"') return http.Response('', 304);
      return http.Response(body, 200, headers: {'etag': '"v1"'});
    });
    final m = OfflinePackManager(root: Directory('${tmp.path}/p'), client: c, manifestUri: manifestUri);
    await m.load();
    final a = await m.fetchManifest();
    expect(a.packs.single.code, 'CMH');
    expect(a.fromCache, isFalse);
    final b = await m.fetchManifest();
    expect(seen, [null, '"v1"']);
    expect(b.packs.single.code, 'CMH');
    down = true;
    final off = await m.fetchManifest();
    expect(off.fromCache, isTrue);
    expect(off.packs.single.code, 'CMH');
    expect(off.fetchedAt, isNotNull);
    final empty = OfflinePackManager(root: Directory('${tmp.path}/q'), client: c, manifestUri: manifestUri);
    await empty.load();
    expect(empty.fetchManifest(), throwsA(isA<SocketException>()));
  });

  test('policy: Wi-Fi only asks on cellular, queues offline, persists the queue and the switch across restarts', () async {
    final m = mgr(MockClient.streaming((req, _) async => http.StreamedResponse(Stream.value(body), 200)));
    await m.load();
    expect(m.wifiOnly, isTrue);
    expect(await m.start(entry(), NetworkKind.cellular), StartResult.needsCellularConsent);
    expect(await m.start(entry(), NetworkKind.unknown), StartResult.needsCellularConsent);
    expect(m.active, isEmpty);
    expect(await m.start(entry(), NetworkKind.offline), StartResult.offline);
    expect(m.active['CMH']!.phase, PackPhase.waiting);
    final again = mgr(MockClient.streaming((req, _) async => http.StreamedResponse(Stream.value(body), 200)));
    await again.load();
    expect(again.pending.keys, ['CMH']);
    expect(again.pending['CMH']!.url.toString(), 'https://tiles.meshsonar.com/cmh-v1.pmtiles');
    expect(again.active['CMH']!.phase, PackPhase.waiting);
    expect(await again.resumePending(NetworkKind.cellular), 0);
    again.allowCellular('CMH');
    expect(await again.resumePending(NetworkKind.cellular), 1);
    for (var i = 0; i < 100 && again.installed.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(again.installed.keys, ['CMH']);
    expect(again.pending, isEmpty);
    await again.setWifiOnly(false);
    final third = mgr(MockClient((_) async => http.Response('', 404)));
    await third.load();
    expect(third.wifiOnly, isFalse);
    expect(third.pending, isEmpty);
  });

  test('deleteAll removes packs, partials, sidecars and strays; bytesByPack counts per code', () async {
    final m = mgr(MockClient.streaming((req, _) async => http.StreamedResponse(Stream.value(body), 200)));
    await m.load();
    await m.download(entry());
    File('${tmp.path}/p/DAY.pmtiles.part').writeAsBytesSync(List.filled(100, 1));
    File('${tmp.path}/p/DAY.pmtiles.part.json').writeAsStringSync('{}');
    File('${tmp.path}/p/OLD.pmtiles').writeAsBytesSync(List.filled(10, 1));
    expect(await m.bytesByPack(), {'CMH': body.length, 'DAY': 100, 'OLD': 10});
    await m.deleteAll();
    expect(m.installed, isEmpty);
    expect(await m.usedBytes(), 0);
    expect(Directory('${tmp.path}/p').listSync().map((f) => f.uri.pathSegments.last).where((n) => n.contains('.pmtiles')), isEmpty);
  });

  test('packCovering: smallest box wins, equal boxes tie-break by code, a filter can exclude packs', () async {
    final root = Directory('${tmp.path}/p')..createSync(recursive: true);
    Map<String, dynamic> ip(List<double> b) => {'name': 'x', 'version': 1, 'bytes': 1, 'sha256': '0' * 64, 'bbox': b, 'installed_at': '2026-10-24T00:00:00Z'};
    File('${root.path}/packs.json').writeAsStringSync(jsonEncode({
      'BIG': ip([-85.0, 38.0, -80.0, 42.0]),
      'BBB': ip([-84.0, 39.0, -82.0, 41.0]),
      'AAA': ip([-84.0, 39.0, -82.0, 41.0]),
    }));
    for (final c in ['BIG', 'BBB', 'AAA']) {
      File('${root.path}/$c.pmtiles').writeAsBytesSync([0]);
    }
    final m = mgr(MockClient((_) async => http.Response('', 404)));
    await m.load();
    expect(m.packCovering(40, -83)?.code, 'AAA');
    expect(m.packCovering(40, -83, where: (c) => c != 'AAA')?.code, 'BBB');
    expect(m.packCovering(38.5, -84.5)?.code, 'BIG');
    expect(m.packCovering(50, 0), isNull);
  });

  test('storage accounting never throws while files are renamed or deleted under it (the old screen-test flake)', () async {
    final m = mgr(MockClient((_) async => http.Response('', 404)));
    expect(await m.usedBytes(), 0); // folder does not exist yet
    await m.load();
    final dir = Directory('${tmp.path}/p');
    var stop = false;
    final churn = () async {
      var i = 0;
      while (!stop) {
        final part = File('${dir.path}/X$i.pmtiles.part')..writeAsBytesSync(List.filled(64, 1));
        await part.rename('${dir.path}/X$i.pmtiles'); // what a finished download does
        await File('${dir.path}/X$i.pmtiles').delete(); // what delete does
        i++;
      }
    }();
    for (var k = 0; k < 300; k++) {
      await m.usedBytes();
      await m.bytesByPack();
    }
    stop = true;
    await churn;
    dir.deleteSync(recursive: true);
    expect(await m.usedBytes(), 0); // folder removed (test teardown) -> 0, not PathNotFoundException
  });
}
