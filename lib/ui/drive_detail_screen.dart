// One saved drive: map of the whole route, stats, repeaters heard, and every ping with its echoes.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/api.dart';
import '../core/model.dart';
import 'app.dart';
import 'drive_detail_map.dart';
import 'drive_stats.dart';
import 'onboarding/ui_prefs.dart';
import 'report/drive_report_screen.dart';
import 'ping_log_screen.dart';
import 'sessions_screen.dart';
import 'widgets.dart';

void openDriveDetail(BuildContext context, String sessionId) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DriveDetailScreen(sessionId: sessionId)));
}

class DriveDetailScreen extends StatefulWidget {
  final String sessionId;
  const DriveDetailScreen({super.key, required this.sessionId});
  @override
  State<DriveDetailScreen> createState() => _DriveDetailScreenState();
}

class _DriveDetailScreenState extends State<DriveDetailScreen> {
  Future<List<DrivePing>>? _pings;
  int _loadedCount = -1;
  bool _showAll = false;
  static const _pageSize = 60;

  void _ensureLoaded(AppState s, SessionSummary? x) {
    final n = x?.pingCount ?? 0;
    if (_pings == null || n != _loadedCount) {
      _loadedCount = n;
      _pings = s.services.store.pings(widget.sessionId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final prefs = uiPrefsFor(s);
    SessionSummary? x;
    for (final e in s.sessions) {
      if (e.session.id == widget.sessionId) x = e;
    }
    _ensureLoaded(s, x);
    final t = Theme.of(context);

    if (x == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Drive')),
        body: const EmptyState(icon: Icons.delete_outline, title: 'This drive is no longer on this phone.'),
      );
    }
    final summary = x;
    final ses = summary.session;
    final active = s.currentSession?.id == ses.id;

    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        final label = driveLabel(s, ses.id, ses.label);
        return Scaffold(
          key: const Key('drive-detail'),
          appBar: AppBar(
            title: Text(label ?? 'Drive', maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              TextButton.icon(
                key: const Key('detail-report'),
                onPressed: summary.pingCount == 0 ? null : () => openDriveReport(context, ses.id),
                icon: const Icon(Icons.insights),
                label: const Text('Report'),
              ),
              IconButton(
                key: const Key('detail-rename'),
                tooltip: 'Rename',
                onPressed: () => renameDrive(context, summary),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                key: const Key('detail-delete'),
                tooltip: 'Delete drive',
                onPressed: active
                    ? null
                    : () async {
                        final nav = Navigator.of(context);
                        if (await runDriveAction(context, 'delete', summary)) nav.maybePop();
                      },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          body: FutureBuilder<List<DrivePing>>(
            future: _pings,
            builder: (context, snap) {
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: ErrorBanner('Couldn\'t read this drive. ${snap.error}'),
                );
              }
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final pings = List.of(snap.data!)..sort((a, b) => a.ts.compareTo(b.ts));
              final st = DriveStats.of(ses, pings);
              final newestFirst = pings.reversed.toList();
              final shown = _showAll ? newestFirst : newestFirst.take(_pageSize).toList();
              return SafeArea(
                top: false,
                child: CustomScrollView(
                  key: const Key('detail-scroll'),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(Corners.card),
                          child: SizedBox(
                            height: 300,
                            child: pings.isEmpty
                                ? ColoredBox(
                                    color: t.colorScheme.surfaceContainerHighest,
                                    child: const EmptyState(icon: Icons.map_outlined, title: 'No pings to map'),
                                  )
                                : DriveDetailMap(key: const Key('detail-map'), pings: pings),
                          ),
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(child: _Header(summary: summary, label: label, stats: st)),
                    SliverToBoxAdapter(child: _Actions(summary: summary)),
                    SliverToBoxAdapter(child: _StatsGrid(stats: st)),
                    if (st.repeaters.isNotEmpty) SliverToBoxAdapter(child: _Repeaters(stats: st)),
                    SliverToBoxAdapter(
                      child: _SectionTitle('Pings', trailing: '${pings.length}'),
                    ),
                    if (pings.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(padding: EdgeInsets.all(16), child: Text('No pings were recorded on this drive.')),
                      ),
                    SliverList.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) => _PingRow(ping: shown[i]),
                    ),
                    if (!_showAll && newestFirst.length > _pageSize)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: OutlinedButton(
                            key: const Key('show-all-pings'),
                            onPressed: () => setState(() => _showAll = true),
                            child: Text('Show all ${newestFirst.length} pings'),
                          ),
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final SessionSummary summary;
  final String? label;
  final DriveStats stats;
  const _Header({required this.summary, required this.label, required this.stats});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ses = summary.session;
    final lines = <String>[
      if (label != null) formatDateTime(ses.startedAt),
      if (ses.channel != null) ses.channel!,
      if (ses.companion.name != null) ses.companion.name!,
      if (ses.antenna.type != null) 'Antenna: ${ses.antenna.type}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label ?? formatDateTime(ses.startedAt),
                style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(lines.join(' · '), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: 8),
        SyncBadge(summary: summary),
      ]),
    );
  }
}

class _Actions extends StatelessWidget {
  final SessionSummary summary;
  const _Actions({required this.summary});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final id = summary.session.id;
    final syncing = s.isSyncing(id) || s.isSyncing('*');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(children: [
        Expanded(
          child: FilledButton.icon(
            key: const Key('detail-sync'),
            style: FilledButton.styleFrom(
                minimumSize: const Size(0, 52),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(fontSize: 16)),
            onPressed: (syncing || summary.unsyncedCount == 0) ? null : () => s.syncSession(id),
            icon: syncing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(summary.unsyncedCount == 0 ? Icons.cloud_done : Icons.cloud_upload),
            label: Text(summary.unsyncedCount == 0 ? 'Synced' : 'Sync ${summary.unsyncedCount}'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('detail-export'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 52),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(fontSize: 16)),
            onPressed: () => s.exportAndShare(id),
            icon: const Icon(Icons.ios_share),
            label: const Text('Export'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('detail-ping-log'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 52),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(fontSize: 16)),
            onPressed: () => openPingLog(context, sessionId: id),
            icon: const Icon(Icons.list_alt),
            label: const Text('Ping log'),
          ),
        ),
      ]),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  final DriveStats stats;
  const _StatsGrid({required this.stats});

  @override
  Widget build(BuildContext context) {
    final st = stats;
    String snr(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} dB';
    final tiles = <(String, String, String)>[
      ('Pings', '${st.pings}', 'stat-pings'),
      ('Heard', st.heardPercent == null ? '—' : '${st.heardPercent}%', 'stat-heard-pct'),
      ('Distance', formatDistance(st.distanceM), 'stat-distance'),
      ('Duration', formatDuration(st.duration), 'stat-duration'),
      ('Best SNR', snr(st.bestSnr), 'stat-best-snr'),
      ('Median SNR', snr(st.medianSnr), 'stat-median-snr'),
      ('Repeaters', '${st.repeaters.length}', 'stat-repeaters'),
      ('Multi-hop', '${st.multiHopEchoes}', 'stat-multihop'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Column(children: [
        LayoutBuilder(builder: (context, box) {
          final cols = box.maxWidth > 640 ? 4 : 2;
          final w = (box.maxWidth - (cols - 1) * 8) / cols;
          return Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (label, value, key) in tiles) SizedBox(width: w, child: _Tile(label: label, value: value, valueKey: Key(key))),
          ]);
        }),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Heard over the drive', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            HeardStrip(timeline: st.timeline, snr: st.timelineSnr, height: 22),
          ]),
        ),
      ]),
    );
  }
}

class _Tile extends StatelessWidget {
  final String label;
  final String value;
  final Key valueKey;
  const _Tile({required this.label, required this.value, required this.valueKey});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Corners.chip),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, key: valueKey, style: numberStyle(context, size: 28)),
        ),
      ]),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final String? trailing;
  const _SectionTitle(this.text, {this.trailing});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Row(children: [
        Text(text, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Text(trailing!, style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
      ]),
    );
  }
}

class _Repeaters extends StatelessWidget {
  final DriveStats stats;
  const _Repeaters({required this.stats});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final max = stats.repeaters.first.pings;
    final m = MeshSonarColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _SectionTitle('Repeaters heard', trailing: '${stats.repeaters.length}'),
      Card(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(children: [
          for (final r in stats.repeaters)
            ListTile(
              key: ValueKey('repeater-${r.repeater}'),
              dense: false,
              leading: CircleAvatar(
                backgroundColor: m.beacon.withValues(alpha: 0.16),
                child: Icon(Icons.cell_tower, color: m.beacon, size: 20),
              ),
              title: Text(s.repeaterName(r.repeater) ?? r.repeater,
                  style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text([
                  if (s.repeaterName(r.repeater) != null) r.repeater,
                  if (r.bestSnr != null) 'best ${formatSnr(r.bestSnr)}',
                ].join(' · ')),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: r.pings / max, minHeight: 5, color: m.beacon),
                ),
              ]),
              trailing: Text('${r.pings}×',
                  key: ValueKey('repeater-count-${r.repeater}'), style: numberStyle(context, size: 22)),
            ),
        ]),
      ),
    ]);
  }
}

class _PingRow extends StatelessWidget {
  final DrivePing ping;
  const _PingRow({required this.ping});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final nothing = ping.heardNothing;
    final rx = ping.kind == PingKind.rx;
    final snr = bestSnr(ping);
    final title = rx
        ? 'Heard a packet'
        : nothing
            ? 'Heard nothing'
            : '${repeatersHeard(ping).length} repeater${repeatersHeard(ping).length == 1 ? '' : 's'} · ${formatSnr(snr)}';
    return Padding(
      key: ValueKey('detail-ping-${ping.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Container(
        decoration: BoxDecoration(
          color: t.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: MeshSonarColors.of(context).forPing(heard: !nothing, snr: snr),
              ),
            ),
            Text(formatTime(ping.ts),
                style: t.textTheme.labelLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
          ]),
          for (final e in ping.echoes)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 14),
              child: Row(children: [
                Icon(Icons.cell_tower, size: 15, color: MeshSonarColors.of(context).beacon),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: s.repeaterLabel(e.repeater), style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (s.repeaterName(e.repeater) != null)
                        TextSpan(text: '  ${e.repeater}', style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  [formatSnr(e.snrDb), if (e.hops != null) '${e.hops} hop${e.hops == 1 ? '' : 's'}'].join(' · '),
                  style: t.textTheme.bodySmall,
                ),
              ]),
            ),
          if (ping.neighbor != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Row(children: [
                Icon(Icons.swap_horiz, size: 16, color: t.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Neighbor ${s.repeaterLabel(ping.neighbor!.repeater)}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(formatSnr(ping.neighbor!.localSnrDb), style: t.textTheme.bodySmall),
              ]),
            ),
        ]),
      ),
    );
  }
}
