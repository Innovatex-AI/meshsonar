// Opt-in live check of the hosted offline packs (tiles.meshsonar.com, Cloudflare R2). Skipped unless
// MESHSONAR_LIVE_TILES=1. Fetches the real manifest through OfflinePackManager (same code as the app), then asks for
// the first 127 bytes of each pack with a Range request and parses the PMTiles header: bbox and zooms must match the
// manifest, the server must honour Range (206) since resume depends on it. Downloads ~127 bytes per pack, nothing more.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/core/offline_packs.dart';
import 'package:meshsonar/core/pmtiles_reader.dart';

void main() {
  final skip = Platform.environment['MESHSONAR_LIVE_TILES'] == '1' ? false : 'set MESHSONAR_LIVE_TILES=1';

  test('live manifest parses and every pack header matches it (Range request, 127 bytes)', () async {
    final tmp = Directory.systemTemp.createTempSync('tiles_live');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final client = http.Client();
    addTearDown(client.close);
    final m = OfflinePackManager(root: tmp, client: client);
    final mf = await m.fetchManifest();
    expect(mf.fromCache, isFalse);
    expect(mf.packs, isNotEmpty);
    expect(mf.packs.map((e) => e.code), contains('CMH'));
    for (final e in mf.packs) {
      expect(e.url.host, 'tiles.meshsonar.com');
      final r = await client.get(e.url, headers: {'range': 'bytes=0-126'});
      expect(r.statusCode, 206, reason: '${e.code}: Range must be honoured for resume');
      expect(r.headers['content-range'], 'bytes 0-126/${e.bytes}', reason: e.code);
      final h = PmtilesHeader.parse(Uint8List.fromList(r.bodyBytes));
      expect(h.tileType, PmtilesHeader.typeMvt);
      expect(h.tileCompression, PmtilesHeader.gzip);
      expect([h.minZoom, h.maxZoom], [e.minZoom, e.maxZoom]);
      expect(h.minLon, closeTo(e.bbox[0], 1e-4));
      expect(h.minLat, closeTo(e.bbox[1], 1e-4));
      expect(h.maxLon, closeTo(e.bbox[2], 1e-4));
      expect(h.maxLat, closeTo(e.bbox[3], 1e-4));
    }
    // Second fetch: the saved ETag goes back as If-None-Match (a 304 when unchanged).
    final again = await m.fetchManifest();
    expect(again.packs.length, mf.packs.length);
  }, skip: skip);
}
