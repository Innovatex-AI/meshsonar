// AC-12, static half (spec m1-app-0.4.0 §5): every http(s) host written in lib/ is on the allow-list, and only the
// two HTTP clients (CMAT client, public node map) create an HTTP client. The dynamic half is hosts_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/server_url.dart';
import 'package:path/path.dart' as p;

/// The MeshSonar server's addresses (0.5.0: the default https://meshsonar.com plus the aliases in
/// lib/core/server_url.dart, kept equal to [sameServerHosts] by the test below), the public node map, and
/// our basemap (api.meshsonar.com/basemap) with the OpenFreeMap fallback (tiles.openfreemap.org).
const allowedServerHosts = {'meshsonar.com', 'cmh.meshsonar.com', 'cmh-meshcore.lovable.app'};
const allowedLiteralHosts = {...allowedServerHosts, 'map.meshcore.io', 'api.meshsonar.com', 'tiles.openfreemap.org', 'api.meshcore.nz', 'tiles.meshsonar.com', 'open-meteo.com', 'www.openstreetmap.org', 'opendatacommons.org', 'www.esri.com', 'www.usgs.gov', 'creativecommons.org', 'flasher.meshcore.io', 'protomaps.com', 'openfreemap.org'};
// protomaps.com, openfreemap.org: basemap credit LINKS in the Credits sheet, opened in the browser on tap only (M2).
// www.esri.com, www.usgs.gov (M3 Satellite imagery credit LINKS, on tap only; the imagery itself is fetched from the URLs in the Map Definition, never hard-coded here).
// www.openstreetmap.org, opendatacommons.org, creativecommons.org: the map credit LINKS in the Credits sheet (the (i)
// on the map's credit line), opened in the browser on tap only, like open-meteo.com above (Drive WP2 default decision, HANDOFF 105).
// open-meteo.com: the licence credit LINK for server-side weather, opened in the browser on tap only (About, drive report
// Weather block). The app never contacts Open-Meteo; the server does (stream 7 WP6).
// flasher.meshcore.io: the official MeshCore firmware flasher, a LINK opened in the browser on tap only (Device settings >
// Firmware, chat plan 4.14); the app never contacts it and never flashes firmware itself.
// api.meshsonar.com: our basemap tiles + offline packs (core/basemap.dart, core/offline_packs.dart; plan M2). tiles.openfreemap.org:
// the keyless basemap fallback (OpenFreeMap TileJSON + tiles), contacted only when our tiles fail or the view leaves our extract.
// tiles.meshsonar.com stays for the pre-M2 pack manifest (read only while the M2 one is not published).
// coverage_v2.dart: the coverage v2 reads (tiles, cell, meta) go to the configured MeshSonar server only (WP5, Nov 8 2026).
// photo_wire.dart: the photo upload's socket (dart:io HttpClient for real per-chunk progress); it only opens the URL
// HttpCmatClient.endpoint('photo-upload') hands it, i.e. the configured MeshSonar server.
// api.meshcore.nz: read-only MeshCore community radio-preset list (Andy, Oct 21 2026 decision; Radio tab, on tap only).

void main() {
  test('the allow-list matches the alias set, and the default server is one of them', () {
    expect(allowedServerHosts, sameServerHosts);
    expect(retiredServerHosts.difference(sameServerHosts), isEmpty);
    expect(sameServerHosts, contains(Uri.parse(defaultServerUrl).host));
  });

  test('every http(s) host in lib/ is allowed; only cmat_client, repeater_directory and region_repeaters_api make HTTP clients', () {
    final hostRe = RegExp(r'''https?://([A-Za-z0-9.-]+)''');
    final clientRe = RegExp(r'''http\.Client\(|HttpClient\(|IOClient\(|http\.(get|post|put|patch|delete|head|read|readBytes)\(''');
    final hosts = <String, String>{};
    final clients = <String>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      // The generated bundled Map Definition is data (the website's definition, incl. hillshade/sprite URLs the app never
      // fetches); the app reads only its basemap tile URL, which is pinned to OurBasemap by test/core/map_definition_test.dart.
      if (f.path.endsWith('map_definition_bundled.g.dart')) continue;
      final src = f.readAsStringSync();
      for (final m in hostRe.allMatches(src)) {
        hosts[m.group(1)!.toLowerCase()] = f.path;
      }
      if (clientRe.hasMatch(src)) clients.add(p.basename(f.path));
    }
    expect(hosts.keys, containsAll(['map.meshcore.io', 'api.meshsonar.com', 'tiles.openfreemap.org']), reason: 'the scan itself works');
    final unknown = {for (final e in hosts.entries) if (!allowedLiteralHosts.contains(e.key)) e.key: e.value};
    expect(unknown, isEmpty, reason: 'a new host in lib/ needs a spec decision (MeshSonar sends only to its server)');
    expect(clients.difference({'cmat_client.dart', 'repeater_directory.dart', 'region_repeaters_api.dart', 'region_overview_api.dart', 'region_reports_api.dart', 'region_packets_api.dart', 'region_analysis_api.dart', 'repeater_detail_api.dart', 'etag_client.dart', 'region_stats_api.dart', 'region_timeline_api.dart', 'coverage_v2.dart', 'live_stream.dart', 'radio_presets.dart', 'offline_packs.dart', 'offline_basemap.dart', 'repeater_sync.dart', 'tile_source.dart', 'basemap.dart', 'map_definition.dart', 'photo_cache.dart', 'photo_wire.dart'}), isEmpty);
    expect(hosts.keys.where((h) => h.contains('meshmapper')), isEmpty);
  });

  test('no setting or code path names MeshMapper as a destination', () {
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final code = f
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n')
          .toLowerCase();
      expect(code.contains('also_send') || code.contains('alsosend'), isFalse, reason: f.path);
      expect(RegExp(r'meshmapper[a-z_]*(url|endpoint|upload|send)').hasMatch(code), isFalse, reason: f.path);
    }
  });
}
