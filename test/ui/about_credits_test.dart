// The Open-Meteo credit (CC BY 4.0) in About, in the third-party notices file, and findable from Settings search.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart' show openMeteoCredit;
import 'package:meshsonar/ui/about_screen.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart' show dismissAppToast;
import 'package:meshsonar/ui/settings/settings_index.dart';

import 'fakes.dart';

void main() {
  test('the credit is the exact licence line', () {
    expect(openMeteoCredit, 'Weather data by Open-Meteo.com (CC BY 4.0)');
    expect(thirdPartyNotices.where((n) => n.name == 'Open-Meteo').single.note, openMeteoCredit);
    expect(thirdPartyNoticeLinks['Open-Meteo'], Uri.parse('https://open-meteo.com'));
  });

  test('MeshTrack credits: Open Location Code (Apache-2.0) and MeshCore-TEAM (CC BY-NC-SA 4.0, format only, no code)', () {
    final olc = thirdPartyNotices.where((n) => n.name == 'Open Location Code').single;
    expect(olc.license, contains('Apache-2.0'));
    expect(olc.license, contains('google/open-location-code'));
    final team = thirdPartyNotices.where((n) => n.name == 'MeshCore-TEAM').single;
    expect(team.license, contains('CC BY-NC-SA 4.0'));
    expect(team.note, contains('no code used'));
    expect(thirdPartyNotices.map((n) => n.name), containsAllInOrder(['pdf', 'Open Location Code', 'MeshCore-TEAM', 'Open-Meteo']));
    for (final n in thirdPartyNotices) {
      expect('${n.name} ${n.license} ${n.note}'.toUpperCase(), isNot(contains('APRS')), reason: 'never APRS in product copy');
    }
    final md = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
    expect(md, contains('### Open Location Code'));
    expect(md, contains('https://github.com/google/open-location-code'));
    expect(md, contains('### MeshCore-TEAM'));
    expect(md, contains('No MeshCore-TEAM code is copied'));
    expect(File('test/fixtures/olc/LICENSE').readAsStringSync(), contains('Apache License'));
  });

  test('THIRD_PARTY_NOTICES.md carries the credit line and the licence', () {
    final md = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
    expect(md, contains('Weather data by Open-Meteo.com (CC BY 4.0)'));
    expect(md, contains('https://open-meteo.com'));
    expect(md, contains('non-commercial'));
  });

  test('Settings search finds the credit', () {
    expect(searchSettings('open-meteo').map((e) => e.id), contains('about'));
    expect(searchSettings('attribution').map((e) => e.id), contains('about'));
  });

  testWidgets('About shows the credit line and its link opens open-meteo.com', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.state.init();
    await tester.pumpWidget(MeshSonarApp(state: h.state));
    await tester.pump();
    Navigator.of(tester.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen()));
    await tester.pumpAndSettle();
    final scroll = find.descendant(of: find.byType(AboutScreen), matching: find.byType(Scrollable)).first;
    // Build 76: the page is rows; the licence text and the credits open on a tap, the long text is not on the page.
    expect(find.byKey(const Key('mit-license')), findsNothing);
    expect(find.byKey(const Key('notice-Open-Meteo')), findsNothing);
    expect(find.text('${thirdPartyNotices.length} projects MeshSonar builds on'), findsOneWidget);
    await tester.tap(find.byKey(const Key('about-licence')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mit-license')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('about-credits')), 200, scrollable: scroll);
    await tester.ensureVisible(find.byKey(const Key('about-credits')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('about-credits')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('notice-Open-Meteo')), 300, scrollable: scroll);
    expect(find.textContaining('Weather data by Open-Meteo.com (CC BY 4.0)'), findsOneWidget);
    expect(find.textContaining('non-commercial'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('notice-Open-Meteo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notice-Open-Meteo')));
    await tester.pumpAndSettle();
    expect(h.openedUrls, [Uri.parse('https://open-meteo.com')]);
  });

  testWidgets('About at 375 pt and 2x text: rows, no overflow; the version row copies the version', (tester) async {
    tester.view.physicalSize = const Size(750, 1334);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    String? clip;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final h = Harness();
    await h.state.init();
    await tester.pumpWidget(MaterialApp(home: AppScope(state: h.state, child: const AboutScreen())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('about-version')));
    await tester.pump();
    expect(clip, startsWith('MeshSonar '));
    await tester.pump(const Duration(seconds: 6));
    final scroll = find.byType(Scrollable).first;
    for (final k in ['about-version', 'about-privacy-policy', 'about-licence', 'about-credits']) {
      await tester.scrollUntilVisible(find.byKey(Key(k)), 100, scrollable: scroll);
      expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(44), reason: k);
    }
    await tester.ensureVisible(find.byKey(const Key('about-credits')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('about-credits')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('show-licenses')), 300, scrollable: scroll);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('show-licenses'))).height, greaterThanOrEqualTo(44));
    dismissAppToast();
  });

  testWidgets('build 77 (round 5 S12): About has the terms of service beside the privacy policy', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.state.init();
    await tester.pumpWidget(AppScope(state: h.state, child: const MaterialApp(home: AboutScreen())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('about-terms')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('about-terms'))).dy,
        greaterThan(tester.getTopLeft(find.byKey(const Key('about-privacy-policy'))).dy));
    await tester.tap(find.byKey(const Key('about-terms')));
    await tester.pump();
    expect(h.openedUrls.map((u) => u.path), contains('/terms'));
  });
}
