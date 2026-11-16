// The Open-Meteo credit (CC BY 4.0) in About, in the third-party notices file, and findable from Settings search.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart' show openMeteoCredit;
import 'package:meshsonar/ui/about_screen.dart';
import 'package:meshsonar/ui/app.dart';
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
    await tester.scrollUntilVisible(find.byKey(const Key('notice-Open-Meteo')), 300, scrollable: scroll);
    expect(find.textContaining('Weather data by Open-Meteo.com (CC BY 4.0)'), findsOneWidget);
    expect(find.textContaining('non-commercial'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('notice-Open-Meteo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notice-Open-Meteo')));
    await tester.pumpAndSettle();
    expect(h.openedUrls, [Uri.parse('https://open-meteo.com')]);
  });
}
