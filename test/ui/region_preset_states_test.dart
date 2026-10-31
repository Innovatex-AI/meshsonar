// Radio presets for 559 regions: a region with no preset says so honestly (with the stored reason when the server sends
// it), never shows another region's, shows where a preset comes from; the time zone shows when the server sends it;
// the catalogue (/v1/regions) parses presets with provenance; a switch in flight never shows the previous region's preset.
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_cache.dart';
import 'package:meshsonar/core/region_stats_api.dart';
import 'package:meshsonar/ui/region/preset_info.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

const _ukk = RegionInfo(slug: 'ukk', url: 'https://ukk.meshsonar.com');
const _aah = RegionInfo(slug: 'aah', url: 'https://aah.meshsonar.com');

RegionIndexEntry reg(String code, String name) =>
    RegionIndexEntry(code: code, slug: code.toLowerCase(), name: name, url: 'https://${code.toLowerCase()}.meshsonar.com', bbox: const [-180, -90, 180, 90]);

final settingsScroll = find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;

Future<Harness> openSettings(WidgetTester tester, SiteConfig sc, {List<RegionIndexEntry> index = const [], Settings? settings}) async {
  useTallScreen(tester);
  final h = Harness();
  h.client.siteConfigResult = sc;
  h.client.regionsIndexResult = index;
  if (settings != null) h.settings.saved = settings;
  await h.pumpApp(tester);
  await tester.pumpAndSettle();
  await openSettingsTab(tester);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.byKey(const Key('site-radio-preset')), 100, scrollable: settingsScroll);
  return h;
}

void main() {
  group('parsing', () {
    test('site-config: radioPresetNone and timezone are read; the reason is trimmed; only with a null preset', () async {
      final c = HttpCmatClient(Uri.parse('https://ukk.meshsonar.com'),
          client: MockClient((r) async => http.Response(
              '{"region":{"slug":"ukk","url":"https://ukk.meshsonar.com"},"radioPreset":null,"radioPresetNone":{"reason":"  Kazakhstan has no published LoRa preset.  ","source":"https://example.org/e"},"timezone":"Asia/Almaty","capabilities":{}}',
              200,
              headers: {'content-type': 'application/json'})));
      final sc = await c.siteConfig();
      expect(sc.radioPreset, isNull);
      expect(sc.radioPresetNone!.reason, 'Kazakhstan has no published LoRa preset.');
      expect(sc.radioPresetNone!.source, 'https://example.org/e');
      expect(sc.timezone, 'Asia/Almaty');
      final both = HttpCmatClient(Uri.parse('https://x'),
          client: MockClient((r) async => http.Response(
              '{"region":{"slug":"x","url":"https://x"},"radioPreset":{"name":"P","freqMHz":869.618,"bwKHz":62.5,"sf":8,"cr":8},"radioPresetNone":{"reason":"stale"},"capabilities":{}}', 200)));
      expect((await both.siteConfig()).radioPresetNone, isNull, reason: 'a preset and a reason cannot both be true; the preset wins');
    });

    test('site-config survives the disk cache round trip with the reason and zone', () {
      const sc = SiteConfig(region: _ukk, radioPresetNone: PresetNone(reason: 'No preset.', source: 'https://e'), timezone: 'Asia/Almaty');
      final back = siteConfigFromJson(siteConfigToJson(sc))!;
      expect(back.radioPreset, isNull);
      expect(back.radioPresetNone!.reason, 'No preset.');
      expect(back.radioPresetNone!.source, 'https://e');
      expect(back.timezone, 'Asia/Almaty');
      const old = SiteConfig(region: _ukk);
      expect(siteConfigFromJson(siteConfigToJson(old))!.radioPresetNone, isNull);
    });

    test('/v1/regions rows: preset with basis / source / note, none, reason, timezone, group', () {
      final hub = HubRegions.fromJson({
        'regions': [
          {'code': 'AAH', 'group': null, 'default_preset': {'name': 'EU/UK (Narrow)', 'freq_mhz': 869.618, 'bw_khz': 62.5, 'sf': 8, 'cr': 8, 'basis': 'published', 'source': 'https://api.meshcore.nz/api/v1/config'}},
          {'code': 'MOW', 'default_preset': {'name': 'Moscow (community)', 'freq_mhz': 868.731, 'bw_khz': 62.5, 'sf': 7, 'cr': 7, 'basis': 'community-observed', 'note': '398 of 500 observers', 'hash_bytes': 3}, 'timezone': 'Europe/Moscow'},
          {'code': 'UKK', 'default_preset': null, 'preset_none': {'reason': 'No preset published for KZ.'}},
          {'code': 'BAD', 'default_preset': {'name': 'x', 'freq_mhz': 'nope'}},
          {'nocode': 1},
          'x',
        ],
        'groups': [
          {'code': 'SWOH', 'name': 'Cincinnati/Dayton, US', 'members': ['CVG', 'DAY']}
        ],
      });
      expect(hub.byCode.keys, containsAll(['AAH', 'MOW', 'UKK', 'BAD']));
      expect(hub.byCode['AAH']!.preset!.basis, 'published');
      expect(hub.byCode['AAH']!.preset!.source, 'https://api.meshcore.nz/api/v1/config');
      expect(hub.byCode['MOW']!.preset!.note, '398 of 500 observers');
      expect(hub.byCode['MOW']!.timezone, 'Europe/Moscow');
      expect(hub.byCode['UKK']!.preset, isNull);
      expect(hub.byCode['UKK']!.presetNone!.reason, 'No preset published for KZ.');
      expect(hub.byCode['BAD']!.preset, isNull, reason: 'a malformed preset is no preset, not a guess');
      expect(hub.groupOf['CVG'], 'SWOH');
    });

    test('withProvenance only borrows provenance for the same numbers', () {
      const sc = RadioPreset(name: 'EU/UK (Narrow)', freqMhz: 869.618, bwKhz: 62.5, sf: 8, cr: 8);
      const cat = RadioPreset(name: 'EU/UK (Narrow)', freqMhz: 869.618, bwKhz: 62.5, sf: 8, cr: 8, basis: 'published', source: 'https://s', note: 'n');
      expect(sc.withProvenance(cat).basis, 'published');
      const other = RadioPreset(name: 'USA', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5, basis: 'published');
      expect(sc.withProvenance(other).basis, isNull, reason: 'different numbers: no borrowing');
      expect(sc.withProvenance(null).basis, isNull);
    });

    test('presetProvenanceText', () {
      expect(presetProvenanceText(const RadioPreset(name: 'a', freqMhz: 1, bwKhz: 1, sf: 7, cr: 5)), isNull);
      expect(presetProvenanceText(const RadioPreset(name: 'a', freqMhz: 1, bwKhz: 1, sf: 7, cr: 5, basis: 'published')), 'Published in the MeshCore preset list.');
      expect(presetProvenanceText(const RadioPreset(name: 'a', freqMhz: 1, bwKhz: 1, sf: 7, cr: 5, basis: 'community-observed', note: '398 of 500 observers')),
          'Observed from the community radios on the open analyzers. 398 of 500 observers');
    });
  });

  group('Settings > Region > Radio preset', () {
    testWidgets('no preset and a stored reason: the reason is shown as written, with its evidence, and no preset numbers', (tester) async {
      await openSettings(
          tester, const SiteConfig(region: _ukk, radioPresetNone: PresetNone(reason: 'Kazakhstan has no published LoRa preset; any frequency would be a guess.', source: 'https://example.org/kz')),
          index: [reg('UKK', 'East Kazakhstan, KZ')]);
      expect(find.text('This region has no suggested preset.'), findsOneWidget);
      expect(find.byKey(const Key('no-preset-note')), findsOneWidget);
      expect(find.text('East Kazakhstan, KZ has no radio preset on file.'), findsOneWidget);
      expect(find.byKey(const Key('no-preset-reason')), findsOneWidget);
      expect(find.text('Kazakhstan has no published LoRa preset; any frequency would be a guess.'), findsOneWidget);
      expect(find.text('Evidence: https://example.org/kz'), findsOneWidget);
      expect(find.textContaining('does not guess one'), findsOneWidget);
      expect(find.textContaining('910.525'), findsNothing, reason: 'never the US preset');
      expect(find.byKey(const Key('site-radio-preset-compare')), findsNothing);
    });

    testWidgets('no preset and no reason from the server: says so, still no preset', (tester) async {
      await openSettings(tester, const SiteConfig(region: _ukk), index: [reg('UKK', 'East Kazakhstan, KZ')]);
      expect(find.byKey(const Key('no-preset-no-reason')), findsOneWidget);
      expect(find.text('The server has not said why.'), findsOneWidget);
      expect(find.textContaining('MHz'), findsNothing);
    });

    testWidgets('the reason can come from the catalogue when site-config does not carry it', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.regionCatalogFetch = (_) async => HubRegions.fromJson({
            'regions': [
              {'code': 'UKK', 'default_preset': null, 'preset_none': {'reason': 'From the catalogue.'}, 'timezone': 'Asia/Almaty'}
            ]
          }); // before anything reads h.client: that builds the services
      h.client.siteConfigResult = const SiteConfig(region: _ukk);
      h.client.regionsIndexResult = [reg('UKK', 'East Kazakhstan, KZ')];
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      await openSettingsTab(tester);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('site-radio-preset')), 100, scrollable: settingsScroll);
      expect(find.text('From the catalogue.'), findsOneWidget);
      expect(h.state.viewingTimezone, 'Asia/Almaty');
      await tester.scrollUntilVisible(find.byKey(const Key('site-region-timezone')), 100, scrollable: settingsScroll);
      expect(find.text('Time zone of East Kazakhstan, KZ: Asia/Almaty'), findsOneWidget);
    });

    testWidgets('a preset shows where it comes from (catalogue provenance) next to the numbers', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.regionCatalogFetch = (_) async => HubRegions.fromJson({
            'regions': [
              {'code': 'AAH', 'default_preset': {'name': 'EU/UK (Narrow)', 'freq_mhz': 869.618, 'bw_khz': 62.5, 'sf': 8, 'cr': 8, 'basis': 'published'}}
            ]
          });
      h.client.siteConfigResult = const SiteConfig(region: _aah, radioPreset: RadioPreset(name: 'EU/UK (Narrow)', freqMhz: 869.618, bwKhz: 62.5, sf: 8, cr: 8));
      h.client.regionsIndexResult = [reg('AAH', 'Aachen, DE')];
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      await openSettingsTab(tester);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('site-radio-preset')), 100, scrollable: settingsScroll);
      expect(find.text('869.618 MHz · 62.5 kHz · SF8 · CR8'), findsOneWidget);
      expect(find.byKey(const Key('site-radio-preset-provenance')), findsOneWidget);
      expect(find.text('Published in the MeshCore preset list.'), findsOneWidget);
    });

    testWidgets('right after a region switch the previous region\'s site-config is NOT shown as the new region\'s', (tester) async {
      // Viewing UKK (picked) while the held site-config still belongs to AAH (the fetch for UKK has not answered).
      final h = await openSettings(tester, const SiteConfig(region: _aah, radioPreset: RadioPreset(name: 'EU/UK (Narrow)', freqMhz: 869.618, bwKhz: 62.5, sf: 8, cr: 8)),
          index: [reg('AAH', 'Aachen, DE'), reg('UKK', 'East Kazakhstan, KZ')], settings: const Settings(regionManual: 'UKK'));
      expect(h.state.viewingRegion!.code, 'UKK');
      expect(h.state.siteConfigIsForViewing, isFalse);
      expect(h.state.viewingPreset, isNull);
      expect(find.text('Loading this region\'s preset.'), findsOneWidget);
      expect(find.textContaining('869.618'), findsNothing);
    });
  });
}
