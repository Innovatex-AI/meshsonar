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

void main() {
  final body = Uint8List.fromList(List.generate(3000, (i) => i % 200));
  final manifest = jsonEncode({
    'packs': [
      {
        'code': 'CMH',
        'name': 'Columbus',
        'version': 1,
        'bytes': body.length,
        'sha256': sha256.convert(body).toString(),
        'url': 'cmh.pmtiles',
        'bbox': [-83.65, 39.36, -82.02, 40.71],
      },
    ],
  });

  testWidgets('lists packs, downloads one, shows storage, deletes it', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('packui');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final client = MockClient.streaming((req, _) async {
      if (req.url.path.endsWith('manifest.json')) {
        return http.StreamedResponse(Stream.value(utf8.encode(manifest)), 200);
      }
      return http.StreamedResponse(Stream.value(body), 200);
    });
    final m = OfflinePackManager(root: Directory('${tmp.path}/p'), client: client);
    await tester.runAsync(() => m.load());
    await tester.pumpWidget(MaterialApp(home: OfflinePacksScreen(manager: m)));
    Future<void> settle([Finder? until]) async {
      for (var i = 0; i < 400; i++) {
        if (until != null && until.evaluate().isNotEmpty) {
          return;
        }
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    await settle(find.byKey(const Key('pack-download-CMH')));
    expect(find.text('Columbus (CMH)'), findsOneWidget);
    expect(find.byKey(const Key('pack-download-CMH')), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('pack-download-CMH')));
    });
    await settle(find.textContaining('Downloaded'));
    expect(find.textContaining('Downloaded'), findsOneWidget);
    expect(find.textContaining('Storage used by map packs: 2 KB'), findsNothing); // 2.9 KB rounds to 3 KB
    expect(find.textContaining('3 KB'), findsWidgets);

    await tester.tap(find.byKey(const Key('pack-delete-CMH')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pack-delete-confirm')), findsOneWidget); // asks before deleting
    await tester.runAsync(() => m.delete('CMH'));
    await tester.pump();
    await settle(find.byKey(const Key('pack-download-CMH')));
    expect(find.byKey(const Key('pack-download-CMH')), findsOneWidget);
    expect(m.installed, isEmpty);
  });

  testWidgets('manifest failure shows an honest message and keeps installed packs deletable', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('packui2');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final m = OfflinePackManager(root: Directory('${tmp.path}/p'), client: MockClient((_) async => throw const SocketException('offline')));
    await tester.runAsync(() => m.load());
    await tester.pumpWidget(MaterialApp(home: OfflinePacksScreen(manager: m)));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.byKey(const Key('pack-manifest-error')), findsOneWidget);
  });
}
