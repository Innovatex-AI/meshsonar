// Settings has no dead ends (Andy, Oct 24 2026): every row in the settings index is either actionable, or a declared
// information row, or says why it is not usable and how to make it so (SettingsWhyNot); every disabled control sits
// next to such a reason. Walked in several real states. Also: every link row opens something real, the app bar's
// Sections index jumps to a section, the per-quantity unit rows work end to end, and the list lays out on 320 / 375 /
// 390 / 430 dp phones at 1.0x and 2.0x text in light and dark without overflow. Golden-free.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart' show AppState, RadioKind;
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/settings/settings_index.dart';
import 'package:meshsonar/ui/settings/settings_kit.dart';

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

/// Checks every row on screen against the rule; returns the problems (empty = no dead ends).
List<String> _deadEnds(WidgetTester tester, AppState s) {
  final keys = tester.widget<SettingsAnchors>(find.byType(SettingsAnchors)).keys;
  final problems = <String>[];
  for (final e in settingsEntries.where((e) => e.isAvailable(s))) {
    final el = keys[e.id]?.currentContext as Element?;
    if (el == null) {
      problems.add('${e.id}: no row on screen');
      continue;
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
    testWidgets('first run: no key, no server answer, no radio ever set up', (tester) async {
      useTallScreen(tester);
      final h = await _open(tester, Harness(antennaProfile: false));
      expect(_deadEnds(tester, h.state), isEmpty);
      // The rows that cannot work yet say what makes them work.
      expect(find.textContaining('needs a driver key'), findsOneWidget, reason: 'repeater names');
      expect(find.textContaining('Nothing to remove: there are no drives on this phone.'), findsOneWidget);
    });

    testWidgets('approved key, server answered, discovery on, uploads off, drives on the phone', (tester) async {
      useTallScreen(tester);
      final h = Harness()..approveKey();
      h.settings.saved = h.settings.saved.copyWith(discoveryMode: true, autoSync: false);
      h.store.seed(_ended('up'), [silentPing('u1')], syncedFirst: 1);
      h.store.seed(_ended('waiting'), [silentPing('w1'), silentPing('w2')], syncedFirst: 1);
      await _open(tester, h, site: true);
      expect(_deadEnds(tester, h.state), isEmpty);
      expect(find.textContaining('Turn Discovery (listen-only) off to use it'), findsNWidgets(2));
      expect(find.textContaining('Turn that on first'), findsOneWidget);
      expect(find.textContaining('Turn them on first'), findsOneWidget);
    });

    testWidgets('upload at end on, during the drive off: the interval says to turn it on', (tester) async {
      useTallScreen(tester);
      final h = Harness()..approveKey();
      h.settings.saved = h.settings.saved.copyWith(syncDuringDrive: false);
      await _open(tester, h);
      expect(_deadEnds(tester, h.state), isEmpty);
      expect(find.textContaining('Turn it on to choose the interval'), findsOneWidget);
    });

    testWidgets('while driving: locked rows say so and how to unlock them', (tester) async {
      useTallScreen(tester);
      final h = Harness()..approveKey();
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await h.state.startDrive();
      await tester.pumpAndSettle();
      expect(h.state.driving, isTrue);
      await openSettingsTab(tester);
      expect(_deadEnds(tester, h.state), isEmpty);
      expect(find.textContaining('Locked while driving: stop the drive to change it.'), findsOneWidget);
      expect(find.textContaining('Locked while this radio is on a drive'), findsOneWidget);
      await h.state.stopDrive();
      await tester.pumpAndSettle();
    });

    testWidgets('key pending approval', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.settings.saved = const Settings(driverKey: 'secretkey-abcdef-1234', keyStatus: DriverKeyStatus.pending);
      await _open(tester, h);
      expect(_deadEnds(tester, h.state), isEmpty);
    });

    test('information rows are only the read-only status rows', () {
      expect(settingsEntries.where((e) => e.info).map((e) => e.id), unorderedEquals(['site-region', 'site-radio-preset', 'last-upload']));
    });
  });

  testWidgets('every link row opens something real (a screen, a dialog, a sheet or the website)', (tester) async {
    useTallScreen(tester);
    final h = Harness(antennaProfile: false);
    await _open(tester, h);
    final list = find.byKey(const Key('settings-list'));
    for (final key in [
      'region-pick',
      'unit-distance',
      'unit-pressure',
      'offline-maps',
      'privacy-what-shared',
      'privacy-location',
      'privacy-zones-website',
      'radio-tab-link',
      'antenna-none',
      'diagnostics-log',
      'report-problem',
      'about',
      'show-intro',
      'key-website',
      'storage-offline-maps-open',
    ]) {
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
    expect(h.openedUrls.map((u) => u.path), containsAll(['/me/privacy', '/me/devices']));
  });

  group('app bar: Search and Sections', () {
    testWidgets('Sections lists every section; picking one opens it (even when folded) and scrolls to it',
        (tester) async {
      tester.view.physicalSize = const Size(1170, 2532); // 390 dp phone
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final handle = tester.ensureSemantics();
      await _open(tester, Harness()..approveKey());
      expect(find.byTooltip('Jump to a section'), findsOneWidget);
      // Fold Data & storage, then jump to it from the index.
      await showSetting(tester, 'section-toggle-storage');
      await tester.tap(find.byKey(const Key('section-toggle-storage')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('settings-search')), -400, scrollable: settingsList);
      await tester.tap(find.byKey(const Key('settings-sections-action')));
      await tester.pumpAndSettle();
      for (final s in settingsSections) {
        expect(find.byKey(Key('jump-${s.id}')), findsOneWidget, reason: s.id);
      }
      expect(find.text('Folded; opens when you jump to it'), findsOneWidget);
      await tester.tap(find.byKey(const Key('jump-storage')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-section-index')), findsNothing);
      expect(find.byKey(const Key('section-toggle-storage')).hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('storage-drives')), findsOneWidget, reason: 'unfolded');
      handle.dispose();
    });

    testWidgets('Search from far down the list goes back to the field and focuses it', (tester) async {
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

    testWidgets('wide screens list sections on the left, so there is no Sections button', (tester) async {
      tester.view.physicalSize = const Size(2388, 1668);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await _open(tester, Harness());
      expect(find.byKey(const Key('settings-sections-action')), findsNothing);
      expect(find.byKey(const Key('settings-search-action')), findsOneWidget);
    });
  });

  group('per-quantity units', () {
    testWidgets('each quantity follows Units by default; picking one changes only it, everywhere, and saves it',
        (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.settings.saved = const Settings(units: UnitsPreference.metric);
      await _open(tester, h);
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
      expect(find.textContaining('Own choice below: speed in mph.'), findsOneWidget);

      // Pressure has mmHg too.
      await showSetting(tester, 'unit-pressure');
      await tester.tap(find.byKey(const Key('unit-pressure')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('unit-pressure-option-mmHg')));
      await tester.pumpAndSettle();
      expect(h.state.units.pressure(1013.25), '760 mmHg');

      // Back to "all follow", with Undo.
      await showSetting(tester, 'units-reset-overrides');
      await tester.tap(find.byKey(const Key('units-reset-overrides')));
      await tester.pumpAndSettle();
      expect(h.settings.saved.unitOverrides.isEmpty, isTrue);
      expect(find.byKey(const Key('units-reset-overrides')), findsNothing);
      await tester.tap(find.byKey(const Key('units-reset-undo')));
      await tester.pumpAndSettle();
      expect(h.settings.saved.unitOverrides,
          const UnitOverrides(speed: UnitChoice.imperial, pressure: PressureChoice.mmHg));
    });

    testWidgets('a dismissed picker changes nothing; the current choice is marked for screen readers', (tester) async {
      useTallScreen(tester);
      final handle = tester.ensureSemantics();
      final h = Harness();
      h.settings.saved = const Settings(units: UnitsPreference.imperial, unitOverrides: UnitOverrides(temperature: UnitChoice.metric));
      await _open(tester, h);
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
          testWidgets('${width.toInt()} dp, ${scale}x text, ${dark ? 'dark' : 'light'}: every row lays out', (tester) async {
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
            expect(_deadEnds(tester, h.state), isEmpty);
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
