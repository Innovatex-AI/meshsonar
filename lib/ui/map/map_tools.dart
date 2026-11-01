// Map tab quick tools: the base-map cycler, the filter drawer, the leaderboard / my stats sheet and the coverage % pill.
// One column (MapToolColumn) the Drive screen map and the full-screen map both add under their layers button; everything
// reads and writes DriveMapModel, so the two screens stay in step. Feature ideas only from the wider wardriving world:
// the design, wording and code are MeshSonar's own.
//
// Keys (prefix p = 'drive' or 'full'): '$p-map-style', '$p-map-filter', '$p-map-leaders', '$p-coverage-pct';
// sheets: 'map-filter-sheet' (+ 'filter-heard-*', 'filter-age-*', 'filter-repeater', 'filter-own', 'filter-reset',
// 'filter-counts'), 'map-leaders-sheet' ('leaders-board', 'leaders-me').
import 'package:flutter/material.dart';

import '../../core/map_filter.dart';
import '../../core/map_styles.dart';
import '../../core/personal_progress.dart';
import '../../core/region_stats_api.dart';
import '../app.dart';
import '../drive/drive_controls.dart' show MapIconButton;
import '../drive/drive_map_model.dart';
import '../region/stats_panel.dart' show LeaderboardView, regionStatsApiFactory;
import '../report/local_drives.dart';
import '../report/progress_screen.dart' show openProgress;

IconData baseStyleIcon(BaseMapStyle s) => switch (s) {
  BaseMapStyle.chart => Icons.radar,
  BaseMapStyle.street => Icons.map_outlined,
  BaseMapStyle.dark => Icons.dark_mode_outlined,
  BaseMapStyle.topo => Icons.terrain,
};

/// The three buttons and the coverage pill, for a right-hand map column.
class MapToolColumn extends StatelessWidget {
  final DriveMapModel model;

  /// 'drive' or 'full': keeps keys unique while both maps are alive.
  final String keyPrefix;
  const MapToolColumn({super.key, required this.model, required this.keyPrefix});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final style = model.baseStyle;
        final n = model.filter.activeCount;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            MapIconButton(
              key: Key('$keyPrefix-map-style'),
              icon: baseStyleIcon(style),
              tooltip: 'Base map: ${style.label}. Tap for ${style.next.label}',
              onPressed: () {
                model.cycleBaseStyle();
                final m = ScaffoldMessenger.maybeOf(context);
                m?.hideCurrentSnackBar();
                m?.showSnackBar(SnackBar(
                  duration: const Duration(milliseconds: 1400),
                  content: Text('${model.baseStyle.label}: ${model.baseStyle.blurb}'),
                ));
              },
            ),
            const SizedBox(height: Gap.s),
            Stack(
              clipBehavior: Clip.none,
              children: [
                MapIconButton(
                  key: Key('$keyPrefix-map-filter'),
                  icon: Icons.filter_alt_outlined,
                  tooltip: n == 0 ? 'Filter the map' : 'Filter the map ($n on)',
                  active: n > 0,
                  onPressed: () => showMapFilterSheet(context, model),
                ),
                if (n > 0)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: CircleAvatar(
                      radius: 9,
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: Text('$n', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onPrimary)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Gap.s),
            MapIconButton(
              key: Key('$keyPrefix-map-leaders'),
              icon: Icons.emoji_events_outlined,
              tooltip: 'Leaderboard and your stats',
              onPressed: () => showMapLeadersSheet(context),
            ),
            CoveragePctChip(model: model, keyName: '$keyPrefix-coverage-pct'),
          ],
        );
      },
    );
  }
}

/// "62% heard · 140 cells" for what is on screen, "73% of your 55 pings heard" when you have pings in view. Tap for the filter.
class CoveragePctChip extends StatelessWidget {
  final DriveMapModel model;
  final String keyName;
  const CoveragePctChip({super.key, required this.model, required this.keyName});

  @override
  Widget build(BuildContext context) {
    final sum = model.coverageSummary;
    final text = coverageLine(sum);
    if (text == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.s),
      child: Semantics(
        label: 'Coverage in view: $text',
        child: Container(
          key: Key(keyName),
          constraints: const BoxConstraints(maxWidth: 150),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: t.colorScheme.surface.withValues(alpha: 0.93),
            borderRadius: BorderRadius.circular(Corners.small),
            border: Border.all(color: t.colorScheme.outlineVariant),
          ),
          child: Text(text, textAlign: TextAlign.right, style: t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

/// The pill's words; null when there is nothing to say (no cells and no pings in view).
String? coverageLine(CoverageSummary s) {
  if (s.isEmpty) return null;
  final parts = <String>[
    if (s.cellPercent != null) 'In view: ${s.cellPercent}% of ${s.cells} ${s.cells == 1 ? 'cell' : 'cells'} heard',
    if (s.pingPercent != null) '${s.pingPercent}% of your ${s.pings} ${s.pings == 1 ? 'ping' : 'pings'} heard',
  ];
  return parts.join('\n');
}

// ------------------------------------------------------------------ filter drawer

Future<void> showMapFilterSheet(BuildContext context, DriveMapModel model) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => SafeArea(child: MapFilterSheet(model: model)),
);

class MapFilterSheet extends StatelessWidget {
  final DriveMapModel model;
  const MapFilterSheet({super.key, required this.model});

  static const _heardLabels = {HeardFilter.any: 'All', HeardFilter.heard: 'Heard', HeardFilter.notHeard: 'Not heard'};

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final f = model.filter;
        // Repeaters this drive heard, plus the one already picked (so it can always be cleared or seen).
        final options = <String, String>{
          for (final h in model.heard) h.id: h.label,
          if (f.repeater != null) f.repeater!: model.labelFor(f.repeater!),
        };
        final total = model.pings.length, shown = model.visiblePings.length;
        final cellsTotal = model.networkCells.length, cellsShown = model.visibleNetworkCells.length;
        return SingleChildScrollView(
          key: const Key('map-filter-sheet'),
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Expanded(child: Text('Filter the map', style: t.textTheme.titleLarge)),
                TextButton(key: const Key('filter-reset'), onPressed: f.isNone ? null : () => model.filter = MapFilter.none, child: const Text('Reset')),
              ]),
              Text('Narrows what is drawn. Nothing is deleted.', style: t.textTheme.bodySmall),
              const SizedBox(height: Gap.m),
              Text('Result', style: t.textTheme.labelLarge),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.s, children: [
                for (final h in HeardFilter.values)
                  ChoiceChip(
                    key: Key('filter-heard-${h.name}'),
                    label: Text(_heardLabels[h]!),
                    selected: f.heard == h,
                    onSelected: (_) => model.filter = f.copyWith(heard: h),
                  ),
              ]),
              const SizedBox(height: Gap.m),
              Text('Newer than', style: t.textTheme.labelLarge),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.s, children: [
                for (final a in AgeFilter.values)
                  ChoiceChip(
                    key: Key('filter-age-${a.name}'),
                    label: Text(a.label),
                    selected: f.age == a,
                    onSelected: (_) => model.filter = f.copyWith(age: a),
                  ),
              ]),
              const SizedBox(height: Gap.m),
              Text('Repeater', style: t.textTheme.labelLarge),
              const SizedBox(height: Gap.xs),
              DropdownButtonFormField<String?>(
                key: const Key('filter-repeater'),
                initialValue: f.repeater,
                isExpanded: true,
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Any repeater')),
                  for (final e in options.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => model.filter = v == null ? f.copyWith(clearRepeater: true) : f.copyWith(repeater: v),
              ),
              if (options.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text('Repeaters appear here once a drive has heard some.', style: t.textTheme.bodySmall),
                ),
              if (f.repeater != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(
                    'Shows only your pings this repeater heard. Network cells list no repeaters, so they are hidden while one is picked.',
                    style: t.textTheme.bodySmall,
                  ),
                ),
              SwitchListTile(
                key: const Key('filter-own'),
                contentPadding: EdgeInsets.zero,
                title: const Text('My pings only'),
                subtitle: const Text('Hides the network-wide cells; what is left is what this phone recorded.'),
                value: f.ownOnly,
                onChanged: (v) => model.filter = f.copyWith(ownOnly: v),
              ),
              const Divider(),
              Text(
                'Showing $shown of $total of your pings, $cellsShown of $cellsTotal network cells.',
                key: const Key('filter-counts'),
                style: t.textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ leaderboard and my stats

Future<void> showMapLeadersSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const SafeArea(child: MapLeadersSheet()),
);

/// The viewed region's 30-day leaderboard (the website's public `leaderboard` endpoint, opted-in drivers only) above your
/// own totals from the drives stored on this phone. Each part fails alone.
class MapLeadersSheet extends StatefulWidget {
  const MapLeadersSheet({super.key});
  @override
  State<MapLeadersSheet> createState() => _MapLeadersSheetState();
}

class _MapLeadersSheetState extends State<MapLeadersSheet> {
  Future<Leaderboard>? _board;
  Future<PersonalProgress>? _me;
  RegionStatsApi? _api;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_board != null) return;
    final s = AppScope.read(context);
    final base = s.viewingRegion?.url ?? s.settings.serverUrl;
    _api = regionStatsApiFactory(base);
    _board = _api!.leaderboard();
    _me = loadLocalDrives(s.services.store).then((l) => PersonalProgress.compute(l.drives, now: s.services.clock()));
  }

  @override
  void dispose() {
    _api?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = AppScope.of(context);
    final units = AppScope.unitsOf(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      child: ListView(
        key: const Key('map-leaders-sheet'),
        padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
        shrinkWrap: true,
        children: [
          Text('You', style: t.textTheme.titleLarge),
          Text('From the drives stored on this phone.', style: t.textTheme.bodySmall),
          const SizedBox(height: Gap.s),
          FutureBuilder<PersonalProgress>(
            future: _me,
            builder: (context, snap) {
              if (snap.hasError) return Text('Could not read the drives on this phone.', key: const Key('leaders-me'), style: t.textTheme.bodyMedium);
              final p = snap.data;
              if (p == null) return const Padding(padding: EdgeInsets.all(Gap.m), child: Center(child: CircularProgressIndicator()));
              if (p.isEmpty) return Text('No drives yet. Start one and your totals show here.', key: const Key('leaders-me'), style: t.textTheme.bodyMedium);
              final m = personalTotals(p);
              return Column(
                key: const Key('leaders-me'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${m.drives} ${m.drives == 1 ? 'drive' : 'drives'} · ${units.distance(m.distanceM)}', style: t.textTheme.titleMedium),
                  Text(
                    '${m.heardPercent == null ? 'No pings sent yet' : '${m.heardPercent}% of ${m.txPings} pings heard'} · ${p.totalCells} grid cells · ${p.totalRepeaters} repeaters',
                    style: t.textTheme.bodyMedium,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        openProgress(context);
                      },
                      icon: const Icon(Icons.insights),
                      label: const Text('Your progress'),
                    ),
                  ),
                ],
              );
            },
          ),
          const Divider(),
          Text('Leaderboard${s.viewingRegion == null ? '' : ' · ${s.viewingRegion!.name}'}', style: t.textTheme.titleLarge),
          Text('Last 30 days. Only drivers who opted in appear.', style: t.textTheme.bodySmall),
          const SizedBox(height: Gap.s),
          FutureBuilder<Leaderboard>(
            future: _board,
            builder: (context, snap) {
              if (snap.hasError) {
                final e = snap.error;
                return Text(
                  e is RegionStatsException ? e.message : 'The leaderboard could not be loaded.',
                  key: const Key('leaders-board'),
                  style: t.textTheme.bodyMedium,
                );
              }
              final b = snap.data;
              if (b == null) return const Padding(padding: EdgeInsets.all(Gap.m), child: Center(child: CircularProgressIndicator()));
              return Column(
                key: const Key('leaders-board'),
                children: [
                  if (b.offlineAsOf != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.s),
                      child: Text('Offline copy from ${b.offlineAsOf!.toLocal().toString().substring(0, 16)}', style: t.textTheme.bodySmall),
                    ),
                  LeaderboardView(b),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// All-time totals over [p]'s weeks (every drive on this phone).
({int drives, double distanceM, int txPings, int heard, int? heardPercent}) personalTotals(PersonalProgress p) {
  var dist = 0.0, tx = 0, heard = 0;
  for (final w in p.weeks) {
    dist += w.distanceM;
    tx += w.txPings;
    heard += w.heard;
  }
  return (drives: p.drives.length, distanceM: dist, txPings: tx, heard: heard, heardPercent: tx == 0 ? null : (100 * heard / tx).round());
}
