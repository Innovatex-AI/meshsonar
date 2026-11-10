// M2 offline packs (core/offline_packs.dart): packs cut from our Protomaps tiles (schema "protomaps") with a coverage snapshot
// (Measured + Predicted) per region; the snapshot is size- and SHA-checked and never replaces a good one with a bad one; it is
// refreshed at most every 12 h; pre-M2 packs keep working; the pre-M2 manifest is read while the M2 one is not published.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/offline_packs.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/ui/settings/offline_packs_screen.dart' show noPackNote;

final newManifest = Uri.parse(defaultPackManifestUrl);
final basemap = Uint8List.fromList(List.generate(4000, (i) => i % 251));
final cov1 = Uint8List.fromList(List.generate(900, (i) => (i * 7) % 256));
final cov2 = Uint8List.fromList(List.generate(950, (i) => (i * 11) % 256));
String sha(List<int> b) => sha256.convert(b).toString();

Map<String, dynamic> m2Entry({Uint8List? cov, int covVersion = 227, String? covSha}) => {
  'code': 'CMH',
  'name': 'Columbus, US',
  'version': 261108,
  'bytes': basemap.length,
  'sha256': sha(basemap),
  'url': 'CMH-p261108.pmtiles',
  'bbox': [-83.6534, 39.3613, -82.0242, 40.7127],
  'min_zoom': 0,
  'max_zoom': 14,
  'schema': 'protomaps',
  if (cov != null)
    'coverage': {'url': 'CMH-cov-sf7bw62_5-v$covVersion.pmtiles', 'bytes': cov.length, 'sha256': covSha ?? sha(cov), 'version': covVersion, 'preset': 'sf7bw62.5'},
};

String manifest(List<Map<String, dynamic>> packs) => jsonEncode({'attribution': 'Protomaps © OpenStreetMap contributors', 'packs': packs});

void main() {
  // Plan §8d (Nov 10 2026): packs build automatically for every region with coverage inside the NA extract (24 that day). The
  // live manifest parses whole (every entry protomaps, with coverage); a region outside it (SEA, AAH) has no entry and the app
  // keeps the online map there.
  test('the all-regions manifest (24 packs, Nov 10) parses whole; regions without a pack have no entry', () {
    final m = PackManifest.parse(
      File('test/fixtures/packs/manifest-2026-11-10.json').readAsStringSync(),
      Uri.parse('https://api.meshsonar.com/basemap/packs/manifest.json'),
    );
    expect(m.packs, hasLength(24));
    expect(m.packs.every((p) => p.schema == PackSchema.protomaps && p.coverage != null), isTrue);
    expect(m.packs.map((p) => p.code), containsAll(['CMH', 'DAY', 'CVG', 'ORD', 'PHX']));
    expect(m.packs.map((p) => p.code), isNot(contains('SEA')));
    expect(m.packs.map((p) => p.code), isNot(contains('AAH')));
    final codes = [for (final p in m.packs) p.code];
    const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.65, 39.36, -82.02, 40.71]);
    const sea = RegionIndexEntry(code: 'SEA', slug: 'sea', name: 'Seattle, US', url: 'https://sea.meshsonar.com', bbox: [-124.85, 46.23, -121.07, 48.5]);
    const aah = RegionIndexEntry(code: 'AAH', slug: 'aah', name: 'Aachen, DE', url: 'https://aah.meshsonar.com', bbox: [5.97, 50.49, 6.42, 50.95]);
    expect(noPackNote(cmh, codes), isNull, reason: 'CMH has a pack');
    expect(noPackNote(sea, codes), contains('built once the region has coverage'), reason: 'inside the NA extract, no coverage yet');
    expect(noPackNote(aah, codes), contains('North America only'));
    expect(noPackNote(null, codes), isNull);
  });

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('packs-m2'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the M2 manifest is on our basemap host; schema and coverage parse; a foreign-host coverage is ignored', () {
    expect(newManifest.toString(), 'https://api.meshsonar.com/basemap/packs/manifest.json');
    final m = PackManifest.parse(manifest([m2Entry(cov: cov1)]), newManifest);
    final e = m.packs.single;
    expect(e.schema, PackSchema.protomaps);
    expect(e.url.toString(), 'https://api.meshsonar.com/basemap/packs/CMH-p261108.pmtiles');
    expect(e.coverage!.url.toString(), 'https://api.meshsonar.com/basemap/packs/CMH-cov-sf7bw62_5-v227.pmtiles');
    expect(e.coverage!.preset, 'sf7bw62.5');
    final bad = m2Entry(cov: cov1)..['coverage'] = {...(m2Entry(cov: cov1)['coverage'] as Map), 'url': 'https://evil.example/c.pmtiles'};
    expect(PackManifest.parse(manifest([bad]), newManifest).packs.single.coverage, isNull);
    final old = PackManifestEntry.fromJson({...m2Entry()..remove('schema')}, newManifest);
    expect(old.schema, PackSchema.openmaptiles, reason: 'pre-M2 entries have no schema');
  });

  OfflinePackManager mgr(Map<String, Uint8List> files, {List<String>? log, int manifestStatus = 200, String? body}) => OfflinePackManager(
    root: Directory('${tmp.path}/p'),
    client: MockClient((req) async {
      log?.add(req.url.toString());
      final name = req.url.pathSegments.last;
      if (name == 'manifest.json') {
        if (req.url.host == 'api.meshsonar.com') return http.Response.bytes(utf8.encode(body ?? ''), manifestStatus);
        return http.Response.bytes(utf8.encode(manifest([{...m2Entry()..remove('schema')..remove('coverage'), 'url': 'CMH-v1.pmtiles'}])), 200);
      }
      final f = files[name];
      return f == null ? http.Response('', 404) : http.Response.bytes(f, 200);
    }),
  );

  test('install = basemap, then its coverage snapshot; schema and snapshot persisted; delete removes both', () async {
    final m = mgr({'CMH-p261108.pmtiles': basemap, 'CMH-cov-sf7bw62_5-v227.pmtiles': cov1});
    await m.load();
    final e = PackManifestEntry.fromJson(m2Entry(cov: cov1), newManifest);
    await m.download(e);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(m.installed['CMH']!.schema, PackSchema.protomaps);
    expect(m.installed['CMH']!.coverage!.version, 227);
    expect(m.coverageFile('CMH').readAsBytesSync(), cov1);
    expect((await m.bytesByPack())['CMH'], basemap.length + cov1.length);
    final again = mgr({});
    await again.load();
    expect(again.installed['CMH']!.schema, PackSchema.protomaps, reason: 'persisted');
    expect(again.installed['CMH']!.coverage!.sha256, sha(cov1));
    await again.delete('CMH');
    expect(again.coverageFile('CMH').existsSync(), isFalse);
  });

  test('a snapshot that fails its checksum never replaces the good one', () async {
    final m = mgr({'CMH-p261108.pmtiles': basemap, 'CMH-cov-sf7bw62_5-v227.pmtiles': cov1, 'CMH-cov-sf7bw62_5-v228.pmtiles': cov2});
    await m.load();
    await m.download(PackManifestEntry.fromJson(m2Entry(cov: cov1), newManifest));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final broken = PackManifestEntry.fromJson(m2Entry(cov: cov2, covVersion: 228, covSha: sha(cov1)), newManifest);
    expect(await m.downloadCoverage(broken), isFalse);
    expect(m.coverageFile('CMH').readAsBytesSync(), cov1);
    expect(m.installed['CMH']!.coverage!.version, 227);
    final good = PackManifestEntry.fromJson(m2Entry(cov: cov2, covVersion: 228), newManifest);
    expect(await m.downloadCoverage(good), isTrue);
    expect(m.coverageFile('CMH').readAsBytesSync(), cov2);
    expect(m.installed['CMH']!.coverage!.version, 228);
    expect(await m.downloadCoverage(good), isFalse, reason: 'already current');
  });

  test('coverage refresh: at most every 12 h, Wi-Fi rule respected, nothing without installed packs', () async {
    final files = {'CMH-p261108.pmtiles': basemap, 'CMH-cov-sf7bw62_5-v227.pmtiles': cov1, 'CMH-cov-sf7bw62_5-v228.pmtiles': cov2};
    final log = <String>[];
    var body = manifest([m2Entry(cov: cov1)]);
    final m = OfflinePackManager(
      root: Directory('${tmp.path}/p'),
      client: MockClient((req) async {
        log.add(req.url.pathSegments.last);
        if (req.url.pathSegments.last == 'manifest.json') return http.Response.bytes(utf8.encode(body), 200);
        final f = files[req.url.pathSegments.last];
        return f == null ? http.Response('', 404) : http.Response.bytes(f, 200);
      }),
    );
    await m.load();
    final t0 = DateTime.utc(2026, 11, 9, 12);
    expect(await m.refreshCoverageIfStale(NetworkKind.wifi, now: t0), 0);
    expect(log, isEmpty, reason: 'no packs: no request');
    await m.download(PackManifestEntry.fromJson(m2Entry(cov: cov1), newManifest));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    body = manifest([m2Entry(cov: cov2, covVersion: 228)]);
    log.clear();
    expect(await m.refreshCoverageIfStale(NetworkKind.cellular, now: t0), 0);
    expect(m.installed['CMH']!.coverage!.version, 227, reason: 'Wi-Fi only (default) on cellular: manifest read, no download');
    expect(await m.refreshCoverageIfStale(NetworkKind.wifi, now: t0.add(const Duration(hours: 1))), 0, reason: 'checked 1 h ago');
    expect(await m.refreshCoverageIfStale(NetworkKind.wifi, now: t0.add(const Duration(hours: 13))), 1);
    expect(m.installed['CMH']!.coverage!.version, 228);
  });

  test('while the M2 manifest is not published, the pre-M2 one keeps the packs screen working', () async {
    final m = mgr({}, manifestStatus: 404);
    await m.load();
    final man = await m.fetchManifest();
    expect(man.packs.single.code, 'CMH');
    expect(man.packs.single.url.host, 'tiles.meshsonar.com');
    expect(man.packs.single.schema, PackSchema.openmaptiles);
    // and from the saved copy with no network, still resolved against its own host
    final offline = OfflinePackManager(root: Directory('${tmp.path}/p'), client: MockClient((_) async => throw http.ClientException('offline')));
    await offline.load();
    final cached = await offline.fetchManifest();
    expect(cached.fromCache, isTrue);
    expect(cached.packs.single.url.host, 'tiles.meshsonar.com');
  });

  test('once the M2 manifest answers, it wins', () async {
    final m = mgr({}, body: manifest([m2Entry(cov: cov1)]));
    await m.load();
    final man = await m.fetchManifest();
    expect(man.packs.single.schema, PackSchema.protomaps);
    expect(man.packs.single.url.host, 'api.meshsonar.com');
  });
}
