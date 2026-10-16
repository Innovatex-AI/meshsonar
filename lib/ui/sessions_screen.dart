// Saved drives, newest first. Each card: name/date, duration, distance, pings, heard %, a heard/not strip and the
// sync state. Tap for the drive's map and details; Sync, Export & share, Rename and Delete from the card.
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/api.dart';
import 'app.dart';
import 'drive_detail_screen.dart';
import 'drive_stats.dart';
import 'onboarding/ui_prefs.dart';
import 'widgets.dart';

/// Loads and caches per-drive stats (they need the drive's pings). Reloaded when a drive's ping count changes.
class DriveStatsCache {
  final Map<String, ({int pings, DateTime? end, DriveStats stats})> _cache = {};
  final Map<String, Future<DriveStats>> _loading = {};

  DriveStats? peek(SessionSummary x) {
    final c = _cache[x.session.id];
    if (c == null || c.pings != x.pingCount || c.end != x.session.endedAt) return null;
    return c.stats;
  }

  Future<DriveStats> load(AppState s, SessionSummary x) {
    final hit = peek(x);
    if (hit != null) return Future.value(hit);
    final key = '${x.session.id}/${x.pingCount}/${x.session.endedAt}';
    return _loading[key] ??= () async {
      try {
        final pings = await s.services.store.pings(x.session.id);
        final st = DriveStats.of(x.session, pings);
        _cache[x.session.id] = (pings: x.pingCount, end: x.session.endedAt, stats: st);
        return st;
      } finally {
        _loading.remove(key);
      }
    }();
  }
}

final Expando<DriveStatsCache> _statsCaches = Expando('driveStats');
DriveStatsCache driveStatsCache(AppState s) => _statsCaches[s] ??= DriveStatsCache();

/// Sync state of one drive, as shown on badges.
enum SyncBadgeKind { empty, synced, waiting, failed, syncing }

SyncBadgeKind syncBadgeKind(AppState s, SessionSummary x) {
  final id = x.session.id;
  if (s.isSyncing(id) || (s.isSyncing('*') && x.unsyncedCount > 0)) return SyncBadgeKind.syncing;
  if (x.pingCount == 0) return SyncBadgeKind.empty;
  if (x.unsyncedCount == 0) return SyncBadgeKind.synced;
  if (s.lastSyncFailed) return SyncBadgeKind.failed;
  return SyncBadgeKind.waiting;
}

class SyncBadge extends StatelessWidget {
  final SessionSummary summary;
  const SyncBadge({super.key, required this.summary});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = Theme.of(context).colorScheme;
    final m = MeshSonarColors.of(context);
    final green = m.snrStrong;
    final amber = c.onSurface;
    final kind = syncBadgeKind(s, summary);
    final n = summary.unsyncedCount;
    final (IconData icon, String text, Color color) = switch (kind) {
      SyncBadgeKind.empty => (Icons.remove_circle_outline, 'Nothing to sync', c.outline),
      SyncBadgeKind.synced => (Icons.cloud_done, 'All synced', green),
      SyncBadgeKind.waiting => (Icons.cloud_upload_outlined, '$n not synced', amber.withValues(alpha: 0.8)),
      SyncBadgeKind.failed => (Icons.cloud_off, '$n not synced', c.error),
      SyncBadgeKind.syncing => (Icons.sync, 'Syncing…', c.primary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(text,
              key: ValueKey('unsynced-${summary.session.id}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        if (kind == SyncBadgeKind.failed) ...[
          const SizedBox(width: 4),
          Flexible(
            child: Text('· Sync failed',
                key: ValueKey('sync-failed-${summary.session.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        ],
      ]),
    );
  }
}

/// One bar per ping (bucketed on long drives): coloured by SNR when heard, the "silent" colour when nothing heard.
class HeardStrip extends StatelessWidget {
  final List<bool> timeline;
  final List<double?> snr;
  final double height;
  const HeardStrip({super.key, required this.timeline, this.snr = const [], this.height = 14});

  @override
  Widget build(BuildContext context) {
    final m = MeshSonarColors.of(context);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _StripPainter(timeline, snr, m, Theme.of(context).colorScheme.surfaceContainerHighest)),
    );
  }
}

class _StripPainter extends CustomPainter {
  final List<bool> t;
  final List<double?> snr;
  final MeshSonarColors m;
  final Color track;
  _StripPainter(this.t, this.snr, this.m, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4));
    canvas.clipRRect(rr);
    canvas.drawRect(Offset.zero & size, Paint()..color = track);
    if (t.isEmpty) return;
    // Bucket long drives so each bar is at least 3 px wide.
    final buckets = (size.width / 4).floor().clamp(1, t.length);
    final w = size.width / buckets;
    for (var b = 0; b < buckets; b++) {
      final from = (b * t.length / buckets).floor();
      final to = ((b + 1) * t.length / buckets).ceil().clamp(from + 1, t.length);
      var heard = 0;
      double? best;
      for (var i = from; i < to; i++) {
        if (t[i]) heard++;
        final v = i < snr.length ? snr[i] : null;
        if (v != null && (best == null || v > best)) best = v;
      }
      final frac = heard / (to - from);
      final color = frac == 0 ? m.silent.withValues(alpha: 0.55) : m.forPing(heard: true, snr: best);
      final h = frac == 0 ? size.height * 0.4 : size.height * (0.6 + 0.4 * frac);
      final gap = w > 4 ? 1.5 : 0.75;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(b * w, size.height - h, w - gap, h), const Radius.circular(1.5)),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.t != t || old.snr != snr || old.m != m;
}

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});
  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  /// Swiped away and being deleted; hidden so the Dismissible leaves the tree at once.
  final Set<String> _hidden = {};

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final prefs = uiPrefsFor(s);
    final t = Theme.of(context);
    final list = s.sessions.where((x) => !_hidden.contains(x.session.id)).toList();
    final unsyncedTotal = list.fold<int>(0, (a, x) => a + x.unsyncedCount);
    final pingTotal = list.fold<int>(0, (a, x) => a + x.pingCount);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Drives'),
        actions: [
          IconButton(
            key: const Key('refresh-drives'),
            tooltip: 'Refresh',
            onPressed: s.sessionsLoading ? null : () => s.refreshSessions(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: prefs,
          builder: (context, _) => RefreshIndicator(
            onRefresh: s.refreshSessions,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              children: [
                if (s.sessionsError != null) ErrorBanner(s.sessionsError!),
                if (s.lastSyncFailed && s.lastSyncMessage != null)
                  ErrorBanner(s.lastSyncMessage!, key: const Key('sync-error')),
                if (list.isNotEmpty)
                  _Overview(
                    drives: list.length,
                    pings: pingTotal,
                    unsynced: unsyncedTotal,
                    syncing: s.anySyncing,
                    onSyncAll: () => s.syncAll(),
                  ),
                if (list.isEmpty && s.sessionsError == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 80),
                    child: EmptyState(
                      icon: Icons.directions_car,
                      title: 'No drives yet',
                      body: 'Start a drive on the Drive tab. Drives are saved on this phone and listed here.',
                      action: Text('Pull down to refresh.', style: t.textTheme.bodySmall),
                    ),
                  ),
                for (final x in list)
                  _SessionCard(
                    key: ValueKey('card-${x.session.id}'),
                    summary: x,
                    onSwipeDelete: () async {
                      final ok = await confirmDeleteDrive(context, x);
                      if (!ok || !context.mounted) return false;
                      setState(() => _hidden.add(x.session.id));
                      final done = await AppScope.read(context).deleteSession(x.session.id);
                      if (done) unawaited(prefs.forget(x.session.id));
                      if (mounted) setState(() => _hidden.remove(x.session.id));
                      return true;
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  final int drives;
  final int pings;
  final int unsynced;
  final bool syncing;
  final VoidCallback onSyncAll;
  const _Overview(
      {required this.drives, required this.pings, required this.unsynced, required this.syncing, required this.onSyncAll});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(4, 6, 4, 10),
      color: c.primaryContainer.withValues(alpha: 0.55),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$drives drive${drives == 1 ? '' : 's'} · $pings pings',
                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: c.onPrimaryContainer)),
              const SizedBox(height: 2),
              Text(
                unsynced == 0 ? 'Everything is uploaded.' : '$unsynced ping${unsynced == 1 ? '' : 's'} waiting to upload',
                key: const Key('overview-unsynced'),
                style: t.textTheme.bodyMedium?.copyWith(color: c.onPrimaryContainer.withValues(alpha: 0.8)),
              ),
            ]),
          ),
          if (unsynced > 0)
            FilledButton.icon(
              key: const Key('sync-all'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48), textStyle: const TextStyle(fontSize: 16)),
              onPressed: syncing ? null : onSyncAll,
              icon: syncing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload),
              label: const Text('Sync all'),
            ),
        ]),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final SessionSummary summary;
  final Future<bool> Function() onSwipeDelete;
  const _SessionCard({super.key, required this.summary, required this.onSwipeDelete});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final c = t.colorScheme;
    final ses = summary.session;
    final id = ses.id;
    final active = s.currentSession?.id == id;
    final pct = summary.pingCount == 0 ? null : (100 * summary.heardCount / summary.pingCount).round();
    final syncing = s.isSyncing(id) || s.isSyncing('*');
    final unsynced = summary.unsyncedCount;
    final label = driveLabel(s, id, ses.label);
    final cache = driveStatsCache(s);

    final card = Card(
      key: ValueKey('session-$id'),
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('open-$id'),
        onTap: () => openDriveDetail(context, id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      label ?? formatDateTime(ses.startedAt),
                      key: ValueKey('title-$id'),
                      style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [if (label != null) formatDateTime(ses.startedAt), if (ses.channel != null) ses.channel!].join(' · '),
                      style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant),
                    ),
                  ]),
                ),
                if (active)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Chip(
                      avatar: Icon(Icons.fiber_manual_record, color: c.error, size: 14),
                      label: const Text('Recording'),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                _CardMenu(summary: summary, active: active),
              ]),
              const SizedBox(height: 10),
              FutureBuilder<DriveStats>(
                future: cache.load(s, summary),
                initialData: cache.peek(summary),
                builder: (context, snap) {
                  final st = snap.data;
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(spacing: 18, runSpacing: 6, children: [
                      _Fact(Icons.timer_outlined, formatDuration(st?.duration), key: ValueKey('duration-$id')),
                      _Fact(Icons.route, st == null ? '—' : formatDistance(st.distanceM), key: ValueKey('distance-$id')),
                      _Fact(Icons.podcasts, '${summary.pingCount} pings'),
                      _Fact(Icons.cell_tower, pct == null ? 'Heard —' : 'Heard $pct%', strong: true),
                    ]),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: HeardStrip(key: ValueKey('strip-$id'), timeline: st?.timeline ?? const [], snr: st?.timelineSnr ?? const []),
                    ),
                  ]);
                },
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(child: Align(alignment: Alignment.centerLeft, child: SyncBadge(summary: summary))),
                  if (syncing)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else
                    IconButton(
                      key: ValueKey('sync-$id'),
                      tooltip: 'Sync now',
                      onPressed: unsynced == 0 ? null : () => s.syncSession(id),
                      icon: const Icon(Icons.cloud_upload_outlined),
                    ),
                  IconButton(
                    key: ValueKey('export-$id'),
                    tooltip: 'Export & share',
                    onPressed: () => s.exportAndShare(id),
                    icon: const Icon(Icons.ios_share),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (active) return card;
    return Dismissible(
      key: ValueKey('dismiss-$id'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => onSwipeDelete(),
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(color: c.errorContainer, borderRadius: BorderRadius.circular(Corners.card)),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('Delete', style: TextStyle(color: c.onErrorContainer, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Icon(Icons.delete_outline, color: c.onErrorContainer),
        ]),
      ),
      child: card,
    );
  }
}

class _Fact extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool strong;
  const _Fact(this.icon, this.text, {super.key, this.strong = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 17, color: t.colorScheme.onSurfaceVariant),
      const SizedBox(width: 5),
      Text(text, style: TextStyle(fontSize: 15, fontWeight: strong ? FontWeight.w700 : FontWeight.w500, fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }
}

class _CardMenu extends StatelessWidget {
  final SessionSummary summary;
  final bool active;
  const _CardMenu({required this.summary, required this.active});

  @override
  Widget build(BuildContext context) {
    final id = summary.session.id;
    return PopupMenuButton<String>(
      key: ValueKey('menu-$id'),
      tooltip: 'More',
      onSelected: (v) => runDriveAction(context, v, summary),
      itemBuilder: (_) => [
        PopupMenuItem(
          key: ValueKey('menu-sync-$id'),
          value: 'sync',
          enabled: summary.unsyncedCount > 0,
          child: const ListTile(leading: Icon(Icons.cloud_upload_outlined), title: Text('Sync now')),
        ),
        PopupMenuItem(
          key: ValueKey('menu-export-$id'),
          value: 'export',
          child: const ListTile(leading: Icon(Icons.ios_share), title: Text('Export & share')),
        ),
        PopupMenuItem(
          key: ValueKey('rename-$id'),
          value: 'rename',
          child: const ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename')),
        ),
        PopupMenuItem(
          key: ValueKey('delete-$id'),
          value: 'delete',
          enabled: !active,
          child: const ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete')),
        ),
      ],
    );
  }
}

/// Shared by the list and the detail screen. Returns true if the drive was deleted.
Future<bool> runDriveAction(BuildContext context, String action, SessionSummary x) async {
  final s = AppScope.read(context);
  final id = x.session.id;
  switch (action) {
    case 'sync':
      await s.syncSession(id);
    case 'export':
      await s.exportAndShare(id);
    case 'rename':
      await renameDrive(context, x);
    case 'delete':
      if (await confirmDeleteDrive(context, x)) {
        final ok = await s.deleteSession(id);
        if (ok) await uiPrefsFor(s).forget(id);
        return ok;
      }
  }
  return false;
}

Future<void> renameDrive(BuildContext context, SessionSummary x) async {
  final s = AppScope.read(context);
  final prefs = uiPrefsFor(s);
  final current = driveLabel(s, x.session.id, x.session.label) ?? '';
  final c = TextEditingController(text: current);
  final v = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Name this drive'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          key: const Key('rename-field'),
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: formatDateTime(x.session.startedAt)),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        const SizedBox(height: 8),
        Text('Shown on this phone. Leave empty to use the date.', style: Theme.of(ctx).textTheme.bodySmall),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(key: const Key('rename-save'), onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
      ],
    ),
  );
  if (v == null) return;
  // Empty: fall back to the recorded label (if the drive had one) by clearing the local name.
  await prefs.setLabel(x.session.id, v.trim().isEmpty ? null : v);
}

Future<bool> confirmDeleteDrive(BuildContext context, SessionSummary x) async {
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
  return ok == true;
}
