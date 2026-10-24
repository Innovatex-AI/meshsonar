// Colours of the "Region repeaters" map layer (the viewed region's roster, GET region-repeaters), by roster status.
// The layer itself is drawn by the clustered painter (layers/repeater_cluster_layer.dart, layer id `repeaters`); the
// old one-Marker-per-repeater widget layer was folded into it (tap now opens the repeater sheet instead of a tooltip).
import 'package:flutter/material.dart';

import '../../core/region_repeaters_api.dart';

Color regionRepeaterColor(RepeaterActivity s) => switch (s) {
  RepeaterActivity.active => const Color(0xFF2E9E5B),
  RepeaterActivity.quiet => const Color(0xFFE0A030),
  RepeaterActivity.fresh => const Color(0xFF3B82F6),
  RepeaterActivity.stale => const Color(0xFF8A8F98),
};
