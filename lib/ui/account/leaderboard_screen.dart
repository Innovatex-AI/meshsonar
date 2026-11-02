// The full leaderboard (the website's /drives/leaderboard and /leaderboard): opted-in drivers by distance, 30 days or all time,
// for the viewed region or for every region. The Drive tab's trophy sheet links here. Last good answer is cached by the region
// client, so it opens offline with an "offline copy" note.
import 'package:flutter/material.dart';

import '../../core/region_stats_api.dart';
import '../app.dart';
import '../region/stats_panel.dart' show LeaderboardView, regionStatsApiFactory;

Future<void> openLeaderboard(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LeaderboardScreen()));

class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});
  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  String _period = '30d';
  bool _everywhere = false;
  RegionStatsApi? _api;
  Future<Leaderboard>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future == null) _load();
  }

  @override
  void dispose() {
    _api?.close();
    super.dispose();
  }

  void _load() {
    final s = AppScope.read(context);
    _api?.close();
    final base = s.viewingRegion?.url ?? s.settings.serverUrl;
    final api = _api = regionStatsApiFactory(base);
    final hubOk = s.siteConfig?.networkLeaderboard ?? s.uploadSiteConfig?.networkLeaderboard ?? false;
    _future = _everywhere && hubOk ? api.networkLeaderboard(period: _period) : api.leaderboard(period: _period);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final canNetwork = s.siteConfig?.networkLeaderboard ?? s.uploadSiteConfig?.networkLeaderboard ?? false;
    final region = s.viewingRegion?.name;
    return Scaffold(
      appBar: AppBar(title: const Text('Leaderboard')),
      body: SafeArea(
        child: ListView(key: const Key('leaderboard-screen'), padding: const EdgeInsets.all(Gap.l), children: [
          SegmentedButton<String>(
            key: const Key('leaderboard-period'),
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: '30d', label: Text('Last 30 days')), ButtonSegment(value: 'all', label: Text('All time'))],
            selected: {_period},
            onSelectionChanged: (v) {
              _period = v.first;
              _load();
            },
          ),
          if (canNetwork) ...[
            const SizedBox(height: Gap.s),
            SegmentedButton<bool>(
              key: const Key('leaderboard-scope'),
              showSelectedIcon: false,
              segments: [ButtonSegment(value: false, label: Text(region ?? 'This region')), const ButtonSegment(value: true, label: Text('Every region'))],
              selected: {_everywhere},
              onSelectionChanged: (v) {
                _everywhere = v.first;
                _load();
              },
            ),
          ],
          const SizedBox(height: Gap.s),
          Text('Only drivers who opted in appear, by their callsign. Each driver is counted once.', style: t.textTheme.bodySmall),
          const SizedBox(height: Gap.m),
          FutureBuilder<Leaderboard>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const Center(child: Padding(padding: EdgeInsets.all(Gap.l), child: CircularProgressIndicator()));
              if (snap.hasError) {
                final e = snap.error;
                return Column(children: [
                  Text(e is RegionStatsException ? e.message : 'The leaderboard could not be loaded.', key: const Key('leaderboard-error')),
                  TextButton(key: const Key('leaderboard-retry'), onPressed: _load, child: const Text('Try again')),
                ]);
              }
              final b = snap.data!;
              final mine = (s.settings.display ?? '').toLowerCase();
              return Column(children: [
                if (b.offlineAsOf != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.s),
                    child: Text('Offline copy from ${b.offlineAsOf!.toLocal().toString().substring(0, 16)}', key: const Key('leaderboard-offline'), style: t.textTheme.bodySmall),
                  ),
                LeaderboardView(b, highlight: mine.isEmpty ? null : mine),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}
