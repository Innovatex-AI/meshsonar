// Build 77, round 4 (the Plan tab): one set of words. Verdicts are Works / Marginal / Unlikely everywhere; the radio row names
// the preset; Find sites says "Backup paths"; plan times go through the app's one formatter (Local / UTC setting).
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart' show RadioPreset;
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/core/plan_contract.dart';
import 'package:meshsonar/core/time_format.dart';
import 'package:meshsonar/ui/plan/modes/find_sites_mode.dart' show siteGoalWords;
import 'package:meshsonar/ui/plan/modes/link_mode.dart' show linkVerdictWords, linkGlossary;
import 'package:meshsonar/ui/plan/plan_modes.dart' show verdictWords;
import 'package:meshsonar/ui/plan/planner_sheet.dart' show kPlanRadioEuNarrow, radioPresetWords;
import 'package:meshsonar/ui/plan/saved_plans.dart' show savedWhen;

void main() {
  test('one verdict set: Coverage and Link use the same three words', () {
    for (final v in PlanVerdict.values) {
      expect(verdictWords(v), linkVerdictWords(v), reason: v.name);
    }
    expect([for (final v in PlanVerdict.values) verdictWords(v)], containsAll(['Works', 'Marginal', 'Unlikely']));
  });

  test('the radio row names the preset, not its figures', () {
    expect(radioPresetWords(PlanRadio.usDefault, null), 'US / Canada preset');
    expect(radioPresetWords(kPlanRadioEuNarrow, null), 'EU / UK preset');
    expect(radioPresetWords(const PlanRadio(freqMHz: 915, bwKHz: 125, sf: 10, cr: 5), null), 'Custom (SF10, 125 kHz)');
  });

  test('Find sites: Backup paths; the glossary keeps the band ranges the results dropped', () {
    expect(siteGoalWords(PlanGoal.redundancy), 'Backup paths');
    final bands = linkGlossary.firstWhere((g) => g.$1.startsWith('Fringe')).$2;
    expect(bands, contains('0 to 6 dB'));
    expect(linkGlossary.map((g) => g.$1), contains('Spot'));
  });

  test('saved plans: today / yesterday with the time, older by date, through the one formatter', () {
    final prev = activeTimeZone;
    addTearDown(() => activeTimeZone = prev);
    activeTimeZone = TimeZonePreference.utc;
    final now = DateTime.utc(2026, 11, 27, 18, 0);
    expect(savedWhen(DateTime.utc(2026, 11, 27, 14, 5), now), 'today ${timeOfDay(DateTime.utc(2026, 11, 27, 14, 5))}');
    expect(savedWhen(DateTime.utc(2026, 11, 26, 9, 12), now), startsWith('yesterday '));
    expect(savedWhen(DateTime.utc(2026, 11, 20, 9, 12), now), dateOnly(DateTime.utc(2026, 11, 20, 9, 12)));
    expect(savedWhen(DateTime.utc(2026, 11, 27, 14, 5), now), endsWith('UTC'), reason: 'the UTC setting applies');
  });

  test('a region preset of its own reads by the region\'s preset name', () {
    const region = RadioPreset(name: 'Columbus narrow', freqMhz: 910.525, bwKhz: 62.5, sf: 9, cr: 5);
    expect(radioPresetWords(planRadioFor(region), region), 'Columbus narrow preset');
  });
}
