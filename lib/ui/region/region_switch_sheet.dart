// Switching the viewed region from the map: the switch with an Undo toast (no confirm sheet) and the "Nearest regions" sheet for a
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
import '../design/app_surfaces.dart';

/// Switches to [region] at once and says so with an Undo toast; Undo puts back the previous pick (or "Follow my
/// location" if there was none). Returns true: the region was switched. No confirm sheet.
Future<bool> confirmRegionSwitch(BuildContext context, RegionIndexEntry region) async {
  final s = AppScope.read(context);
  final before = s.settings.regionManual;
  final following = !s.viewingIsManual;
  await switchViewedRegion(s, region);
  if (!context.mounted) return true;
  showAppToast(
    context,
    'Switched to ${shortNameOf(region)}.${following ? ' The app stops following your location.' : ''}',
    actionLabel: 'Undo',
    onAction: () => unawaited(s.setViewingRegion(before)),
  );
  return true;
}

/// The switch itself, without asking (the caller has). Public for the switcher and tests.
Future<void> switchViewedRegion(AppState s, RegionIndexEntry region) async {
  unawaited(uiPrefsFor(s).pushRecentRegion(region.code));
  await s.setViewingRegion(region.code);
}

/// "Outside coverage": the regions nearest to the phone, one tap each (then the usual confirm).
Future<void> showNearestRegionsSheet(BuildContext context) {
  final s = AppScope.read(context);
  return showAppSheet<void>(
    context,
    detents: const [0.6, 0.92],
    builder: (sheet, c) {
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
