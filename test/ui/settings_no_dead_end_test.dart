// Settings has no dead ends (Andy, Oct 24 2026): every row in the settings index is either actionable, or a declared
// information row, or says why it is not usable and how to make it so (SettingsWhyNot); every disabled control sits
// next to such a reason. Walked in several real states. Also: every link row opens something real, the app bar's
// Sections index jumps to a section, the per-quantity unit rows work end to end, and the list lays out on 320 / 375 /
// 390 / 430 dp phones at 1.0x and 2.0x text in light and dark without overflow. Golden-free.
// Build 76: Settings is eight sections with the rare rows one level down on pages (settings_pages.dart). The walk
// covers the first level AND every page available in the state: each page is opened from its row (a row that opens
// nothing is a dead end), must lay out without an error, and its rows are held to the same rule.
import 'toast_test_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart' show AppState, RadioKind;
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/settings/settings_index.dart';
import 'package:meshsonar/ui/settings/settings_kit.dart';
import 'package:meshsonar/ui/settings/settings_pages.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _preset = RadioPreset(name: 'MeshCore US Recommended', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5);

DriveSession _ended(String id) =>
    DriveSession(id: id, startedAt: DateTime.utc(2026, 10, 15, 14), endedAt: DateTime.utc(2026, 10, 15, 15));

/// What one row contains.
class _Audit {
  int enabled = 0;
  int disabled = 0;
  bool whyNot = false;
  final texts = <String>[];
  final disabledWhat = <String>[];
}

_Audit _audit(Element root) {
  final a = _Audit();
  void count(bool on, Widget w) {
    if (on) {
      a.enabled++;
    } else {
      a.disabled++;
      a.disabledWhat.add('${w.runtimeType}${w.key == null ? '' : ' ${w.key}'}');
    }
  }

  void visit(Element e) {
    final w = e.widget;
    if (w is SettingsWhyNot) a.whyNot = true;
    if (w is Text && w.data != null) a.texts.add(w.data!);
    if (w is ListTile) {
      if (w.onTap != null || w.onLongPress != null) {
        count(w.enabled, w);
      } else if (!w.enabled) {
        count(false, w);
      }
    } else if (w is Switch) {
      count(w.onChanged != null, w);
    } else if (w is Slider) {
      count(w.onChanged != null, w);
    } else if (w is ButtonStyleButton) {
      count(w.enabled, w);
    } else if (w is IconButton) {
      count(w.onPressed != null, w);
    } else if (w is SegmentedButton) {
      count((w as dynamic).onSelectionChanged != null, w);
    } else if (w is TextField) {
      count(w.enabled ?? true, w);
    }
    e.visitChildren(visit);
  }

  visit(root);
  return a;
}

/// Opens page [id] the way a person does: from its row on the first level, or, for Units per quantity (the one page
/// with no row of its own), from the button on the Units row.
Future<void> _openPage(WidgetTester tester, String id) async {
  if (id != 'units') return openSettingsPageRow(tester, id);
  if (find.byKey(const Key('settings-page-units')).evaluate().isNotEmpty) return;
  await closeSettingsPage(tester);
  await showSetting(tester, 'units-per-quantity');
  await tester.tap(find.byKey(const Key('units-per-quantity')));
  await tester.pumpAndSettle();
}

/// The rule for one index row, read from the anchors of the level in front.
void _checkRow(SettingsEntry e, Map<String, GlobalKey> keys, List<String> problems) {
  final el = keys[e.id]?.currentContext as Element?;
  if (el == null) {
    problems.add('${e.id}: no row on screen (${e.where})');
    return;
  }
  final a = _audit(el);
  if (a.disabled > 0 && !a.whyNot) {
    problems.add('${e.id}: disabled ${a.disabledWhat.join(', ')} with no reason (SettingsWhyNot)');
  }
  if (a.enabled == 0 && !e.info && !a.whyNot) problems.add('${e.id}: nothing to do here and no reason why');
  if (e.info && !a.texts.any((t) => t.trim().length > 12 && t != e.title)) {
    problems.add('${e.id}: information row with no explanation');
  }
}

/// A label in a SegmentedButton never raises an overflow error: in a segment that is too narrow a word is broken in
/// two, or the text is cut. Lists the labels in front that do not fit their segment whole.
List<String> _brokenSegmentLabels(WidgetTester tester) {
  final out = <String>[];
  final labels = find.descendant(of: find.byWidgetPredicate((w) => w is SegmentedButton), matching: find.byType(RichText));
  for (final e in labels.evaluate()) {
    final p = e.renderObject! as RenderParagraph;
    final widestWord = p.getMinIntrinsicWidth(double.infinity);
    if (p.didExceedMaxLines || p.size.width + 0.5 < widestWord) {
      out.add('"${p.text.toPlainText()}" (${p.size.width.toStringAsFixed(0)} dp wide, its longest word needs ${widestWord.toStringAsFixed(0)})');
    }
  }
  return out;
}

Map<String, GlobalKey> _anchors(WidgetTester tester) => tester.widget<SettingsAnchors>(find.byType(SettingsAnchors)).keys;

/// Walks the first level and then every page available in [s], checking every row against the rule; returns the
/// problems (empty = no dead ends, nothing that fails to lay out). [at] runs extra checks while a level is in front:
/// the key is the page id, or null for the first level. Ends back on the first level.
Future<List<String>> _deadEnds(WidgetTester tester, AppState s, {Map<String?, void Function()> at = const {}}) async {
  final problems = <String>[];
  void layout(String where, {bool labels = true}) {
    final ex = tester.takeException();
    if (ex != null) problems.add('$where: does not lay out: ${ex.toString().split('\n').first}');
    if (!labels) return;
    for (final l in _brokenSegmentLabels(tester)) {
      problems.add('$where: a choice does not fit its segment: $l');
    }
  }

  await closeSettingsPage(tester);
  layout('first level');
  final first = _anchors(tester);
  for (final e in settingsEntries.where((e) => e.page == null && e.isAvailable(s))) {
    _checkRow(e, first, problems);
  }
  at[null]?.call();
  for (final p in settingsPages) {
    final available = p.isAvailable(s);
    if (!available) {
      if (find.byKey(Key('page-${p.id}')).evaluate().isNotEmpty) problems.add('page-${p.id}: a row for a page this build does not have');
      if (at.containsKey(p.id)) problems.add('page ${p.id}: not available in this state, so its checks never ran');
      continue;
    }
    if (p.id != 'units') {
      // The row that opens the page is a row like any other: it must be there and tappable.
      final el = first['page-${p.id}']?.currentContext as Element?;
      if (el == null) {
        problems.add('page-${p.id}: no row on the first level opens this page');
        continue;
      }
      if (_audit(el).enabled == 0) problems.add('page-${p.id}: the row cannot be tapped');
    }
    await _openPage(tester, p.id);
    if (find.byKey(Key('settings-page-${p.id}')).evaluate().isEmpty) {
      problems.add('page-${p.id}: the row opens nothing');
      await closeSettingsPage(tester);
      continue;
    }
    layout('page ${p.id}');
    final keys = _anchors(tester);
    final rows = settingsEntries.where((e) => e.page == p.id && e.isAvailable(s)).toList();
    if (rows.isEmpty && settingsEntries.every((e) => e.page != p.id)) problems.add('page ${p.id}: no row in the index is on it');
    for (final e in rows) {
      _checkRow(e, keys, problems);
    }
    at[p.id]?.call();
    await closeSettingsPage(tester);
    layout('back from page ${p.id}', labels: false); // the first level's choices were checked above
  }
  if (find.byType(SettingsPageScreen).evaluate().isNotEmpty) problems.add('a page stayed open after the walk');
  return problems;
}

Future<Harness> _open(WidgetTester tester, Harness h, {bool site = false}) async {
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

void main() {
  group('no dead ends: every row is actionable, information, or says why not', () {
    testWidgetsT('first run: no key, no server answer, no radio ever set up', (tester) async {
      useTallScreen(tester);
      final h = await _open(tester, Harness(antennaProfile: false));
      // The rows that cannot work yet say what makes them work (they are on Storage & diagnostics > Storage on this phone).
      expect(
          await _deadEnds(tester, h.state, at: {
            'storage-items': () {
              expect(find.textContaining('needs a driver key'), findsOneWidget, reason: 'repeater names');
              expect(find.textContaining('Nothing to remove: there are no drives on this phone.'), findsOneWidget);
            },
          }),
          isEmpty);
    });

    testWidgetsT('approved key, server answered, discovery on, uploads off, drives on the phone', (tester) async {
      useTallScreen(tester);
      final h = Harness()..approveKey();
      h.settings.saved = h.settings.saved.copyWith(discoveryMode: true, autoSync: false);
      h.store.seed(_ended('up'), [silentPing('u1')], syncedFirst: 1);
      h.store.seed(_ended('waiting'), [silentPing('w1'), silentPing('w2')], syncedFirst: 1);
      await _open(tester, h, site: true);
      const notSending = 'Turn on "Send pings to the mesh" to use it';
      expect(
          await _deadEnds(tester, h.state, at: {
            null: () => expect(find.textContaining(notSending), findsNWidgets(2), reason: 'Auto-ping and Minimum distance'),
            'driving-advanced': () => expect(find.textContaining(notSending), findsOneWidget, reason: 'Listen window'),
            'uploads': () {
              expect(find.textContaining('Turn that on first'), findsOneWidget);
              expect(find.textContaining('Turn them on first'), findsOneWidget);
            },
          }),
          isEmpty);
    });

    testWidgetsT('upload at end on, during the drive off: the interval says to turn it on', (tester) async {
      useTallScreen(tester);
      final h = Harness()..approveKey();
      h.settings.saved = h.settings.saved.copyWith(syncDuringDrive: false);
      await _open(tester, h);
      expect(
          await _deadEnds(tester, h.state, at: {
            'uploads': () => expect(find.textContaining('Turn it on to choose the interval'), findsOneWidget),
          }),
          isEmpty);
    });

    testWidgetsT('while driving: locked rows say so and how to unlock them', (tester) async {
      useTallScreen(tester);
      final h = Harness()..approveKey();
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await h.state.startDrive();
      await tester.pumpAndSettle();
      expect(h.state.driving, isTrue);
      await openSettingsTab(tester);
      expect(
          await _deadEnds(tester, h.state, at: {
            null: () {
              expect(find.textContaining('Locked while driving: stop the drive to change it.'), findsNWidgets(2), reason: 'channel and Send pings');
              expect(find.textContaining('Locked while this radio is on a drive'), findsOneWidget);
            },
          }),
          isEmpty);
      await h.state.stopDrive();
      await tester.pumpAndSettle();
    });

    testWidgetsT('key pending approval', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.settings.saved = const Settings(driverKey: 'secretkey-abcdef-1234', keyStatus: DriverKeyStatus.pending);
      await _open(tester, h);
      expect(await _deadEnds(tester, h.state), isEmpty);
    });

    test('information rows are only the read-only status rows', () {
      expect(settingsEntries.where((e) => e.info).map((e) => e.id), unorderedEquals(['site-region', 'site-radio-preset', 'last-upload', 'ping-message', 'ping-airtime', 'wardrive-counters', 'observer-status', 'diagnostics-power-counters']));
    });
  });

  testWidgetsT('every link row opens something real (a screen, a dialog, a sheet or the website)', (tester) async {
    useTallScreen(tester);
    final h = Harness(antennaProfile: false);
    await _open(tester, h);
    final list = find.byKey(const Key('settings-list'));
    for (final key in [
      'region-pick',
      'unit-distance',
      'unit-pressure',
      'privacy-what-shared',
      'privacy-location',
      'privacy-zones',
      'privacy-policy',
      'radio-tab-link',
      'antenna-none',
      'diagnostics-log',
      'report-problem',
      'about',
      'terms-of-service-link',
      'show-intro',
      'key-website',
    ]) {
      // A row on a page (unit-distance, privacy-what-shared) is reached through its page; showSetting opens it.
      if (key.startsWith('unit-')) await _openPage(tester, 'units');
      await showSetting(tester, key);
      final urls = h.openedUrls.length;
      await tester.tap(find.byKey(Key(key)));
      // Fixed pumps, not pumpAndSettle: some screens show a spinner while they load.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final opened = h.openedUrls.length > urls || list.hitTestable().evaluate().isEmpty;
      expect(opened, isTrue, reason: '$key opened nothing');
      // Back to Settings.
      var guard = 0;
      while (list.hitTestable().evaluate().isEmpty && guard++ < 4) {
        // The root Navigator first (dialogs, pushed screens sit above), then the More tab's own Navigator.
        for (final e in find.byType(Navigator, skipOffstage: false).evaluate().toList()) {
          if (await (tester.state(find.byElementPredicate((x) => x == e)) as NavigatorState).maybePop()) break;
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(list.hitTestable(), findsOneWidget, reason: 'came back from $key');
    }
    expect(h.openedUrls.map((u) => u.path), containsAll(['/privacy', '/terms']));
    // Build 76: "Manage privacy zones on the website" is no longer a Settings row; the link is on the Privacy zones
    // screen (zones-website), and the old id still resolves to the Privacy zones row.
    expect(find.byKey(const Key('privacy-zones-website')), findsNothing);
    expect(resolveSettingsTarget('privacy-zones-website')?.section, 'privacy');
    expect(settingsEntry('privacy-zones-website').id, 'privacy-zones');
    await showSetting(tester, 'privacy-zones');
    await tester.tap(find.byKey(const Key('privacy-zones')));
    await tester.pumpAndSettle();
    final site = find.byKey(const Key('zones-website'), skipOffstage: false); // built, below the fold of the panel
    await tester.ensureVisible(site); // the panel keeps all of its rows built
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('zones-website')));
    await tester.pump();
    expect(h.openedUrls.map((u) => u.path), contains('/me/privacy')); // /me/devices is a native screen now (Devices and keys)
  });

  group('app bar: Search and Sections', () {
    testWidgetsT('Sections lists every section; picking one opens it (even when folded) and scrolls to it',
        (tester) async {
      tester.view.physicalSize = const Size(1170, 3000); // 390 dp wide, tall enough that the index sheet lists all 8 sections
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final handle = tester.ensureSemantics();
      await _open(tester, Harness()..approveKey());
      expect(find.byTooltip('Jump to a section'), findsOneWidget);
      // Fold Storage & diagnostics, then jump to it from the index.
      await showSetting(tester, 'section-toggle-storage');
      await tester.tap(find.byKey(const Key('section-toggle-storage')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('page-storage-items')), findsNothing, reason: 'folded');
      await tester.scrollUntilVisible(find.byKey(const Key('settings-search')), -400, scrollable: settingsList);
      await tester.tap(find.byKey(const Key('settings-sections-action')));
      await tester.pumpAndSettle();
      for (final s in settingsSections) {
        await tester.scrollUntilVisible(find.byKey(Key('jump-${s.id}')), 100, scrollable: find.byType(Scrollable).last);
        expect(find.byKey(Key('jump-${s.id}')), findsOneWidget, reason: s.id);
      }
      await tester.scrollUntilVisible(find.text('Folded; opens when you jump to it'), -80, scrollable: find.descendant(of: find.byKey(const Key('settings-section-index')), matching: find.byType(Scrollable)).first);
      expect(find.text('Folded; opens when you jump to it'), findsOneWidget);
      await tester.tap(find.byKey(const Key('jump-storage')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-section-index')), findsNothing);
      expect(find.byKey(const Key('section-toggle-storage')).hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('page-storage-items')), findsOneWidget, reason: 'unfolded');
      expect(find.byKey(const Key('diagnostics-log')), findsOneWidget, reason: 'unfolded');
      handle.dispose();
    });

    testWidgetsT('Search from far down the list goes back to the field and focuses it', (tester) async {
      useTallScreen(tester);
      await _open(tester, Harness()..approveKey());
      await showSetting(tester, 'show-intro', step: 400);
      expect(find.byKey(const Key('settings-search')).hitTestable(), findsNothing);
      await tester.tap(find.byKey(const Key('settings-search-action')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-search')).hitTestable(), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const Key('settings-search')));
      expect(field.focusNode!.hasFocus, isTrue);
    });

    testWidgetsT('wide screens list sections on the left, so there is no Sections button', (tester) async {
      tester.view.physicalSize = const Size(2388, 1668);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await _open(tester, Harness());
      expect(find.byKey(const Key('settings-sections-action')), findsNothing);
      expect(find.byKey(const Key('settings-search-action')), findsOneWidget);
    });
  });

  group('per-quantity units', () {
    testWidgetsT('each quantity follows Units by default; picking one changes only it, everywhere, and saves it',
        (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.settings.saved = const Settings(units: UnitsPreference.metric);
      await _open(tester, h);
      // The quantity rows are one level down: Map & display > Units > "A different unit for one thing".
      expect(find.byKey(const Key('unit-speed')), findsNothing);
      await _openPage(tester, 'units');
      await showSetting(tester, 'unit-speed');
      expect(find.textContaining('Follows Units: km/h.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('unit-speed')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unit-speed-dialog')), findsOneWidget);
      expect(find.text('Follow Units (now km/h)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('unit-speed-option-imperial')));
      await tester.pumpAndSettle();
      expect(h.settings.saved.unitOverrides, const UnitOverrides(speed: UnitChoice.imperial));
      expect(h.state.units.speed(10), '22 mph');
      expect(h.state.units.distance(2345), '2.3 km');
      expect(find.textContaining('Always mph, whatever Units says.'), findsOneWidget);
      // The Units row on the first level (behind the page) names the quantity with its own unit.
      expect(tester.widget<Text>(find.byKey(const Key('units-explanation'), skipOffstage: false)).data, contains('Own unit: speed in mph.'));

      // Pressure has mmHg too.
      await showSetting(tester, 'unit-pressure');
      await tester.tap(find.byKey(const Key('unit-pressure')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('unit-pressure-option-mmHg')));
      await tester.pumpAndSettle();
      expect(h.state.units.pressure(1013.25), '760 mmHg');

      // Back to "all follow", with Undo (the button is on the Units row, on the first level).
      await showSetting(tester, 'units-reset-overrides');
      expect(find.textContaining('Own unit: speed in mph'), findsOneWidget);
      await tester.tap(find.byKey(const Key('units-reset-overrides')));
      await tester.pumpAndSettle();
      expect(h.settings.saved.unitOverrides.isEmpty, isTrue);
      expect(find.byKey(const Key('units-reset-overrides')), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(h.settings.saved.unitOverrides,
          const UnitOverrides(speed: UnitChoice.imperial, pressure: PressureChoice.mmHg));
    });

    testWidgetsT('a dismissed picker changes nothing; the current choice is marked for screen readers', (tester) async {
      useTallScreen(tester);
      final handle = tester.ensureSemantics();
      final h = Harness();
      h.settings.saved = const Settings(units: UnitsPreference.imperial, unitOverrides: UnitOverrides(temperature: UnitChoice.metric));
      await _open(tester, h);
      await _openPage(tester, 'units');
      await showSetting(tester, 'unit-temperature');
      await tester.tap(find.byKey(const Key('unit-temperature')));
      await tester.pumpAndSettle();
      expect(tester.getSemantics(find.byKey(const Key('unit-temperature-option-metric'))),
          isSemantics(isChecked: true, hasCheckedState: true, isInMutuallyExclusiveGroup: true, label: 'Celsius (°C)', isSelected: true, isButton: true, hasTapAction: true, isEnabled: true, hasEnabledState: true, isFocusable: true, hasSelectedState: true));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.settings.saved.unitOverrides, const UnitOverrides(temperature: UnitChoice.metric));
      handle.dispose();
    });

    test('search finds the quantity rows', () {
      expect(searchSettings('temperature').first.id, 'unit-temperature');
      expect(searchSettings('fahrenheit').first.id, 'unit-temperature');
      expect(searchSettings('mmhg').first.id, 'unit-pressure');
      expect(searchSettings('altitude').first.id, 'unit-height');
      expect(searchSettings('mph').map((e) => e.id), containsAll(['units-tile', 'unit-speed']));
    });
  });

  group('phones: 320 / 375 / 390 / 430 dp, 1.0x and 2.0x text, light and dark', () {
    for (final width in [320.0, 375.0, 390.0, 430.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final dark in [false, true]) {
          testWidgetsT('${width.toInt()} dp, ${scale}x text, ${dark ? 'dark' : 'light'}: every row lays out', (tester) async {
            tester.view.physicalSize = Size(width * 3, 2532);
            tester.view.devicePixelRatio = 3.0;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
            addTearDown(tester.view.reset);
            addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
            addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
            final h = Harness()..approveKey();
            h.settings.saved = h.settings.saved.copyWith(
                discoveryMode: true, unitOverrides: const UnitOverrides(speed: UnitChoice.imperial, pressure: PressureChoice.mmHg));
            await _open(tester, h, site: true);
            // The phone list is one scroll view: every section is built and laid out now.
            expect(tester.takeException(), isNull);
            // ... and so is every page, one after the other (each is opened, must lay out, and is walked).
            expect(await _deadEnds(tester, h.state), isEmpty);
            expect(Theme.of(tester.element(find.byKey(const Key('settings-list')))).brightness,
                dark ? Brightness.dark : Brightness.light);
            await tester.tap(find.byKey(const Key('settings-sections-action')));
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(find.byKey(const Key('jump-about-section')), 200,
                scrollable: find.descendant(of: find.byKey(const Key('settings-section-index')), matching: find.byType(Scrollable)));
            // The sheet is now only as tall as the tab area: nudge the list so the last row is fully inside.
            await tester.drag(find.byKey(const Key('settings-section-index')), const Offset(0, -150));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const Key('jump-about-section')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await _openPage(tester, 'units');
            await showSetting(tester, 'unit-pressure');
            await tester.tap(find.byKey(const Key('unit-pressure')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: 'the unit picker fits');
          });
        }
      }
    }
  });
}
