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

  testWidgets('state (b): siteConfig.radioPreset == null shows a clear "no preset" state', (tester) async {
    final h = await openSettings(tester, siteConfig: const SiteConfig(region: _region, radioPreset: null));
    expect(h.state.siteConfig?.radioPreset, isNull);
    await showSetting(tester, 'site-region');
    expect(find.byKey(const Key('site-region')), findsOneWidget);
    expect(find.text('cmh.meshsonar.com'), findsOneWidget);

    await showSetting(tester, 'site-radio-preset');
    expect(find.byKey(const Key('site-radio-preset')), findsOneWidget);
    expect(find.text('This region has no suggested preset.'), findsOneWidget);
    expect(find.byKey(const Key('site-radio-preset-no-radio')), findsNothing);
    expect(find.byKey(const Key('site-radio-preset-compare')), findsNothing);
  });

  testWidgets('state (c): a preset with no radio connected shows the preset and "no radio connected"', (tester) async {
    final h = await openSettings(tester, siteConfig: const SiteConfig(region: _region, radioPreset: _preset));
    expect(h.state.connected, isFalse);
    await showSetting(tester, 'site-radio-preset');
    expect(find.byKey(const Key('site-radio-preset-no-radio')), findsOneWidget);
    expect(find.byKey(const Key('site-radio-preset-compare')), findsNothing);
    expect(find.textContaining('MeshCore US Recommended'), findsOneWidget);
    expect(find.text('910.525 MHz · 62.5 kHz · SF7 · CR5'), findsOneWidget);
    expect(find.text('No radio connected to compare.'), findsOneWidget);
  });

  testWidgets('state (d): a preset with a radio connected shows both, clearly labeled', (tester) async {
    final h = await openSettings(tester, siteConfig: const SiteConfig(region: _region, radioPreset: _preset));
    // Harness.selfInfo's radio differs from the region preset so "yours" and "this region's" are distinguishable.
    h.selfInfo = const SelfInfo(
      publicKey: 'ABCDEF0123',
      name: 'Truck Radio',
      radio: Radio(freqMhz: 915.0, bwKhz: 125.0, sf: 8, cr: 6, txDbm: 22),
      firmware: 'v1.9.0',
    );
    await h.state.connectSimulator();
    await tester.pumpAndSettle();
    expect(h.state.connected, isTrue);

    await showSetting(tester, 'site-radio-preset');
    expect(find.byKey(const Key('site-radio-preset-compare')), findsOneWidget);
    expect(find.byKey(const Key('site-radio-preset-no-radio')), findsNothing);
    expect(find.text('Yours'), findsOneWidget);
    expect(find.text('915.000 MHz · 125.0 kHz · SF8 · CR6'), findsOneWidget);
    expect(find.textContaining('MeshCore US Recommended'), findsOneWidget);
    expect(find.text('910.525 MHz · 62.5 kHz · SF7 · CR5'), findsOneWidget);
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
