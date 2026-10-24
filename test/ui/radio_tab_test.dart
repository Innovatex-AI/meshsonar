import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/radio_presets.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/onboarding/ui_prefs.dart';
import 'package:meshsonar/ui/radio/radio_screen.dart';

import 'fakes.dart';

class _Src implements CommunityPresetSource {
  @override
  Future<List<CommunityPreset>> fetch() async => const [
        CommunityPreset(title: 'Elsewhere', freqMhz: 915.8, bwKhz: 250, sf: 10, cr: 5),
        CommunityPreset(title: 'Here', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5),
      ];
}

void main() {
  testWidgets('Radio tab: not connected state', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await tester.tap(find.text('Radio').last);
    await tester.pumpAndSettle();
    expect(find.text('Radio not connected'), findsOneWidget);
    expect(find.byKey(const Key('radio-readonly-note')), findsOneWidget);
  });

  testWidgets('Radio tab: connected radio compared with region and community presets', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.client.siteConfigResult = const SiteConfig(
      region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'),
      radioPreset: RadioPreset(name: 'MeshCore US Recommended', freqMhz: 910.525, bwKhz: 62.5, sf: 8, cr: 5),
    );
    await h.pumpApp(tester);
    await h.state.connectSimulator();
    await tester.pumpAndSettle();
    final radio = h.state.selfInfo!.radio;
    await tester.pumpWidget(MaterialApp(
      home: AppScope(state: h.state, child: RadioScreen(communitySource: _Src())),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('radio-settings')), findsOneWidget);
    expect(find.byKey(const Key('radio-region-compare')), findsOneWidget);
    expect(find.byKey(const Key('cmp-summary')), findsOneWidget);
    if (radio.sf != 8) expect(find.textContaining('differs'), findsWidgets);
    await tester.tap(find.byKey(const Key('radio-community-load')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('community-Here')), findsOneWidget);
    expect(find.byKey(const Key('community-Elsewhere')), findsOneWidget);
  });

  testWidgets('Settings: telemetry toggle persists', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('telemetry-toggle'));
    await tester.scrollUntilVisible(toggle, 200, scrollable: find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(h.state.settings.telemetryEnabled, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(h.state.settings.telemetryEnabled, isFalse);
    expect(h.settings.saved.telemetryEnabled, isFalse);
  });

  testWidgets('first run shows the disclosure sheet once; Turn off opts out', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.state.init();
    attachUiPrefs(h.state, UiPrefs(seen: true, telemetryDisclosed: false));
    await tester.pumpWidget(MeshSonarApp(state: h.state));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('telemetry-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('telemetry-off')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('telemetry-sheet')), findsNothing);
    expect(h.state.settings.telemetryEnabled, isFalse);
    expect(uiPrefsFor(h.state).telemetryDisclosed, isTrue);
  });
}
