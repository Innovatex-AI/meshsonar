// The one Share sheet for a drive (Round 5 D-6). The drive card's menu, the drive detail screen and the report all open
// it, with the same four rows under the same names:
//   Report (PDF)                 the report: numbers, charts in vector, repeaters and grid cells;
//   Summary (text)               the report's numbers as a short text;
//   Spreadsheet (CSV)            every table of the report in one CSV file, including the exact track;
//   Drive file (for re-upload)   the drive in Drive Format v1 (JSON), exact track, for uploading again elsewhere.
// Build 76 had "Share", "Export" and "Export & share" for the drive file and hid the PDF behind an icon.
// Exported files are UTC whatever the time setting and say so (Round 2 N-U8); a drive with no pings has no PDF or CSV
// (never an empty file).
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/drive_context_hook.dart' show contextLedgerOf;
import '../../core/api.dart' show DriveEnvStatus, WeatherSnapshot;
import '../../core/drive_report.dart';
import '../../core/drive_report_battery.dart' show loadDriveBatteryLine;
import '../../core/drive_report_export.dart';
import '../../core/drive_report_pdf.dart';
import '../../core/drive_stats.dart' show formatDuration;
import '../../core/drive_store.dart' show JsonlDriveStore;
import '../../core/time_format.dart' show utcStamp;
import '../app.dart';
import '../design/app_surfaces.dart' show AppAction, AppToastKind, showAppActionSheet, showAppToast;
import '../onboarding/ui_prefs.dart' show driveLabel;
import 'drive_report_screen.dart' show loadDriveReport;
import 'pdf_export.dart';

/// The drive's name, or its start in UTC: the title inside an exported file ("2026-10-24 21:39 UTC").
String exportTitleOf(AppState s, DriveReport r) => driveLabel(s, r.session.id, r.session.label) ?? utcStamp(r.session.startedAt);

/// The phone battery headline of [sessionId] ("Battery: 82% → 61% ..."); null with fewer than 2 battery samples.
Future<String?> driveBatteryLine(AppState s, String sessionId) {
  final store = s.services.store;
  return loadDriveBatteryLine(contextLedgerOf(s.services), store is JsonlDriveStore ? store.root : null, sessionId);
}

/// The server's hourly weather for this drive, for the exports: only when the report's Weather block would show it
/// (server does weather, key approved, category on, drive uploaded) and the answer is `ready`. Anything else exports
/// without a weather section; nothing is invented and the export is never held up (8 s at most).
Future<List<WeatherSnapshot>> weatherForExport(AppState s, DriveReport r) async {
  if (!s.driveWeatherEnabled) return const [];
  try {
    final unsynced = (await s.services.store.unsyncedPings(r.session.id)).length;
    if (r.sortedPings.length - unsynced <= 0) return const [];
    final res = await s.driveWeather(r.session.id).timeout(const Duration(seconds: 8));
    return res.env.status == DriveEnvStatus.ready ? res.env.snapshots : const [];
  } catch (_) {
    return const [];
  }
}

/// The rows of the Share sheet, in order.
enum DriveShareChoice { pdf, text, csv, driveFile }

/// Opens the Share sheet for [sessionId]. [report] and [battery] are passed by the report screen, which already has
/// them; from the card and the detail screen the report is built when a row that needs it is picked.
Future<void> showDriveShareSheet(BuildContext context, String sessionId, {DriveReport? report, String? battery}) async {
  final s = AppScope.read(context);
  var pings = report?.sortedPings.length;
  if (pings == null) {
    for (final x in s.sessions) {
      if (x.session.id == sessionId) pings = x.pingCount;
    }
  }
  final hasPings = (pings ?? 0) > 0;
  final v = await showAppActionSheet<DriveShareChoice>(
    context,
    title: 'Share',
    message: hasPings ? 'The spreadsheet and the drive file contain your exact track. The report shows where you drove (grid cells).' : null,
    actions: [
      if (hasPings) const AppAction('Report (PDF)', DriveShareChoice.pdf, key: Key('report-export-pdf')),
      const AppAction('Summary (text)', DriveShareChoice.text, key: Key('report-export-text')),
      if (hasPings) const AppAction('Spreadsheet (CSV)', DriveShareChoice.csv, key: Key('report-export-csv')),
      const AppAction('Drive file (for re-upload)', DriveShareChoice.driveFile, key: Key('share-drive-file')),
    ],
  );
  if (v == null || !context.mounted) return;
  await shareDrive(context, sessionId, v, report: report, battery: battery);
}

/// Makes and shares one of the Share sheet's files.
Future<void> shareDrive(BuildContext context, String sessionId, DriveShareChoice choice, {DriveReport? report, String? battery}) async {
  final s = AppScope.read(context);
  if (choice == DriveShareChoice.driveFile) {
    await s.exportAndShare(sessionId);
    return;
  }
  void fail(String what, Object e) {
    if (context.mounted) showAppToast(context, 'Couldn\'t make the $what. $e', kind: AppToastKind.error);
  }

  DriveReport r;
  try {
    r = report ?? await loadDriveReport(s, sessionId);
  } catch (e) {
    fail('report', e);
    return;
  }
  final line = battery ?? (report == null ? await driveBatteryLine(s, sessionId).catchError((Object _) => null) : null);
  final w = await weatherForExport(s, r);
  final base = 'meshsonar-report-${sessionId.split('-').first}';
  final title = exportTitleOf(s, r);
  try {
    switch (choice) {
      case DriveShareChoice.pdf:
        final light = MeshSonarColors.light;
        final colors = DrivePdfColors(
          signal: (snr) => light.forPing(heard: true, snr: snr).toARGB32(),
          neutral: DrivePdfColors.standard.neutral,
          warning: light.warning.toARGB32(),
        );
        await shareReportPdf(s, '$base.pdf',
            driveReportPdf(r, title: title, units: s.units, duration: formatDuration, weather: w, battery: line, colors: colors));
      case DriveShareChoice.text:
        await _write(s, '$base.txt',
            r.toText(title: 'MeshSonar drive report: $title', units: s.units, duration: formatDuration, weather: w, battery: line));
      case DriveShareChoice.csv:
        await _write(s, '$base.csv', r.toCsv(nameOf: s.repeaterName, weather: w));
      case DriveShareChoice.driveFile:
        break;
    }
  } catch (e) {
    fail(choice == DriveShareChoice.pdf ? 'PDF' : 'file', e);
  }
}

Future<void> _write(AppState s, String name, String text) async {
  final dir = await s.services.exportDir();
  final f = File('${dir.path}/$name');
  await f.writeAsString(text);
  await s.services.shareFile(f);
}
