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
        body: 'Drivers show up here after they turn the leaderboard on and drive. Turn yours on in Settings.',
      );
    }
    return Column(
      key: const Key('stats-leaderboard'),
      children: [
        for (final r in board.rows)
          ListTile(
            // Full-height rows (they were dense) and a name that is cut with an ellipsis, never wrapped under the distance.
            selected: highlight != null && r.callsign.toLowerCase() == highlight,
            leading: CircleAvatar(radius: 14, child: Text('${r.rank}')),
            title: Text(highlight != null && r.callsign.toLowerCase() == highlight ? '${r.callsign} (you)' : r.callsign, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${r.drives} ${r.drives == 1 ? 'drive' : 'drives'} · ${r.cells} map cells · ${r.repeatersHeard} repeaters heard', maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: Text(AppScope.unitsOf(context).distance(r.km * 1000)),
          ),
      ],
    );
  }
}
