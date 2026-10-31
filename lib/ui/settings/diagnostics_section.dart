// Settings > Diagnostics: the in-app diagnostic log (memory only, this session) to read, copy or clear, and Report a
// problem. Copying applies the same redaction as problem reports (lib/core/redact.dart): driver keys, tokens and
// passwords are replaced and coordinates rounded to 3 decimals, so a pasted log never leaks a secret or a home.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../core/diagnostics.dart';
import '../../core/redact.dart';
import '../app.dart';
import '../report_problem_screen.dart';
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Log copied${what == null ? '.' : ' ($what).'}')));
  }

  Future<void> _clear(BuildContext context, AppState s) async {
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'diagnostics-clear-dialog',
      title: 'Clear the diagnostic log?',
      body: 'The lines so far are deleted. A problem report sent afterwards can only include what happens from now on.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(s.diagnostics.clear);
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
