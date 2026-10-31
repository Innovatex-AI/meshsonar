// Multi-region offline packs: which pack the map draws as the camera moves (sticky in overlaps, switches when the
// view enters another pack, back to online tiles outside all packs), and that a deleted pack disappears from the map.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/offline_basemap.dart';
import 'package:meshsonar/ui/theme.dart';

import 'fakes.dart';

/// A valid, empty PMTiles v3 file (header + empty root directory): enough for the reader to open it.
Uint8List emptyPack() {
  final h = ByteData(127);
  for (var i = 0; i < 7; i++) {
    h.setUint8(i, 'PMTiles'.codeUnitAt(i));
  }
  h.setUint8(7, 3);
  h.setUint64(8, 127, Endian.little);
  h.setUint64(16, 1, Endian.little);
  h.setUint8(97, 1);
  h.setUint8(98, 2);
  h.setUint8(99, 1);
  h.setUint8(101, 14);
  return Uint8List.fromList([...h.buffer.asUint8List(), 0]);
}

const cmhBox = [-83.6534, 39.3613, -82.0242, 40.7127];
const dayBox = [-84.6, 39.4, -83.5, 40.2]; // overlaps CMH between -83.65 and -83.5

Future<OfflineBasemap> basemapWith(Directory root, Map<String, List<double>> packs) async {
  root.createSync(recursive: true);
  final index = <String, dynamic>{};
  packs.forEach((code, box) {
    File('${root.path}/$code.pmtiles').writeAsBytesSync(emptyPack());
    index[code] = {'name': code, 'version': 1, 'bytes': 128, 'sha256': '0' * 64, 'bbox': box, 'installed_at': '2026-10-24T00:00:00Z'};
  });
  File('${root.path}/packs.json').writeAsStringSync(jsonEncode(index));
  final b = OfflineBasemap.forTest();
  await b.manager(root: root, client: MockClient((_) async => http.Response('', 404)), network: FakeNetworkMonitor());
  return b;
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('basemap');
    // flutter_map's built-in tile cache asks path_provider for a cache dir; unmocked, the late MissingPluginException
    // lands in whichever test is running (flaky full-suite failure).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });
  tearDown(() {
    OfflineBasemap.debugInstance = null;
    OfflineBasemapLayer.debugBuilder = null;
    tmp.deleteSync(recursive: true);
  });

  test('choosePack: smallest covering pack, sticky in the overlap, null outside every pack', () async {
    final b = await basemapWith(Directory('${tmp.path}/p'), {'CMH': cmhBox, 'DAY': dayBox});
    final sel = OfflinePackSelection(b);
    expect(sel.update(39.96, -83.00), isTrue); // Columbus
    expect(sel.code, 'CMH');
    expect(sel.reader, isNotNull);
    expect(sel.update(39.9, -83.58), isFalse); // into the overlap: stays on CMH (no flicker)
    expect(sel.code, 'CMH');
    expect(sel.update(39.76, -84.19), isTrue); // Dayton: only DAY covers it
    expect(sel.code, 'DAY');
    expect(sel.update(39.9, -83.58), isFalse); // back into the overlap from DAY: stays on DAY
    expect(sel.code, 'DAY');
    expect(sel.update(41.5, -81.7), isTrue); // Cleveland: no pack -> online tiles
    expect(sel.code, isNull);
    expect(sel.reader, isNull);
    // Fresh selection in the overlap: the smaller box (DAY) wins.
    final fresh = OfflinePackSelection(b)..update(39.9, -83.58);
    expect(fresh.code, 'DAY');
    await b.debugClose();
  });

  test('a pack whose file will not open is skipped; deleting the drawn pack switches away from it', () async {
    final root = Directory('${tmp.path}/p');
    final b = await basemapWith(root, {'CMH': cmhBox, 'DAY': dayBox});
    final sel = OfflinePackSelection(b)..update(39.9, -83.58);
    expect(sel.code, 'DAY');
    final m = b.managerOrNull!;
    await m.delete('DAY');
    await Future<void>.delayed(const Duration(milliseconds: 50)); // basemap closes the reader on the change event
    expect(sel.refresh(), isTrue);
    expect(sel.code, 'CMH');
    await b.debugClose();

    // A corrupt file: installed in the index but unreadable -> never chosen.
    final root2 = Directory('${tmp.path}/q');
    final b2 = await basemapWith(root2, {'CMH': cmhBox});
    await b2.debugClose();
    File('${root2.path}/CMH.pmtiles').writeAsBytesSync(List.filled(200, 0));
    final b3 = OfflineBasemap.forTest();
    await b3.manager(root: root2, client: MockClient((_) async => http.Response('', 404)), network: FakeNetworkMonitor());
    expect(b3.choosePack(39.96, -83.0), isNull);
    await b3.debugClose();
  });

  testWidgets('the map switches pack when the view is dragged from Columbus into Dayton, then to online tiles', (tester) async {
    late OfflineBasemap b;
    await tester.runAsync(() async => b = await basemapWith(Directory('${tmp.path}/p'), {'CMH': cmhBox, 'DAY': dayBox}));
    OfflineBasemap.debugInstance = b;
    OfflineBasemapLayer.debugBuilder = (_) => const SizedBox.shrink();
    await tester.pumpWidget(
      MaterialApp(
        theme: meshSonarTheme(Brightness.light),
        home: const Scaffold(
          body: SizedBox(
            width: 600,
            height: 600,
            child: CoverageMap(pings: [], showTiles: true, fallbackCenter: LatLng(39.96, -83.0)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('offline-pack-CMH')), findsOneWidget);
    expect(find.byKey(const ValueKey('offline-pack-DAY')), findsNothing);

    // Zoom 8: about 0.0055 degrees of longitude per pixel. Dragging right by 220 px moves the centre ~1.2 deg west.
    await tester.drag(find.byType(CoverageMap), const Offset(220, 0));
    await tester.pump();
    expect(find.byKey(const ValueKey('offline-pack-DAY')), findsOneWidget);
    expect(find.byKey(const ValueKey('offline-pack-CMH')), findsNothing);

    // Far north-west, outside both packs: online tiles again (no offline layer).
    await tester.drag(find.byType(CoverageMap), const Offset(250, 400));
    await tester.pump();
    expect(find.byKey(const ValueKey('offline-pack-DAY')), findsNothing);
    expect(find.byKey(const ValueKey('offline-pack-CMH')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => b.debugClose());
  });
}
