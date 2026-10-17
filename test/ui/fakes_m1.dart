// Fakes for the MeshSonar 0.4.0 (M1) tests: problem reports and the report draft file.
// Kept apart from fakes.dart because they use 0.4.0 API (ProblemReportResult, ReportDraftStore, AppInfo.build);
// until that exists only the new M1 test files fail to compile, never the older suites.
//
// Contract these fakes assume (spec docs/specs/m1-app-0.4.0.md §3; names chosen by Q where the spec gave none):
//   CmatClient.reportProblem(String driverKey, String body) -> Future<ProblemReportResult>; `body` is the exact
//     JSON text that is POSTed (the same string the preview shows). Errors are CmatException like every call.
//   ProblemReportResult({required String id, String? status, ...}) in lib/core/api.dart.
//   ReportDraftStore (lib/core/report_draft_store.dart): Future<String?> load(); Future<void> save(String draft);
//     Future<void> clear() — dumb persistence of the one saved draft (AppState decides its JSON: the previewed body
//     plus form state). FileReportDraftStore(File) writes `report_draft.json` next to settings atomically.
//   AppServices(reportDraftStore: ReportDraftStore?) — null = keep the draft in memory only.
//   AppInfo(build: ...) — build number for reports (not part of the Drive Format v1 `app` object).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/report_draft_store.dart';

import 'fakes.dart';

/// The phone's saved-draft slot. Share one between two harnesses to simulate an app restart.
class FakeReportDraftStore implements ReportDraftStore {
  String? draft;
  int saves = 0;
  int clears = 0;
  FakeReportDraftStore([this.draft]);
  @override
  Future<String?> load() async => draft;
  @override
  Future<void> save(String d) async {
    saves++;
    draft = d;
  }

  @override
  Future<void> clear() async {
    clears++;
    draft = null;
  }
}

/// One call of reportProblem, as the server would have received it.
class SentReport {
  final String driverKey;
  final String body;
  const SentReport(this.driverKey, this.body);
}

/// What the fake server answers; shared by every client the app builds (it rebuilds one per server URL).
class ReportScript {
  final List<SentReport> sent = [];

  /// Thrown instead of answering (e.g. CmatException('…', status: 503), or status null for a network error).
  Object? error;
  ProblemReportResult result = const ProblemReportResult(id: '3f2a9c1e-7b6d-4e21-9a0c-1d2e3f4a5b6c', status: 'new');
}

class ReportingCmatClient extends FakeCmatClient {
  final ReportScript script;
  ReportingCmatClient(super.baseUrl, this.script);

  @override
  Future<ProblemReportResult> reportProblem(String driverKey, String body) async {
    script.sent.add(SentReport(driverKey, body));
    if (script.error != null) throw script.error!;
    return script.result;
  }
}

/// [Harness] plus the report pieces. Pass the same [drafts] to a second harness to simulate an app restart.
class M1Harness extends Harness {
  final FakeReportDraftStore drafts;
  final AppInfo appInfo;
  final ReportScript reports;
  M1Harness({
    super.antennaProfile,
    FakeReportDraftStore? drafts,
    ReportScript? reports,
    this.appInfo = const AppInfo(name: 'MeshSonar', version: '0.4.0', build: '5', platform: 'iOS'),
  })  : drafts = drafts ?? FakeReportDraftStore(),
        reports = reports ?? ReportScript();

  ReportingCmatClient get reporter => state.client as ReportingCmatClient;

  @override
  FakeCmatClient newClient(Uri u) => ReportingCmatClient(u, reports);

  @override
  AppServices buildServices() => AppServices(
    store: store,
    settingsStore: settings,
    cmatClientFactory: makeClient,
    syncServiceFactory: (_) => sync,
    bluetoothScanner: bt,
    simulatorScanner: sim,
    linkFactory: (_) => FakeLink(selfInfo),
    location: location,
    simulatedLocation: simLocation,
    engineFactory: makeEngine,
    openUrl: recordOpenUrl,
    repeaterCache: cache,
    exportDir: () async => Directory.systemTemp,
    shareFile: (f) async => shared.add(f),
    clock: () => DateTime.utc(2026, 10, 16, 18, 0, 0),
    newId: nextId,
    appInfo: appInfo,
    reportDraftStore: drafts,
  );
}

/// A finished drive for "attach drive" / "Report a problem with this drive".
void seedDrive(Harness h, {String id = 'd1', String label = 'Evening loop'}) {
  h.store.seed(
    DriveSession(
      id: id,
      startedAt: DateTime.utc(2026, 10, 16, 17),
      endedAt: DateTime.utc(2026, 10, 16, 17, 30),
      label: label,
      channel: '#wardriving',
    ),
    [
      DrivePing(id: '$id-p1', ts: DateTime.utc(2026, 10, 16, 17, 1), lat: 40.128091, lon: -82.977705),
      DrivePing(id: '$id-p2', ts: DateTime.utc(2026, 10, 16, 17, 2), lat: 40.129, lon: -82.978),
    ],
  );
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Lets snackbars time out so no timers are left pending.
Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pump(const Duration(seconds: 1));
}

Finder settingsScrollable() =>
    find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
}

/// Scrolls the settings list until [target] is built and then into view. The step is most of a phone screen (400 dp)
/// so the list's far end is reached within the default 50 steps even at 320 dp wide with 2.0× text (AC-16), where
/// the list is several times taller than at 1×. scrollUntilVisible scrolls by drag gestures, which leave a ballistic
/// scroll running; pumpAndSettle lets it come to rest so the tap that follows lands on the target.
Future<void> scrollSettingsTo(WidgetTester tester, Finder target, {double step = 400}) async {
  await tester.scrollUntilVisible(target, step, scrollable: settingsScrollable());
  await tester.pumpAndSettle();
}

/// Settings → About → "Report a problem".
Future<void> openReportFromSettings(WidgetTester tester) async {
  await openSettings(tester);
  await scrollSettingsTo(tester, find.byKey(const Key('report-problem')));
  await tester.tap(find.byKey(const Key('report-problem')));
  await tester.pumpAndSettle();
}

/// The enabled state of any Material button (FilledButton, TextButton, …) found by key.
bool isEnabled(WidgetTester tester, Finder button) {
  final w = tester.widget(button);
  if (w is ButtonStyleButton) return w.onPressed != null;
  if (w is IconButton) return w.onPressed != null;
  if (w is ListTile) return w.enabled && w.onTap != null;
  final inner = find.descendant(of: button, matching: find.byWidgetPredicate((x) => x is ButtonStyleButton));
  if (inner.evaluate().isNotEmpty) return (tester.widget(inner.first) as ButtonStyleButton).onPressed != null;
  throw StateError('not a button: ${w.runtimeType}');
}
