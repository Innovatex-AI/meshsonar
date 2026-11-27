// One saved drive, its home (Round 5 D-10): the verdict, the map of the whole route, the upload state, Share, four
// tiles (Pings, Heard, Distance, Duration), repeaters heard, the latest pings (each opens the ping; "All N pings" opens
// the Ping log) and a row to the report, which holds the analysis. The menu is the drive card's (D-7).
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/api.dart';
import '../core/model.dart';
import '../core/time_format.dart' as tf;
import 'app.dart';
import 'drive/drive_timing_card.dart';
import 'drive_detail_map.dart';
import 'drive_stats.dart';
import 'onboarding/ui_prefs.dart';
import 'ping_detail_sheet.dart' show showPingDetail;
import 'ping_log_screen.dart';
import 'repeater_detail_sheet.dart' show showRepeaterDetail;
import 'report/drive_report_screen.dart';
import 'report/drive_share.dart' show showDriveShareSheet;
import 'sessions_screen.dart';
import 'widgets.dart';
import 'design/app_symbols.dart';

void openDriveDetail(BuildContext context, String sessionId) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DriveDetailScreen(sessionId: sessionId)));
}

/// A repeater's short id as every drive screen prints it: upper case ("F5"), like the report and the map.
String repeaterIdText(String id) => id.toUpperCase();

/// A repeater's name, or its short id in upper case.
String repeaterNameOrId(AppState s, String id) => s.repeaterName(id) ?? repeaterIdText(id);

class DriveDetailScreen extends StatefulWidget {
  final String sessionId;
  const DriveDetailScreen({super.key, required this.sessionId});
  @override
  State<DriveDetailScreen> createState() => _DriveDetailScreenState();
}

class _DriveDetailScreenState extends State<DriveDetailScreen> {
  Future<List<DrivePing>>? _pings;
  int _loadedCount = -1;

  /// Pings listed on this screen, newest first; "All N pings" opens the Ping log with every one and its filters.
  static const pingsShown = 20;

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
            // The name, or the short date: said once (the header below carries the verdict, not the name again).
            title: Text(label ?? tf.shortDateTime(ses.startedAt), key: const Key('detail-title'), maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              TextButton.icon(
                key: const Key('detail-report'),
                onPressed: summary.pingCount == 0 ? null : () => openDriveReport(context, ses.id),
                icon: const Icon(Icons.insights),
                label: const Text('Report'),
              ),
              IconButton(
                key: const Key('detail-more'),
                tooltip: 'More',
                icon: const AppSymbolIcon(AppSymbols.ellipsisCircle, size: 24),
                onPressed: () async {
                  final nav = Navigator.of(context);
                  if (await showDriveMenu(context, summary, active: active, onDetail: true)) nav.maybePop();
                },
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
              final shown = newestFirst.take(pingsShown).toList();
              void openRepeater(String id) => showRepeaterDetail(context, id: id, lookup: s.lookup, pings: pings);
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
                    SliverToBoxAdapter(child: _UploadLine(summary: summary)),
                    SliverToBoxAdapter(child: _Actions(summary: summary)),
                    SliverToBoxAdapter(child: _StatsGrid(stats: st)),
                    SliverToBoxAdapter(child: DriveTimingCard(state: s, sessionId: ses.id)),
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
                      itemBuilder: (context, i) => _PingRow(
                        ping: shown[i],
                        onTap: () => showPingDetail(context, ping: shown[i], lookup: s.lookup, onRepeaterTap: openRepeater),
                      ),
                    ),
                    if (pings.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: OutlinedButton.icon(
                            key: const Key('show-all-pings'),
                            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                            onPressed: () => openPingLog(context, sessionId: ses.id),
                            icon: const Icon(Icons.list_alt),
                            label: Text('All ${pings.length} ping${pings.length == 1 ? '' : 's'}'),
                          ),
                        ),
                      ),
                    if (summary.pingCount > 0)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
                          child: Card(
                            margin: EdgeInsets.zero,
                            child: ListTile(
                              key: const Key('detail-report-row'),
                              leading: const Icon(Icons.insights),
                              title: const Text('Signal, charts and new cells'),
                              subtitle: const Text('The drive report'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => openDriveReport(context, ses.id),
                            ),
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

/// "External antenna" / "Internal antenna": one spelling on the detail screen and the report.
String? antennaText(String? type) => type == null ? null : '${type == 'external' ? 'External' : 'Internal'} antenna';

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
      // The app bar has the name or the short date; a named drive's date and time go here, once.
      if (label != null) tf.dateTime(ses.startedAt, weekday: true),
      if (ses.channel != null) ses.channel!,
      if (ses.companion.name != null) ses.companion.name!,
      ?antennaText(ses.antenna.type),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(DriveVerdict.ofStats(stats).line,
            key: const Key('detail-verdict'), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        if (lines.isNotEmpty) Text(lines.join(' · '), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

/// The upload state, shown once (Round 5 D-4): "12 of 40 uploaded" with Upload; "Uploaded" as a quiet line when done;
/// without an approved key, what that means and Check key (D-3).
class _UploadLine extends StatelessWidget {
  final SessionSummary summary;
  const _UploadLine({required this.summary});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final id = summary.session.id;
    final kind = uploadBadgeKind(s, summary);
    final Widget? action = switch (kind) {
      UploadBadgeKind.waiting || UploadBadgeKind.failed => TextButton.icon(
          key: const Key('detail-sync'),
          style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () => s.syncSession(id),
          icon: const Icon(Icons.cloud_upload_outlined),
          label: Text(summary.unsyncedCount > 0 ? 'Upload ${summary.unsyncedCount}' : 'Upload name'),
        ),
      UploadBadgeKind.phoneOnly => TextButton.icon(
          key: const Key('detail-check-key'),
          style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () => openDriverKeySettings(context),
          icon: const Icon(Icons.key_outlined),
          label: const Text('Check key'),
        ),
      UploadBadgeKind.uploading => const Padding(
          padding: EdgeInsets.all(12),
          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      _ => null,
    };
    final n = summary.unsyncedCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Align(alignment: Alignment.centerLeft, child: UploadBadge(summary: summary))),
          ?action,
        ]),
        if (kind == UploadBadgeKind.phoneOnly)
          Text(
            n > 0
                ? '$n ping${n == 1 ? '' : 's'} saved on this phone. Uploads start when your driver key is approved.'
                : 'The new name is saved on this phone. Uploads start when your driver key is approved.',
            key: const Key('detail-phone-only'),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
      ]),
    );
  }
}

class _Actions extends StatelessWidget {
  final SessionSummary summary;
  const _Actions({required this.summary});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: OutlinedButton.icon(
        // One Share sheet (Round 5 D-6): Report (PDF), Summary (text), Spreadsheet (CSV), Drive file (for re-upload).
        key: const Key('detail-export'),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), textStyle: const TextStyle(fontSize: 16)),
        onPressed: () => showDriveShareSheet(context, summary.session.id),
        icon: const Icon(Icons.ios_share),
        label: const Text('Share'),
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  final DriveStats stats;
  const _StatsGrid({required this.stats});

  @override
  Widget build(BuildContext context) {
    final st = stats;
    // Four tiles (Round 5 D-10). Signal, hops and the charts are the report's job.
    final tiles = <(String, String, String)>[
      ('Pings', '${st.pings}', 'stat-pings'),
      ('Heard', st.heardPercent == null ? '—' : '${st.heardPercent}%', 'stat-heard-pct'),
      ('Distance', AppScope.unitsOf(context).distance(st.distanceM), 'stat-distance'),
      ('Duration', formatDuration(st.duration), 'stat-duration'),
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
                backgroundColor: m.repeaterTint,
                child: Icon(Icons.cell_tower, color: m.repeater, size: 20),
              ),
              title: Text(repeaterNameOrId(s, r.repeater),
                  style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text([
                  if (s.repeaterName(r.repeater) != null) repeaterIdText(r.repeater),
                  if (r.bestSnr != null) 'best ${signalWords(r.bestSnr)}',
                ].join(' · ')),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: r.pings / max, minHeight: 5, color: m.repeater, backgroundColor: m.repeaterTint),
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

/// One line per ping (Round 5 D-12): dot, time, "1 repeater · Strong" (or "Heard nothing"), chevron. Tap opens the ping.
class _PingRow extends StatelessWidget {
  final DrivePing ping;
  final VoidCallback onTap;
  const _PingRow({required this.ping, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final nothing = ping.heardNothing;
    final rx = ping.kind == PingKind.rx;
    final snr = bestSnr(ping);
    final n = repeatersHeard(ping).length;
    final title = rx
        ? 'Heard a packet'
        : nothing
            ? 'Heard nothing'
            : '$n repeater${n == 1 ? '' : 's'}${snr == null ? '' : ' · ${signalWord(snr)}'}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: t.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('detail-ping-${ping.id}'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(children: [
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: MeshSonarColors.of(context).forPing(heard: !nothing, snr: snr),
                  ),
                ),
                Text(tf.timeOfDay(ping.ts, seconds: true),
                    style: t.textTheme.labelLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                Icon(Icons.chevron_right, size: 20, color: t.colorScheme.onSurfaceVariant),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
