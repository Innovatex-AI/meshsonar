// Map for the drive detail screen: the shared CoverageMap framed on the whole drive (no live position). With coverage v2 the
// drive's cells are res-11 cells with the mean SNR in the coverage bands, and a tap opens the server's cell inspector.
import 'package:flutter/material.dart';

import '../core/model.dart';
import 'app.dart';
import 'map/coverage_map.dart';
import 'map/region_center.dart';

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
      showLinks: false,
      fallbackCenter: viewedRegionCenter(s),
      coverageV2: s.coverageV2 ? CoverageV2Inputs(tiles: s.coverageTiles, meta: s.coverageMeta, drawTiles: false, fetchCell: s.coverageCell) : null,
    );
  }
}
