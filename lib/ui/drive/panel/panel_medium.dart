// Medium's content (Drive plan 4.5, 5.2) as a list of widgets for the panel's scroll view, in order: the ratio line, the 2x3
// stat grid, "Heard last ping" (2 rows), nearby repeaters, MeshTrack, then the list rows (antenna, ping settings, log and,
// when no drive runs, "Where to drive next" and "Drives").
//
// Build 77 (Round 1 F6, one message in one place): the "pings not saved" banner and the location note are the strip's alone
// (dock_strip.dart), the second "Set up this radio's antenna" hint is gone (the Antenna row is the one), and the "Map guide"
// row is gone (the Legend panel, the Layers sheet and More > Help keep it). Round 4 P-U1: "Where to drive next" opens Plan
// in Where to drive mode in one tap. Round 5 M4: "Drives" (past drives and their reports; Drives stays in More too).
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../core/heard.dart' show haversineM;
import '../../../core/model.dart';
import '../../../core/region_repeaters_api.dart' show RegionRepeater;
import '../../../radio/radio_api.dart' show GeoFix;
import '../../design/tokens.dart';
import '../../drive_stats.dart' show formatDuration;
import '../../theme.dart';
import '../../widgets.dart';
import '../drive_controls.dart';
import '../drive_live_stats.dart';
import '../ping_settings_sheet.dart';
import 'panel_meshtrack.dart';

double _distanceM(List<DrivePing> pings) {
  var d = 0.0;
  for (var i = 1; i < pings.length; i++) {
    d += haversineM(pings[i - 1].lat, pings[i - 1].lon, pings[i].lat, pings[i].lon);
  }
  return d;
}

/// One row of "Nearby repeaters" (nearest first).
class NearbyRepeater {
  final String key, name;
  final double distanceM;
  const NearbyRepeater(this.key, this.name, this.distanceM);
}

/// The [count] nearest placed repeaters or rooms to [here] from the region roster. Pure, so it is tested without a screen.
List<NearbyRepeater> nearestRepeaters(Iterable<RegionRepeater> roster, double lat, double lon, {int count = 3}) {
  final out = <NearbyRepeater>[];
  for (final r in roster) {
    if (r.lat == null || r.lon == null) continue;
    if (r.role != 'repeater' && r.role != 'room') continue;
    out.add(NearbyRepeater(r.key, r.name ?? r.hashPrefix, haversineM(lat, lon, r.lat!, r.lon!)));
  }
  out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
  return out.take(count).toList();
}

class MediumContent {
  /// Rebuilds on every state change because the panel's builder does (the caller wraps it in a listener).
  static List<Widget> build(
    BuildContext context, {
    required AppState state,
    required DriveLiveStats liveStats,
    required GeoFix? fix,
    List<NearbyRepeater> nearby = const [],
    ValueChanged<String>? onPickNearby,
    VoidCallback? onWhereToDrive,
    VoidCallback? onDrives,
  }) {
    final s = state;
    final t = Theme.of(context);
    final c = AppColors.fromTheme(t);
    final driving = s.driving;
    final pct = s.heardPercent;
    final session = s.currentSession;
    final elapsed = session == null ? null : s.services.clock().toUtc().difference(session.startedAt);
    final last = s.recentPings.isEmpty ? null : s.recentPings.first;
    final lastSnr = last == null ? null : bestSnr(last);
    final acc = fix?.accuracyM;
    final ready = liveStats.historyLoaded;
    final repeaters = <String>{for (final p in s.drivePings) for (final e in p.echoes) e.repeater}.length;

    Widget cell(String label, String value, Key key) => Expanded(
          child: Semantics(
            container: true,
            label: '$label: $value',
            excludeSemantics: true,
            // At least 52 pt; it grows with large text instead of clipping the label (2x text overflowed the fixed 52).
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, key: key, style: numberStyle(context, size: 22, weight: FontWeight.w600))),
                  const SizedBox(height: 2),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.textMuted)),
                ],
              ),
            ),
          ),
        );

    final heardRows = <Widget>[];
    if (last != null && last.kind == PingKind.tx) {
      final ech = [...last.echoes]..sort((a, b) => (b.snrDb ?? -99).compareTo(a.snrDb ?? -99));
      final seen = <String>{};
      for (final e in ech) {
        if (!seen.add(e.repeater)) continue;
        if (heardRows.length == 2) break;
        heardRows.add(SizedBox(
          height: 44,
          child: Row(children: [
            Expanded(child: Text(s.repeaterLabel(e.repeater), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16))),
            Text(e.snrDb == null ? '' : '${e.snrDb! > 0 ? '+' : ''}${e.snrDb!.toStringAsFixed(1)} dB', style: numberStyle(context, size: 14, weight: FontWeight.w500)),
          ]),
        ));
      }
    }

    return [
      if (driving) ...[
        Text(
          s.pingCount == 0 ? 'No pings yet' : '${s.heardCount} of ${s.pingCount} pings heard${pct == null ? '' : ' ($pct%)'}',
          key: const Key('medium-ratio'),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Row(children: [
          cell('Distance', s.units.distance(_distanceM(s.drivePings)), const Key('stat-distance')),
          cell('Elapsed', formatDuration(elapsed), const Key('stat-elapsed')),
          cell('Last SNR', last == null ? '—' : (last.heardNothing ? 'none' : (lastSnr == null ? '—' : '${lastSnr > 0 ? '+' : ''}${lastSnr.toStringAsFixed(1)} dB')), const Key('stat-snr')),
        ]),
        Row(children: [
          cell('New cells', ready ? '${liveStats.newCells}' : '—', const Key('stat-cells')),
          cell('Repeaters', '$repeaters', const Key('stat-repeaters')),
          cell('GPS accuracy', fix == null ? 'No fix' : (acc == null ? '—' : '±${s.units.shortLength(acc)}'), const Key('stat-gps')),
        ]),
        const Divider(height: 16),
        if (heardRows.isNotEmpty) ...[
          Text('HEARD LAST PING', style: TextStyle(fontSize: 12, letterSpacing: 0.6, color: c.textMuted)),
          ...heardRows,
          const Divider(height: 16),
        ],
      ],
      if (nearby.isNotEmpty) ...[
        Text('NEARBY REPEATERS', style: TextStyle(fontSize: 12, letterSpacing: 0.6, color: c.textMuted)),
        for (final n in nearby)
          GestureDetector(
            key: Key('nearby-${n.key}'),
            behavior: HitTestBehavior.opaque,
            onTap: onPickNearby == null ? null : () => onPickNearby(n.key),
            child: SizedBox(
              height: 48,
              child: Row(children: [
                Expanded(child: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16))),
                Text(s.units.distance(n.distanceM), style: numberStyle(context, size: 14, weight: FontWeight.w500)),
                // Says the row does something: it shows the repeater on the map (build 76; the rows looked like plain text).
                if (onPickNearby != null) ...[const SizedBox(width: 8), Icon(Icons.my_location_rounded, size: 18, color: c.textMuted)],
              ]),
            ),
          ),
        const Divider(height: 16),
      ],
      // MeshTrack (build 69): a full-width row by the chips, so friends' sharing is in the panel, not a pill on the map.
      const MeshTrackPanelRow(),
      // One list, every row labelled and 48 pt tall (build 76): the old chips did not say what they were.
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AntennaChip(state: s),
        PingSettingsChip(state: s),
        LogButton(state: s),
        if (!driving && onWhereToDrive != null)
          DrivePanelRow(
            key: const Key('medium-where-to-drive'),
            icon: Icons.explore_outlined,
            label: 'Where to drive next',
            semanticsHint: 'Opens Plan in Where to drive mode',
            onTap: onWhereToDrive,
          ),
        if (!driving && onDrives != null)
          DrivePanelRow(
            key: const Key('medium-drives'),
            icon: Icons.list_alt,
            label: 'Drives',
            semanticsHint: 'Opens your saved drives',
            onTap: onDrives,
          ),
      ]),
    ];
  }
}
