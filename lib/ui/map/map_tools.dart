// The map filter drawer, opened from the layers sheet ("Filter pings and cells"). It reads and writes DriveMapModel. Feature ideas
// only from the wider wardriving world: the design, wording and code are MeshSonar's own. (The Drive footer's tool column, its
// base-map cycler and the leaderboard sheet went with the old Drive layout in build 70; Leaderboard lives in More.)
//
// Keys: 'map-filter-sheet' (+ 'filter-heard-*', 'filter-age-*', 'filter-repeater', 'filter-own', 'filter-reset', 'filter-counts').
import 'package:flutter/material.dart';

import '../../core/map_filter.dart';
import '../app.dart';
import '../drive/drive_map_model.dart';
import '../design/app_surfaces.dart';

Future<void> showMapFilterSheet(BuildContext context, DriveMapModel model) => showAppSheet<void>(
  context,
  detents: const [0.7, 0.92],
  builder: (_, c) => SafeArea(child: MapFilterSheet(model: model)),
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
