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

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('My reports')),
      body: SafeArea(
        child: FutureBuilder<List<ReportRow>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(Gap.l),
                child: Column(children: [
                  ErrorBanner(friendlyError(snap.error!, action: 'Loading your reports'), key: const Key('reports-error')),
                  TextButton(
                      key: const Key('reports-retry'),
                      onPressed: () => setState(() => _future = AppScope.read(context).loadServerReports()),
                      child: const Text('Try again')),
                ]),
              );
            }
            final rows = snap.data!;
            if (rows.isEmpty) {
              return const EmptyState(
                  key: Key('reports-empty'),
                  icon: Icons.report_gmailerrorred_outlined,
                  title: 'No reports yet',
                  body: 'Reports you send from Report a problem appear here for 90 days.');
            }
            return ListView(key: const Key('reports-list'), padding: const EdgeInsets.all(Gap.l), children: [
              Text('Kept for 90 days.', style: t.textTheme.bodySmall),
              for (final r in rows)
                Card(
                  key: ValueKey('report-${r.id}'),
                  child: ListTile(
                    minVerticalPadding: Gap.s,
                    title: Text(r.categoryWords),
                    subtitle: Text('${formatDateTime(r.createdAt)} · ${r.status}\n${r.statusWords}${r.summary.isEmpty ? '' : '\n${r.summary}'}'),
                    isThreeLine: true,
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }
}
