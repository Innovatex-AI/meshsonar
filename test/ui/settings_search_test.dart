// Settings search, collapsible sections, every section rendering, 2.0x text at 320 dp, and the wide two-pane layout.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/settings/settings_index.dart';
import 'package:meshsonar/ui/settings/settings_kit.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _preset = RadioPreset(name: 'MeshCore US Recommended', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5);

Future<Harness> openSettings(WidgetTester tester, {bool key = true, bool site = true}) async {
  final h = Harness();
  if (key) h.approveKey();
  await h.state.init();
  if (site) {
    h.client.siteConfigResult = const SiteConfig(region: _region, radioPreset: _preset);
    await h.state.refreshSiteConfig();
  }
  await tester.pumpWidget(MeshSonarApp(state: h.state));
  await tester.pump();
  await openSettingsTab(tester);
  return h;
}

SettingsAnchors anchors(WidgetTester tester) => tester.widget<SettingsAnchors>(find.byType(SettingsAnchors));

Future<void> search(WidgetTester tester, String q) async {
  await tester.scrollUntilVisible(find.byKey(const Key('settings-search')), -300, scrollable: settingsList);
  await tester.enterText(find.byKey(const Key('settings-search')), q);
  await tester.pumpAndSettle();
}

void main() {
  group('searchSettings', () {
    test('ids are unique and every entry names a real section', () {
      final ids = settingsEntries.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final e in settingsEntries) {
        expect(settingsSections.any((s) => s.id == e.section), isTrue, reason: e.id);
        expect(e.summary.trim(), isNotEmpty, reason: '${e.id} needs its one-line explanation');
      }
    });

    test('matches titles, explanations, keywords and section names; title hits first', () {
      expect(searchSettings('').isEmpty, isTrue);
      expect(searchSettings('   ').isEmpty, isTrue);
      expect(searchSettings('zzqx'), isEmpty);
      expect(searchSettings('units').first.id, 'units-tile');
      expect(searchSettings('MILES').map((e) => e.id), contains('units-tile'), reason: 'case-insensitive keyword');
      expect(searchSettings('upload').first.id, 'auto-sync');
      expect(searchSettings('privacy zones').first.id, 'privacy-zones-website');
      expect(searchSettings('opt out').map((e) => e.id), contains('telemetry-toggle'));
      expect(searchSettings('data & storage').map((e) => e.id), contains('storage-drives'), reason: 'section name');
      expect(searchSettings('bug').map((e) => e.id), contains('report-problem'));
    });

    testWidgets('rows that are not on screen are never offered', (tester) async {
      final h = await openSettings(tester, key: false, site: false);
      final ids = searchSettings('erase', state: h.state).map((e) => e.id);
      expect(ids, isNot(contains('telemetry-erase-now')), reason: 'no key, no erase row');
      expect(searchSettings('preset', state: h.state).map((e) => e.id), isNot(contains('site-radio-preset')));
    });
  });

  testWidgets('every available entry has its row on screen (so a result can always jump to it)', (tester) async {
    useTallScreen(tester);
    final h = await openSettings(tester);
    final a = anchors(tester);
    for (final e in settingsEntries.where((e) => e.isAvailable(h.state))) {
      expect(a.keys[e.id]?.currentContext, isNotNull, reason: '${e.id} has no SettingsAnchor');
    }
    for (final s in settingsSections) {
      expect(find.byKey(Key('section-${s.id}')), findsOneWidget, reason: s.id);
    }
  });

  testWidgets('typing filters to results; tapping one jumps to the row, opens its section and tints it',
      (tester) async {
    useTallScreen(tester);
    await openSettings(tester);
    // Fold the Drives & uploads section first: the jump must open it.
    await showSetting(tester, 'section-toggle-drives');
    await tester.tap(find.byKey(const Key('section-toggle-drives')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-every')), findsNothing);

    await search(tester, 'upload interval');
    expect(find.byKey(const Key('settings-search-results')), findsOneWidget);
    expect(find.byKey(const Key('section-driver')), findsNothing, reason: 'sections are replaced by the results');
    expect(find.byKey(const Key('search-result-sync-every')), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-result-sync-every')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-search-results')), findsNothing);
    expect(find.byKey(const Key('sync-every')).hitTestable(), findsOneWidget, reason: 'scrolled into view');
    expect(anchors(tester).highlighted, 'sync-every');
    expect(tester.widget<TextField>(find.byKey(const Key('settings-search'))).controller!.text, isEmpty);
  });

  testWidgets('no match says so and suggests words; clearing brings the sections back', (tester) async {
    useTallScreen(tester);
    await openSettings(tester);
    await search(tester, 'qqqzzz');
    expect(find.textContaining('No setting matches "qqqzzz"'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-search-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('section-driver')), findsOneWidget);
  });

  testWidgets('a section folds and unfolds from its header, and says so to screen readers', (tester) async {
    useTallScreen(tester);
    final handle = tester.ensureSemantics();
    await openSettings(tester);
    await showSetting(tester, 'section-toggle-wardriving');
    expect(find.byKey(const Key('channel')), findsOneWidget);
    expect(tester.getSemantics(find.byKey(const Key('section-toggle-wardriving'))), isSemantics(isButton: true, isExpanded: true, hasExpandedState: true, isHeader: true, hasTapAction: true, isFocusable: true, label: 'WARDRIVING'));
    await tester.tap(find.byKey(const Key('section-toggle-wardriving')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('channel')), findsNothing);
    await tester.tap(find.byKey(const Key('section-toggle-wardriving')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('channel')), findsOneWidget);
    handle.dispose();
  });

  for (final (label, size, dpr) in [('phone 320 dp', const Size(960, 1920), 3.0), ('phone 390 dp', const Size(1170, 2532), 3.0)]) {
    testWidgets('2.0x text on a $label: every section and the search results render without overflow',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = dpr;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await openSettings(tester);
      for (final s in settingsSections) {
        await tester.scrollUntilVisible(find.byKey(Key('section-${s.id}')), 300, scrollable: settingsList);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: s.id);
      }
      // Walk to the very end so every row has been laid out on screen.
      await tester.scrollUntilVisible(find.byKey(const Key('show-intro')), 300, scrollable: settingsList);
      expect(tester.takeException(), isNull);
      await search(tester, 'upload');
      expect(find.byKey(const Key('search-result-auto-sync')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('wide screen (iPad landscape): sections on the left, one section on the right; search jumps across',
      (tester) async {
    tester.view.physicalSize = const Size(2388, 1668);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await openSettings(tester);
    expect(find.byKey(const Key('settings-section-pane')), findsOneWidget);
    for (final s in settingsSections) {
      expect(find.byKey(Key('section-nav-${s.id}')), findsOneWidget);
    }
    expect(find.byKey(const Key('section-driver')), findsOneWidget);
    expect(find.byKey(const Key('section-wardriving')), findsNothing, reason: 'one section at a time');
    await tester.tap(find.byKey(const Key('section-nav-privacy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('telemetry-toggle')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('section-toggle-privacy')), findsNothing, reason: 'nothing to fold in the detail pane');

    await tester.enterText(find.byKey(const Key('settings-search')), 'minimum distance');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search-result-min-distance')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('section-wardriving')), findsOneWidget);
    expect(find.byKey(const Key('min-distance')).hitTestable(), findsOneWidget);
    expect(tester.widget<ListTile>(find.byKey(const Key('section-nav-wardriving'))).selected, isTrue);
  });
}

