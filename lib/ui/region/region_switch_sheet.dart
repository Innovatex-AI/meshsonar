// Switching the viewed region from the map: the confirm sheet ("Switch to <region>?") and the "Nearest regions" sheet for a
// phone outside every region. Both end in the app's one switch, AppState.setViewingRegion (saved as the manual pick, so it
// survives a restart; "Follow my location" in the region switcher goes back), and remember the region as a recent.
//
// Keys (tests): 'region-switch-sheet', 'region-switch-confirm', 'region-switch-cancel', 'nearest-regions-sheet',
// 'nearest-region-<code>'.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/region_lookup.dart';
import '../../core/region_search.dart' show shortNameOf;
import '../app.dart';
import '../onboarding/ui_prefs.dart';

/// Asks "Switch to (region)?" and, on Switch, makes it the viewed region. Returns true when the region was switched. The
/// sheet starts on Cancel (autofocus), so a stray tap or Return never switches; dismissing it is Cancel.
Future<bool> confirmRegionSwitch(BuildContext context, RegionIndexEntry region) async {
  final s = AppScope.read(context);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ConfirmSheet(region: region),
  );
  if (ok != true) return false;
  await switchViewedRegion(s, region);
  return true;
}

/// The switch itself, without asking (the caller has). Public for the switcher and tests.
Future<void> switchViewedRegion(AppState s, RegionIndexEntry region) async {
  unawaited(uiPrefsFor(s).pushRecentRegion(region.code));
  await s.setViewingRegion(region.code);
}

class _ConfirmSheet extends StatelessWidget {
  final RegionIndexEntry region;
  const _ConfirmSheet({required this.region});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = AppScope.read(context);
    final name = shortNameOf(region);
    final following = !s.viewingIsManual;
    return SafeArea(
      child: SingleChildScrollView(
        key: const Key('region-switch-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Semantics(header: true, child: Text('Switch to $name?', style: t.textTheme.titleLarge)),
          const SizedBox(height: 8),
          Text('The map and stats will show that region.', style: t.textTheme.bodyLarge),
          if (following) ...[
            const SizedBox(height: 8),
            Text('The app stops following your location until you choose "Follow my location" in the region switcher.',
                style: t.textTheme.bodyMedium),
          ],
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('region-switch-cancel'),
                autofocus: true,
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                key: const Key('region-switch-confirm'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Switch'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// "Outside coverage": the regions nearest to the phone, one tap each (then the usual confirm).
Future<void> showNearestRegionsSheet(BuildContext context) {
  final s = AppScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) {
      final near = s.switcherRegions.take(5).toList();
      final t = Theme.of(sheet);
      return SafeArea(
        child: SingleChildScrollView(
          key: const Key('nearest-regions-sheet'),
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Semantics(header: true, child: Text('Nearest regions', style: t.textTheme.titleLarge)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('No MeshSonar region covers this location. Pings you send here are still recorded.', style: t.textTheme.bodyMedium),
            ),
            if (near.isEmpty)
              const Padding(padding: EdgeInsets.all(12), child: Text('No regions loaded yet. Connect to the internet once and they will be remembered.')),
            for (final r in near)
              ListTile(
                key: Key('nearest-region-${r.code}'),
                minTileHeight: 56,
                leading: const Icon(Icons.map_outlined),
                title: Text(shortNameOf(r)),
                subtitle: Text(r.code),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final nav = Navigator.of(sheet);
                  if (await confirmRegionSwitch(sheet, r)) nav.pop();
                },
              ),
          ]),
        ),
      );
    },
  );
}
