// Ping log: every ping of a drive with its full result, plus the repeaters heard.
//
//   PingLogScreen()                  the current drive, live from AppScope (newest first, updates as pings arrive);
//                                    after Stop it keeps showing the drive that just ended.
//   PingLogScreen(sessionId: id)     a saved drive, loaded from the store (live if it's the drive in progress).
//
// Tap a ping → ping_detail_sheet.dart; tap a repeater → repeater_detail_sheet.dart.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/api.dart';
import '../core/heard.dart';
import '../core/model.dart';
import 'app.dart';
import 'ping_detail_sheet.dart';
import 'repeater_detail_sheet.dart';
import 'repeater_widgets.dart';
import 'widgets.dart';

void openPingLog(BuildContext context, {String? sessionId}) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PingLogScreen(sessionId: sessionId)));
}

enum PingFilter { all, heard, nothing }

enum _Tab { pings, repeaters }

/// Repeaters heard in [pings] (any order), aggregated like the live tracker. Nothing is ever "stale" here.
List<HeardRepeater> aggregateRepeaters(List<DrivePing> pings, RepeaterLookup lookup) {
  final t = HeardTracker(holdPings: 1 << 30, lookup: lookup);
  for (final p in List.of(pings)..sort((a, b) => a.ts.compareTo(b.ts))) {
    t.addPing(p);
  }
  return t.repeaters..sort((a, b) => b.timesHeard != a.timesHeard ? b.timesHeard.compareTo(a.timesHeard) : b.lastPingIndex.compareTo(a.lastPingIndex));
}

class PingLogScreen extends StatefulWidget {
  /// Null = the current (or just-finished) drive, live.
  final String? sessionId;
  const PingLogScreen({super.key, this.sessionId});
  @override
  State<PingLogScreen> createState() => _PingLogScreenState();
}

class _PingLogScreenState extends State<PingLogScreen> {
  PingFilter _filter = PingFilter.all;
  _Tab _tab = _Tab.pings;
  Future<List<DrivePing>>? _future;
  int _loadedCount = -1;

  bool _isLive(AppState s) => widget.sessionId == null || widget.sessionId == s.currentSession?.id;

  void _ensureLoaded(AppState s) {
    var n = 0;
    for (final x in s.sessions) {
      if (x.session.id == widget.sessionId) n = x.pingCount;
    }
    if (_future == null || n != _loadedCount) {
      _loadedCount = n;
      _future = s.services.store.pings(widget.sessionId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final live = _isLive(s);
    String subtitle;
    if (live) {
      subtitle = s.driving ? 'Current drive · live' : (s.drivePings.isEmpty ? 'No drive yet' : 'Last drive');
    } else {
      SessionSummary? x;
      for (final e in s.sessions) {
        if (e.session.id == widget.sessionId) x = e;
      }
      subtitle = x == null ? 'Saved drive' : (x.session.label ?? formatDateTime(x.session.startedAt));
    }
    return Scaffold(
      key: const Key('ping-log'),
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Ping log'),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      ),
      body: SafeArea(
        top: false,
        child: live
            ? _body(context, s, s.drivePings, live: true)
            : Builder(builder: (context) {
                _ensureLoaded(s);
                return FutureBuilder<List<DrivePing>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Padding(
                        padding: const EdgeInsets.all(Gap.l),
                        child: ErrorBanner('Couldn\'t read this drive. ${snap.error}'),
                      );
                    }
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                    return _body(context, s, snap.data!, live: false);
                  },
                );
              }),
      ),
    );
  }

  Widget _body(BuildContext context, AppState s, List<DrivePing> pings, {required bool live}) {
    final newestFirst = List.of(pings)..sort((a, b) => b.ts.compareTo(a.ts));
    final tx = newestFirst.where((p) => p.kind == PingKind.tx).toList();
    final heardN = tx.where((p) => !p.heardNothing).length;
    final reps = live ? s.heard.repeaters : aggregateRepeaters(pings, s.lookup);
    // A live tracker only exists for the drive in progress; after Stop, aggregate the finished drive instead.
    final repeaters = (live && reps.isEmpty && pings.isNotEmpty) ? aggregateRepeaters(pings, s.lookup) : reps;

    final shown = switch (_filter) {
      PingFilter.all => newestFirst,
      PingFilter.heard => newestFirst.where((p) => !p.heardNothing).toList(),
      PingFilter.nothing => newestFirst.where((p) => p.heardNothing).toList(),
    };

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(Gap.m, Gap.xs, Gap.m, Gap.s),
      child: Column(children: [
        StatStrip(tiles: [
          StatTile(label: 'Pings', value: '${newestFirst.length}', valueKey: const Key('log-sum-pings')),
          StatTile(
            label: 'Heard',
            value: tx.isEmpty ? '—' : '${(100 * heardN / tx.length).round()}%',
            valueKey: const Key('log-sum-heard'),
          ),
          StatTile(label: 'Repeaters', value: '${repeaters.length}', valueKey: const Key('log-sum-repeaters')),
        ]),
        const SizedBox(height: Gap.m),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<_Tab>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: Theme.of(context).colorScheme.primaryContainer,
              selectedForegroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
            segments: [
              ButtonSegment(value: _Tab.pings, label: Text('Pings', key: const Key('log-tab-pings'))),
              ButtonSegment(value: _Tab.repeaters, label: Text('Repeaters', key: const Key('log-tab-repeaters'))),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() => _tab = v.first),
          ),
        ),
        if (_tab == _Tab.pings) ...[
          const SizedBox(height: Gap.s),
          Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
            for (final (f, label) in [
              (PingFilter.all, 'All'),
              (PingFilter.heard, 'Heard'),
              (PingFilter.nothing, 'Heard nothing'),
            ])
              ChoiceChip(
                key: Key('log-filter-${f.name}'),
                label: Text(label),
                selected: _filter == f,
                showCheckmark: false,
                selectedColor: Theme.of(context).colorScheme.primaryContainer,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                onSelected: (_) => setState(() => _filter = f),
              ),
          ]),
        ],
      ]),
    );

    void openRepeater(String id) => showRepeaterDetail(context, id: id, lookup: s.lookup, pings: pings);

    Widget list;
    if (_tab == _Tab.pings) {
      if (shown.isEmpty) {
        list = EmptyState(
          icon: Icons.radar,
          title: newestFirst.isEmpty ? 'No pings yet' : 'No pings match this filter',
          body: newestFirst.isEmpty && live ? 'Start a drive; every ping shows up here as it finishes.' : null,
        );
      } else {
        list = ListView.separated(
          key: const Key('log-list'),
          padding: const EdgeInsets.only(bottom: Gap.xl),
          itemCount: shown.length,
          separatorBuilder: (_, _) => const Divider(indent: Gap.l, endIndent: Gap.l),
          itemBuilder: (context, i) => PingLogRow(
            ping: shown[i],
            lookup: s.lookup,
            onTap: () => showPingDetail(context, ping: shown[i], lookup: s.lookup, onRepeaterTap: openRepeater),
          ),
        );
      }
    } else {
      if (repeaters.isEmpty) {
        list = const EmptyState(icon: Icons.cell_tower, title: 'No repeaters heard yet');
      } else {
        list = ListView.separated(
          key: const Key('log-repeaters'),
          padding: const EdgeInsets.only(bottom: Gap.xl),
          itemCount: repeaters.length,
          separatorBuilder: (_, _) => const Divider(indent: Gap.l, endIndent: Gap.l),
          itemBuilder: (context, i) => HeardRepeaterTile(repeaters[i], onTap: () => openRepeater(repeaters[i].id)),
        );
      }
    }
    return Column(children: [header, Expanded(child: list)]);
  }
}

/// One ping in the log: time, result, best SNR, and compact chips of the repeaters heard.
class PingLogRow extends StatelessWidget {
  final DrivePing ping;
  final RepeaterLookup lookup;
  final VoidCallback? onTap;
  const PingLogRow({super.key, required this.ping, required this.lookup, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final ids = repeatersHeard(ping);
    final nothing = ping.heardNothing;
    final snr = bestSnr(ping);
    final color = mc.forPing(heard: !nothing, snr: snr);
    final title = ping.kind == PingKind.rx
        ? 'Heard a packet'
        : nothing
            ? 'Heard nothing'
            : 'Heard ${ids.length}';
    return InkWell(
      key: ValueKey('log-ping-${ping.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s + 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(width: 12, height: 12, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(formatTime(ping.ts),
                    style: t.textTheme.labelLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Text(
                    title,
                    style: t.textTheme.titleSmall?.copyWith(color: nothing ? mc.silent : null),
                  ),
                ),
              ]),
              if (ids.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final id in ids.take(4)) _RepChip(match: lookup.resolve(id)),
                  if (ids.length > 4) Text('+${ids.length - 4}', style: t.textTheme.labelMedium),
                ]),
              ],
            ]),
          ),
          if (snr != null) ...[const SizedBox(width: Gap.s), SnrPill(snr)],
          const SizedBox(width: Gap.xs),
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(Icons.chevron_right, size: 20, color: t.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}

class _RepChip extends StatelessWidget {
  final RepeaterMatch match;
  const _RepChip({required this.match});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final name = match.ref?.name.isNotEmpty == true ? match.ref!.name : null;
    return Container(
      constraints: const BoxConstraints(maxWidth: 190),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: mc.beacon.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (name != null)
          Flexible(
            child: Text(name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurface)),
          ),
        if (name != null) const SizedBox(width: 5),
        Text(
          match.id.toUpperCase() + (match.ambiguous ? '?' : ''),
          style: TextStyle(fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.w600, color: t.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}
