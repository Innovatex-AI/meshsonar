// "Stats" tab for the viewed region: public-stats numbers, the live-drivers chip (public-live) and the 30-day
// leaderboard. Each of the three reads fails on its own; an empty leaderboard says so instead of showing zeros.
import 'package:flutter/material.dart';

import '../../core/region_stats_api.dart';
import '../app.dart' show AppScope;
import '../theme.dart';
import '../widgets.dart';
import 'region_common.dart';

/// Tests replace this to inject a fake HTTP client.
RegionStatsApi Function(String baseUrl) regionStatsApiFactory = (b) => RegionStatsApi(b);

class StatsPanel extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;
  const StatsPanel({super.key, required this.baseUrl, required this.regionSlug});

  @override
  State<StatsPanel> createState() => _StatsPanelState();
}

class _StatsPanelState extends State<StatsPanel> {
  late RegionStatsApi _api;
  late Future<RegionPublicStats> _stats;
  late Future<Leaderboard> _board;
  late Future<RegionLive> _live;

  @override
  void initState() {
    super.initState();
    _api = regionStatsApiFactory(widget.baseUrl);
    _load();
  }

  void _load() {
    _stats = _api.stats();
    _board = _api.leaderboard();
    _live = _api.live();
  }

  @override
  void didUpdateWidget(StatsPanel old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl || old.regionSlug != widget.regionSlug) {
      _api.close();
      _api = regionStatsApiFactory(widget.baseUrl);
      _reload();
    }
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  void _reload() => setState(_load);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () async {
        _reload();
        await Future.wait([_stats.catchError((_) => const RegionPublicStats()), _board.catchError((_) => const Leaderboard(period: '30d', rows: [])), _live.catchError((_) => const RegionLive(activeDrivers: 0, pings15m: 0))]);
      },
      child: ListView(
        key: const Key('stats-panel'),
        padding: const EdgeInsets.all(12),
        children: [
          Row(children: [
            Expanded(child: Text('Region stats', style: t.textTheme.titleLarge)),
            IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh)),
          ]),
          _Section<RegionLive>(future: _live, loadingKey: const Key('stats-live-loading'), builder: (l) => _LiveChip(l), retry: _reload),
          const SizedBox(height: Gap.m),
          _Section<RegionPublicStats>(future: _stats, loadingKey: const Key('stats-loading'), builder: (s) => StatsFigures(s), retry: _reload),
          const SizedBox(height: Gap.l),
          Text('Leaderboard, last 30 days', style: t.textTheme.titleMedium),
          const SizedBox(height: Gap.s),
          _Section<Leaderboard>(future: _board, loadingKey: const Key('stats-board-loading'), builder: (b) => LeaderboardView(b), retry: _reload),
        ],
      ),
    );
  }
}

class _Section<T> extends StatelessWidget {
  final Future<T> future;
  final Key loadingKey;
  final Widget Function(T) builder;
  final VoidCallback retry;
  const _Section({required this.future, required this.loadingKey, required this.builder, required this.retry});

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Padding(padding: const EdgeInsets.all(Gap.m), child: Center(child: CircularProgressIndicator(key: loadingKey)));
          }
          if (snap.hasError) {
            return Column(children: [
              ErrorBanner('${snap.error}'),
              TextButton.icon(onPressed: retry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
            ]);
          }
          return builder(snap.data as T);
        },
      );
}

class _LiveChip extends StatelessWidget {
  final RegionLive live;
  const _LiveChip(this.live);

  @override
  Widget build(BuildContext context) {
    final n = live.activeDrivers;
    final label = n == 0
        ? 'No one driving right now'
        : '$n ${n == 1 ? 'driver' : 'drivers'} driving now${live.callsigns.isEmpty ? '' : ' (${live.callsigns.join(', ')})'}';
    return Align(
      alignment: Alignment.centerLeft,
      child: Chip(
        key: const Key('stats-live-chip'),
        avatar: Icon(n == 0 ? Icons.pause_circle_outline : Icons.sensors, size: 18),
        label: Text(n == 0 && live.lastUploadAt != null ? '$label · last upload ${agoText(live.lastUploadAt)}' : label),
      ),
    );
  }
}

String _pct(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}%';
String _n(int? v) => v == null ? '—' : groupInt(v);

/// The public-stats grid. Public so tests and the All regions screen can reuse it without HTTP.
class StatsFigures extends StatelessWidget {
  final RegionPublicStats stats;
  const StatsFigures(this.stats, {super.key});

  @override
  Widget build(BuildContext context) {
    final s = stats;
    if (s.isEmpty) {
      return const EmptyState(icon: Icons.directions_car_outlined, title: 'No drives here yet', body: 'Numbers appear after the first uploaded drive.');
    }
    final cells = <(String, String)>[
      ('Drives', _n(s.drives)),
      ('Drivers', _n(s.drivers)),
      (AppScope.unitsOf(context).isImperial ? 'Miles driven' : 'Km driven', s.km == null ? '—' : AppScope.unitsOf(context).total(s.km! * 1000, groupInt).split(' ').first),
      ('Pings', _n(s.pings)),
      ('Pings heard', _pct(s.heardPct)),
      ('Squares heard', _pct(s.cellsHeardPct)),
      ('Repeaters heard', _n(s.repeatersHeard)),
      ('Last drive', s.lastDriveAt == null ? '—' : agoText(s.lastDriveAt)),
    ];
    return Wrap(
      key: const Key('stats-figures'),
      spacing: Gap.s,
      runSpacing: Gap.s,
      children: [for (final c in cells) _Tile(c.$1, c.$2)],
    );
  }
}

class _Tile extends StatelessWidget {
  final String label, value;
  const _Tile(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox(
      width: 150,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.textTheme.labelMedium),
            const SizedBox(height: Gap.xs),
            Text(value, style: t.textTheme.titleLarge, key: Key('stat-$label')),
          ]),
        ),
      ),
    );
  }
}

class LeaderboardView extends StatelessWidget {
  final Leaderboard board;
  const LeaderboardView(this.board, {super.key});

  @override
  Widget build(BuildContext context) {
    if (board.rows.isEmpty) {
      return const EmptyState(
        icon: Icons.emoji_events_outlined,
        title: 'No one on the leaderboard yet',
        body: 'Drivers appear here when they opt in and have driven in the last 30 days.',
      );
    }
    return Column(
      key: const Key('stats-leaderboard'),
      children: [
        for (final r in board.rows)
          ListTile(
            dense: true,
            leading: CircleAvatar(radius: 14, child: Text('${r.rank}')),
            title: Text(r.callsign),
            subtitle: Text('${r.drives} drives · ${r.cells} squares · ${r.repeatersHeard} repeaters'),
            trailing: Text(AppScope.unitsOf(context).distance(r.km * 1000)),
          ),
      ],
    );
  }
}
