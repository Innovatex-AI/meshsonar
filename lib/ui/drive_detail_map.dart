// Map for the drive detail screen: the shared CoverageMap framed on the whole drive (no live position or rings).
import 'package:flutter/material.dart';

import '../core/model.dart';
import 'app.dart';
import 'map/coverage_map.dart';

class DriveDetailMap extends StatelessWidget {
  final List<DrivePing> pings;
  const DriveDetailMap({super.key, required this.pings});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return CoverageMap(
      pings: pings,
      repeaters: s.repeaters,
      repeaterLabel: s.repeaterLabel,
      follow: false,
      fitToPings: true,
      showRings: false,
      showLinks: false,
    );
  }
}
