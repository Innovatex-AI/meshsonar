// Settings search, collapsible sections, every section rendering, 2.0x text at 320 dp, and the wide two-pane layout.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/settings/settings_index.dart';
import 'package:meshsonar/ui/settings/settings_kit.dart';
import 'package:meshsonar/ui/settings/settings_pages.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

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
        if (e.page != null) expect(settingsPage(e.page!).section, e.section, reason: '${e.id}: its page is in its section');
      }
      expect(settingsSections.length, lessThanOrEqualTo(8), reason: 'Andy, build 76: at most 8 sections');
      expect(settingsPages.map((p) => p.id).toSet().length, settingsPages.length);
    });

    test('pre-76 section ids, page ids and row ids all resolve to a place (deep links keep working)', () {
      for (final old in ['driver', 'region', 'wardriving', 'radio', 'my-radios-section', 'meshtrack', 'battery', 'display', 'maps', 'privacy', 'observer', 'notifications', 'drives', 'storage', 'diagnostics', 'about-section']) {
        final t = resolveSettingsTarget(old);
        expect(t, isNotNull, reason: old);
        expect(settingsSections.any((s) => s.id == t!.section), isTrue, reason: old);
        expect(sectionInfo(old).id, t!.section);
      }
      expect(resolveSettingsTarget('observer')!.page, 'observer');
      expect(resolveSettingsTarget('my-radios-section')!.page, 'claims');
      expect(resolveSettingsTarget('battery')!.page, 'battery');
      expect(resolveSettingsTarget('drives')!.page, 'uploads');
      final r = resolveSettingsTarget('sync-every')!;
      expect((r.section, r.page, r.anchor), ('wardriving', 'uploads', 'sync-every'));
      // The two rows that were merged into another keep their id as a second anchor on it.
      expect(resolveSettingsTarget('observer-share')!.anchor, 'observer-share');
      expect(settingsEntry('observer-share').id, 'telemetry-toggle');
      expect(settingsEntry('privacy-zones-website').id, 'privacy-zones');
      expect(resolveSettingsTarget('nope'), isNull);
    });

    test('nothing of the removed features is left in the index', () {
      for (final e in settingsEntries) {
        final text = '${e.id} ${e.title} ${e.summary} ${e.keywords.join(' ')}'.toLowerCase();
        for (final gone in ['offline map', 'map pack', 'simple basemap', 'basemap', 'passenger']) {
          expect(text, isNot(contains(gone)), reason: e.id);
        }
    });

    test('matches titles, explanations, keywords and section names; title hits first', () {
      expect(searchSettings('').isEmpty, isTrue);
      expect(searchSettings('   ').isEmpty, isTrue);
      expect(searchSettings('zzqx'), isEmpty);
      expect(searchSettings('units').first.id, 'units-tile');
      expect(searchSettings('MILES').map((e) => e.id), contains('units-tile'), reason: 'case-insensitive keyword');
      expect(searchSettings('upload').first.id, 'auto-sync');
      expect(searchSettings('privacy zones').first.id, 'privacy-zones');
      expect(searchSettings('opt out').map((e) => e.id), contains('telemetry-toggle'));
      expect(searchSettings('storage & diagnostics').map((e) => e.id), contains('diagnostics-log'), reason: 'section name');
      // Build 76: a row is still found by the name of the section it used to be in, and by its page's name.
      expect(searchSettings('data & storage').map((e) => e.id), contains('storage-drives'), reason: 'old section name');
      expect(searchSettings('drives & uploads').map((e) => e.id), contains('sync-every'), reason: 'old section name');
      expect(searchSettings('wardriving').map((e) => e.id), containsAll(['channel', 'ping-airtime']), reason: 'old section name');
      expect(searchSettings('battery details').map((e) => e.id), contains('battery-gps'), reason: 'page name');
      for (final e in settingsEntries) {
        expect(e.was, isNotNull, reason: '${e.id} keeps the name of its pre-76 section');
        expect(searchSettings(e.was!).map((x) => x.id), contains(e.id), reason: '${e.id} by "${e.was}"');
      }
      expect(searchSettings('bug').map((e) => e.id), contains('report-problem'));
    });

    testWidgets('rows that are not on screen are never offered', (tester) async {
      final h = await openSettings(tester, key: false, site: false);
      final ids = searchSettings('erase', state: h.state).map((e) => e.id);
      expect(ids, isNot(contains('telemetry-erase-now')), reason: 'no key, no erase row');
      expect(searchSettings('preset', state: h.state).map((e) => e.id), isNot(contains('site-radio-preset')));
    });
  });

  testWidgets('every available entry has its row: on the first level, or on its page (so a result can always jump to it)',
      (tester) async {
    useTallScreen(tester);
    final h = await openSettings(tester);
    final avail = settingsEntries.where((e) => e.isAvailable(h.state)).toList();
    final a = anchors(tester);
    for (final e in avail.where((e) => e.page == null)) {
      expect(a.keys[e.id]?.currentContext, isNotNull, reason: '${e.id} has no SettingsAnchor on the first level');
    }
    for (final alias in settingsEntryAliases.keys) {
      expect(a.keys[alias]?.currentContext, isNotNull, reason: 'the merged row $alias keeps its anchor');
    }
    for (final s in settingsSections) {
      expect(find.byKey(Key('section-${s.id}')), findsOneWidget, reason: s.id);
    }
    var firstLevel = 0;
    for (final s in settingsSections) {
      firstLevel += settingsSectionRows(tester.element(find.byKey(Key('section-${s.id}'))), s.id).length;
    }
    expect(firstLevel, lessThanOrEqualTo(50), reason: 'the first level stays short (it was about 95 rows before build 76)');
    for (final p in settingsPages.where((p) => p.isAvailable(h.state))) {
      await openSettingsPageRow(tester, p.id);
      final pa = anchors(tester);
      for (final e in avail.where((e) => e.page == p.id)) {
        expect(pa.keys[e.id]?.currentContext, isNotNull, reason: '${e.id} has no SettingsAnchor on the page ${p.id}');
      }
      expect(tester.takeException(), isNull, reason: p.id);
      await closeSettingsPage(tester);
    }
  });

  testWidgets('typing filters to results; a first-level result jumps to the row, opens its section and tints it',
      (tester) async {
    useTallScreen(tester);
    await openSettings(tester);
    // Fold the Driving section first: the jump must open it.
    await showSetting(tester, 'section-toggle-wardriving');
    await tester.tap(find.byKey(const Key('section-toggle-wardriving')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('min-distance')), findsNothing);

    await search(tester, 'minimum distance');
    expect(find.byKey(const Key('settings-search-results')), findsOneWidget);
    expect(find.byKey(const Key('section-driver')), findsNothing, reason: 'sections are replaced by the results');
    await tester.tap(find.byKey(const Key('search-result-min-distance')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-search-results')), findsNothing);
    expect(find.byKey(const Key('min-distance')).hitTestable(), findsOneWidget, reason: 'scrolled into view');
    expect(anchors(tester).highlighted, 'min-distance');
    expect(tester.widget<TextField>(find.byKey(const Key('settings-search'))).controller!.text, isEmpty);
  });

  testWidgets('a result on a page opens that page with the row tinted; Back returns to the row that opens the page',
      (tester) async {
    useTallScreen(tester);
    await openSettings(tester);
    await search(tester, 'upload interval');
    expect(find.textContaining('Driving > Uploads'), findsWidgets, reason: 'the result says where the row is');
    await tester.tap(find.byKey(const Key('search-result-sync-every')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-page-uploads')), findsOneWidget);
    expect(find.byKey(const Key('sync-every')).hitTestable(), findsOneWidget);
    expect(anchors(tester).highlighted, 'sync-every');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('page-uploads')).hitTestable(), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('settings-search'))).controller!.text, isEmpty);
  });

  testWidgets('a link that names a pre-76 section still lands: Observer and Claimed radios open their page', (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    await h.pumpApp(tester);
    // The More tab's own links still pass the pre-76 ids (lib/ui/shell/more_tab.dart).
    for (final (item, page, row) in [(MoreItem.observer, 'observer', 'observer-status'), (MoreItem.myRadios, 'claims', 'my-radios')]) {
      ShellController.active!.openMore(item);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('settings-page-$page')), findsOneWidget, reason: '$item');
      expect(find.byKey(Key(row)), findsOneWidget, reason: '$item');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(Key('page-$page')).hitTestable(), findsOneWidget, reason: 'Back shows the row the page opens from');
    }
    ShellController.active!.openMore(MoreItem.notifications);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notif-state')).hitTestable(), findsOneWidget);
    ShellController.active!.openMore(MoreItem.wardriving);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('send-pings')).hitTestable(), findsOneWidget);
  });

  testWidgets('Share with MeshSonar is one switch in Settings, with both of its old keys', (tester) async {
    useTallScreen(tester);
    await openSettings(tester);
    await showSetting(tester, 'telemetry-toggle');
    expect(find.byKey(const Key('telemetry-toggle')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('observer-share-toggle')), matching: find.byKey(const Key('telemetry-toggle'))), findsOneWidget);
    expect(find.text('Share with MeshSonar'), findsOneWidget);
    await openSettingsPageRow(tester, 'observer');
    expect(find.text('Share with MeshSonar'), findsNothing, reason: 'not repeated on the Observer page');
    await openSettingsPageRow(tester, 'sharing');
    expect(find.byKey(const Key('telemetry-toggle')), findsNothing, reason: 'not repeated on What is shared');
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
    expect(tester.getSemantics(find.byKey(const Key('section-toggle-wardriving'))), isSemantics(isButton: true, isExpanded: true, hasExpandedState: true, isHeader: true, hasTapAction: true, isFocusable: true, label: 'DRIVING'));
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
      // Every page one level down, top to bottom, at the same text size.
      for (final p in settingsPages.where((p) => find.byKey(Key('page-${p.id}')).evaluate().isNotEmpty)) {
        await openSettingsPageRow(tester, p.id);
        await tester.drag(settingsList, const Offset(0, -6000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'page ${p.id}');
        await closeSettingsPage(tester);
      }
      await search(tester, 'upload');
      await tester.pumpAndSettle();
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
    final pane = find.descendant(of: find.byKey(const Key('settings-section-pane')), matching: find.byType(Scrollable)).first;
    for (final s in settingsSections) {
      await tester.scrollUntilVisible(find.byKey(Key('section-nav-${s.id}')), 80, scrollable: pane);
      expect(find.byKey(Key('section-nav-${s.id}')), findsOneWidget);
    }
    await tester.scrollUntilVisible(find.byKey(const Key('settings-search')), -80, scrollable: pane);
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

