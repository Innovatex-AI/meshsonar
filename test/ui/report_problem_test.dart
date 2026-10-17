// "Report a problem" (spec m1-app-0.4.0 §3): AC-2, AC-3, AC-4, AC-5, AC-6, AC-8, AC-9, AC-16 (report screens).
//
// UI contract (keys chosen by Q; texts from the spec):
//   Settings → About: ListTile Key('report-problem') "Report a problem", above Key('about').
//   Drive detail: overflow button Key('detail-more') → item "Report a problem with this drive" (pre-selects the drive).
//   Form screen Key('report-screen'): category chips ValueKey('report-category-<bug|radio|gps|upload|map|idea|other>'),
//     description TextField Key('report-description') with live counter Text Key('report-counter'),
//     Switch Key('report-include-log') (on by default), Key('report-attach-drive'), Review button Key('report-review').
//     Without a usable key (none / rejected / revoked): Key('report-needs-key') explanation + Key('report-key-settings')
//     link to Settings → driver key section; Review disabled.
//     With a saved draft: Key('report-send-saved') "Send saved report" and Key('report-discard-saved') "Discard".
//   Preview screen Key('report-preview'): SelectableText Key('report-preview-body') = the exact body; size line
//     "… MB of 5 MB"; "We removed N keys and rounded M locations."; the only Send button Key('report-send').
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/api.dart';

import 'fakes.dart';
import 'fakes_m1.dart';

const notSent = 'Not sent. Your report is saved on this phone; send it when you have signal.';
const msKey = 'ms_Ab3_-xYz09Ab3_-xYz09Ab3_-xYz09Ab3_-xYz09Q7k';
const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.abcDEF_123-x';
const appKey = 'secretkey-abcdef-1234';

Settings approved({String server = 'https://cmat.example.org/private/path'}) =>
    Settings(serverUrl: server, driverKey: appKey, keyStatus: DriverKeyStatus.approved, display: 'KD8XYZ');

String previewText(WidgetTester tester) {
  final f = find.descendant(
      of: find.byKey(const Key('report-preview-body')), matching: find.byType(SelectableText), matchRoot: true);
  final w = tester.widget<SelectableText>(f.first);
  return w.data ?? w.textSpan!.toPlainText();
}

Future<void> pickCategory(WidgetTester tester, String c) async {
  final f = find.byKey(ValueKey('report-category-$c'));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> describe(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('report-description')), text);
  await tester.pump();
}

Future<void> review(WidgetTester tester) async {
  final f = find.byKey(const Key('report-review'));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('report-preview')), findsOneWidget);
}

Future<void> send(WidgetTester tester) async {
  final f = find.byKey(const Key('report-send'));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await settle(tester);
  await tester.pumpAndSettle();
}

/// Settings → Report a problem → category + description → Review. Returns the preview text.
Future<String> fillAndReview(WidgetTester tester, {String category = 'upload', String text = 'Upload failed after the tunnel'}) async {
  await openReportFromSettings(tester);
  await pickCategory(tester, category);
  await describe(tester, text);
  await review(tester);
  return previewText(tester);
}

bool counterInError(WidgetTester tester) {
  final counter = find.byKey(const Key('report-counter'));
  final err = Theme.of(tester.element(counter)).colorScheme.error;
  final w = tester.widget<Text>(counter);
  final styleColor = w.style?.color ?? DefaultTextStyle.of(tester.element(counter)).style.color;
  final field = tester.widget<TextField>(find.byKey(const Key('report-description')));
  return styleColor == err || field.decoration?.errorText != null;
}

void main() {
  group('AC-2 entry points and the key rule', () {
    testWidgets('Settings → About has "Report a problem" above "About MeshSonar"', (tester) async {
      useTallScreen(tester);
      final h = M1Harness()..approveKey();
      await h.pumpApp(tester);
      await openSettings(tester);
      await scrollSettingsTo(tester, find.byKey(const Key('about')));
      final row = find.byKey(const Key('report-problem'));
      expect(find.descendant(of: find.byKey(const Key('section-about-section')), matching: row), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Report a problem')), findsOneWidget);
      expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(find.byKey(const Key('about'))).dy));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('report-screen')), findsOneWidget);
      await drain(tester);
    });

    for (final (label, settings) in [
      ('no key', const Settings()),
      ('a rejected key', const Settings(driverKey: appKey, keyStatus: DriverKeyStatus.rejected)),
      ('a revoked key', const Settings(driverKey: appKey, keyStatus: DriverKeyStatus.revoked)),
    ]) {
      testWidgets('with $label the screen explains why, Review is disabled, and the link opens the key section',
          (tester) async {
        useTallScreen(tester);
        final h = M1Harness();
        h.settings.saved = settings;
        await h.pumpApp(tester);
        await openReportFromSettings(tester);
        expect(find.byKey(const Key('report-needs-key')), findsOneWidget);
        await pickCategory(tester, 'bug');
        await describe(tester, 'Something broke');
        expect(isEnabled(tester, find.byKey(const Key('report-review'))), isFalse);
        expect(find.byKey(const Key('report-send')), findsNothing, reason: 'Send only exists on the preview');
        await tester.tap(find.byKey(const Key('report-key-settings')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('report-screen')), findsNothing);
        expect(find.byKey(const Key('section-driver')).hitTestable(), findsOneWidget);
        expect(h.reports.sent, isEmpty);
        await drain(tester);
      });
    }

    for (final status in [DriverKeyStatus.pending, DriverKeyStatus.approved]) {
      testWidgets('a ${status.name} key may report (CMAT §5)', (tester) async {
        useTallScreen(tester);
        final h = M1Harness();
        h.settings.saved = Settings(driverKey: appKey, keyStatus: status);
        await h.pumpApp(tester);
        await openReportFromSettings(tester);
        expect(find.byKey(const Key('report-needs-key')), findsNothing);
        await pickCategory(tester, 'gps');
        await describe(tester, 'GPS jumps around');
        expect(isEnabled(tester, find.byKey(const Key('report-review'))), isTrue);
        await drain(tester);
      });
    }

    testWidgets('drive detail → "Report a problem with this drive" sends only that drive\'s id, never its pings',
        (tester) async {
      useTallScreen(tester);
      final h = M1Harness()..approveKey();
      seedDrive(h);
      await h.pumpApp(tester);
      await tester.tap(find.text('Drives'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-d1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('detail-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Report a problem with this drive'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('report-screen')), findsOneWidget);
      await pickCategory(tester, 'map');
      await describe(tester, 'The map of this drive is empty');
      await review(tester);
      final body = previewText(tester);
      final j = jsonDecode(body) as Map<String, dynamic>;
      expect(j['driveId'], 'd1');
      for (final ping in ['d1-p1', 'd1-p2', '40.128091', '"pings"', '"lat"']) {
        expect(body, isNot(contains(ping)));
      }
      await drain(tester);
    });
  });

  group('AC-3 description length', () {
    testWidgets('0 chars (or only spaces) → Review disabled; 4,001 → blocked, counter in error; 4,000 → allowed',
        (tester) async {
      useTallScreen(tester);
      final h = M1Harness()..approveKey();
      await h.pumpApp(tester);
      await openReportFromSettings(tester);
      await pickCategory(tester, 'bug');
      final reviewBtn = find.byKey(const Key('report-review'));
      expect(isEnabled(tester, reviewBtn), isFalse);
      await describe(tester, '   ');
      expect(isEnabled(tester, reviewBtn), isFalse);
      await describe(tester, 'x' * 4001);
      expect(isEnabled(tester, reviewBtn), isFalse);
      expect(tester.widget<Text>(find.byKey(const Key('report-counter'))).data, matches(RegExp(r'4,?001')));
      expect(counterInError(tester), isTrue);
      await describe(tester, 'x' * 4000);
      expect(isEnabled(tester, reviewBtn), isTrue);
      expect(tester.widget<Text>(find.byKey(const Key('report-counter'))).data, matches(RegExp(r'4,?000')));
      expect(counterInError(tester), isFalse);
      await describe(tester, 'ok');
      expect(tester.widget<Text>(find.byKey(const Key('report-counter'))).data, contains('2'));
      await drain(tester);
    });
  });

  group('AC-4 / AC-5 / AC-6 preview = what is sent, redacted and rounded', () {
    testWidgets('preview shows the exact body sent; secrets gone; coords at 3 decimals; no key, no URL path',
        (tester) async {
      useTallScreen(tester);
      final h = M1Harness();
      h.settings.saved = approved();
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await tester.pumpAndSettle();
      for (final line in [
        'upload x-driver-key $appKey to https://cmat.example.org/private/path/api/cmh/drive-upload',
        'pasted key $msKey',
        'jwt $jwt',
        'Authorization: Bearer abc.def-ghi',
        'observer mqtt://obs:hunter2@broker.example:1883',
        '> set mqtt1.password x',
        'fix 40.128091,-82.977705',
      ]) {
        h.state.diagnostics.add(line);
      }
      final shown = await fillAndReview(tester, text: 'Upload failed near 40.128091,-82.977705');
      expect(find.textContaining('of 5 MB'), findsOneWidget);
      expect(find.textContaining(RegExp(r'We removed \d+ keys? and rounded \d+ locations?\.')), findsOneWidget);

      final j = jsonDecode(shown) as Map<String, dynamic>;
      expect(j['category'], 'upload');
      expect(j['description'], 'Upload failed near 40.128,-82.978');
      expect(j['app'], {'name': 'MeshSonar', 'version': '0.4.0', 'build': '5', 'platform': 'iOS'});
      expect((j['device'] as Map).keys.toSet(), {'os', 'osVersion', 'locale'});
      expect(j['device']['os'], Platform.operatingSystem);
      expect(j['radio'],
          {'name': 'Truck Radio', 'firmware': 'v1.9.0', 'freqMhz': 910.525, 'bwKhz': 62.5, 'sf': 7, 'cr': 5, 'txDbm': 22});
      final log = j['log'] as String;
      expect(log, contains('cmat.example.org'), reason: 'settings snapshot: server host');
      expect(log, contains('#wardriving'), reason: 'settings snapshot: channel');
      expect(log, contains('approved'), reason: 'settings snapshot: key status');
      expect(log, contains('40.128,-82.978'));
      expect(log, contains('[redacted:driver-key]'));
      expect(log, contains('[redacted:jwt]'));
      for (final clear in [
        appKey, msKey, jwt, 'abc.def-ghi', 'hunter2', 'password x', '40.128091', '82.977705',
        '/private/path', 'https://cmat.example.org/private', 'abcdef0123', 'ABCDEF0123',
      ]) {
        expect(shown, isNot(contains(clear)), reason: '"$clear" must not be sent');
      }

      // Back returns to the form with nothing sent.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('report-screen')), findsOneWidget);
      expect(h.reports.sent, isEmpty);
      await review(tester);
      expect(previewText(tester), shown, reason: 'same input, same preview');

      await send(tester);
      expect(h.reports.sent, hasLength(1));
      expect(h.reports.sent.single.body, shown, reason: 'AC-4: the preview string is the request body');
      expect(h.reports.sent.single.driverKey, appKey);
      await drain(tester);
    });

    testWidgets('"Include app log" off → no log is sent; not connected → no radio', (tester) async {
      useTallScreen(tester);
      final h = M1Harness();
      h.settings.saved = approved();
      await h.pumpApp(tester);
      h.state.diagnostics.add('something private-ish');
      await openReportFromSettings(tester);
      await pickCategory(tester, 'idea');
      await describe(tester, 'Dark tiles please');
      final sw = find.byKey(const Key('report-include-log'));
      await tester.ensureVisible(sw);
      expect(tester.widget<Switch>(find.descendant(of: sw, matching: find.byType(Switch), matchRoot: true)).value, isTrue,
          reason: 'on by default');
      await tester.tap(sw);
      await tester.pumpAndSettle();
      await review(tester);
      final j = jsonDecode(previewText(tester)) as Map<String, dynamic>;
      expect(j['log'], isNull);
      expect(j['radio'], isNull);
      expect(previewText(tester), isNot(contains('private-ish')));
      await drain(tester);
    });
  });

  group('AC-8 server answers', () {
    final cases = <(String, Object?, String, bool)>[
      // (label, error thrown by the fake server or null for 201, text the app shows, draft kept?)
      ('201', null, 'Sent. Thank you.', false),
      // Report-specific copy (review fix 7, L Oct 17): the drive-upload wording ("your pings are saved") doesn't fit.
      ('401', const CmatException('x-driver-key required', status: 401),
          'The server doesn\'t recognise this driver key. Your report is saved on this phone.', true),
      ('403', const CmatException('driver key is revoked', status: 403),
          'This driver key can\'t send reports (rejected or revoked). Your report is saved on this phone.', true),
      ('404', const CmatException('not found', status: 404), 'This server doesn\'t accept problem reports.', true),
      ('503', const CmatException('Problem reports are turned off on this server.', status: 503),
          'This server doesn\'t accept problem reports.', true),
      ('413', const CmatException('Report is larger than 5 MB.', status: 413), 'The report is too large.', true),
      ('429', const CmatException('Too many requests. Try again later.', status: 429),
          'Too many reports in the last hour. Try again later. Your report is saved on this phone.', true),
      ('400', const CmatException('category: required', status: 400),
          'The server couldn\'t accept this report as written.', true),
      ('network error', const CmatException('network error: no route'), notSent, true),
      ('timeout', const CmatException('timed out talking to cmat.example.org'), notSent, true),
      ('500', const CmatException('boom', status: 500), notSent, true),
      ('502', const CmatException('bad gateway', status: 502), notSent, true),
    ];
    for (final (label, error, message, kept) in cases) {
      testWidgets('$label → "$message", draft ${kept ? 'kept' : 'deleted'}', (tester) async {
        useTallScreen(tester);
        final h = M1Harness();
        h.settings.saved = approved();
        h.reports.error = error;
        await h.pumpApp(tester);
        await fillAndReview(tester);
        await send(tester);
        expect(h.reports.sent, hasLength(1));
        expect(find.textContaining(message), findsWidgets);
        if (error == null) expect(find.textContaining('3f2a9c1e'), findsWidgets, reason: 'short report id');
        expect(h.drafts.draft != null, kept);
        await drain(tester);
      });
    }
  });

  group('AC-9 offline: one saved draft, sent only by a tap', () {
    testWidgets('network error keeps the draft; after a restart "Send saved report" shows the same preview and sends the same body',
        (tester) async {
      useTallScreen(tester);
      final drafts = FakeReportDraftStore();
      final h1 = M1Harness(drafts: drafts);
      h1.settings.saved = approved();
      h1.reports.error = const CmatException('network error: no route');
      await h1.pumpApp(tester);
      final shown = await fillAndReview(tester);
      await send(tester);
      expect(find.textContaining(notSent), findsWidgets);
      expect(drafts.draft, isNotNull);
      final firstBody = h1.reports.sent.single.body;
      expect(firstBody, shown);
      await drain(tester);

      // App restart: a fresh app over the same phone storage, and signal is back.
      final h2 = M1Harness(drafts: drafts);
      h2.settings.saved = approved();
      await h2.pumpApp(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(h2.reports.sent, isEmpty, reason: 'no background auto-send');
      await openReportFromSettings(tester);
      expect(h2.reports.sent, isEmpty);
      expect(find.byKey(const Key('report-discard-saved')), findsOneWidget);
      await tester.tap(find.byKey(const Key('report-send-saved')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('report-preview')), findsOneWidget);
      expect(previewText(tester), shown, reason: 'the same approved preview');
      expect(h2.reports.sent, isEmpty, reason: 'nothing sends without the Send tap');
      await send(tester);
      expect(h2.reports.sent.single.body, firstBody);
      expect(find.textContaining('Sent. Thank you.'), findsWidgets);
      expect(drafts.draft, isNull, reason: 'deleted after 201');
      await drain(tester);
    });

    testWidgets('Discard removes the saved draft and nothing is sent', (tester) async {
      useTallScreen(tester);
      final h1 = M1Harness();
      h1.settings.saved = approved();
      h1.reports.error = const CmatException('timed out talking to cmat.example.org');
      await h1.pumpApp(tester);
      await fillAndReview(tester);
      await send(tester);
      expect(h1.drafts.draft, isNotNull);
      await drain(tester);

      final h2 = M1Harness(drafts: h1.drafts);
      h2.settings.saved = approved();
      await h2.pumpApp(tester);
      await openReportFromSettings(tester);
      await tester.tap(find.byKey(const Key('report-discard-saved')));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('report-discard-confirm'));
      if (confirm.evaluate().isNotEmpty) {
        await tester.tap(confirm);
        await tester.pumpAndSettle();
      }
      expect(h2.drafts.draft, isNull);
      expect(find.byKey(const Key('report-send-saved')), findsNothing);
      expect(h2.reports.sent, isEmpty);
      await drain(tester);
    });
  });

  group('diagnostic log is fed by the app', () {
    testWidgets('messages shown to the user and sync attempts land in the log, without the driver key', (tester) async {
      useTallScreen(tester);
      final h = M1Harness();
      h.settings.saved = approved();
      h.sync.failWith = 'network error: Failed host lookup: cmat.example.org';
      await h.pumpApp(tester);
      await h.state.startDrive(); // not connected → "Connect a radio (or the simulator) first."
      await tester.pump();
      expect(h.state.diagnostics.lines.any((l) => l.contains('Connect a radio')), isTrue);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await h.state.startDrive();
      h.engines.single.emit(silentPing('p1'));
      await settle(tester);
      await h.state.stopDrive();
      await settle(tester);
      final lines = h.state.diagnostics.lines;
      expect(lines.any((l) => l.toLowerCase().contains('sync') || l.toLowerCase().contains('upload')), isTrue,
          reason: lines.join('\n'));
      expect(lines.any((l) => l.toLowerCase().contains('drive')), isTrue, reason: 'drive start/stop');
      expect(lines.join('\n'), isNot(contains(appKey)));
      await drain(tester);
    });
  });

  group('AC-16 accessibility of the report screens', () {
    testWidgets('form and preview: 320 dp wide, 2.0× text, no overflow; labelled controls; 48 dp targets',
        (tester) async {
      tester.view.physicalSize = const Size(960, 2400); // 320 × 800 dp at 3.0
      tester.view.devicePixelRatio = 3.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final semantics = tester.ensureSemantics();
      final h = M1Harness();
      h.settings.saved = approved();
      await h.pumpApp(tester);
      await openReportFromSettings(tester);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await pickCategory(tester, 'other');
      await describe(tester, 'Large text check');
      await review(tester);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      expect(find.bySemanticsLabel(RegExp('Send', caseSensitive: false)), findsWidgets);
      semantics.dispose();
      await drain(tester);
    });
  });
}
