// State of the Drive panel (Drive plan 5.1): the extent (visible height from the screen bottom), the settled detent,
// drag handling with rubber band, and the spring that settles it. The map never listens to this; it hears about the panel once,
// at settle, through [settleCount] / [onSettled].
import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';

import 'panel_physics.dart';

class DrivePanelController extends ChangeNotifier {
  DrivePanelController({required TickerProvider vsync, PanelDetent initial = PanelDetent.dock, this.reduceMotion = false})
      : _detent = initial,
        _anim = AnimationController.unbounded(vsync: vsync) {
    _anim.addListener(_tick);
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.completed && _settling) _finish();
    });
  }

  final AnimationController _anim;

  /// Reduce Motion: jump to the detent instead of springing.
  bool reduceMotion;

  /// Visible panel height from the screen bottom, updated every frame of a drag or spring. Only the panel listens.
  final ValueNotifier<double> extent = ValueNotifier<double>(0);

  PanelGeometry? _g;
  PanelGeometry? get geometry => _g;

  PanelDetent _detent;

  /// The detent the panel is at, or heading to while it springs.
  PanelDetent get detent => _detent;

  bool _dragging = false, _settling = false;
  double _raw = 0;
  bool get dragging => _dragging;
  bool get settling => _settling;

  /// True when the panel rests on a detent (the control column becomes tappable, MapInsets are published).
  bool get settled => !_dragging && !_settling;

  /// Counts settles (tests assert "once per move").
  int settleCount = 0;

  /// Called after the panel came to rest, and when the detent changed (the tab bar hook listens to the latter).
  VoidCallback? onSettled;
  void Function(PanelDetent from, PanelDetent to)? onDetentChanged;

  /// Sets the geometry (device change, rotation, tab bar). Rests the panel on the current detent when it is not moving.
  void setGeometry(PanelGeometry g) {
    if (g == _g) return;
    final first = _g == null;
    _g = g;
    if (!_dragging && !_settling) {
      if (!g.detents.contains(_detent)) _detent = PanelDetent.dock;
      extent.value = g.extentOf(_detent);
      if (!first) _afterSettle();
    }
  }

  /// First layout: lets the owner place the panel without calling a settle.
  void dragStart() {
    final g = _g;
    if (g == null) return;
    _anim.stop();
    _settling = false;
    _dragging = true;
    _raw = unbandedExtent(extent.value, g);
    notifyListeners();
  }

  /// [dy] is the finger's vertical movement in logical pixels (positive = down), as a drag delta gives it.
  void dragUpdate(double dy) {
    final g = _g;
    if (g == null) return;
    if (!_dragging) dragStart();
    _raw -= dy;
    extent.value = bandedExtent(_raw, g);
  }

  /// [vy] is the finger's vertical velocity in pt/s (positive = down).
  void dragEnd(double vy) {
    final g = _g;
    if (g == null || !_dragging) return;
    _dragging = false;
    final up = -vy;
    final to = chooseDetent(extent: extent.value, velocity: up, geometry: g, from: _detent);
    _goTo(to, velocity: up);
  }

  void dragCancel() => dragEnd(0);

  /// Moves to [d] (spring, or a jump under Reduce Motion).
  void settleTo(PanelDetent d) {
    if (_g == null) return;
    _dragging = false;
    _goTo(d, velocity: 0);
  }

  /// Tap on the header: Dock <-> Medium; Immersive opens to Dock.
  void toggle() => settleTo(_detent == PanelDetent.dock ? PanelDetent.medium : PanelDetent.dock);

  void _goTo(PanelDetent d, {required double velocity}) {
    final g = _g!;
    final from = _detent;
    _detent = g.detents.contains(d) ? d : PanelDetent.dock;
    if (from != _detent) onDetentChanged?.call(from, _detent);
    final to = g.extentOf(_detent);
    _settling = true;
    notifyListeners();
    if (reduceMotion || (extent.value - to).abs() < 0.5) {
      _anim.stop();
      extent.value = to;
      _finish();
      return;
    }
    _anim.value = extent.value;
    _anim.animateWith(SpringSimulation(kPanelSpring, extent.value, to, velocity));
  }

  void _tick() {
    if (_settling) extent.value = _anim.value;
  }

  void _finish() {
    _settling = false;
    final g = _g;
    if (g != null) extent.value = g.extentOf(_detent);
    notifyListeners();
    _afterSettle();
  }

  void _afterSettle() {
    settleCount++;
    onSettled?.call();
  }

  @override
  void dispose() {
    _anim.dispose();
    extent.dispose();
    super.dispose();
  }
}
