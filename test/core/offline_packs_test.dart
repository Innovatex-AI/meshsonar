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
}
