// Settings > Diagnostics: the in-app diagnostic log (memory only, this session) to read, copy or clear, and Report a
// problem. Copying applies the same redaction as problem reports (lib/core/redact.dart): driver keys, tokens and
// passwords are replaced and coordinates rounded to 3 decimals, so a pasted log never leaks a secret or a home.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/app_surfaces.dart';
import '../../app/app_state.dart';
import '../../core/diagnostics.dart';
import '../../core/map_prefs.dart';
import '../../core/power_profile.dart';
import '../../core/redact.dart';
import '../app.dart';
import '../report_problem_screen.dart';
import 'ble_diagnostics_screen.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String diagnosticsHelp = 'Helps explain a problem. The log lives in memory only: it is empty after the app '
    'restarts and is never sent unless you include it in a problem report.';

List<Widget> diagnosticsSectionRows(BuildContext context) {
  return [
    SettingsAnchor(
      id: 'diagnostics-log',
      child: ListTile(
        key: const Key('diagnostics-log'),
        leading: const Icon(Icons.receipt_long_outlined),
        title: Text(settingsEntry('diagnostics-log').title),
        // No line count here: the log grows without telling the screen, and a stale number would mislead.
        subtitle: const Text('Recent app events since the app started. View them, copy them with secrets hidden, or '
            'clear them.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsLogScreen())),
      ),
    ),
    SettingsAnchor(id: 'diagnostics-ble', child: bleDiagnosticsRows(context).first),
    SettingsAnchor(
      id: 'map-health-overlay',
      child: ListenableBuilder(
        listenable: MapPrefs.shared,
        builder: (context, _) => SwitchListTile(
          key: const Key('map-health-overlay'),
          secondary: const Icon(Icons.speed_outlined),
          title: Text(settingsEntry('map-health-overlay').title),
          subtitle: const Text('Frame times, GPS rate, camera and map source over the map. While this is on, a sample every 10 s is '
              'saved with each drive (Drives > menu > Share map health). Off saves battery. Stays on this phone.'),
          value: MapPrefs.shared.healthOverlay,
          onChanged: (v) => MapPrefs.shared.healthOverlay = v,
        ),
      ),
    ),
    const SettingsAnchor(id: 'diagnostics-power-counters', child: PowerCountersCard()),
    SettingsAnchor(
      id: 'report-problem',
      child: ListTile(
        key: const Key('report-problem'),
        leading: const Icon(Icons.bug_report_outlined),
        title: const Text('Report a problem'),
        subtitle: const Text('Goes to your server\'s operators with your driver key. You see exactly what is sent first.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openReportProblem(context),
      ),
    ),
  ];
}

/// The text Copy puts on the clipboard: app details, the settings snapshot (never the key) and the log, redacted.
RedactionResult diagnosticsExport(AppState s) {
  final info = s.services.appInfo;
  final raw = [
    'MeshSonar ${info.version ?? ''} ${info.platform ?? ''}'.trim(),
    ...settingsSnapshot(s.settings, antenna: s.antennaProfile),
    ...s.diagnostics.lines,
  ].join('\n');
  return redactText(raw);
}

/// "2 secrets hidden, 3 positions rounded" from the redaction counts; null when nothing was changed.
String? redactionSummary(Map<String, int> counts) {
  final secrets = counts.entries.where((e) => e.key != 'coords').fold<int>(0, (a, e) => a + e.value);
  final coords = counts['coords'] ?? 0;
  final parts = [
    if (secrets > 0) '$secrets secret${secrets == 1 ? '' : 's'} hidden',
    if (coords > 0) '$coords position${coords == 1 ? '' : 's'} rounded',
  ];
  return parts.isEmpty ? null : parts.join(', ');
}

class DiagnosticsLogScreen extends StatefulWidget {
  const DiagnosticsLogScreen({super.key});
  @override
  State<DiagnosticsLogScreen> createState() => _DiagnosticsLogScreenState();
}

class _DiagnosticsLogScreenState extends State<DiagnosticsLogScreen> {
  Future<void> _copy(BuildContext context, AppState s) async {
    final r = diagnosticsExport(s);
    await Clipboard.setData(ClipboardData(text: r.text));
    if (!context.mounted) return;
    final what = redactionSummary(r.counts);
    showAppToast(context, 'Log copied${what == null ? '.' : ' ($what).'}', kind: AppToastKind.success);
  }

  Future<void> _clear(BuildContext context, AppState s) async {
    runWithUndo(context, 'Clearing the diagnostic log.', commit: () async {
      if (mounted) {
        setState(s.diagnostics.clear);
      } else {
        s.diagnostics.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    // What is on screen is the redacted text too, so reading and copying show the same thing.
    final lines = s.diagnostics.lines.map((l) => redactText(l).text).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostic log'),
        actions: [
          IconButton(
            key: const Key('diagnostics-copy'),
            tooltip: 'Copy (secrets hidden, positions rounded)',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () => _copy(context, s),
          ),
          IconButton(
            key: const Key('diagnostics-clear'),
            tooltip: 'Clear the log',
            icon: const Icon(Icons.delete_outline),
            onPressed: lines.isEmpty ? null : () => _clear(context, s),
          ),
        ],
      ),
      body: SafeArea(
        child: lines.isEmpty
            ? const Center(
                key: Key('diagnostics-empty'),
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Nothing logged since the app started. Connecting, drives, uploads and errors add lines '
                      'here.', textAlign: TextAlign.center),
                ),
              )
            : ListView.builder(
                key: const Key('diagnostics-lines'),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: lines.length + 1,
                itemBuilder: (_, i) => i == 0
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('Oldest first, times in UTC. Secrets are hidden and positions rounded here and '
                            'when copied.', style: t.textTheme.bodySmall),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: SelectableText(lines[i - 1],
                            style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                      ),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------- power counters (build 70, battery plan §4)

const Map<String, String> _counterWords = {
  PowerCounters.gpsBestSeconds: 'GPS, best accuracy',
  PowerCounters.gpsHighSeconds: 'GPS, high accuracy',
  PowerCounters.gpsLowSeconds: 'GPS, low accuracy',
  PowerCounters.screenOnSeconds: 'Screen kept on',
  PowerCounters.compassSeconds: 'Compass',
  PowerCounters.mapFrame: 'Map frames drawn',
  PowerCounters.bleCommand: 'Radio commands',
  PowerCounters.blePoll: 'Radio message checks',
  PowerCounters.httpRequest: 'Internet requests',
  PowerCounters.timerWake: 'Timer wake-ups',
};

/// Keys counted in seconds (shown as minutes, and minutes per hour).
const Set<String> _secondsCounters = {
  PowerCounters.gpsBestSeconds,
  PowerCounters.gpsHighSeconds,
  PowerCounters.gpsLowSeconds,
  PowerCounters.screenOnSeconds,
  PowerCounters.compassSeconds,
};

String _rate(double v) => v >= 100 ? v.round().toString() : v.toStringAsFixed(1);

/// One line per counter: (words, "12 min (4.0 min/h)" or "720 (240/h)"), the known counters first in a fixed order,
/// then any other key by name. The rate is per hour since [since]; with under a minute counted it is left out.
List<(String, String)> powerCounterLines(Map<String, int> counts, DateTime since, DateTime now) {
  final hours = now.difference(since).inSeconds / 3600;
  final keys = [..._counterWords.keys, ...(counts.keys.where((k) => !_counterWords.containsKey(k)).toList()..sort())];
  return [
    for (final k in keys)
      () {
        final n = counts[k] ?? 0;
        final secs = _secondsCounters.contains(k);
        final value = secs ? n / 60 : n.toDouble();
        final total = secs ? '${_rate(value)} min' : '$n';
        final per = hours < 1 / 60 ? '' : ' (${_rate(value / hours)}${secs ? ' min' : ''}/h)';
        return (_counterWords[k] ?? k, '$total$per');
      }(),
  ];
}

/// Diagnostics > Power counters: what used power since the app started, with per-hour rates. Counted in code
/// (lib/core/power_profile.dart PowerCounters); Refresh reads them again.
class PowerCountersCard extends StatefulWidget {
  const PowerCountersCard({super.key});
  @override
  State<PowerCountersCard> createState() => _PowerCountersCardState();
}

class _PowerCountersCardState extends State<PowerCountersCard> {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final now = DateTime.now();
    final since = PowerCounters.since;
    final lines = powerCounterLines(PowerCounters.snapshot(), since, now);
    final up = now.difference(since);
    final upWords = up.inHours >= 1 ? '${up.inHours} h ${up.inMinutes % 60} min' : '${up.inMinutes} min';
    return Padding(
      key: const Key('diagnostics-power-counters'),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.battery_unknown_outlined),
          const SizedBox(width: 16),
          Expanded(child: Text(settingsEntry('diagnostics-power-counters').title, style: t.textTheme.titleMedium)),
          IconButton(
            key: const Key('diagnostics-power-counters-refresh'),
            tooltip: 'Read the counters again',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 40, right: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Since the app started $upWords ago. Rates are per hour. Stays on this phone.',
                style: t.textTheme.bodySmall),
            const SizedBox(height: 6),
            for (final (what, value) in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Text(what, style: t.textTheme.bodyMedium)),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(value,
                        key: Key('power-counter-$what'),
                        textAlign: TextAlign.end,
                        style: t.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}
