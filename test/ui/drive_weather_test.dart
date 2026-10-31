// Drive report weather block (stream 7 WP6): shown only for an uploaded drive on a server that does weather, with an
// approved key and the category on; every state is explicit; values go through Units; the Open-Meteo credit sits
// directly under any values and links out; the phone barometer is compared honestly; no coordinate is ever shown.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart' show DriveWeatherGate;
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/report/drive_report_screen.dart';
import 'package:meshsonar/ui/report/drive_weather_section.dart';

import 'fakes.dart';

final t0 = DateTime.utc(2026, 10, 16, 18);

/// A client whose `drive-env` answer the test scripts.
class WeatherClient extends FakeCmatClient {
  WeatherClient(super.baseUrl);
  Future<DriveEnv> Function(String key, String session)? script;
  final List<String> askedSessions = [];
  final List<String> askedKeys = [];

  @override
  Future<DriveEnv> driveEnv(String driverKey, String sessionId) async {
    askedSessions.add(sessionId);
    askedKeys.add(driverKey);
    return script!(driverKey, sessionId);
  }
}

class WeatherHarness extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => WeatherClient(u);
  WeatherClient get weather => state.client as WeatherClient;
}

WeatherSnapshot snap(int h,
        {double? t, double? dew, double? rh, double? p, double? mm, double? cloud, double? wind, double? dir}) =>
    WeatherSnapshot(
        at: DateTime.utc(2026, 10, 16, h),
        temperatureC: t,
        dewPointC: dew,
        humidityPct: rh,
        pressureHpa: p,
        precipMm: mm,
        cloudPct: cloud,
        windMs: wind,
        windDirDeg: dir);

DriveEnv ready([List<WeatherSnapshot>? s]) => DriveEnv(
      session: 'd1',
      status: DriveEnvStatus.ready,
      attribution: 'whatever the server says',
      snapshots: s ??
          [
            snap(18, t: 11.2, dew: 8.0, rh: 81, p: 1012.4, mm: 0.2, cloud: 90, wind: 4.1, dir: 230),
            snap(19, t: 13.0, dew: 7.5, rh: 70, p: 1011.0, mm: 0.0, cloud: 70, wind: 6, dir: 250),
            snap(20, t: 12.0, dew: 7.0, rh: 75, p: 1010.2, mm: 0.4, cloud: 80, wind: 2, dir: 240),
          ],
    );

DriveEnv noSnaps(DriveEnvStatus s) => DriveEnv(session: 'd1', status: s, attribution: 'x');

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');

DrivePing ping(String id, int min) => DrivePing(id: id, ts: t0.add(Duration(minutes: min)), lat: 40.1234, lon: -82.9876, echoes: const []);

/// Opens drive `d1` (uploaded: its first ping is confirmed by the server) on a server that does weather.
Future<WeatherHarness> open(
  WidgetTester tester, {
  Future<DriveEnv> Function(String, String)? script,
  bool capability = true,
  bool approved = true,
  bool categoryOn = true,
  int synced = 2,
  UnitsPreference units = UnitsPreference.metric,
  UnitOverrides overrides = const UnitOverrides(),
  void Function(WeatherHarness h)? setup,
  bool openReportScreen = true,
}) async {
  useTallScreen(tester);
  final h = WeatherHarness();
  if (approved) h.approveKey();
  h.settings.saved = h.settings.saved
      .copyWith(units: units, unitOverrides: overrides)
      .withCollection('weather', categoryOn);
  h.store.seed(DriveSession(id: 'd1', startedAt: t0, endedAt: t0.add(const Duration(minutes: 90))),
      [ping('a', 0), ping('b', 30), ping('c', 60)], syncedFirst: synced);
  setup?.call(h);
  await h.state.init();
  h.weather.script = script ?? (_, _) async => ready();
  h.weather.siteConfigResult = SiteConfig(region: _region, capabilities: capability ? const {'driveEnv'} : const {});
  await h.state.refreshSiteConfig();
  await tester.pumpWidget(MeshSonarApp(state: h.state));
  await tester.pump();
  if (openReportScreen) await openReport(tester, h);
  return h;
}

Future<void> openReport(WidgetTester tester, Harness h) async {
  openDriveReport(tester.element(find.byType(Scaffold).first), 'd1');
  await tester.pumpAndSettle();
}

/// Scrolls [f] fully into view, then taps it.
Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder get _list => find.descendant(of: find.byKey(const Key('report-list')), matching: find.byType(Scrollable)).first;

Future<void> toWeather(WidgetTester tester) async {
  await tester.scrollUntilVisible(find.byKey(const Key('report-weather')), 300, scrollable: _list);
  await tester.pumpAndSettle();
}

String text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

/// Every string drawn by Text widgets inside the weather block (including the collapsed hourly table), joined.
String allText(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: find.byKey(const Key('report-weather')), matching: find.byType(Text), skipOffstage: false))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .join('\n');

void main() {
  group('ready', () {
    testWidgets('tiles, charts, the credit directly under the values, and the one lazy ask', (tester) async {
      final handle = tester.ensureSemantics();
      final h = await open(tester);
      await toWeather(tester);
      expect(h.weather.askedSessions, ['d1']);
      expect(h.weather.askedKeys.single, 'secretkey-abcdef-1234');
      expect(text(tester, 'weather-tile-temp'), '11 °C to 13 °C');
      expect(text(tester, 'weather-tile-dew'), '7 °C to 8 °C');
      expect(text(tester, 'weather-tile-humidity'), '70% to 81%');
      expect(text(tester, 'weather-tile-wind'), startsWith('about 15 km/h, up to 22 km/h, from WSW'));
      expect(text(tester, 'weather-tile-precip'), '0.6 mm');
      expect(text(tester, 'weather-tile-cloud'), '80% on average');
      expect(text(tester, 'weather-tile-pressure'), '1010.2 hPa to 1012.4 hPa');
      expect(find.byKey(const Key('chart-weather-temp')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Temperature \(°C\)\. 3 hours, temperature from 11 °C to 13 °C')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('chart-weather-wind')), 300, scrollable: _list);
      expect(find.bySemanticsLabel(RegExp(r'^Wind speed \(km/h\)\. 3 hours, average 15 km/h, highest 22 km/h')), findsOneWidget);
      // The licence line, exactly, once, and after the values (below the last chart).
      expect(find.text('Weather data by Open-Meteo.com (CC BY 4.0)'), findsOneWidget);
      final credit = tester.getTopLeft(find.byKey(const Key('weather-credit'))).dy;
      expect(credit, greaterThan(tester.getTopLeft(find.byKey(const Key('chart-weather-wind'))).dy));
      expect(find.text('whatever the server says'), findsNothing);
      handle.dispose();
    });

    testWidgets('the credit opens open-meteo.com through the app seam; a browser that fails says so', (tester) async {
      final h = await open(tester);
      await toWeather(tester);
      await tester.scrollUntilVisible(find.byKey(const Key('weather-credit')), 300, scrollable: _list);
      await tester.ensureVisible(find.byKey(const Key('weather-credit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('weather-credit')));
      await tester.pumpAndSettle();
      expect(h.openedUrls, [Uri.parse('https://open-meteo.com')]);
      h.browserWorks = false;
      await tapVisible(tester, find.byKey(const Key('weather-credit')));
      expect(find.textContaining('Couldn\'t open the browser'), findsOneWidget);
    });

    testWidgets('the Chart/Table switch shows every hour; all hourly values are listed with precipitation and cloud', (tester) async {
      await open(tester);
      await toWeather(tester);
      await tester.scrollUntilVisible(find.byKey(const Key('chart-weather-temp-toggle')), 300, scrollable: _list);
      await tapVisible(tester, find.descendant(of: find.byKey(const Key('chart-weather-temp-toggle')), matching: find.text('Table')));
      expect(find.byKey(const Key('chart-weather-temp-table')), findsOneWidget);
      expect(find.text('11 °C'), findsWidgets);
      expect(find.text('13 °C'), findsWidgets);
      await tester.scrollUntilVisible(find.byKey(const Key('weather-hourly')), 300, scrollable: _list);
      await tapVisible(tester, find.byKey(const Key('weather-hourly')));
      await tester.scrollUntilVisible(find.text('0.4 mm'), 300, scrollable: _list);
      expect(find.text('0.4 mm'), findsOneWidget);
      expect(find.text('90%'), findsOneWidget);
      expect(find.text('0 mm'), findsOneWidget);
    });

    testWidgets('imperial with a metric temperature choice: °C, mph, inHg and inches, never the other unit', (tester) async {
      await open(tester, units: UnitsPreference.imperial, overrides: const UnitOverrides(temperature: UnitChoice.metric));
      await toWeather(tester);
      expect(text(tester, 'weather-tile-temp'), '11 °C to 13 °C');
      expect(text(tester, 'weather-tile-wind'), startsWith('about 9 mph, up to 13 mph'));
      expect(text(tester, 'weather-tile-precip'), '0.02 in');
      expect(text(tester, 'weather-tile-pressure'), '29.83 inHg to 29.90 inHg');
      final all = allText(tester);
      expect(all, isNot(contains('km/h')));
      expect(all, isNot(contains('hPa')));
      expect(all, isNot(contains('°F')));
    });

    testWidgets('metric with a °F choice and mmHg', (tester) async {
      await open(tester, overrides: const UnitOverrides(temperature: UnitChoice.imperial, pressure: PressureChoice.mmHg));
      await toWeather(tester);
      expect(text(tester, 'weather-tile-temp'), '52 °F to 55 °F');
      expect(text(tester, 'weather-tile-pressure'), '758 mmHg to 759 mmHg');
      expect(allText(tester), isNot(contains('°C')));
    });

    testWidgets('phone barometer vs station pressure: honest labels and the measured difference', (tester) async {
      final handle = tester.ensureSemantics();
      final h = await open(tester, openReportScreen: false, setup: (h) {
        h.store.ctx.appendSamples('d1', [
          DriveSample(ts: t0.add(const Duration(minutes: 10)), src: SampleSource.phone, pressureHpa: 1014.2),
          DriveSample(ts: t0.add(const Duration(minutes: 40)), src: SampleSource.phone, pressureHpa: 1014.4),
          DriveSample(ts: t0.add(const Duration(minutes: 70)), src: SampleSource.phone, pressureHpa: 1012.5),
        ]);
      });
      await openReport(tester, h);
      await toWeather(tester);
      await tester.scrollUntilVisible(find.byKey(const Key('chart-weather-pressure')), 300, scrollable: _list);
      expect(find.bySemanticsLabel(RegExp(r'Weather model station pressure from 1010\.2 hPa to 1012\.4 hPa over 3 hours\. 3 phone barometer readings\. The phone read higher than the weather model by 1\.7 hPa on average over 2 hours')),
          findsOneWidget);
      expect(find.textContaining('Station pressure: a model value for about a 5 km cell'), findsOneWidget);
      expect(find.textContaining('Phone barometer: measured inside the car (cabin pressure)'), findsOneWidget);
      expect(find.byKey(const Key('weather-pressure-compare')), findsOneWidget);
      await tapVisible(tester, find.descendant(of: find.byKey(const Key('chart-weather-pressure-toggle')), matching: find.text('Table')));
      await tester.scrollUntilVisible(find.text('Station pressure (model)'), 300, scrollable: _list);
      expect(find.text('Station pressure (model)'), findsOneWidget);
      expect(find.text('Phone barometer'), findsOneWidget);
      expect(find.text('1014.4 hPa'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('no phone barometer readings: says there is nothing to compare, invents nothing', (tester) async {
      await open(tester);
      await toWeather(tester);
      await tester.scrollUntilVisible(find.byKey(const Key('weather-pressure-nophone')), 300, scrollable: _list);
      expect(find.byKey(const Key('weather-pressure-compare')), findsNothing);
    });

    testWidgets('a quantity the source did not give is not shown or invented', (tester) async {
      await open(tester, script: (_, _) async => ready([snap(18, t: 10.0), snap(19, t: 12.0)]));
      await toWeather(tester);
      expect(text(tester, 'weather-tile-temp'), '10 °C to 12 °C');
      for (final k in ['dew', 'humidity', 'wind', 'precip', 'cloud', 'pressure']) {
        expect(find.byKey(Key('weather-tile-$k')), findsNothing, reason: k);
      }
      expect(find.byKey(const Key('chart-weather-wind')), findsNothing);
      expect(find.byKey(const Key('chart-weather-pressure')), findsNothing);
      expect(find.byKey(const Key('weather-credit')), findsOneWidget);
    });

    testWidgets('no coordinate appears anywhere in the block', (tester) async {
      await open(tester);
      await toWeather(tester);
      final all = allText(tester);
      expect(all, isNot(contains('40.12')));
      expect(all, isNot(contains('82.98')));
    });

    testWidgets('part of the drive not uploaded yet: said, and the weather is for what the server has', (tester) async {
      await open(tester, synced: 1);
      await toWeather(tester);
      await tester.scrollUntilVisible(find.byKey(const Key('weather-partial-upload')), 300, scrollable: _list);
      expect(find.byKey(const Key('weather-partial-upload')), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('pending with nothing yet: explains the 30-minute job and the 2 hour wait; no credit (no values)', (tester) async {
      await open(tester, script: (_, _) async => noSnaps(DriveEnvStatus.pending));
      await toWeather(tester);
      expect(text(tester, 'weather-pending'),
          'Added after upload: not looked up yet. The server waits until the drive has been quiet for 2 hours, then checks every 30 minutes, so expect it within about 2 to 3 hours of the end of the drive.');
      expect(find.byKey(const Key('weather-asof')), findsOneWidget);
      expect(find.byKey(const Key('weather-credit')), findsNothing);
    });

    testWidgets('pending with some hours: shows them with the credit and says more may follow', (tester) async {
      await open(tester, script: (_, _) async => DriveEnv(session: 'd1', status: DriveEnvStatus.pending, attribution: 'x', snapshots: [snap(18, t: 9.0)]));
      await toWeather(tester);
      expect(find.byKey(const Key('weather-partial')), findsOneWidget);
      expect(text(tester, 'weather-tile-temp'), '9 °C to 9 °C');
      await tester.scrollUntilVisible(find.byKey(const Key('weather-credit')), 300, scrollable: _list);
      expect(find.text('Weather data by Open-Meteo.com (CC BY 4.0)'), findsOneWidget);
    });

    testWidgets('disabled: weather is off for this drive', (tester) async {
      await open(tester, script: (_, _) async => noSnaps(DriveEnvStatus.disabled));
      await toWeather(tester);
      expect(text(tester, 'weather-disabled'), contains('not looking up weather for this drive'));
      expect(find.byKey(const Key('weather-credit')), findsNothing);
    });

    testWidgets('unavailable: nothing visible to look up or older than 60 days, and the start/end trim is named', (tester) async {
      await open(tester, script: (_, _) async => noSnaps(DriveEnvStatus.unavailable));
      await toWeather(tester);
      final t = text(tester, 'weather-unavailable');
      expect(t, contains('nothing was publicly visible to look up'));
      expect(t, contains('trimmed for privacy'));
      expect(t, contains('older than 60 days'));
      expect(find.byKey(const Key('weather-credit')), findsNothing);
    });

    testWidgets('ready but no hours: said plainly', (tester) async {
      await open(tester, script: (_, _) async => noSnaps(DriveEnvStatus.ready));
      await toWeather(tester);
      expect(text(tester, 'weather-empty'), 'The server has no weather hours for this drive.');
    });

    testWidgets('offline on first open: error with Retry, then Retry works', (tester) async {
      var online = false;
      final h = await open(tester, script: (_, _) async {
        if (!online) throw const CmatException('Connection failed');
        return ready();
      });
      await toWeather(tester);
      expect(find.byKey(const Key('weather-error-offline')), findsOneWidget);
      expect(find.textContaining('You may be offline'), findsOneWidget);
      expect(find.byKey(const Key('weather-credit')), findsNothing);
      online = true;
      await tapVisible(tester, find.byKey(const Key('weather-retry')));
      expect(find.byKey(const Key('weather-error-offline')), findsNothing);
      expect(text(tester, 'weather-tile-temp'), '11 °C to 13 °C');
      expect(h.weather.askedSessions, hasLength(2));
    });

    testWidgets('404: the server does not know this drive; no Retry', (tester) async {
      await open(tester, script: (_, _) async => throw const CmatException('no such session', status: 404));
      await toWeather(tester);
      expect(find.byKey(const Key('weather-error-404')), findsOneWidget);
      expect(find.textContaining('doesn\'t know this drive'), findsOneWidget);
      expect(find.byKey(const Key('weather-retry')), findsNothing);
    });

    testWidgets('429: asks for a pause and offers Retry', (tester) async {
      await open(tester, script: (_, _) async => throw const CmatException('slow', status: 429));
      await toWeather(tester);
      expect(find.textContaining('asked for a pause'), findsOneWidget);
      expect(find.byKey(const Key('weather-retry')), findsOneWidget);
    });

    testWidgets('500 and key trouble say what happened', (tester) async {
      await open(tester, script: (_, _) async => throw const CmatException('boom', status: 500));
      await toWeather(tester);
      expect(find.textContaining('answered with an error (500)'), findsOneWidget);
    });

    testWidgets('offline later: the stored answer is shown with its age and the credit', (tester) async {
      var online = true;
      final h = await open(tester, script: (_, _) async {
        if (!online) throw const CmatException('Connection failed');
        return ready();
      });
      await toWeather(tester);
      expect(find.byKey(const Key('weather-offline')), findsNothing);
      // 7 hours later (past the ready window) with no network: reopen the report.
      h.clockNow = h.clockNow.add(const Duration(hours: 7));
      online = false;
      Navigator.of(tester.element(find.byKey(const Key('drive-report')))).pop();
      await tester.pumpAndSettle();
      await openReport(tester, h);
      await toWeather(tester);
      expect(h.weather.askedSessions, hasLength(2));
      expect(text(tester, 'weather-offline'), 'Offline - as of 7h ago. The server could not be reached.');
      expect(text(tester, 'weather-tile-temp'), '11 °C to 13 °C');
      expect(find.byKey(const Key('weather-credit')), findsOneWidget);
    });

    testWidgets('reopening the report inside the window does not ask the server again', (tester) async {
      final h = await open(tester);
      await toWeather(tester);
      Navigator.of(tester.element(find.byKey(const Key('drive-report')))).pop();
      await tester.pumpAndSettle();
      await openReport(tester, h);
      await toWeather(tester);
      expect(h.weather.askedSessions, hasLength(1));
      expect(text(tester, 'weather-tile-temp'), '11 °C to 13 °C');
    });
  });

  group('explained, nothing invented, nothing asked', () {
    Future<void> explained(WidgetTester tester, WeatherHarness h, String key, {String? has}) async {
      await toWeather(tester);
      expect(find.text('WEATHER'), findsOneWidget);
      expect(find.byKey(Key(key)), findsOneWidget);
      if (has != null) expect(text(tester, key), contains(has));
      expect(find.byKey(const Key('weather-credit')), findsNothing);
      expect(h.weather.askedSessions, isEmpty);
    }

    testWidgets('a server that says it does no weather', (tester) async {
      await explained(tester, await open(tester, capability: false), 'weather-gate-serverDoesNot', has: 'does not add weather');
    });

    testWidgets('a key that is not approved', (tester) async {
      await explained(tester, await open(tester, approved: false), 'weather-gate-noApprovedKey', has: 'approved driver key');
    });

    testWidgets('a pending key', (tester) async {
      await explained(
          tester,
          await open(tester, setup: (h) {
            h.settings.saved = h.settings.saved.copyWith(driverKey: 'k-pending-1234', keyStatus: DriverKeyStatus.pending);
          }),
          'weather-gate-noApprovedKey');
    });

    testWidgets('the weather category switched off says where to turn it on', (tester) async {
      await explained(tester, await open(tester, categoryOn: false), 'weather-gate-switchedOff', has: 'Privacy & data sharing');
    });

    testWidgets('a drive that never reached the server says weather is added after upload, with the real delay', (tester) async {
      final h = await open(tester, synced: 0);
      await explained(tester, h, 'weather-not-uploaded', has: '2 to 3 hours');
    });

    testWidgets('the gate follows the server capabilities', (tester) async {
      final h = await open(tester, capability: false);
      expect(h.state.driveWeatherGate, DriveWeatherGate.serverDoesNot);
      expect(h.state.driveWeatherEnabled, isFalse);
    });
  });

  group('failure text', () {
    test('maps every status to its own sentence', () {
      expect(weatherFailureText(const CmatException('x', status: 404)).retry, isFalse);
      for (final c in [429, 401, 403, 500, 503]) {
        expect(weatherFailureText(CmatException('x', status: c)).retry, isTrue, reason: '$c');
      }
      expect(weatherFailureText(const CmatException('x')).text, contains('offline'));
      expect(weatherFailureText(StateError('x')).text, contains('Couldn\'t load'));
    });
  });
}
