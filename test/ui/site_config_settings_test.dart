// Settings: region + radio-preset tiles from GET /api/cmh/site-config (app-settings-match-site spec, pieces 1-2),
// and the "manage privacy zones" deep link (piece 3).
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';

import 'fakes.dart';

final settingsScroll =
    find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;

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
    expect(find.byKey(const Key('site-region')), findsNothing);
    expect(find.byKey(const Key('site-radio-preset')), findsNothing);
  });

  testWidgets('state (b): siteConfig.radioPreset == null shows a clear "no preset" state', (tester) async {
    final h = await openSettings(tester, siteConfig: const SiteConfig(region: _region, radioPreset: null));
    expect(h.state.siteConfig?.radioPreset, isNull);
    await tester.scrollUntilVisible(find.byKey(const Key('site-region')), 100, scrollable: settingsScroll);
    expect(find.byKey(const Key('site-region')), findsOneWidget);
    expect(find.text('cmh.meshsonar.com'), findsOneWidget);

    await tester.scrollUntilVisible(find.byKey(const Key('site-radio-preset')), 100, scrollable: settingsScroll);
    expect(find.byKey(const Key('site-radio-preset')), findsOneWidget);
    expect(find.text('This region has no suggested preset.'), findsOneWidget);
    expect(find.byKey(const Key('site-radio-preset-no-radio')), findsNothing);
    expect(find.byKey(const Key('site-radio-preset-compare')), findsNothing);
  });

  testWidgets('state (c): a preset with no radio connected shows the preset and "no radio connected"', (tester) async {
    final h = await openSettings(tester, siteConfig: const SiteConfig(region: _region, radioPreset: _preset));
    expect(h.state.connected, isFalse);
    await tester.scrollUntilVisible(find.byKey(const Key('site-radio-preset')), 100, scrollable: settingsScroll);
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

    await tester.scrollUntilVisible(find.byKey(const Key('site-radio-preset')), 100, scrollable: settingsScroll);
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
    await tester.scrollUntilVisible(find.byKey(const Key('server-url')), 100, scrollable: settingsScroll);
    expect(find.byKey(const Key('site-region')), findsNothing);
  });

  testWidgets('privacy-zones-website opens <server>/me/privacy, styled like "Get a key on the website"', (tester) async {
    final h = await openSettings(tester);
    await tester.scrollUntilVisible(find.byKey(const Key('privacy-zones-website')), 100, scrollable: settingsScroll);
    expect(find.text('Manage privacy zones on the website'), findsOneWidget);
    await tester.tap(find.byKey(const Key('privacy-zones-website')));
    await tester.pumpAndSettle();
    expect(h.openedUrls, [Uri.parse('https://meshsonar.com/me/privacy')]);
  });
}
