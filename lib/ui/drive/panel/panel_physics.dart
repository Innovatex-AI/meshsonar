// Pure panel maths (Drive plan 5.1, 4.13): the three detents and where they sit on a device, which detent a release
// lands on, the rubber band past the ends, the spring. No Flutter widgets in here so the tables are unit tested.
import 'dart:math' as math;

import 'package:flutter/physics.dart';

/// Immersive: dock only, at the safe bottom, tab bar hidden. Dock: dock above the tab bar. Medium: dock plus the stats.
enum PanelDetent { immersive, dock, medium }

/// Grabber row (16) + dock row (72).
const double kPanelHeaderHeight = 16;
const double kPanelDockRowHeight = 72;
const double kPanelDockHeight = kPanelHeaderHeight + kPanelDockRowHeight;

/// The dock row at text scale >= 2 (plan 4.13: dock 152 incl. the 16 pt grabber row).
const double kPanelDockRowAx = 136;

/// Floating card widths: iPad (>= 700 wide, tall) and the side card of a landscape phone.
const double kCardWidthPad = 380;
const double kCardWidthLandscape = 300;

/// The reserved GPS / radio strip (plan 4.12), shown above the dock row inside the panel surface.
const double kPanelStripHeight = 28;

/// A release faster than this (pt/s) moves one detent in its direction; slower releases project 0.15 s ahead.
const double kFlingVelocity = 700;
const double kProjectSeconds = 0.15;

/// `SpringDescription` stiffness 300, damping ratio 0.95: no visible overshoot, like system sheets.
final SpringDescription kPanelSpring = SpringDescription.withDampingRatio(mass: 1, stiffness: 300, ratio: 0.95);

/// Where the three detents sit, as an extent: the visible height of the panel measured from the bottom of the screen.
class PanelGeometry {
  /// Total height of the screen area the Drive tab fills.
  final double screenHeight;

  /// Height of the tab bar zone (the shell's bottom padding, device inset included) while the bar is shown.
  final double navBar;

  /// Device bottom inset (home indicator) that is kept when the bar is hidden.
  final double safeBottom;
  final double mediumHeight;

  /// Height of the dock row: 72, or [kPanelDockRowAx] at text scale >= 2 (hero + Ping on one row, Stop / Start on a second).
  final double dockRow;

  /// iPad / landscape phone (width >= 700): the panel is a floating card at the bottom-left, [navBar] is its bottom margin (16 + inset),
  /// Immersive moves the card off-screen (only the Start pill remains) and Medium is 0.5h (0.85h on a landscape phone).
  final bool floating;
  const PanelGeometry({required this.screenHeight, required this.navBar, required this.safeBottom, required this.mediumHeight, this.dockRow = kPanelDockRowHeight, this.floating = false});

  /// Grabber row + dock row.
  double get dockHeight => kPanelHeaderHeight + dockRow;

  /// Medium: 0.46h (clamp 360..0.55h) on phones; short screens (SE) take 0.5h (table 4.13). [mediumHeightFor] is the one rule.
  factory PanelGeometry.forScreen({required double screenHeight, required double navBar, required double safeBottom, double dockRow = kPanelDockRowHeight, bool floating = false}) =>
      PanelGeometry(
        screenHeight: screenHeight,
        navBar: navBar,
        safeBottom: safeBottom,
        mediumHeight: floating ? (screenHeight < 500 ? 0.85 * screenHeight : 0.5 * screenHeight) : mediumHeightFor(screenHeight),
        dockRow: dockRow,
        floating: floating,
      );

  static double mediumHeightFor(double h) => h < 700 ? 0.5 * h : (0.46 * h).clamp(360.0, 0.55 * h);

  double get immersiveExtent => floating ? 0 : safeBottom + dockHeight;
  double get dockExtent => navBar + dockHeight;
  double get mediumExtent => navBar + mediumHeight;

  /// With no tab bar (rail layouts, tests without a shell) Immersive and Dock coincide and Immersive is not offered.
  bool get hasImmersive => immersiveExtent < dockExtent - 1;

  double extentOf(PanelDetent d) => switch (d) {
        PanelDetent.immersive => hasImmersive ? immersiveExtent : dockExtent,
        PanelDetent.dock => dockExtent,
        PanelDetent.medium => mediumExtent,
      };

  /// Distance from the top of the screen to the top of the panel at [d] (the numbers in table 4.13).
  double topOf(PanelDetent d) => screenHeight - extentOf(d);

  /// Share of the screen the map shows above the panel at [d].
  double mapShareAt(PanelDetent d) => topOf(d) / screenHeight;

  List<PanelDetent> get detents => [if (hasImmersive) PanelDetent.immersive, PanelDetent.dock, PanelDetent.medium];

  /// Panel height (the part above the tab bar) at [extent].
  double panelHeightAt(double extent) => math.max(dockHeight, extent - navBar);

  @override
  bool operator ==(Object other) =>
      other is PanelGeometry && other.screenHeight == screenHeight && other.navBar == navBar && other.safeBottom == safeBottom && other.mediumHeight == mediumHeight && other.dockRow == dockRow && other.floating == floating;
  @override
  int get hashCode => Object.hash(screenHeight, navBar, safeBottom, mediumHeight, dockRow, floating);
}

/// The detent a release at [extent] with [velocity] lands on. [velocity] is the extent's rate of change in pt/s: positive
/// while the panel is moving up (opening).
PanelDetent chooseDetent({required double extent, required double velocity, required PanelGeometry geometry, required PanelDetent from}) {
  final ds = geometry.detents;
  if (velocity.abs() > kFlingVelocity) {
    final i = ds.indexOf(from).clamp(0, ds.length - 1);
    return ds[(velocity > 0 ? i + 1 : i - 1).clamp(0, ds.length - 1)];
  }
  final target = extent + velocity * kProjectSeconds;
  var best = ds.first;
  var bestD = double.infinity;
  for (final d in ds) {
    final dist = (geometry.extentOf(d) - target).abs();
    if (dist < bestD) {
      bestD = dist;
      best = d;
    }
  }
  return best;
}

/// Resistance past the ends: `(1 - 1/(x*0.55/d + 1)) * d`, d = 300 pt.
double rubberBand(double overshoot, {double d = 300}) {
  if (overshoot <= 0) return 0;
  return (1 - 1 / (overshoot * 0.55 / d + 1)) * d;
}

/// The displayed extent for an unclamped finger position [raw]: linear inside the detents, banded beyond Medium and below Immersive.
double bandedExtent(double raw, PanelGeometry g) {
  final lo = g.extentOf(g.detents.first), hi = g.mediumExtent;
  if (raw > hi) return hi + rubberBand(raw - hi);
  if (raw < lo) return lo - rubberBand(lo - raw);
  return raw;
}

/// What the finger position was for a displayed (banded) extent; keeps a drag that starts mid-band continuous.
double unbandedExtent(double shown, PanelGeometry g) {
  final lo = g.extentOf(g.detents.first), hi = g.mediumExtent;
  double inv(double b, {double d = 300}) => b >= d ? double.infinity : d * (1 / (1 - b / d) - 1) / 0.55;
  if (shown > hi) return hi + inv(shown - hi);
  if (shown < lo) return lo - inv(lo - shown);
  return shown;
}
