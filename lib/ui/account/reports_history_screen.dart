// "My reports" (the website's /me/reports): the problem reports this account filed in the last 90 days and where each stands.
// The admin's notes and logs stay internal and are never shown.
import 'package:flutter/material.dart';

import '../../app/messages.dart';
import '../../core/driver_account.dart';
import '../app.dart';
import '../widgets.dart';

class ReportsHistoryScreen extends StatefulWidget {
  const ReportsHistoryScreen({super.key});
  @override
  State<ReportsHistoryScreen> createState() => _ReportsHistoryScreenState();
}

class _ReportsHistoryScreenState extends State<ReportsHistoryScreen> {
  Future<List<ReportRow>>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= AppScope.read(context).loadServerReports();
  }

  /// Try again and pull to refresh: ends when the new answer (or its error) is in.
  Future<void> _reload() async {
    final f = AppScope.read(context).loadServerReports();
    setState(() {
      _future = f;
    });
    try {
      await f;
    } catch (_) {
      // the FutureBuilder shows the error and its Try again
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dim = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('My reports')),
      body: SafeArea(
        child: FutureBuilder<List<ReportRow>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(
                key: Key('reports-loading'),
                child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: Gap.s), Text('Loading your reports…')]),
              );
            }
            if (snap.hasError) {
              return ListView(padding: const EdgeInsets.all(Gap.l), children: [
                ErrorBanner(friendlyError(snap.error!, action: 'Loading your reports'), key: const Key('reports-error')),
                const SizedBox(height: Gap.s),
                FilledButton.tonalIcon(
                  key: const Key('reports-retry'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ]);
            }
            final rows = snap.data!;
            if (rows.isEmpty) {
              return EmptyState(
                key: const Key('reports-empty'),
                icon: Icons.report_gmailerrorred_outlined,
                title: 'No reports yet',
                body: 'What you send with Report a problem shows here for 90 days, with its answer.',
                action: FilledButton.tonalIcon(
                  key: const Key('reports-empty-refresh'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Check again'),
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView(key: const Key('reports-list'), physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(Gap.l), children: [
                Text('${rows.length == 1 ? '1 report' : '${rows.length} reports'} · kept for 90 days', key: const Key('reports-count'), style: dim),
                const SizedBox(height: Gap.xs),
                for (final r in rows)
                  Card(
                    key: ValueKey('report-${r.id}'),
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.m),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(r.categoryWords, style: t.textTheme.titleMedium),
                        const SizedBox(height: Gap.xs),
                        // Where it stands, in words (the raw status code is not shown), marked done or still open.
                        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Icon(_closed(r) ? Icons.check_circle_outline : Icons.schedule, size: 18, color: _closed(r) ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
                          const SizedBox(width: Gap.s),
                          Expanded(child: Text(r.statusWords, key: ValueKey('report-status-${r.id}'))),
                        ]),
                        if (r.summary.isNotEmpty) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(r.summary, style: t.textTheme.bodyMedium)),
                        const SizedBox(height: Gap.xs),
                        Text('Sent ${formatDateTime(r.createdAt)}', style: dim),
                      ]),
                    ),
                  ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

/// Nothing more will happen to this report on the server's side.
bool _closed(ReportRow r) => r.status == 'closed';
