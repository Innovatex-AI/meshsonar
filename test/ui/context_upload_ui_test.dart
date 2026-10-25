// Stream 7 WP5 UI: each category says truthfully where its data goes with the connected server, switching one off strips
// what was never uploaded and offers the server erase (Erase highlighted), a server that cannot erase says so, weather
// goes live with the server's capability, and "Delete my collected data" handles every state in words.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/context_upload_hook.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/drive_context_wire.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/settings/delete_my_data.dart';
import 'package:meshsonar/ui/settings/settings_index.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _v1 = SiteConfig(region: _region, driveFormats: ['meshsonar.drive.v1', 'meshsonar.drive.v1.1']);
const _v12NoErase = SiteConfig(region: _region, driveFormats: ['meshsonar.drive.v1', 'meshsonar.drive.v1.2']);
const _v12 = SiteConfig(
    region: _region, driveFormats: ['meshsonar.drive.v1', 'meshsonar.drive.v1.2'], capabilities: {'driveContextErase', 'driveEnv'});

final t0 = DateTime.utc(2026, 10, 16, 18);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ms_ctx_upload_ui_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<DiskHarness> open(WidgetTester tester,
      {SiteConfig? caps, bool key = true, void Function(DiskHarness h)? setup}) async {
    useTallScreen(tester);
    final h = DiskHarness(tmp);
    if (key) h.approveKey();
    h.tele.siteConfigResult = caps;
    setup?.call(h);
    await h.pumpDiskApp(tester);
    if (caps != null) await settleIo(tester, until: () => h.state.uploadSiteConfig != null);
    await openSettingsTab(tester);
    return h;
  }

  void seed(Harness h) {
    // d1: never uploaded. d2: its first ping's context and first sample were uploaded, the rest was not.
    for (final id in ['d1', 'd2']) {
      h.store.seed(DriveSession(id: id, startedAt: t0, endedAt: t0.add(const Duration(minutes: 5))), [
        DrivePing(id: '$id-p1', ts: t0, lat: 40.1, lon: -82.9),
        DrivePing(id: '$id-p2', ts: t0.add(const Duration(minutes: 1)), lat: 40.1, lon: -82.9),
      ], syncedFirst: id == 'd2' ? 2 : 0);
      for (final p in ['p1', 'p2']) {
        h.store.ctx.appendPingContext(id, '$id-$p', PingContext(altM: 250, pressureHpa: 990));
      }
      h.store.ctx.appendSamples(id, [
        DriveSample(ts: t0, src: SampleSource.phone, battPct: 60, pressureHpa: 990),
        DriveSample(ts: t0.add(const Duration(minutes: 1)), src: SampleSource.phone, battPct: 59, pressureHpa: 991),
      ]);
    }
    h.store.ctx.markCtxSent('d2', ['d2-p1']);
    h.store.ctx.markSamplesSent('d2', [sampleKey(DriveSample(ts: t0, src: SampleSource.phone, battPct: 60))]);
  }

  /// Text inside one category's switch row (every row shows its own destination line).
  Finder inTile(String key, String text) => find.descendant(of: find.byKey(Key(key)), matching: find.textContaining(text));

  /// Drives whose context never reached any server.
  void seedUnsent(Harness h) {
    seed(h);
    h.store.ctx.ctxSent.clear();
    h.store.ctx.samplesSent.clear();
  }

  Future<void> switchOff(WidgetTester tester, String id) async {
    await showSetting(tester, 'collect-$id-toggle');
    await tester.tap(find.byKey(Key('collect-$id-toggle')));
    await tester.pumpAndSettle();
  }

  group('where each category says its data goes', () {
    testWidgets('unknown server: saved on this phone only until the app can check', (tester) async {
      await open(tester);
      await showSetting(tester, 'collect-motion-toggle');
      expect(inTile('collect-motion-toggle', 'Saved on this phone only until the app can check'), findsOneWidget);
    });

    testWidgets('a server that does not accept v1.2: saved on this phone only, this server does not accept it yet',
        (tester) async {
      await open(tester, caps: _v1);
      await showSetting(tester, 'collect-barometer-toggle');
      expect(inTile('collect-barometer-toggle', 'Saved on this phone only: this server does not accept it yet.'), findsOneWidget);
    });

    testWidgets('a server that accepts v1.2: uploaded with your drive', (tester) async {
      await open(tester, caps: _v12);
      await showSetting(tester, 'collect-radio_health-toggle');
      expect(inTile('collect-radio_health-toggle', 'Uploaded with your drive.'), findsOneWidget);
      expect(inTile('collect-radio_health-toggle', 'this server does not accept it yet'), findsNothing);
    });

    testWidgets('without an approved key the upload is conditional, said plainly', (tester) async {
      await open(tester, caps: _v12, key: false);
      await showSetting(tester, 'collect-device-toggle');
      expect(inTile('collect-device-toggle', 'Uploaded with your drive once your driver key is approved'), findsOneWidget);
    });

    testWidgets('weather is live only when the server looks it up and accepts v1.2', (tester) async {
      await open(tester, caps: _v12);
      await showSetting(tester, 'collect-weather-toggle');
      expect(inTile('collect-weather-toggle', 'On: this server looks up weather near your uploaded drives'), findsOneWidget);
      expect(inTile('collect-weather-toggle', 'Not available yet'), findsNothing);
    });

    testWidgets('weather says plainly when the server does not do it', (tester) async {
      await open(tester, caps: _v1);
      await showSetting(tester, 'collect-weather-toggle');
      expect(inTile('collect-weather-toggle', 'Not available yet on this server: it does not look up weather for drives'), findsOneWidget);
    });
  });

  group('switching a category off', () {
    testWidgets('v1.2 server that can erase: unsent context is stripped, sent context stays, Erase is offered first',
        (tester) async {
      final h = await open(tester, caps: _v12, setup: seed);
      await switchOff(tester, 'barometer');
      expect(h.state.settings.collectionOff, {'barometer'});
      // The erase offer comes first, with Erase as the highlighted (filled) button.
      expect(find.byKey(const Key('barometer-erase-dialog')), findsOneWidget);
      expect(tester.widget(find.byKey(const Key('barometer-erase-yes'))), isA<FilledButton>());
      expect(tester.widget(find.byKey(const Key('barometer-erase-keep'))), isA<TextButton>());
      await settleIo(tester, until: () => h.store.ctx.ctxBySession['d1']!['d1-p1']!.pressureHpa == null);
      // d1 was never sent: stripped. d2: the uploaded ping keeps its history, the unsent one is stripped.
      expect(h.store.ctx.ctxBySession['d1']!['d1-p1']!.pressureHpa, isNull);
      expect(h.store.ctx.ctxBySession['d1']!['d1-p2']!.pressureHpa, isNull);
      expect(h.store.ctx.ctxBySession['d1']!['d1-p1']!.altM, 250, reason: 'other categories stay');
      expect(h.store.ctx.ctxBySession['d2']!['d2-p1']!.pressureHpa, 990, reason: 'the server has this one');
      expect(h.store.ctx.ctxBySession['d2']!['d2-p2']!.pressureHpa, isNull);
      expect(h.store.ctx.samplesBySession['d1']!.every((x) => x.pressureHpa == null), isTrue);
      expect(h.store.ctx.samplesBySession['d2']!.where((x) => x.pressureHpa != null), hasLength(1));

      await tester.tap(find.byKey(const Key('barometer-erase-yes')));
      await settleIo(tester, until: () => h.tele.erasedCategories.isNotEmpty);
      expect(h.tele.erasedCategories, ['barometer']);
      expect(find.textContaining('The server erased 340 samples and the context of 120 pings on 3 drives.'), findsOneWidget);
      // Then the local offer, default Keep.
      await tester.pumpAndSettle(const Duration(seconds: 5));
      expect(find.byKey(const Key('barometer-local-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('barometer-local-keep')));
      await tester.pumpAndSettle();
      expect(h.store.ctx.ctxBySession['d2']!['d2-p1']!.pressureHpa, 990);
    });

    testWidgets('Keep on the erase offer sends no DELETE', (tester) async {
      final h = await open(tester, caps: _v12, setup: seed);
      await switchOff(tester, 'motion');
      await tester.tap(find.byKey(const Key('motion-erase-keep')));
      await tester.pumpAndSettle();
      expect(h.tele.erasedCategories, isEmpty);
      expect(find.byKey(const Key('motion-local-dialog')), findsOneWidget);
    });

    testWidgets('a server that accepts context but cannot erase it says so plainly and claims nothing else', (tester) async {
      final h = await open(tester, caps: _v12NoErase, setup: seed);
      await switchOff(tester, 'phone_battery');
      expect(find.byKey(const Key('phone_battery-erase-dialog')), findsNothing);
      expect(find.byKey(const Key('phone_battery-local-dialog')), findsOneWidget);
      expect(find.textContaining(serverCannotEraseText), findsWidgets);
      expect(find.textContaining('Nothing else is claimed'), findsOneWidget);
      expect(find.textContaining('Nothing of it has left this phone'), findsNothing);
      expect(h.tele.erasedCategories, isEmpty);
    });

    testWidgets('a server that does not accept it: as before, nothing left the phone, nothing stripped, Keep default',
        (tester) async {
      final h = await open(tester, caps: _v1, setup: seedUnsent);
      await switchOff(tester, 'barometer');
      expect(find.byKey(const Key('barometer-erase-dialog')), findsNothing);
      expect(find.byKey(const Key('barometer-local-dialog')), findsOneWidget);
      expect(find.textContaining('Nothing of it has left this phone'), findsOneWidget);
      await tester.tap(find.byKey(const Key('barometer-local-keep')));
      await tester.pumpAndSettle();
      expect(h.store.ctx.ctxBySession['d1']!['d1-p1']!.pressureHpa, 990, reason: 'kept: it never goes anywhere');
      expect(h.tele.erasedCategories, isEmpty);
    });

    testWidgets('weather off: no dialog, the server is asked to stop and delete, the text says so', (tester) async {
      final h = await open(tester, caps: _v12);
      await switchOff(tester, 'weather');
      await settleIo(tester, until: () => h.tele.erasedCategories.contains('weather'));
      expect(h.tele.erasedCategories, ['weather']);
      expect(find.byKey(const Key('weather-erase-dialog')), findsNothing);
      expect(find.byKey(const Key('weather-local-dialog')), findsNothing);
      expect(find.textContaining('asks the server to stop looking up weather'), findsOneWidget);
      expect(h.state.settings.contextErasePending, isEmpty, reason: 'done, nothing to retry');
    });

    testWidgets('weather off while offline: remembered, retried by itself when the server answers', (tester) async {
      final h = await open(tester, caps: _v12);
      h.tele.eraseError = const CmatException('network error: down');
      await switchOff(tester, 'weather');
      await settleIo(tester, until: () => h.state.settings.contextErasePending.isNotEmpty);
      expect(h.state.settings.contextErasePending, {'weather'});
      expect(h.settings.saved.contextErasePending, {'weather'}, reason: 'persisted');
      h.tele.eraseError = null;
      await tester.runAsync(() => h.state.refreshUploadSiteConfig(force: true));
      await settleIo(tester, until: () => h.state.settings.contextErasePending.isEmpty);
      expect(h.state.settings.contextErasePending, isEmpty);
      expect(h.tele.erasedCategories.where((c) => c == 'weather').length, greaterThanOrEqualTo(2));
    });
  });

  group('Delete my collected data', () {
    Future<void> openScreen(WidgetTester tester) async {
      await showSetting(tester, 'delete-my-data');
      await tester.tap(find.byKey(const Key('delete-my-data')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-my-data-screen')), findsOneWidget);
    }

    Future<void> showLocalButton(WidgetTester tester) => tester.scrollUntilVisible(
        find.byKey(const Key('delete-local-context')), 200,
        scrollable: find.descendant(of: find.byKey(const Key('delete-my-data-screen')), matching: find.byType(Scrollable)).first);

    Future<void> deleteOnServer(WidgetTester tester, DiskHarness h) async {
      await tester.tap(find.byKey(const Key('delete-server-data')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-server-dialog')), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      await tester.tap(find.byKey(const Key('delete-server-dialog-confirm')));
      await settleIo(tester, until: () => find.byKey(const Key('delete-server-result')).evaluate().isNotEmpty);
    }

    testWidgets('it is in the index, searchable, and says what it does and does not touch', (tester) async {
      await open(tester, caps: _v12);
      expect(searchSettings('delete my data').map((e) => e.id), contains('delete-my-data'));
      expect(searchSettings('gdpr erase').map((e) => e.id), contains('delete-my-data'));
      await openScreen(tester);
      expect(find.text(deleteMyDataLead), findsOneWidget);
    });

    testWidgets('delete on the server: category=all and the packet headers, with the server\'s counts', (tester) async {
      final h = await open(tester, caps: _v12);
      await openScreen(tester);
      await deleteOnServer(tester, h);
      expect(h.tele.erasedCategories, ['all']);
      expect(h.tele.deletes, 1);
      expect(find.textContaining('Drive context: The server erased 340 samples and the context of 120 pings on 3 drives.'), findsOneWidget);
      expect(find.textContaining('Packet headers: the server erased 7.'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('cancel does nothing', (tester) async {
      final h = await open(tester, caps: _v12);
      await openScreen(tester);
      await tester.tap(find.byKey(const Key('delete-server-data')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-server-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(h.tele.erasedCategories, isEmpty);
      expect(h.tele.deletes, 0);
    });

    testWidgets('429: try again in an hour, remembered and retried', (tester) async {
      final h = await open(tester, caps: _v12);
      h.tele.eraseError = const CmatException('rate', status: 429);
      await openScreen(tester);
      await deleteOnServer(tester, h);
      expect(find.textContaining('Try again in an hour'), findsOneWidget);
      expect(find.text('Not finished'), findsOneWidget);
      expect(h.state.settings.contextErasePending, {'all'});
    });

    testWidgets('401/403: the server does not recognise the key, nothing erased, nothing pending', (tester) async {
      final h = await open(tester, caps: _v12);
      h.tele.eraseError = const CmatException('no', status: 401);
      await openScreen(tester);
      await deleteOnServer(tester, h);
      expect(find.textContaining('does not recognise this driver key'), findsOneWidget);
      expect(h.state.settings.contextErasePending, isEmpty);
    });

    testWidgets('offline: said plainly, remembered', (tester) async {
      final h = await open(tester, caps: _v12);
      h.tele.eraseError = const CmatException('network error: down');
      await openScreen(tester);
      await deleteOnServer(tester, h);
      expect(find.textContaining('Can\'t reach the server'), findsWidgets);
      expect(h.state.settings.contextErasePending, {'all'});
    });

    testWidgets('no driver key: the server button is disabled with the reason; local delete is still offered',
        (tester) async {
      final h = await open(tester, key: false, setup: seed);
      await openScreen(tester);
      expect(find.byKey(const Key('delete-server-whynot')), findsOneWidget);
      expect(find.textContaining('no driver key'), findsWidgets);
      expect(tester.widget<ButtonStyleButton>(find.byKey(const Key('delete-server-data'))).onPressed, isNull);
      expect(tester.widget<ButtonStyleButton>(find.byKey(const Key('delete-local-context'))).onPressed, isNotNull);
      expect(h.tele.erasedCategories, isEmpty);
    });

    testWidgets('an older server: the button says it is unavailable on this server; local delete still works',
        (tester) async {
      final h = await open(tester, caps: _v12NoErase, setup: seed);
      await openScreen(tester);
      expect(find.byKey(const Key('delete-server-whynot')), findsOneWidget);
      expect(find.textContaining(serverCannotEraseText), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(find.byKey(const Key('delete-server-data'))).onPressed, isNull);
      await showLocalButton(tester);
      await tester.tap(find.byKey(const Key('delete-local-context')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-local-dialog-confirm')));
      await settleIo(tester, until: () => h.store.ctx.ctxBySession['d1']?.isEmpty ?? true);
      expect(h.store.ctx.ctxBySession['d1'] ?? const {}, isEmpty);
      expect(h.store.ctx.samplesBySession['d1'] ?? const [], isEmpty);
      expect(find.text('Deleted the saved context from 2 drives on this phone.'), findsOneWidget);
      expect(h.tele.erasedCategories, isEmpty);
    });

    testWidgets('local delete is separate and Keep by default: cancel leaves everything', (tester) async {
      final h = await open(tester, caps: _v12, setup: seed);
      await openScreen(tester);
      await showLocalButton(tester);
      await tester.tap(find.byKey(const Key('delete-local-context')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-local-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(h.store.ctx.ctxBySession['d1']!['d1-p1']!.altM, 250);
      expect(h.tele.erasedCategories, isEmpty);
    });
  });

  group('upload report wording', () {
    test('context activity and refusals are said, never hidden', () {
      expect(contextReportParts(const SyncReport()), isEmpty);
      final parts = contextReportParts(const SyncReport(
          samplesStored: 5, contextPingsUpdated: 2, samplesRejected: 1, contextRejected: 2, contextFallbacks: 1));
      expect(parts, contains('5 context samples'));
      expect(parts, contains('context added to 2 pings'));
      expect(parts, contains('3 context items refused by the server'));
      expect(parts.last, contains('refused the context of 1 drive as a whole'));
    });

    test('erase counts', () {
      expect(eraseCountsText(const ContextEraseResult(category: 'all')), 'The server held none of it.');
      expect(eraseCountsText(const ContextEraseResult(category: 'all', sessions: 1, pings: 1, samples: 1)),
          'The server erased 1 sample and the context of 1 ping on 1 drive.');
    });
  });
}
