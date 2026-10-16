// Saved drives, newest first: sync, export & share, delete.
import 'package:flutter/material.dart';

import '../core/api.dart';
import 'app.dart';
import 'widgets.dart';

class SessionsScreen extends StatelessWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final list = s.sessions;
    final unsyncedTotal = list.fold<int>(0, (a, x) => a + x.unsyncedCount);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Drives'),
        actions: [
          if (unsyncedTotal > 0)
            TextButton.icon(
              key: const Key('sync-all'),
              onPressed: s.anySyncing ? null : () => s.syncAll(),
              icon: const Icon(Icons.cloud_upload),
              label: const Text('Sync all'),
            ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: s.refreshSessions,
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [
              if (s.sessionsError != null) ErrorBanner(s.sessionsError!),
              if (s.lastSyncFailed && s.lastSyncMessage != null)
                ErrorBanner(s.lastSyncMessage!, key: const Key('sync-error')),
              if (list.isEmpty && s.sessionsError == null)
                const Padding(
                  padding: EdgeInsets.only(top: 80),
                  child: EmptyState(
                    icon: Icons.directions_car,
                    title: 'No drives yet',
                    body: 'Start a drive on the Drive tab. Drives are saved on this phone and listed here.',
                  ),
                ),
              for (final x in list) _SessionCard(summary: x),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final SessionSummary summary;
  const _SessionCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final ses = summary.session;
    final id = ses.id;
    final active = s.currentSession?.id == id;
    final pct = summary.pingCount == 0 ? null : (100 * summary.heardCount / summary.pingCount).round();
    final syncing = s.isSyncing(id) || s.isSyncing('*');
    final unsynced = summary.unsyncedCount;

    return Card(
      key: ValueKey('session-$id'),
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  ses.label ?? formatDateTime(ses.startedAt),
                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (active) const Chip(label: Text('Recording')),
            ]),
            if (ses.label != null) Text(formatDateTime(ses.startedAt), style: t.textTheme.bodySmall),
            const SizedBox(height: 6),
            Wrap(spacing: 16, runSpacing: 4, children: [
              Text('${summary.pingCount} pings'),
              Text(pct == null ? 'Heard —' : 'Heard $pct%'),
              Text(
                unsynced == 0 ? (summary.pingCount == 0 ? 'Nothing to sync' : 'All synced') : '$unsynced not synced',
                key: ValueKey('unsynced-$id'),
                style: TextStyle(
                  color: unsynced == 0 ? Colors.green.shade600 : t.colorScheme.tertiary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (ses.channel != null) Text(ses.channel!),
            ]),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (syncing)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else
                  TextButton.icon(
                    key: ValueKey('sync-$id'),
                    onPressed: unsynced == 0 ? null : () => s.syncSession(id),
                    icon: const Icon(Icons.cloud_upload),
                    label: const Text('Sync now'),
                  ),
                TextButton.icon(
                  key: ValueKey('export-$id'),
                  onPressed: () => s.exportAndShare(id),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Export'),
                ),
                IconButton(
                  key: ValueKey('delete-$id'),
                  tooltip: 'Delete drive',
                  onPressed: active ? null : () => _confirmDelete(context, summary),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, SessionSummary x) async {
    final s = AppScope.read(context);
    final unsynced = x.unsyncedCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this drive?'),
        content: Text(
          unsynced > 0
              ? '$unsynced of ${x.pingCount} pings have NOT been uploaded and will be lost. '
                  'Export or sync first if you want to keep them.'
              : 'This removes the drive from this phone. Pings already uploaded stay on the server.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('confirm-delete'),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await s.deleteSession(x.session.id);
  }
}
