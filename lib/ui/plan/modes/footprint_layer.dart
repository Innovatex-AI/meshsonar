// The planner map's coverage footprint layer (release 0.38 A9, improvement 9 "coverage as a map layer"). Coverage mode
// fills a [PlanFootprintController] with what to draw; the planner owns the controller, hands it to the sheet through
// [PlanFootprintScope] and to its CoverageMap as an extra layer ([PlanFootprintLayer], under the plan layer so nodes stay on
// top and win taps). The cells are drawn by the map's cached-picture cell layer (cell_raster_layer.dart), so thousands of
// cells cost one image draw per frame.
//
// Colours: by signal, the band ramp of measured coverage (coverage_bands.dart, coverage v2 `coverageBandOf` on the SNR) so
// a predicted footprint reads in the same colours as the drives; by "sites that reach it", 1 / 2 / 3 / 4+ on the same ramp
// from Weak to Excellent. Cells under the minimum SNR are not drawn. Keys: 'plan-footprint-layer'.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;

import '../../../core/coverage_v2.dart' show coverageBandOf, kDefaultCoverageBands;
import '../../../core/hex_cells.dart' show HexPoint;
import '../../map/cell_raster_layer.dart';
import '../../map/coverage_bands.dart' show CoverageBandColors;
import 'footprint_field.dart';

/// How the footprint layer colours a cell.
enum FootprintColour {
  /// The best SNR of any site (measured-coverage band colours).
  signal,

  /// How many of the plan's sites reach the cell.
  sites,
}

/// What the footprint layer draws; [data] null = nothing.
class PlanFootprintController extends ChangeNotifier {
  CellLayerData? _data;
  String _summary = '';
  bool _disposed = false;

  CellLayerData? get data => _data;

  /// One sentence for VoiceOver on the map ("Coverage estimate drawn: 2 sites, 41 km²").
  String get summary => _summary;

  void show(CellLayerData data, {String summary = ''}) {
    _data = data;
    _summary = summary;
    _changed();
  }

  void clear() {
    if (_data == null) return;
    _data = null;
    _summary = '';
    _changed();
  }

  void _changed() {
    // A mode may publish while the sheet builds (initState, a mode switch): the map redraws after the frame.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Hands the planner's [PlanFootprintController] to the sheet's modes.
class PlanFootprintScope extends InheritedWidget {
  final PlanFootprintController controller;
  const PlanFootprintScope({super.key, required this.controller, required super.child});

  static PlanFootprintController? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<PlanFootprintScope>()?.controller;

  @override
  bool updateShouldNotify(PlanFootprintScope old) => old.controller != controller;
}

/// The map layer (a CoverageMap `extraLayers` entry).
class PlanFootprintLayer extends StatelessWidget {
  final PlanFootprintController controller;
  const PlanFootprintLayer({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final d = controller.data;
          if (d == null || d.isEmpty) return const SizedBox.shrink();
          return Semantics(
            label: controller.summary.isEmpty ? null : controller.summary,
            child: IgnorePointer(child: CellRasterLayer(key: const Key('plan-footprint-layer'), data: d)),
          );
        },
      );
}

/// The band (coverage_v2 0-6) a cell takes in [mode]; null = not drawn.
int? footprintBand(FootprintColour mode, {required double bestSnr, required int count, required int sf}) {
  if (count <= 0 || bestSnr.isNaN) return null;
  return switch (mode) {
    FootprintColour.signal => coverageBandOf(snrMean: bestSnr, nOk: 1, nSnr: 1, sf: sf),
    FootprintColour.sites => (count + 1).clamp(2, 5),
  };
}

/// What a band means in [mode] (legend words).
String footprintBandWords(FootprintColour mode, int band) => switch (mode) {
      FootprintColour.signal => kDefaultCoverageBands.firstWhere((b) => b.band == band, orElse: () => kDefaultCoverageBands.first).label,
      FootprintColour.sites => band >= 5 ? '4 or more sites' : (band - 1 == 1 ? '1 site' : '${band - 1} sites'),
    };

/// The legend rows of [mode], strongest first.
List<int> footprintLegendBands(FootprintColour mode) => switch (mode) {
      FootprintColour.signal => const [5, 4, 3, 2, 1],
      FootprintColour.sites => const [5, 4, 3, 2],
    };

/// The cells of [view] as map shapes: each row's runs of equal band merged into one rectangle, filled at [opacity].
CellLayerData footprintCells(FootprintField f, FootprintView view, {required FootprintColour mode, required CoverageBandColors colours, required double opacity, required int sf}) {
  final styles = <CellStyle>[];
  final styleOf = <int, int>{};
  int style(int band) => styleOf.putIfAbsent(band, () {
        final c = colours[band];
        styles.add(CellStyle(c.withValues(alpha: opacity.clamp(0.05, 1.0)), Colors.transparent, 0));
        return styles.length - 1;
      });
  final shapes = <CellShape>[];
  for (var r = 0; r < f.rows; r++) {
    int? runBand;
    var runStart = 0;
    void close(int end) {
      if (runBand == null) return;
      final (s, w) = f.corner(r, runStart);
      final (n, e) = f.corner(r + 1, end);
      shapes.add(CellShape([HexPoint(s, w), HexPoint(s, e), HexPoint(n, e), HexPoint(n, w)], style(runBand)));
    }

    for (var c = 0; c < f.cols; c++) {
      final i = r * f.cols + c;
      final b = footprintBand(mode, bestSnr: view.bestSnr[i], count: view.count[i], sf: sf);
      if (b == runBand) continue;
      close(c);
      runBand = b;
      runStart = c;
    }
    close(f.cols);
  }
  return CellLayerData(shapes, styles);
}
