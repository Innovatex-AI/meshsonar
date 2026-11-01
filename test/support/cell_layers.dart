// Test helpers for the map's cell layers (lib/ui/map/cell_raster_layer.dart): what is drawn is data, not a widget per polygon.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/map/cell_raster_layer.dart';

/// The look of every cell handed to every cell layer on screen.
List<CellStyle> drawnCellStyles(WidgetTester t) => [
  for (final w in t.widgetList<CellRasterLayer>(find.byType(CellRasterLayer))) for (final s in w.data.shapes) w.data.styles[s.style],
];

int drawnCellCount(WidgetTester t) => drawnCellStyles(t).length;
