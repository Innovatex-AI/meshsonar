// On a simulator/device: downloads the REAL CMH pack through the app's own manager from tiles.meshsonar.com (same
// code path as Settings > Offline maps), then draws it with the app's offline layer over Columbus at z10 and z14 in
// light and dark, printing "SCREEN <name>" so scripts/verify_sim.sh (or a person) can screenshot each view.
//   flutter test integration_test/offline_maps_test.dart -d <simulator udid>
// Makes one manifest request and one 53 MB pack download (skipped when the pack is already installed and current).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
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

    for (final dark in [false, true]) {
      for (final zoom in [10.0, 14.0]) {
        await t.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: meshSonarTheme(dark ? Brightness.dark : Brightness.light),
            home: Scaffold(
              body: FlutterMap(
                key: ValueKey('$dark-$zoom'),
                options: MapOptions(initialCenter: const LatLng(39.9612, -82.9988), initialZoom: zoom),
                children: [OfflineBasemapLayer(reader: reader!)],
              ),
            ),
          ),
        );
        await pumpFor(t, const Duration(seconds: 6)); // tiles render off the UI thread
        await shot(t, 'offline-${dark ? 'dark' : 'light'}-z${zoom.toInt()}');
      }
    }
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
