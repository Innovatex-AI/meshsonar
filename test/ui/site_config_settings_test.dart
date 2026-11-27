// Settings: region + radio-preset tiles from GET /api/cmh/site-config (app-settings-match-site spec, pieces 1-2),
// and the "manage privacy zones" deep link (piece 3).
// Build 76: Server URL, "Connected to" and "Radio preset" are on Account > Server (advanced); the website link for
// privacy zones is on the Privacy zones screen. showSetting opens the page a row lives on.
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/settings/settings_index.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

const _preset = RadioPreset(name: 'MeshCore US Recommended', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5);
const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');

Future<Harness> openSettings(WidgetTester tester, {SiteConfig? siteConfig}) async {
  useTallScreen(tester);
  final h = Harness();
  if (siteConfig != null) h.client.siteConfigResult = siteConfig;
  await h.pumpApp(tester);
  await tester.pumpAndSettle(); // let init()'s unawaited refreshSiteConfig() resolve
  await openSettingsTab(tester);
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets('state (a): no site-config yet (or a failed fetch) shows nothing extra', (tester) async {
    final h = await openSettings(tester); // default FakeCmatClient.siteConfig() throws (no siteConfigResult set)
    expect(h.state.siteConfig, isNull);
    await openSettingsPageRow(tester, 'account-advanced');
    expect(find.byKey(const Key('server-url')), findsOneWidget, reason: 'the page is open');
    expect(find.byKey(const Key('site-region')), findsNothing);
    expect(find.byKey(const Key('site-radio-preset')), findsNothing);
  });

  // Build 77 (round 5 S6): Server (advanced) shows which region the server answers for; the region's preset is shown
  // once, in My radio's settings (it was repeated here, with a path to a row that did not exist).
  Future<void> openRadioScreen(WidgetTester tester) async {
    await closeSettingsPage(tester);
    await showSetting(tester, 'radio-tab-link');
    await tester.tap(find.byKey(const Key('radio-tab-link')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('radio-region-preset')), 200,
        scrollable: find.descendant(of: find.byKey(const Key('radio-list')), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
  }

  testWidgets('state (b): siteConfig.radioPreset == null: Server (advanced) names the region, My radio\'s settings says "no preset"', (tester) async {
    final h = await openSettings(tester, siteConfig: const SiteConfig(region: _region, radioPreset: null));
    expect(h.state.siteConfig?.radioPreset, isNull);
    await showSetting(tester, 'site-region');
    expect(find.byKey(const Key('site-region')), findsOneWidget);
    expect(find.text('cmh.meshsonar.com'), findsOneWidget);
    expect(find.text('Radio preset'), findsNothing, reason: 'no second copy of the comparison on Server (advanced)');
    expect(find.textContaining('More > Radio setup'), findsNothing, reason: 'that row never existed');
    await openRadioScreen(tester);
    expect(find.text('This region has no suggested preset.'), findsOneWidget);
    expect(find.byKey(const Key('radio-region-compare')), findsNothing);
  });

  testWidgets('state (c): a preset with no radio connected: My radio\'s settings shows the preset', (tester) async {
    final h = await openSettings(tester, siteConfig: const SiteConfig(region: _region, radioPreset: _preset));
    expect(h.state.connected, isFalse);
    await openRadioScreen(tester);
    expect(find.byKey(const Key('radio-not-connected')), findsOneWidget);
    expect(find.byKey(const Key('radio-region-compare')), findsOneWidget);
    expect(find.textContaining('MeshCore US Recommended'), findsOneWidget);
  });

  testWidgets('state (d): a preset with a radio connected: My radio\'s settings compares them', (tester) async {
    final h = await openSettings(tester, siteConfig: const SiteConfig(region: _region, radioPreset: _preset));
    h.selfInfo = const SelfInfo(
      publicKey: 'ABCDEF0123',
      name: 'Truck Radio',
      radio: Radio(freqMhz: 915.0, bwKhz: 125.0, sf: 8, cr: 6, txDbm: 22),
      firmware: 'v1.9.0',
    );
    await h.state.connectSimulator();
    await tester.pumpAndSettle();
    expect(h.state.connected, isTrue);
    await openRadioScreen(tester);
    expect(find.byKey(const Key('radio-region-compare')), findsOneWidget);
    expect(find.textContaining('MeshCore US Recommended'), findsOneWidget);
    expect(find.textContaining('915.000'), findsWidgets);
  });

  testWidgets('a server-URL change clears the old siteConfig immediately, never shows it against the new server',
      (tester) async {
    final h = await openSettings(tester, siteConfig: const SiteConfig(region: _region, radioPreset: _preset));
    expect(h.state.siteConfig, isNotNull);
    await h.state.updateSettings(h.state.settings.copyWith(serverUrl: 'https://other.example.org'));
    expect(h.state.siteConfig, isNull, reason: 'cleared immediately, before the new fetch can answer');
    await tester.pumpAndSettle();
    await showSetting(tester, 'server-url');
    expect(find.byKey(const Key('site-region')), findsNothing);
    expect(find.byKey(const Key('site-radio-preset')), findsNothing);
    await closeSettingsPage(tester);
    expect(tester.widget<Text>(find.byKey(const Key('page-account-advanced-caption'))).data, 'other.example.org');
  });

  // Build 76: the "Manage privacy zones on the website" row left Settings; the link is on the Privacy zones screen.
  testWidgets('the privacy zones website link opens <server>/me/privacy from the Privacy zones screen; the old row id lands on Privacy zones', (tester) async {
    final h = await openSettings(tester);
    expect(find.byKey(const Key('privacy-zones-website'), skipOffstage: false), findsNothing);
    expect(find.text('Manage privacy zones on the website', skipOffstage: false), findsNothing);
    expect(settingsEntry('privacy-zones-website').id, 'privacy-zones', reason: 'an old link or search still lands on the Privacy zones row');
    await showSetting(tester, 'privacy-zones');
    await tester.tap(find.byKey(const Key('privacy-zones')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('zones-website'), skipOffstage: false));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('zones-website')), matching: find.text('Also on the website')), findsOneWidget);
    await tester.tap(find.byKey(const Key('zones-website')));
    await tester.pumpAndSettle();
    expect(h.openedUrls, [Uri.parse('https://meshsonar.com/me/privacy')]);
  });

  testWidgets('Privacy zones row opens the map editor, which works with no key and no connection', (tester) async {
    await openSettings(tester);
    await showSetting(tester, 'privacy-zones');
    expect(find.text('Privacy zones'), findsOneWidget);
    await tester.tap(find.byKey(const Key('privacy-zones')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('privacy-zones-screen')), findsOneWidget);
    expect(find.byKey(const Key('zones-map')), findsOneWidget);
    expect(find.textContaining('never uploaded'), findsOneWidget);
  });
}
