// The full leaderboard (the website's /drives/leaderboard and /leaderboard): opted-in drivers by distance, 30 days or all time,
// for the viewed region or for every region. The Drive tab's trophy sheet links here. Last good answer is cached by the region
// client, so it opens offline with an "offline copy" note.
import 'package:flutter/material.dart';

import '../../core/region_stats_api.dart';
import '../../core/time_format.dart' as tf;
import '../app.dart';
import '../region/stats_panel.dart' show LeaderboardView, regionStatsApiFactory;
import '../settings_screen.dart' show SettingsScreen;

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
    // ignore(): a failure that lands before the next frame is still shown by the FutureBuilder, not reported as unhandled.
    _future = (_everywhere && hubOk ? api.networkLeaderboard(period: _period) : api.leaderboard(period: _period))..ignore();
    setState(() {});
  }

  /// Pull to refresh: ends when the new answer (or its error) is in.
  Future<void> _refresh() async {
    _load();
    try {
      await _future;
    } catch (_) {
      // the FutureBuilder shows the error and its Try again
    }
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
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(key: const Key('leaderboard-screen'), physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(Gap.l), children: [
            // Full width, so each half is a thumb-sized target and the labels have room at large text.
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                key: const Key('leaderboard-period'),
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(minimumSize: const Size(48, 48)),
                segments: const [
                  ButtonSegment(value: '30d', label: Text('30 days', maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ButtonSegment(value: 'all', label: Text('All time', maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
                selected: {_period},
                onSelectionChanged: (v) {
                  _period = v.first;
                  _load();
                },
              ),
            ),
            if (canNetwork) ...[
              const SizedBox(height: Gap.s),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  key: const Key('leaderboard-scope'),
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(minimumSize: const Size(48, 48)),
                  segments: [
                    ButtonSegment(value: false, label: Text(region ?? 'This region', maxLines: 1, overflow: TextOverflow.ellipsis)),
                    const ButtonSegment(value: true, label: Text('Every region', maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                  selected: {_everywhere},
                  onSelectionChanged: (v) {
                    _everywhere = v.first;
                    _load();
                  },
                ),
              ),
            ],
            const SizedBox(height: Gap.s),
            Text('Ranked by distance. Only drivers who opted in are listed.', key: const Key('leaderboard-note'), style: t.textTheme.bodySmall),
            const SizedBox(height: Gap.m),
            FutureBuilder<Leaderboard>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    key: Key('leaderboard-loading'),
                    padding: EdgeInsets.all(Gap.l),
                    child: Column(children: [CircularProgressIndicator(), SizedBox(height: Gap.s), Text('Loading the leaderboard…')]),
                  );
                }
                if (snap.hasError) {
                  final e = snap.error;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.l),
                    child: Column(children: [
                      Icon(Icons.cloud_off_outlined, size: 40, color: t.colorScheme.onSurfaceVariant),
                      const SizedBox(height: Gap.s),
                      Text(e is RegionStatsException ? e.message : 'The leaderboard could not be loaded. Check your connection.',
                          key: const Key('leaderboard-error'), textAlign: TextAlign.center),
                      const SizedBox(height: Gap.m),
                      FilledButton.tonalIcon(
                        key: const Key('leaderboard-retry'),
                        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'),
                      ),
                    ]),
                  );
                }
                final b = snap.data!;
                final mine = (s.settings.display ?? '').toLowerCase();
                final listed = mine.isNotEmpty && b.rows.any((r) => r.callsign.toLowerCase() == mine);
                return Column(children: [
                  if (b.offlineAsOf != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.s),
                      child: Text('Saved copy from ${tf.dateTime(b.offlineAsOf!, weekday: true)}. Pull down to update.',
                          key: const Key('leaderboard-offline'), style: t.textTheme.bodySmall),
                    ),
                  LeaderboardView(b, highlight: mine.isEmpty ? null : mine),
                  if (b.rows.isNotEmpty && !listed)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.m),
                      child: Text('You are not on this list. Drivers appear after they opt in and drive.',
                          key: const Key('leaderboard-not-listed'), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
                    ),
                  // Round 5 D-9: the way in, where the list says how to get on it.
                  if (!listed) const _JoinLeaderboard(),
                ]);
              },
            ),
          ]),
        ),
      ),
    );
  }
}

/// "Join the leaderboard": opens Settings at the leaderboard switch (Account > How you appear), with one line on what it
/// needs and what it shows.
class _JoinLeaderboard extends StatelessWidget {
  const _JoinLeaderboard();
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.m),
      child: Column(children: [
        FilledButton.tonalIcon(
          key: const Key('leaderboard-join'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen(initialSection: 'profile-leaderboard'))),
          icon: const Icon(Icons.emoji_events_outlined),
          label: const Text('Join the leaderboard'),
        ),
        const SizedBox(height: Gap.xs),
        Text('It needs an approved driver key, and it shows your callsign and your distance.',
            key: const Key('leaderboard-join-note'), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
      ]),
    );
  }
}
