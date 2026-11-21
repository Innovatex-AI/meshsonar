// The 30-day leaderboard list (More > Leaderboard, lib/ui/account/leaderboard_screen.dart) and the stats API factory
// the Regions screen and the leaderboard share. The old region "Stats" tab (StatsPanel) was retired in build 71.
import 'package:flutter/material.dart';

import '../../core/region_stats_api.dart';
import '../app.dart' show AppScope;
import '../widgets.dart';

/// Tests replace this to inject a fake HTTP client.
RegionStatsApi Function(String baseUrl) regionStatsApiFactory = (b) => RegionStatsApi(b);

class LeaderboardView extends StatelessWidget {
  final Leaderboard board;

  /// A lower-case callsign to mark as "you" (the name this phone shows), or null.
  final String? highlight;
  const LeaderboardView(this.board, {super.key, this.highlight});

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
            selected: highlight != null && r.callsign.toLowerCase() == highlight,
            leading: CircleAvatar(radius: 14, child: Text('${r.rank}')),
            title: Text(highlight != null && r.callsign.toLowerCase() == highlight ? '${r.callsign} (you)' : r.callsign),
            subtitle: Text('${r.drives} drives · ${r.cells} cells · ${r.repeatersHeard} repeaters'),
            trailing: Text(AppScope.unitsOf(context).distance(r.km * 1000)),
          ),
      ],
    );
  }
}
