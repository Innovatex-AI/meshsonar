import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/offline_packs.dart';
import 'package:meshsonar/ui/settings/offline_packs_screen.dart';

import 'fakes.dart';

void main() {
  final body = Uint8List.fromList(List.generate(3000, (i) => i % 200));
  final body2 = Uint8List.fromList(List.generate(4000, (i) => i % 199));
  String manifest({int version = 1}) => jsonEncode({
    'packs': [
      {
        'code': 'CMH',
        'name': 'Columbus',
        'version': version,
        'bytes': (version == 1 ? body : body2).length,
        'sha256': sha256.convert(version == 1 ? body : body2).toString(),
        'url': 'cmh-v$version.pmtiles',
        'bbox': [-83.65, 39.36, -82.02, 40.71],
      },
    ],
  });

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('packui'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Serves the manifest (version [v]) and pack bodies; [offline] makes every request fail like no signal.
  OfflinePackManager manager({int Function()? v, bool Function()? offline}) {
    final client = MockClient.streaming((req, _) async {
      if (offline?.call() ?? false) throw const SocketException('offline');
      if (req.url.path.endsWith('manifest.json')) {
        return http.StreamedResponse(Stream.value(utf8.encode(manifest(version: v?.call() ?? 1))), 200);
      }
      return http.StreamedResponse(Stream.value(req.url.path.contains('v2') ? body2 : body), 200);
    });
    return OfflinePackManager(root: Directory('${tmp.path}/p'), client: client);
  }

  Future<void> settle(WidgetTester tester, [Finder? until]) async {
    for (var i = 0; i < 400; i++) {
      if (until != null && until.evaluate().isNotEmpty) return;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<void> tapAsync(WidgetTester tester, Finder f) async {
    await tester.runAsync(() async => tester.tap(f));
    await tester.pump();
  }

  testWidgets('lists packs, downloads one on Wi-Fi, shows storage, deletes it', (tester) async {
    final m = manager();
    await tester.runAsync(() => m.load());
    await tester.pumpWidget(MaterialApp(home: OfflinePacksScreen(manager: m, network: FakeNetworkMonitor())));
    await settle(tester, find.byKey(const Key('pack-download-CMH')));
    expect(find.text('Columbus (CMH)'), findsOneWidget);
    expect(find.text('3 KB'), findsOneWidget); // size before downloading
    final wifi = tester.widget<SwitchListTile>(find.byKey(const Key('pack-wifi-only')));
    expect(wifi.value, isTrue); // default ON

    await tapAsync(tester, find.byKey(const Key('pack-download-CMH')));
    await settle(tester, find.textContaining('Downloaded'));
    expect(find.textContaining('Downloaded, 3 KB'), findsOneWidget);
    await settle(tester, find.textContaining('Storage used by map packs: 3 KB'));
    expect(find.textContaining('Storage used by map packs: 3 KB'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pack-delete-CMH')));
    await tester.pumpAndSettle();
    await tapAsync(tester, find.byKey(const Key('pack-delete-confirm')));
    await settle(tester, find.byKey(const Key('pack-download-CMH')));
    expect(m.installed, isEmpty);
    await settle(tester, find.textContaining('Storage used by map packs: 0 KB'));
    expect(find.textContaining('Storage used by map packs: 0 KB'), findsOneWidget);
  });

  testWidgets('on cellular with Wi-Fi only: asks with the size; "Wait for Wi-Fi" queues it and Wi-Fi starts it', (tester) async {
    final m = manager();
    final net = FakeNetworkMonitor(NetworkKind.cellular);
    await tester.runAsync(() => m.load());
    await tester.pumpWidget(MaterialApp(home: OfflinePacksScreen(manager: m, network: net)));
    await settle(tester, find.byKey(const Key('pack-download-CMH')));
    await tapAsync(tester, find.byKey(const Key('pack-download-CMH')));
    await settle(tester, find.byKey(const Key('pack-cellular-dialog')));
    expect(find.textContaining('Columbus is 3 KB'), findsOneWidget);
    await tapAsync(tester, find.byKey(const Key('pack-wait-wifi')));
    await settle(tester, find.text('Waiting for Wi-Fi'));
    expect(find.text('Waiting for Wi-Fi'), findsOneWidget);
    expect(m.installed, isEmpty);
    expect(m.pending.keys, ['CMH']);

    await tester.runAsync(() => m.onNetwork(NetworkKind.wifi)); // what OfflineBasemap does on a network change
    await settle(tester, find.textContaining('Downloaded'));
    expect(m.installed.keys, ['CMH']);
    expect(m.pending, isEmpty);
  });

  testWidgets('on cellular: "Download now" downloads at once', (tester) async {
    final m = manager();
    await tester.runAsync(() => m.load());
    await tester.pumpWidget(MaterialApp(home: OfflinePacksScreen(manager: m, network: FakeNetworkMonitor(NetworkKind.cellular))));
    await settle(tester, find.byKey(const Key('pack-download-CMH')));
    await tapAsync(tester, find.byKey(const Key('pack-download-CMH')));
    await settle(tester, find.byKey(const Key('pack-use-cellular')));
    await tapAsync(tester, find.byKey(const Key('pack-use-cellular')));
    await settle(tester, find.textContaining('Downloaded'));
    expect(m.installed.keys, ['CMH']);
  });

  testWidgets('Wi-Fi only off: cellular downloads without asking; the switch persists', (tester) async {
    final m = manager();
    await tester.runAsync(() => m.load());
    await tester.pumpWidget(MaterialApp(home: OfflinePacksScreen(manager: m, network: FakeNetworkMonitor(NetworkKind.cellular))));
    await settle(tester, find.byKey(const Key('pack-download-CMH')));
    await tapAsync(tester, find.byKey(const Key('pack-wifi-only')));
    await settle(tester);
    expect(m.wifiOnly, isFalse);
    await tapAsync(tester, find.byKey(const Key('pack-download-CMH')));
    await settle(tester, find.textContaining('Downloaded'));
    expect(find.byKey(const Key('pack-cellular-dialog')), findsNothing);
    final again = manager();
    await tester.runAsync(() => again.load());
    expect(again.wifiOnly, isFalse);
  });

  testWidgets('no connection: the saved pack list shows with "Offline - as of" and installed packs stay', (tester) async {
    var offline = false;
    final m = manager(offline: () => offline);
    await tester.runAsync(() async {
      await m.load();
      await m.download((await m.fetchManifest()).packs.single); // also saves the list
    });
    offline = true;
    await tester.pumpWidget(MaterialApp(home: OfflinePacksScreen(manager: m, network: FakeNetworkMonitor(NetworkKind.offline))));
    await settle(tester, find.byKey(const Key('pack-manifest-offline')));
    expect(find.textContaining('Offline - pack list as of just now'), findsOneWidget);
    expect(find.textContaining('Downloaded, 3 KB'), findsOneWidget);
    expect(find.byKey(const Key('pack-manifest-error')), findsNothing);
  });

  testWidgets('a newer version shows "Update available (size)"; the old pack stays installed until the new one verifies', (tester) async {
    var v = 1;
    final m = manager(v: () => v);
    await tester.runAsync(() async {
      await m.load();
      await m.download((await m.fetchManifest()).packs.single);
    });
    v = 2;
    await tester.pumpWidget(MaterialApp(home: OfflinePacksScreen(manager: m, network: FakeNetworkMonitor())));
    await settle(tester, find.byKey(const Key('pack-update-CMH')));
    expect(find.textContaining('Update available (4 KB)'), findsOneWidget);
    expect(m.installed['CMH']!.version, 1);
    await tapAsync(tester, find.byKey(const Key('pack-update-CMH')));
    await settle(tester, find.text('Downloaded, 4 KB'));
    expect(m.installed['CMH']!.version, 2);
    expect(sha256.convert(m.packFile('CMH').readAsBytesSync()).toString(), sha256.convert(body2).toString());
  });

  testWidgets('Delete all removes packs and partial downloads after confirming', (tester) async {
    final m = manager();
    await tester.runAsync(() async {
      await m.load();
      await m.download((await m.fetchManifest()).packs.single);
      File('${tmp.path}/p/DAY.pmtiles.part').writeAsBytesSync(List.filled(1000, 1));
    });
    await tester.pumpWidget(MaterialApp(home: OfflinePacksScreen(manager: m, network: FakeNetworkMonitor())));
    await settle(tester, find.textContaining('Downloaded'));
    await settle(tester, find.byKey(const Key('pack-delete-all')));
    expect(find.textContaining('Storage used by map packs: 4 KB'), findsOneWidget); // 2.9 KB pack + 1 KB stray part
    await tester.tap(find.byKey(const Key('pack-delete-all')));
    await settle(tester, find.byKey(const Key('pack-delete-all-confirm')));
    await tapAsync(tester, find.byKey(const Key('pack-delete-all-confirm')));
    await settle(tester, find.byKey(const Key('pack-download-CMH')));
    expect(m.installed, isEmpty);
    expect(await tester.runAsync(() => m.usedBytes()), 0);
    await settle(tester);
    expect(find.byKey(const Key('pack-delete-all')), findsNothing);
  });

  testWidgets('manifest failure with nothing saved shows an honest message with Retry', (tester) async {
    final m = OfflinePackManager(root: Directory('${tmp.path}/p'), client: MockClient((_) async => throw const SocketException('offline')));
    await tester.runAsync(() => m.load());
    await tester.pumpWidget(MaterialApp(home: OfflinePacksScreen(manager: m, network: FakeNetworkMonitor(NetworkKind.offline))));
    await settle(tester, find.byKey(const Key('pack-manifest-error')));
    expect(find.byKey(const Key('pack-manifest-error')), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
