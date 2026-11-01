// Settings > Units actually changes what people see: min-distance slider, drive cards, antenna sheet, report text.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/heard.dart' show RepeaterLookup;
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/report/drive_report.dart';

import 'fakes.dart';
import 'settings_controls_test.dart' show openSettings, show, valueText;

void main() {
  testWidgets('imperial: min-distance slider reads feet; metric reads metres', (tester) async {
    await openSettings(tester, settings: const Settings(units: UnitsPreference.imperial));
    await show(tester, 'min-distance');
    expect(valueText(tester, 'min-distance'), '50 ft');
    expect(find.text('50 ft'), findsWidgets);
    expect(find.text('1600 ft'), findsOneWidget);
  });

  testWidgets('metric: min-distance slider reads metres', (tester) async {
    await openSettings(tester, settings: const Settings(units: UnitsPreference.metric));
    await show(tester, 'min-distance');
    expect(valueText(tester, 'min-distance'), '15 m');
    expect(find.text('500 m'), findsOneWidget);
  });

  testWidgets('imperial: a drive card shows miles, not km', (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    h.settings.saved = h.settings.saved.copyWith(units: UnitsPreference.imperial);
    h.store.seed(
      DriveSession(id: 'd1', startedAt: DateTime.utc(2026, 10, 15, 14), endedAt: DateTime.utc(2026, 10, 15, 14, 42)),
      [
        DrivePing(id: 'a', ts: DateTime.utc(2026, 10, 15, 14), lat: 40.00, lon: -82.9),
        DrivePing(id: 'b', ts: DateTime.utc(2026, 10, 15, 14, 1), lat: 40.03, lon: -82.9),
      ],
    );
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    expect(find.text('2.1 mi'), findsOneWidget);
    expect(find.textContaining(' km'), findsNothing);
  });

  test('report text follows the units, one system only', () {
    final r = DriveReport.compute(
      session: DriveSession(id: 's', startedAt: DateTime.utc(2026, 10, 15, 14)),
      pings: [
        DrivePing(id: 'a', ts: DateTime.utc(2026, 10, 15, 14), lat: 40.00, lon: -82.9, speedMps: 10),
        DrivePing(id: 'b', ts: DateTime.utc(2026, 10, 15, 14, 1), lat: 40.03, lon: -82.9, speedMps: 20),
      ],
      lookup: RepeaterLookup.empty,
      cmatListLoaded: true,
    );
    final imp = r.toText(units: Units.imperial);
    expect(imp, contains(' mi in '));
    expect(imp, contains('mph'));
    expect(imp, isNot(contains('km')));
    final met = r.toText();
    expect(met, contains(' km in '));
    expect(met, contains('km/h'));
    expect(met, isNot(contains('mph')));
    expect(met, isNot(contains(RegExp(r'\bmi\b'))));
  });
}
