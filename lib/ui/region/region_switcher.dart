// The region switcher (Andy, Oct 21): lists ALL regions, the phone's GPS region first, then nearest; picking one
// swaps the whole Region tab, the coverage layer and the radio preset shown. "Follow my location" goes back to GPS.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/region_lookup.dart';
import '../app.dart';

Future<void> showRegionSwitcher(BuildContext context) {
  final state = AppScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => RegionSwitcherSheet(state: state),
  );
}

class RegionSwitcherSheet extends StatelessWidget {
  final AppState state;
  const RegionSwitcherSheet({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final t = Theme.of(context);
        final viewing = state.viewingRegion;
        final gps = state.currentRegion;
        final regions = state.switcherRegions;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
            child: ListView(
              key: const Key('region-switcher'),
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('Choose a region', style: t.textTheme.titleLarge),
                ),
                RadioGroup<String>(
                  groupValue: state.viewingIsManual ? viewing?.code : '',
                  onChanged: (v) {
                    if (v == null) return;
                    state.setViewingRegion(v.isEmpty ? null : v);
                    Navigator.of(context).pop();
                  },
                  child: Column(children: [
                    RadioListTile<String>(
                      key: const Key('region-follow'),
                      value: '',
                      title: const Text('Follow my location'),
                      subtitle: Text(gps != null
                          ? 'You are in ${gps.name}'
                          : state.regionFixKnown
                              ? 'Outside every region: showing the nearest'
                              : 'Waiting for a GPS fix'),
                    ),
                    for (final r in regions) _tile(r, gps),
                  ]),
                ),
                if (regions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No regions loaded yet. Connect to the internet once and they will be remembered.'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _tile(RegionIndexEntry r, RegionIndexEntry? gps) => RadioListTile<String>(
        key: Key('region-option-${r.code}'),
        value: r.code,
        title: Text(r.name),
        subtitle: Text(r.code == gps?.code ? '${r.code} · you are here' : r.code),
      );
}

/// A tappable chip with the viewed region; opens the switcher.
class RegionSwitcherChip extends StatelessWidget {
  const RegionSwitcherChip({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final v = s.viewingRegion;
    final gps = s.currentRegion;
    final differs = v != null && gps != null && gps.code != v.code;
    return ActionChip(
      key: const Key('region-switch-chip'),
      avatar: const Icon(Icons.map_outlined, size: 18),
      label: Text(v == null ? 'Region' : differs ? '${v.code} · you are in ${gps.code}' : v.code),
      onPressed: () => showRegionSwitcher(context),
    );
  }
}
