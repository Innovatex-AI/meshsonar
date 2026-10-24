// On a simulator/device: downloads the REAL CMH pack through the app's own manager from tiles.meshsonar.com (same
// code path as Settings > Offline maps), then draws it with the app's offline layer over Columbus at z10 and z14 in
// light and dark next to the online OSM map drawn the same way CoverageMap draws it, printing "SCREEN <name>" so scripts/verify_sim.sh (or a person) can screenshot each view.
//   flutter test integration_test/offline_maps_test.dart -d <simulator udid>
// Makes one manifest request and one 53 MB pack download (skipped when the pack is already installed and current).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/offline_basemap.dart';
import 'package:meshsonar/ui/theme.dart';

import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real CMH pack: download, verify, render z10/z14 light/dark', (t) async {
    final basemap = OfflineBasemap.instance;
    final m = await basemap.manager();
    final mf = await m.fetchManifest();
    final cmh = mf.packs.firstWhere((e) => e.code == 'CMH');
    if (m.installed['CMH']?.sha256 != cmh.sha256) {
      final sw = Stopwatch()..start();
      await m.download(cmh);
      // ignore: avoid_print
      print('DOWNLOAD CMH ${cmh.bytes} bytes in ${sw.elapsed.inSeconds}s: ${m.active['CMH']?.error ?? 'ok'}');
    }
    expect(m.installed['CMH']?.sha256, cmh.sha256, reason: 'pack installed and verified');
    // ignore: avoid_print
    print('PACK_FILE ${m.packFile('CMH').path}');
    for (var i = 0; i < 50 && basemap.readerFor('CMH') == null; i++) {
      await pumpFor(t, const Duration(milliseconds: 100));
    }
    final reader = basemap.readerFor('CMH');
    expect(reader, isNotNull);

    // Side by side: the ONLINE map exactly as CoverageMap draws it (OSM raster + the theme's colour matrix) and the
    // OFFLINE pack, same centre and zoom, both palettes.
    for (final dark in [false, true]) {
      final theme = meshSonarTheme(dark ? Brightness.dark : Brightness.light);
      final mc = theme.extension<MeshSonarColors>()!;
      for (final zoom in [10.0, 12.0, 14.0]) {
        for (final online in [true, false]) {
          await t.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme,
              home: Scaffold(
                body: FlutterMap(
                  key: ValueKey('$dark-$zoom-$online'),
                  options: MapOptions(
                    initialCenter: const LatLng(39.9612, -82.9988),
                    initialZoom: zoom,
                    backgroundColor: mc.mapBackground,
                  ),
                  children: [
                    if (online)
                      TileLayer(
                        urlTemplate: CoverageMap.tileUrl,
                        userAgentPackageName: CoverageMap.userAgentPackageName,
                        maxNativeZoom: 19,
                        tileBuilder: (context, tile, _) => ColorFiltered(colorFilter: ColorFilter.matrix(mc.tileMatrix), child: tile),
                      )
                    else
                      OfflineBasemapLayer(reader: reader!),
                  ],
                ),
              ),
            ),
          );
          await pumpFor(t, const Duration(seconds: 7)); // network tiles / off-thread vector rendering
          await shot(t, '${online ? 'online' : 'offline'}-${dark ? 'dark' : 'light'}-z${zoom.toInt()}');
        }
      }
    }
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
