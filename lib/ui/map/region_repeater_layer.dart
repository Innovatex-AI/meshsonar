// The "Region repeaters" map layer: the selected region's full roster (GET region-repeaters) as small status-coloured
// pins, separate from the amber beacons of repeaters this drive heard. Off by default; toggled in the layers sheet.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/region_repeaters_api.dart';

Color regionRepeaterColor(RepeaterActivity s) => switch (s) {
  RepeaterActivity.active => const Color(0xFF2E9E5B),
  RepeaterActivity.quiet => const Color(0xFFE0A030),
  RepeaterActivity.fresh => const Color(0xFF3B82F6),
  RepeaterActivity.stale => const Color(0xFF8A8F98),
};

class RegionRepeaterLayer extends StatelessWidget {
  final List<RegionRepeater> repeaters;
  const RegionRepeaterLayer({super.key, required this.repeaters});

  @override
  Widget build(BuildContext context) {
    final ring = Theme.of(context).colorScheme.surface;
    return MarkerLayer(
      markers: [
        for (final r in repeaters)
          if (r.hasPosition)
            Marker(
              point: LatLng(r.lat!, r.lon!),
              width: 34,
              height: 34,
              child: Tooltip(
                message: '${r.displayName} (${r.hashPrefix})',
                triggerMode: TooltipTriggerMode.tap,
                child: Container(
                  key: ValueKey('region-repeater-${r.key}'),
                  margin: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: regionRepeaterColor(r.status),
                    shape: BoxShape.circle,
                    border: Border.all(color: ring, width: 2),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}
