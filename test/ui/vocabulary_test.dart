// The 0.38 vocabulary (build plan §4.5 item 6, checked here as the plan says): Radio (the connected device), Observer (this
// phone sharing public packets), Share with MeshSonar (the master switch), MQTT feed (an outside site you feed), Plan (a
// saved set of nodes), Node (any repeater, room or planned site), Link (a pair), Estimate (every modelled number), Measured
// (from drives and observers). The retired terms (Home observer, Become an observer, Drive observer) never come back, and
// the list of radios you claimed is "Claimed radios" everywhere ("My radios" was the old name).
//
// Two checks: the source of the surfaces the table covers (the Plan tab, Settings > Observer, the privacy section, the
// disclosure sheet, More, the observer guide, Delete my data, the node actions) holds no retired term at all, comments
// included; and the words people read there (the constants and labels those screens show) use the table's terms.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/data_categories.dart' show savedWithDriveNote;
import 'package:meshsonar/ui/plan/plan_modes.dart' show planModes;
import 'package:meshsonar/ui/radios/observer_join_screen.dart';
import 'package:meshsonar/ui/settings/data_sharing.dart';
import 'package:meshsonar/ui/settings/delete_my_data.dart';
import 'package:meshsonar/ui/settings/observer_section.dart';
import 'package:meshsonar/ui/settings/privacy_section.dart' show privacySettingsEntries;
import 'package:meshsonar/ui/settings/settings_index.dart' show settingsEntry, settingsSections;
import 'package:meshsonar/ui/telemetry_sheet.dart' show disclosureHeading, disclosureLead;

/// The retired terms, as they were written (any case).
final RegExp retired = RegExp(r'home observer|become an observer|drive observer|\bmy radios\b', caseSensitive: false);

/// Files of the surfaces the vocabulary table covers.
List<File> surfaceFiles() => [
      for (final dir in ['lib/ui/plan', 'lib/ui/nodes'])
        ...Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')),
      // MeshTrack (MT-6 builds it; the gate holds as soon as the folder exists).
      for (final dir in optionalSurfaceDirs)
        if (Directory(dir).existsSync())
          ...Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')),
      for (final f in [
        'lib/ui/shell/plan_tab.dart',
        'lib/ui/shell/more_tab.dart',
        'lib/ui/settings/observer_section.dart',
        'lib/ui/settings/privacy_section.dart',
        'lib/ui/settings/data_sharing.dart',
        'lib/ui/settings/delete_my_data.dart',
        'lib/ui/settings/settings_index.dart',
        'lib/ui/telemetry_sheet.dart',
        'lib/core/data_categories.dart',
        'lib/ui/radios/observer_join_screen.dart',
      ])
        File(f),
    ];

/// Surface folders another branch may not have created yet: scanned when present.
const optionalSurfaceDirs = ['lib/ui/meshtrack'];

/// "APRS" is a registered trademark in amateur radio (MeshTrack plan section 0): no product string contains it. Internal
/// comments may say "APRS-style".
final RegExp aprs = RegExp('aprs', caseSensitive: false);

/// The user-facing string literals on [lines] (comment lines skipped) that match [re], as `path:line: text`.
List<String> literalHits(String path, List<String> lines, RegExp re) {
  final hits = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i].trimLeft();
    if (l.startsWith('//')) continue;
    // A trailing comment is not copy either (a quote inside it would read as a literal).
    final code = l.replaceFirst(RegExp(r'\s//\s.*$'), '');
    for (final m in _literal.allMatches(code)) {
      final s = m.group(1) ?? m.group(2) ?? '';
      if (re.hasMatch(s)) hits.add('$path:${i + 1}: $s');
    }
  }
  return hits;
}

final RegExp _literal = RegExp(r"'((?:[^'\\\n]|\\.)*)'|" r'"((?:[^"\\\n]|\\.)*)"');

void main() {
  test('the surfaces the table covers hold no retired term, not even in a comment', () {
    final hits = <String>[];
    for (final f in surfaceFiles()) {
      expect(f.existsSync(), isTrue, reason: '${f.path} moved: update this list');
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (retired.hasMatch(lines[i])) hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('no string a person can read anywhere in the app uses a retired term', () {
    final hits = <String>[];
    final files = [
      ...Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')),
    ];
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trimLeft();
        if (l.startsWith('//')) continue;
        for (final m in _literal.allMatches(l)) {
          final s = m.group(1) ?? m.group(2) ?? '';
          // `home_observer` is the old settings key the reader ignores (lib/core/api.dart), not copy.
          if (retired.hasMatch(s)) hits.add('${f.path}:${i + 1}: $s');
        }
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('no string a person can read anywhere in the app contains "APRS" (MeshTrack plan section 0, MT-8)', () {
    final hits = <String>[
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
        ...literalHits(f.path, f.readAsLinesSync(), aprs),
    ];
    expect(hits, isEmpty, reason: 'Say MeshTrack, never APRS:\n${hits.join('\n')}');
  });

  test('the APRS check catches copy and skips comments', () {
    final lines = [
      "  // APRS-style friend tracking, internal note",
      "  /// Like 'APRS' on a ham band.",
      "  Text('MeshAPRS friends'),",
      '  const t = "Share like aprs";',
      "  final x = 'MeshTrack'; // not 'APRS' here",
    ];
    expect(literalHits('x.dart', lines, aprs), ['x.dart:3: MeshAPRS friends', 'x.dart:4: Share like aprs']);
  });

  test('no comment names a deleted Plan screen (link_screen, painter_screen, plan_common)', () {
    final gone = RegExp(r'link_screen\.dart|painter_screen\.dart|plan_common\.dart');
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (gone.hasMatch(lines[i])) hits.add('${f.path}:${i + 1}');
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('Plan: the mode chips are Link, Coverage, Find sites, Where to drive', () {
    expect([for (final m in planModes) m.label], ['Link', 'Coverage', 'Find sites', 'Where to drive']);
  });

  test('the Plan tab marks every modelled number as an Estimate and every recorded one as Measured', () {
    String src(String dir) => [
          for (final f in Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) f.readAsStringSync(),
        ].join('\n');
    final plan = src('lib/ui/plan');
    String literals(String s) => [for (final m in _literal.allMatches(s)) m.group(1) ?? m.group(2) ?? ''].join('\n');
    final words = literals(plan);
    expect(words, contains('Estimate'));
    expect(words, contains('Measured'));
    // A modelled number is never called a prediction in the Planner (the map's Predicted coverage layer is a layer name).
    final predicted = RegExp(r'\bpredict(ed|ion|s)?\b', caseSensitive: false);
    final hits = [
      for (final l in words.split('\n'))
        if (predicted.hasMatch(l)) l,
    ];
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('Settings > Observer, the privacy section and the disclosure use Observer, Share with MeshSonar and MQTT feed', () {
    expect(telemetryCategory.title, 'Share with MeshSonar');
    expect([for (final e in observerSettingsEntries) e.title], ['Share with MeshSonar', 'Observer status', 'MQTT feeds']);
    expect(mqttFeedsHelp, contains('An MQTT feed'));
    expect(mqttFeedsHelp, contains('Share with MeshSonar'));
    expect(observerHelp, contains('observer'));
    final privacy = {for (final e in privacySettingsEntries) e.id: e.title};
    expect(privacy['telemetry-toggle'], 'Share with MeshSonar', reason: 'the same switch, the same name in both places');
    expect(telemetryCategory.disclosureTitle, contains('observer'));
    expect(otherDataFlows.map((f) => f.title), contains('MQTT feeds to other sites'));
    final copy = [
      observerHelp,
      mqttFeedsHelp,
      for (final e in [...observerSettingsEntries, ...privacySettingsEntries]) '${e.title} ${e.summary}',
      telemetryCategory.summary,
      telemetryCategory.disclosureLead,
      ...telemetryCategory.shared,
      ...telemetryCategory.neverShared,
      for (final c in dataCategories) '${c.title} ${c.summary} ${c.disclosureLead} ${c.destination} ${c.offEffect}',
      for (final f in otherDataFlows) '${f.title} ${f.body}',
      disclosureHeading,
      disclosureLead,
      savedWithDriveNote,
      deleteMyDataLead,
      deleteAccountText,
      exportText,
      observerJoinTitle,
      observerJoinIntro,
    ].join('\n');
    expect(retired.hasMatch(copy), isFalse, reason: retired.firstMatch(copy)?.group(0));
  });

  test('the observer guide, More and Settings use one name each: Set up a repeater observer, Observer, Claimed radios', () {
    expect(observerJoinTitle, 'Set up a repeater observer');
    expect(observerJoinIntro, contains('Settings > Observer'));
    // Build 71: More keeps the guide's row (titled by observerJoinTitle itself); the Observer and Claimed radios rows moved
    // into Settings, so those two names are checked where they live now: the Settings sections.
    final more = File('lib/ui/shell/more_tab.dart').readAsStringSync();
    expect(more, contains('row(MoreItem.observerJoin, Icons.visibility_outlined, observerJoinTitle'), reason: 'the More row uses the one title');
    expect(RegExp(r"row\(MoreItem\.[A-Za-z]+, [A-Za-z_.]+, '(Observer|Claimed radios|My radios|Home observer)'").hasMatch(more), isFalse,
        reason: 'More has no Observer or Claimed radios row under any name (they are Settings sections)');
    expect(settingsEntry('my-radios').title, 'Claimed radios');
    expect(settingsSections.firstWhere((s) => s.id == 'my-radios-section').title, 'Claimed radios');
    expect(settingsSections.firstWhere((s) => s.id == 'observer').title, 'Observer');
    // One name each, everywhere: no section under an older name.
    final titles = [for (final s in settingsSections) s.title];
    expect(titles.where((t) => t == 'Observer').length, 1);
    expect(titles.where((t) => t == 'Claimed radios').length, 1);
    for (final old in ['My radios', 'My radios and claims', 'Home observer']) {
      expect(titles, isNot(contains(old)), reason: old);
    }
  });
}
