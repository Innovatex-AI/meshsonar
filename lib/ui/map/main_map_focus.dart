// "Open the map here" (map_preview.dart): a preview asks the main map (the Drive tab's CoverageMap) to look at a spot. The
// request is kept until the main map takes it, so it works whether the Drive map is already built or is built after the tab
// switch. The main map stops following the position (the person asked to look elsewhere) until they press Recenter.
//
// Release 0.38: a request can also say what to show when the map opens ("open the map with this overlay/plan"): layers to
// switch on (e.g. the `plan` layer), the plan to draw, and targets to drive to (Find sites results, Where to drive). The
// main map applies them when it takes the request.
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

/// A place the person may want to drive to, drawn as a target on the main map (a suggested site, a plan node).
@immutable
class MapFocusTarget {
  /// Stable within its source (a plan node id, a suggestion id), so the map can mark the one picked.
  final String id;
  final LatLng at;
  final String label;
  const MapFocusTarget({required this.id, required this.at, required this.label});

  @override
  bool operator ==(Object other) => other is MapFocusTarget && other.id == id && other.at == at && other.label == label;
  @override
  int get hashCode => Object.hash(id, at, label);
}

@immutable
class MapFocusRequest {
  final LatLng at;
  final double zoom;
  final int seq;

  /// Layer ids (lib/ui/map/layers/registry.dart) to switch on when the map takes this request; empty = leave the layers.
  final Set<String> showLayers;

  /// The saved plan (lib/core/plan/plan_repository.dart id) the `plan` layer should draw; null = whatever it draws now.
  final String? planId;

  /// Targets to draw, in order; empty = none.
  final List<MapFocusTarget> targets;
  const MapFocusRequest(this.at, this.zoom, this.seq, {this.showLayers = const {}, this.planId, this.targets = const []});

  /// It asks for more than a camera move.
  bool get hasOverlay => showLayers.isNotEmpty || planId != null || targets.isNotEmpty;
}

class MainMapFocus {
  MainMapFocus._();
  static final ValueNotifier<MapFocusRequest?> notifier = ValueNotifier<MapFocusRequest?>(null);
  static int _seq = 0;

  static void request(LatLng at, double zoom, {Set<String> showLayers = const {}, String? planId, List<MapFocusTarget> targets = const []}) =>
      notifier.value = MapFocusRequest(at, zoom.clamp(3, 18).toDouble(), ++_seq,
          showLayers: Set.unmodifiable(showLayers), planId: planId, targets: List.unmodifiable(targets));

  /// The main map took [r]: clears it (only if nothing newer came in).
  static void taken(MapFocusRequest r) {
    if (identical(notifier.value, r)) notifier.value = null;
  }
}
