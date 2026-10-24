// Settings > Data & storage: sizes, and every clear action asks first, says what it costs, and never removes a drive
// the server does not fully have.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/offline_packs.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/ui/settings/storage_section.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

/// True while a size is still being measured (the total line says so).
bool _measuring(WidgetTester tester) {
  final f = find.byKey(const Key('storage-total'), skipOffstage: false);
  if (f.evaluate().isEmpty) return true;
  final t = tester.widget<Text>(f).data!;
  final offline = find.byKey(const Key('storage-offline-maps-value'), skipOffstage: false);
  final o = offline.evaluate().isEmpty ? 'Measuring…' : tester.widget<Text>(offline).data!;
  return t.startsWith('Measuring') || o == 'Measuring…';
}

DriveSession ended(String id) =>
    DriveSession(id: id, startedAt: DateTime.utc(2026, 10, 15, 14), endedAt: DateTime.utc(2026, 10, 15, 15));

void main() {
  late Directory tmp;
  late Future<OfflinePackManager> Function() realPacks;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ms_settings_storage_');
    realPacks = storagePackManager;
    storagePackManager = () async => OfflinePackManager(root: Directory('${tmp.path}/packs'), client: http.Client());
  });
  tearDown(() {
    storagePackManager = realPacks;
    tmp.deleteSync(recursive: true);
  });

  Future<DiskHarness> open(WidgetTester tester, {void Function(DiskHarness h)? seed}) async {
    useTallScreen(tester);
    final h = DiskHarness(tmp)..approveKey();
    seed?.call(h);
    await h.pumpDiskApp(tester);
    await openSettingsTab(tester);
    await settleIo(tester, until: () => !_measuring(tester));
    return h;
  }

  String text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

  String? valueOf(WidgetTester tester, String key) {
    final f = find.byKey(Key(key), skipOffstage: false);
    return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
  }

  testWidgets('drives: only fully uploaded drives are removed, after a dialog that names what stays', (tester) async {
    final h = await open(tester, seed: (h) {
      h.store.seed(ended('up'), [silentPing('u1'), silentPing('u2')], syncedFirst: 2);
      h.store.seed(ended('waiting'), [silentPing('w1'), silentPing('w2'), silentPing('w3')], syncedFirst: 1);
      h.store.seed(ended('rejected'), [silentPing('r1'), silentPing('r2')], syncedFirst: 1, rejectedLast: 1);
    });
    await showSetting(tester, 'storage-drives');
    expect(text(tester, 'storage-drives-value'), contains('3 drives'));
    expect(text(tester, 'storage-drives-value'), contains('1 fully uploaded, 2 not fully uploaded'));

    // Cancel changes nothing.
    await tester.tap(find.byKey(const Key('storage-drives-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('storage-drives-dialog')), findsOneWidget);
    expect(find.textContaining('2 drives not fully uploaded stay on this phone'), findsOneWidget);
    expect(find.textContaining('3 pings the server does not have'), findsOneWidget);
    expect(find.textContaining('This phone loses its copy'), findsOneWidget);
    await tester.tap(find.byKey(const Key('storage-drives-dialog-cancel')));
    await tester.pumpAndSettle();
    expect(h.store.sessionsById.keys, unorderedEquals(['up', 'waiting', 'rejected']));

    await tester.tap(find.byKey(const Key('storage-drives-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('storage-drives-dialog-confirm')));
    await settleIo(tester, until: () => find.textContaining('Removed 1 uploaded drive').evaluate().isNotEmpty);
    expect(h.store.sessionsById.keys, unorderedEquals(['waiting', 'rejected']),
        reason: 'unsynced and rejected pings exist only on this phone: never removed here');
    expect(find.text('Removed 1 uploaded drive from this phone. 2 not fully uploaded kept.'), findsOneWidget);
    expect(find.text('Drive deleted.'), findsNothing, reason: 'one summary, not a notice per drive');
    final btn = tester.widget<TextButton>(find.byKey(const Key('storage-drives-clear')));
    expect(btn.onPressed, isNull, reason: 'nothing left that is safe to remove');
  });

  testWidgets('drives: the drive being recorded is never offered, even if fully uploaded', (tester) async {
    final h = await open(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await tester.pumpAndSettle();
    await h.state.refreshSessions();
    await tester.pumpAndSettle();
    await showSetting(tester, 'storage-drives');
    expect(tester.widget<TextButton>(find.byKey(const Key('storage-drives-clear'))).onPressed, isNull);
    await h.state.stopDrive();
  });

  testWidgets('drives: none on the phone says so and offers nothing', (tester) async {
    await open(tester);
    await showSetting(tester, 'storage-drives');
    expect(text(tester, 'storage-drives-value'), 'No drives on this phone.');
    expect(tester.widget<TextButton>(find.byKey(const Key('storage-drives-clear'))).onPressed, isNull);
  });

  testWidgets('saved region data: size shown, clear asks, then the files are gone', (tester) async {
    final h = await open(tester, seed: (h) {
      final d = Directory('${tmp.path}/region_cache')..createSync(recursive: true);
      File('${d.path}/rc_cmh_site-config.json').writeAsStringSync('{"key":"k","body":"x","at":"2026-10-16T17:00:00Z"}');
      File('${d.path}/rc_day_coverage.json').writeAsStringSync('{"key":"k2","body":"${'y' * 3000}","at":"2026-10-16T17:00:00Z"}');
    });
    await showSetting(tester, 'storage-region');
    expect(text(tester, 'storage-region-value'), contains('KB'));
    await tester.tap(find.byKey(const Key('storage-region-clear')));
    await tester.pumpAndSettle();
    expect(find.textContaining('download again the next time you open them'), findsOneWidget);
    await tester.tap(find.byKey(const Key('storage-region-dialog-cancel')));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(h.regionCache.bytesUsed), greaterThan(0));

    await tester.tap(find.byKey(const Key('storage-region-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('storage-region-dialog-confirm')));
    await settleIo(tester, until: () => valueOf(tester, 'storage-region-value') == 'Nothing saved yet.');
    expect(await tester.runAsync(h.regionCache.bytesUsed), 0);
    expect(text(tester, 'storage-region-value'), 'Nothing saved yet.');
    expect(find.byKey(const Key('storage-region-clear')), findsNothing);
  });

  testWidgets('repeater names: forget asks, then names are gone on disk and in memory', (tester) async {
    final h = await open(tester, seed: (h) {
      h.cache.items = const [RepeaterRef(key: 'abcd01', name: 'Water Tower', lat: 40, lon: -83)];
    });
    expect(h.state.repeaters, hasLength(1));
    await showSetting(tester, 'storage-repeaters-clear');
    await tester.tap(find.byKey(const Key('storage-repeaters-clear')));
    await tester.pumpAndSettle();
    expect(find.textContaining('show as short codes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('storage-repeaters-dialog-confirm')));
    await settleIo(tester, until: () => h.cache.items.isEmpty);
    expect(h.state.repeaters, isEmpty);
    expect(h.cache.items, isEmpty);
    expect(find.textContaining('None saved yet'), findsOneWidget);
  });

  testWidgets('public node map: size shown, clear removes the file and its names', (tester) async {
    final h = await open(tester, seed: (h) => h.seedNodeMap());
    await settleIo(tester, until: () => h.state.directory != null && !_measuring(tester));
    expect(h.state.directory, isNotNull);
    await showSetting(tester, 'storage-node-map');
    expect(text(tester, 'storage-node-map-value'), contains('1 repeater near your drives'));
    await tester.tap(find.byKey(const Key('storage-node-map-clear')));
    await tester.pumpAndSettle();
    expect(find.textContaining('tens of MB'), findsOneWidget);
    await tester.tap(find.byKey(const Key('storage-node-map-dialog-confirm')));
    await settleIo(tester, until: () => valueOf(tester, 'storage-node-map-value') == 'Not downloaded.');
    expect(h.nodeMapFile.existsSync(), isFalse);
    expect(h.state.directory, isNull);
    expect(text(tester, 'storage-node-map-value'), 'Not downloaded.');
  });

  testWidgets('offline maps: shows what is downloaded and opens the packs screen to delete', (tester) async {
    await open(tester);
    await showSetting(tester, 'storage-offline-maps');
    expect(text(tester, 'storage-offline-maps-value'), 'No offline maps downloaded.');
    expect(find.byKey(const Key('storage-offline-maps-open')), findsOneWidget);
  });

  testWidgets('offline maps: a folder that cannot be read says so instead of a number', (tester) async {
    storagePackManager = () async => throw const FileSystemException('denied');
    await open(tester);
    await showSetting(tester, 'storage-offline-maps');
    expect(text(tester, 'storage-offline-maps-value'), 'Couldn\'t read the offline maps folder.');
  });

  testWidgets('total adds up what could be measured', (tester) async {
    await open(tester, seed: (h) => h.seedNodeMap());
    await showSetting(tester, 'storage-total');
    expect(text(tester, 'storage-total'), startsWith('About '));
    expect(text(tester, 'storage-total'), contains('in use'));
  });
}
