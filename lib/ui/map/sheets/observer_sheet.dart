// Tap an observer on the map's Observers layer: a bottom sheet with its name, online state and last sign of life,
// noise floor, packets per hour, nodes heard in 24 h, model/firmware, battery (the observer node's own raw value, not a
// health claim), distance from you (Units setting), the data source and how the position was published.
// Data: the viewed region's `region-observers` rows (only observers whose owner made the position public carry
// lat/lon; the server rounds them per `location_public`). Design: stream-1-maps.md 4.6.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/heard.dart' show haversineM;
import '../../../core/region_overview_api.dart' show RegionObserver;
import '../../../core/units.dart' show Units;
import '../../app.dart' show AppScope;
import '../../region/region_common.dart' show agoText, groupInt;
import '../../theme.dart';

/// What the observer sheet needs from the host besides the observer.
class ObserverSheetContext {
  final LatLng? position;
  final DateTime Function() clock;
  final Units? units;
  const ObserverSheetContext({this.position, this.clock = DateTime.now, this.units});
}

Future<void> showObserverSheet(
  BuildContext context,
  RegionObserver observer, {
  String? regionName,
  ObserverSheetContext ctx = const ObserverSheetContext(),
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(child: ObserverSheet(observer: observer, regionName: regionName, ctx: ctx)),
  );
}

/// "MeshSonar observer" for our own, else the third-party view the region republishes.
String observerSourceText(RegionObserver o, String? regionName) {
  final where = regionName == null ? '' : ' ($regionName)';
  return o.source == 'meshsonar' ? 'MeshSonar observer$where' : 'Observer seen through CoreScope$where';
}

class ObserverSheet extends StatelessWidget {
  final RegionObserver observer;
  final String? regionName;
  final ObserverSheetContext ctx;
  const ObserverSheet({super.key, required this.observer, this.regionName, this.ctx = const ObserverSheetContext()});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final units = ctx.units ?? AppScope.unitsOf(context);
    final o = observer;
    Widget stat(String label, String value, {Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
          const SizedBox(width: Gap.s),
          Flexible(
            child: Text(value, key: key, textAlign: TextAlign.end, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    final pos = ctx.position;
    final distance = (pos == null || o.lat == null || o.lon == null) ? null : haversineM(pos.latitude, pos.longitude, o.lat!, o.lon!);
    final model = [o.model, o.firmware].whereType<String>().join(' · ');
    return SingleChildScrollView(
      child: Padding(
        key: const Key('observer-sheet'),
        padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.change_history_rounded, color: o.online ? t.colorScheme.primary : mc.silent),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: Text(o.displayName, key: const Key('observer-sheet-name'), style: t.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              o.online ? 'Online' : 'Offline',
              key: const Key('observer-sheet-online'),
              style: t.textTheme.bodyMedium?.copyWith(color: o.online ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Gap.s),
            stat('Last seen', agoText(o.lastSeen, now: ctx.clock()), key: const Key('observer-sheet-seen')),
            if (o.noiseFloorDbm != null) stat('Noise floor', '${o.noiseFloorDbm!.round()} dBm', key: const Key('observer-sheet-noise')),
            if (o.packetsPerHour != null) stat('Packets per hour', groupInt(o.packetsPerHour!)),
            if (o.nodesHeard24h != null) stat('Nodes heard (24 h)', groupInt(o.nodesHeard24h!)),
            if (model.isNotEmpty) stat('Radio', model),
            if (o.batteryMv != null) stat('Battery (reported)', '${o.batteryMv} mV'),
            stat(
              'Distance from you',
              distance == null ? 'No position fix' : units.distance(distance, approx: true),
              key: const Key('observer-sheet-distance'),
            ),
            const SizedBox(height: Gap.s),
            Text(
              '${observerSourceText(o, regionName)}. Position as its owner chose to publish it (exact or rounded to about '
              '${units.distance(1000, approx: true)}).',
              key: const Key('observer-sheet-source'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
