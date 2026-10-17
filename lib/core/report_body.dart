// The body of a problem report (CMAT docs/specs/m1-problem-reports.md §5), built in one place: redacted and rounded
// (§8), size-capped, and pretty-printed. The text it returns is what the preview shows and exactly what is sent.
// Pure Dart: no Flutter imports.
import 'dart:convert';

import 'model.dart';
import 'redact.dart';

/// The largest request body the server accepts (A3: 5 MB = 5,000,000 bytes).
const int problemReportMaxBytes = 5000000;

const List<String> problemReportCategories = ['bug', 'radio', 'gps', 'upload', 'map', 'idea', 'other'];

/// The longest description the server accepts, in characters after trimming.
const int problemReportMaxDescription = 4000;

class ProblemReport {
  /// Pretty-printed JSON: the exact text that is sent.
  final String body;

  /// Replacements made, summed over every string (keys of [redactionCountKeys]).
  final Map<String, int> redacted;

  /// The oldest log lines were dropped to fit [problemReportMaxBytes].
  final bool logShortened;

  /// Too large even without any log; it can't be sent.
  final bool tooLarge;

  ProblemReport({required this.body, required this.redacted, this.logShortened = false, this.tooLarge = false})
    : bytes = utf8.encode(body).length;

  /// UTF-8 size of [body].
  final int bytes;

  /// Keys, tokens and passwords removed.
  int get removedKeys => redacted.entries.where((e) => e.key != 'coords').fold(0, (n, e) => n + e.value);

  /// Locations rounded to 3 decimals.
  int get roundedLocations => redacted['coords'] ?? 0;

  /// For keeping an unsent report on the phone; [ProblemReport.fromJson] gives back the same report.
  Map<String, dynamic> toJson() => {'body': body, 'redacted': redacted, 'log_shortened': logShortened};

  factory ProblemReport.fromJson(Map<String, dynamic> j) => ProblemReport(
    body: j['body'] as String,
    redacted: {
      for (final e in ((j['redacted'] as Map?) ?? const {}).entries)
        if (e.value is num) e.key as String: (e.value as num).toInt(),
    },
    logShortened: j['log_shortened'] == true,
  );
}

/// Builds the report body.
///
/// [log] is null when "Include app log" is off; oldest line first. [secrets] are literal strings that must never be
/// sent (the driver key and the full server URL), even where no redaction rule recognises them. If the body is over
/// [maxBytes], the oldest log lines are dropped until it fits.
ProblemReport buildProblemReport({
  required String category,
  required String description,
  required AppInfo app,
  Map<String, Object?> device = const {},
  Map<String, Object?>? radio,
  String? driveId,
  List<String>? log,
  List<String> secrets = const [],
  int maxBytes = problemReportMaxBytes,
}) {
  final counts = {for (final k in redactionCountKeys) k: 0};
  void add(Map<String, int> c) => c.forEach((k, v) => counts[k] = counts[k]! + v);

  String clean(String s) {
    final r = redactText(_withoutControlChars(s), secrets: secrets);
    add(r.counts);
    return r.text;
  }

  Map<String, Object?> cleanMap(Map<String, Object?> m) => {
    for (final e in m.entries)
      e.key: switch (e.value) {
        final String v => clean(v),
        final num v when _coordinateKeys.contains(e.key) => _roundField(v, counts),
        final v => v,
      },
  };

  final head = <String, Object?>{
    'category': category,
    'description': clean(description.trim()),
    'app': cleanMap({'name': app.name, 'version': app.version, 'build': app.build, 'platform': app.platform}),
    if (device.isNotEmpty) 'device': cleanMap(device),
    if (radio != null) 'radio': cleanMap(radio),
    'driveId': ?driveId,
  };

  final lines = <String>[];
  final lineCounts = <Map<String, int>>[];
  for (final l in log ?? const <String>[]) {
    final r = redactText(_withoutControlChars(l), secrets: secrets);
    lines.add(r.text);
    lineCounts.add(r.counts);
  }

  const encoder = JsonEncoder.withIndent('  ');
  String bodyDropping(int dropped) =>
      encoder.convert({...head, if (dropped < lines.length) 'log': lines.sublist(dropped).join('\n')});

  // Fewest oldest lines to drop so the body fits (dropping more never makes it bigger).
  var lo = 0, hi = lines.length;
  if (utf8.encode(bodyDropping(hi)).length <= maxBytes) {
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (utf8.encode(bodyDropping(mid)).length <= maxBytes) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
  }
  final dropped = hi;
  lineCounts.skip(dropped).forEach(add);
  final body = bodyDropping(dropped);
  return ProblemReport(
    body: body,
    redacted: counts,
    logShortened: dropped > 0,
    tooLarge: utf8.encode(body).length > maxBytes,
  );
}

const _coordinateKeys = {'lat', 'lon', 'lng', 'latitude', 'longitude'};

/// C2: a coordinate field rounded to 3 decimals (counted only when that changes it).
num _roundField(num v, Map<String, int> counts) {
  final r = roundCoordinate(v.toDouble());
  if (r == v) return v;
  counts['coords'] = counts['coords']! + 1;
  return r;
}

/// Control characters are removed as the server does for driver notes, keeping line breaks (\n) and tabs.
String _withoutControlChars(String s) => s.replaceAll(RegExp(r'[\u0000-\u0008\u000B-\u001F\u007F]'), '');
