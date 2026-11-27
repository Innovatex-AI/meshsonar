// Saved drives, newest first. Each card: name/date, the verdict ("Good: heard on 3 of 3 pings, mostly strong"),
// duration, distance, pings, heard %, a heard/not strip, the upload state and a Report button. Tap for the drive's map
// and details; the menu has Report, Share, Rename, Report a problem, Diagnostic files and Delete (the same menu as the
// detail screen). Build 77 says "Upload" everywhere (decision 9; build 76 mixed "Sync" and "Upload").
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/api.dart';
import '../core/time_format.dart' as tf;
import 'app.dart';
import 'design/app_surfaces.dart';
import 'design/app_symbols.dart';
import 'map/share_map_health.dart';
import 'charts/heard_strip.dart';
import 'drive_detail_screen.dart';
import 'drive_stats.dart';
import 'onboarding/ui_prefs.dart';
import 'report/drive_report_screen.dart';
import 'report/drive_share.dart' show showDriveShareSheet;
import 'report/progress_screen.dart' show ProgressCard;
import 'report_problem_screen.dart' show openReportProblem;
import 'settings_screen.dart' show SettingsScreen;
import 'widgets.dart';

export 'charts/heard_strip.dart' show HeardStrip;

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

/// Upload state of one drive, as the badge and the detail screen's upload line show it.
enum UploadBadgeKind {
  /// No pings and nothing else to send.
  empty,

  /// Everything that can go up is on the server.
  uploaded,

  /// Something waits and the next upload will send it.
  waiting,

  /// Something waits and the last upload failed.
  failed,

  /// Uploading now.
  uploading,

  /// Something waits but this phone has no approved driver key yet, so nothing can go up (Round 5 D-3).
  phoneOnly,
}

UploadBadgeKind uploadBadgeKind(AppState s, SessionSummary x) {
  final id = x.session.id;
  if (s.isSyncing(id) || (s.isSyncing('*') && x.hasSomethingToSync)) return UploadBadgeKind.uploading;
  if (x.pingCount == 0 && !x.sessionResendPending) return UploadBadgeKind.empty;
  // Rejected pings are never re-sent, so they don't count as waiting.
  if (!x.hasSomethingToSync) return UploadBadgeKind.uploaded;
  if (!s.keyApproved) return UploadBadgeKind.phoneOnly;
  if (s.lastSyncFailed) return UploadBadgeKind.failed;
  return UploadBadgeKind.waiting;
}

/// Pings that can go up at all: rejected pings and pings in a privacy zone never do.
int uploadablePings(SessionSummary x) {
  final n = x.pingCount - x.rejectedCount - x.zoneHeldCount;
  return n < 0 ? 0 : n;
}

/// The badge words: "12 of 40 uploaded", "Not uploaded yet", "Uploaded", "On this phone only" (Round 5 D-3, D-4).
String uploadBadgeText(UploadBadgeKind kind, SessionSummary x) {
  final n = x.unsyncedCount;
  final total = uploadablePings(x);
  final done = total - n;
  // Only the name (or other drive details) is waiting: say so rather than "0 of 0".
  final waiting = n == 0 ? 'Name not uploaded yet' : (done > 0 ? '$done of $total uploaded' : 'Not uploaded yet');
  return switch (kind) {
    UploadBadgeKind.empty => 'Nothing to upload',
    UploadBadgeKind.uploaded => 'Uploaded',
    UploadBadgeKind.waiting || UploadBadgeKind.failed => waiting,
    UploadBadgeKind.uploading => 'Uploading…',
    UploadBadgeKind.phoneOnly => 'On this phone only',
  };
}

/// Opens Settings at the driver key (Settings > Account > Driver key).
void openDriverKeySettings(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen(initialSection: 'driver-key')));

/// One drive's upload state as a plain icon and words (no pill: build 76's grey bordered pill read as a disabled
/// button). Notes for rejected pings, privacy-zone pings and a failed upload follow it.
class UploadBadge extends StatelessWidget {
  final SessionSummary summary;
  const UploadBadge({super.key, required this.summary});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = Theme.of(context).colorScheme;
    final kind = uploadBadgeKind(s, summary);
    final rejected = summary.rejectedCount;
    final held = summary.zoneHeldCount;
    final (IconData icon, Color color) = switch (kind) {
      UploadBadgeKind.empty => (Icons.remove_circle_outline, c.outline),
      UploadBadgeKind.uploaded => (Icons.cloud_done_outlined, c.onSurfaceVariant),
      UploadBadgeKind.waiting => (Icons.cloud_upload_outlined, c.onSurfaceVariant),
      UploadBadgeKind.failed => (Icons.cloud_off, c.error),
      UploadBadgeKind.uploading => (Icons.cloud_sync_outlined, c.primary),
      UploadBadgeKind.phoneOnly => (Icons.smartphone, c.onSurfaceVariant),
    };
    const style = TextStyle(fontWeight: FontWeight.w600, fontSize: 14);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 6),
      Flexible(
        child: Text(uploadBadgeText(kind, summary),
            key: ValueKey('unsynced-${summary.session.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(color: color)),
      ),
      if (held > 0 && kind != UploadBadgeKind.empty) ...[
        const SizedBox(width: 4),
        Flexible(
          child: Tooltip(
            message: 'These pings are inside one of your privacy zones. They are in your own drive log and stats on this '
                'phone, and are never uploaded.',
            child: Text('· $held kept on this phone (privacy zone)',
                key: ValueKey('zone-held-${summary.session.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style.copyWith(color: c.outline)),
          ),
        ),
      ],
      if (rejected > 0 && kind != UploadBadgeKind.empty) ...[
        const SizedBox(width: 4),
        Flexible(
          child: Tooltip(
            message: 'The server refused these pings (for example, bad GPS). They stay on this phone and in exports '
                'but are not sent again.',
            child: Text('· $rejected rejected',
                key: ValueKey('rejected-${summary.session.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style.copyWith(color: c.error)),
          ),
        ),
      ],
      if (kind == UploadBadgeKind.failed) ...[
        const SizedBox(width: 4),
        Flexible(
          child: Text('· Upload failed',
              key: ValueKey('sync-failed-${summary.session.id}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(color: color)),
        ),
      ],
    ]);
  }
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
    final list = s.sessions.where((x) => !_hidden.contains(x.session.id)).toList();
    final unsyncedTotal = list.fold<int>(0, (a, x) => a + x.unsyncedCount);
    final namesPending = list.where((x) => x.unsyncedCount == 0 && x.sessionResendPending).length;
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
                    namesPending: namesPending,
                    syncing: s.anySyncing,
                    keyApproved: s.keyApproved,
                    onSyncAll: () => s.syncAll(),
                  ),
                if (list.isNotEmpty) ProgressCard(sessions: list, now: s.services.clock()),
                if (list.isEmpty && s.sessionsError == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 80),
                    child: EmptyState(
                      icon: Icons.directions_car,
                      title: 'No drives yet',
                      body: 'Your drives are saved on this phone and listed here.',
                      // The next step is a button (build 76; it was the sentence "Start a drive on the Drive tab").
                      action: FilledButton.icon(
                        key: const Key('drives-empty-start'),
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                        onPressed: () {
                          final shell = ShellScope.maybeRead(context);
                          Navigator.of(context).popUntil((r) => r.isFirst);
                          shell?.select(AppTab.drive);
                        },
                        icon: const Icon(Icons.directions_car_rounded),
                        label: const Text('Go to Drive'),
                      ),
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

  /// Drives whose only change waiting to upload is their name.
  final int namesPending;
  final bool syncing;

  /// False: no approved driver key yet, so nothing can upload; the card says so and offers "Check key" (D-3).
  final bool keyApproved;
  final VoidCallback onSyncAll;
  const _Overview(
      {required this.drives,
      required this.pings,
      required this.unsynced,
      this.namesPending = 0,
      required this.syncing,
      this.keyApproved = true,
      required this.onSyncAll});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final waiting = unsynced > 0 || namesPending > 0;
    final String line;
    if (!waiting) {
      line = 'Everything is uploaded.';
    } else if (!keyApproved) {
      line = unsynced > 0
          ? '$unsynced ping${unsynced == 1 ? '' : 's'} saved on this phone. Uploads start when your driver key is approved.'
          : '$namesPending drive name${namesPending == 1 ? '' : 's'} saved on this phone. Uploads start when your driver key is approved.';
    } else {
      line = unsynced > 0
          ? '$unsynced ping${unsynced == 1 ? '' : 's'} waiting to upload'
          : '$namesPending drive name${namesPending == 1 ? '' : 's'} waiting to upload';
    }
    final Widget? button = !waiting
        ? null
        : !keyApproved
            ? FilledButton.tonalIcon(
                key: const Key('check-key'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48), textStyle: const TextStyle(fontSize: 16)),
                onPressed: () => openDriverKeySettings(context),
                icon: const Icon(Icons.key_outlined),
                label: const Text('Check key'),
              )
            : FilledButton.icon(
                key: const Key('sync-all'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48), textStyle: const TextStyle(fontSize: 16)),
                onPressed: syncing ? null : onSyncAll,
                icon: syncing
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cloud_upload),
                label: const Text('Upload all'),
              );
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
              Text(line,
                  key: const Key('overview-unsynced'),
                  style: t.textTheme.bodyMedium?.copyWith(color: c.onPrimaryContainer.withValues(alpha: 0.8))),
            ]),
          ),
          if (button != null) ...[const SizedBox(width: 8), button],
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
    // tx-aware guard (DriveStats.heardPercent does the same): an all-rx (discovery/listen-only) drive has no tx pings
    // at all, so "0% heard" would misread as a failed drive, not a successful listen session.
    final pct = summary.txCount == 0 ? null : (100 * summary.heardCount / summary.txCount).round();
    final syncing = s.isSyncing(id) || s.isSyncing('*');
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
          child: FutureBuilder<DriveStats>(
            future: cache.load(s, summary),
            initialData: cache.peek(summary),
            builder: (context, snap) {
              final st = snap.data;
              // The verdict (Round 5 D-1): the same line as the detail header and the report headline. Before the
              // pings are read it is worked out from the counts, without the strength word.
              final verdict = st == null
                  ? DriveVerdict.of(pings: summary.pingCount, txPings: summary.txCount, heard: summary.heardCount)
                  : DriveVerdict.ofStats(st);
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        label ?? tf.dateTime(ses.startedAt, weekday: true),
                        key: ValueKey('title-$id'),
                        style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Build 76: the second line is the date of a named drive, nothing else. The channel is on the
                      // drive's own page.
                      if (label != null) ...[
                        const SizedBox(height: 2),
                        Text(tf.dateTime(ses.startedAt, weekday: true),
                            style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                      ],
                      const SizedBox(height: 4),
                      Text(verdict.line, key: ValueKey('verdict-$id'), style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
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
                Wrap(spacing: 18, runSpacing: 6, children: [
                  _Fact(Icons.timer_outlined, formatDuration(st?.duration), key: ValueKey('duration-$id')),
                  _Fact(Icons.route, st == null ? '—' : s.units.distance(st.distanceM), key: ValueKey('distance-$id')),
                  _Fact(Icons.podcasts, '${summary.pingCount} pings'),
                  _Fact(Icons.cell_tower, pct == null ? 'Heard —' : 'Heard $pct%', strong: true),
                ]),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: HeardStrip(
                    key: ValueKey('strip-$id'),
                    timeline: st?.timeline ?? const [],
                    snr: st?.timelineSnr ?? const [],
                    summary: st == null ? null : 'Heard on ${st.heard} of ${st.txPings} pings, ping by ping.',
                  ),
                ),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(child: Align(alignment: Alignment.centerLeft, child: UploadBadge(summary: summary))),
                  if (syncing)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  // Upload only when something waits and the key can upload it (without an approved key it would only
                  // show a toast; the overview card above says why and offers Check key).
                  else if (summary.hasSomethingToSync && s.keyApproved)
                    TextButton.icon(
                      key: ValueKey('sync-$id'),
                      style: TextButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 10)),
                      onPressed: () => s.syncSession(id),
                      icon: const Icon(Icons.cloud_upload_outlined, size: 20),
                      label: const Text('Upload'),
                    ),
                  // Round 5 D-5: the report is one tap from the list (Share moved into the menu).
                  if (summary.pingCount > 0)
                    TextButton.icon(
                      key: ValueKey('card-report-$id'),
                      style: TextButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 10)),
                      onPressed: () => openDriveReport(context, id),
                      icon: const Icon(Icons.insights, size: 20),
                      label: const Text('Report'),
                    ),
                ]),
              ]);
            },
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
  Widget build(BuildContext context) => IconButton(
        key: ValueKey('menu-${summary.session.id}'),
        tooltip: 'More',
        icon: const AppSymbolIcon(AppSymbols.ellipsisCircle, size: 24),
        onPressed: () => showDriveMenu(context, summary, active: active),
      );
}

/// The one drive menu (Round 5 D-7), the same on the drive card and the drive detail screen: Report, Share, Rename,
/// Report a problem, Diagnostic files (the ping trace and the map health file, for testers), Delete. [onDetail] gives
/// the rows the detail screen's keys. Returns true if the drive was deleted.
Future<bool> showDriveMenu(BuildContext context, SessionSummary summary, {required bool active, bool onDetail = false}) async {
  final id = summary.session.id;
  Key k(String card, String detail) => onDetail ? Key(detail) : ValueKey('$card$id');
  final v = await showAppActionSheet<String>(
    context,
    title: 'Drive',
    actions: [
      if (summary.pingCount > 0) AppAction('Report', 'report', key: k('menu-report-', 'detail-menu-report')),
      AppAction('Share…', 'share', key: k('menu-share-', 'detail-menu-share')),
      AppAction('Rename', 'rename', key: k('rename-', 'detail-rename')),
      AppAction('Report a problem', 'problem', key: k('menu-problem-', 'detail-more-report')),
      AppAction('Diagnostic files…', 'diagnostics', key: k('menu-diagnostics-', 'detail-diagnostics')),
      if (!active) AppAction('Delete', 'delete', destructive: true, key: k('delete-', 'detail-delete')),
    ],
  );
  if (v == null || !context.mounted) return false;
  return runDriveAction(context, v, summary);
}

/// Shared by the list and the detail screen. Returns true if the drive was deleted.
Future<bool> runDriveAction(BuildContext context, String action, SessionSummary x) async {
  final s = AppScope.read(context);
  final id = x.session.id;
  switch (action) {
    case 'sync':
      await s.syncSession(id);
    case 'report':
      await openDriveReport(context, id);
    case 'share':
    case 'export':
      await showDriveShareSheet(context, id);
    case 'diagnostics':
      final d = await showAppActionSheet<String>(
        context,
        title: 'Diagnostic files',
        message: 'For testers: files that help find a problem with pings or the map.',
        actions: [
          AppAction('Ping trace', 'trace', key: ValueKey('menu-trace-$id')),
          AppAction('Map health', 'map-health', key: ValueKey('menu-map-health-$id')),
        ],
      );
      if (d != null && context.mounted) return runDriveAction(context, d, x);
    case 'trace':
      await s.shareTrace(id);
    case 'map-health':
      await shareMapHealth(context, s, id);
    case 'rename':
      await renameDrive(context, x);
    case 'problem':
      openReportProblem(context, driveId: id);
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
  final current = driveLabel(s, x.session.id, x.session.label) ?? '';
  final v = await showAppSheet<String>(
    context,
    detents: const [0.45],
    builder: (ctx, controller) => _RenameSheet(initial: current, hint: tf.dateTime(x.session.startedAt, weekday: true), controller: controller),
  );
  if (v == null) return;
  // Saved in the drive itself (exports carry it) and marked so the next upload sends it. Empty clears the name.
  await renameDriveTo(s, x.session.id, v);
}

/// Renames through the drive store and drops any older phone-only name, which would otherwise hide the new one.
Future<bool> renameDriveTo(AppState s, String sessionId, String? name) async {
  final ok = await s.renameSession(sessionId, name);
  if (ok) await uiPrefsFor(s).forget(sessionId);
  return ok;
}

Future<bool> confirmDeleteDrive(BuildContext context, SessionSummary x) async {
  final unsynced = x.unsyncedCount;
  final ok = await showAppConfirm(
    context,
    title: 'Delete this drive?',
    message: unsynced > 0
        ? '$unsynced of ${x.pingCount} pings have NOT been uploaded and will be lost. '
            'Share or upload them first if you want to keep them.'
        : 'This removes the drive from this phone. Pings already uploaded stay on the server.',
    confirmLabel: 'Delete',
    destructive: true,
    confirmKey: const Key('confirm-delete'),
  );
  return ok;
}

class _RenameSheet extends StatefulWidget {
  final String initial, hint;
  final ScrollController controller;
  const _RenameSheet({required this.initial, required this.hint, required this.controller});
  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppSheetScaffold(
        controller: widget.controller,
        title: 'Name this drive',
        primaryAction: FilledButton(key: const Key('rename-save'), onPressed: () => Navigator.pop(context, _c.text), child: const Text('Save')),
        secondaryAction: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        children: [
          TextField(
            key: const Key('rename-field'),
            controller: _c,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(hintText: widget.hint),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          const SizedBox(height: 8),
          Text('Saved with the drive and sent to the server on the next upload. Leave empty to use the date.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}
