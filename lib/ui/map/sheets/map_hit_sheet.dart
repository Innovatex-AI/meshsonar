// One entry point for "something on the map was tapped": opens the right detail sheet for a [MapHit], or tells the
// host to move the camera (a cluster). Design: stream-1-maps.md 4.6.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../cell_sheet.dart' show showCellSheet;
import '../layers/clustered_points_layer.dart' show cameraFitForCluster;
import '../layers/map_layer.dart';
import 'observer_sheet.dart';
import 'repeater_sheet.dart';

/// Opens a host's own sheet for a hit the generic sheets do not cover (a plan node, a long-press pin). Returns true when it
/// opened one.
typedef MapHitHandler<T extends MapHit> = Future<bool> Function(BuildContext context, T hit);

/// Opens the sheet for [hit]. A cell opens the cell sheet, a repeater the repeater sheet, an observer the observer sheet, repeaters stacked on one
/// spot a list; a plain cluster moves [controller]'s camera to its members (when a controller is given). A plan node
/// and a long-press go to the host's [onPlanNode] / [onLongPress] (the planner and the map that owns the plan layer);
/// without one nothing opens. Returns true when a sheet was opened.
Future<bool> showMapHitSheet(
  BuildContext context,
  MapHit hit, {
  MapController? controller,
  RepeaterSheetContext repeaterContext = const RepeaterSheetContext(),
  ObserverSheetContext observerContext = const ObserverSheetContext(),
  MapHitHandler<PlanNodeHit>? onPlanNode,
  MapHitHandler<LongPressHit>? onLongPress,
}) async {
  switch (hit) {
    case PlanNodeHit():
      return onPlanNode == null ? false : onPlanNode(context, hit);
    case LongPressHit():
      return onLongPress == null ? false : onLongPress(context, hit);
    case CellHit(:final cell):
      await showCellSheet(context, cell);
      return true;
    case RepeaterHit(:final point):
      await showRepeaterSheet(context, point, ctx: repeaterContext);
      return true;
    case ObserverHit(:final observer, :final regionName):
      await showObserverSheet(context, observer, regionName: regionName, ctx: observerContext);
      return true;
    case ClusterHit(:final tap, :final colocated):
      if (colocated.length > 1) {
        await showRepeaterListSheet(context, colocated, ctx: repeaterContext);
        return true;
      }
      if (colocated.length == 1 && controller == null) {
        await showRepeaterSheet(context, colocated.single, ctx: repeaterContext);
        return true;
      }
      if (controller != null) controller.fitCamera(cameraFitForCluster(tap, controller.camera));
      return false;
  }
}
