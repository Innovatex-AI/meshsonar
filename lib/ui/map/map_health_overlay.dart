// Settings > Diagnostics > "Map and GPS health overlay": a small readout of the newest 10-second health sample (the same numbers
// that go into map_health.jsonl), drawn over the map so a bad stretch can be seen on the spot.
import 'package:flutter/material.dart';

import '../../core/map_prefs.dart';
import '../drive/drive_map_model.dart';

class MapHealthOverlay extends StatelessWidget {
  final DriveMapModel model;
  const MapHealthOverlay({super.key, required this.model});

  static String describe(Map<String, Object?>? s) {
    if (s == null) return 'Map health: waiting for the first 10 s sample';
    final f = (s['frames'] as Map?) ?? const {};
    final p = (s['puck'] as Map?) ?? const {};
    final c = (s['camera'] as Map?) ?? const {};
    final t = (s['tiles'] as Map?) ?? const {};
    return 'frames p95 ${f['p95_ms']} ms  worst ${f['worst_ms']} ms  janky ${f['janky_16']}\n'
        'puck ${p['puck_updates_hz']} Hz  fixes ${p['fixes']}  gap ${p['max_fix_gap_s']} s\n'
        'camera ${c['mode']}${c['heading_up'] == true ? ' (heading up)' : ''}  tiles ${t['source']}  '
        'net ${t['network_ok']} cache ${t['cache_hit']} fail ${t['failed']}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([MapPrefs.shared, model.healthTick]),
      builder: (context, _) {
        if (!MapPrefs.shared.healthOverlay) return const SizedBox.shrink();
        return IgnorePointer(
          child: DecoratedBox(
            key: const Key('map-health-overlay'),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                describe(model.health.last),
                style: const TextStyle(color: Colors.white, fontSize: 10.5, fontFeatures: [FontFeature.tabularFigures()], height: 1.25),
              ),
            ),
          ),
        );
      },
    );
  }
}
