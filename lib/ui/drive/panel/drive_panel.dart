// DrivePanel: the bottom panel of the Drive tab (Drive plan 5.1, 5.4). Hand-rolled, not a DraggableScrollableSheet: its state
// is tied to the tab bar and a pinned dock. Only the person moves it (build 76: no speed-driven collapse). The panel is a sibling above the map, never inside the map's gesture arena,
// and it never dims or resizes the map. Dragging only moves the panel (its own relayout boundary); the map is not touched.
//
// Look and words are the shared map panel's (design/map_panel.dart): the same grabber, chevron and surface, and the state
// names Collapsed (Dock) and Open (Medium); the engine (physics, detents) is this panel's own. Hidden (the
// Immersive pill) exists only here. Id in the map's panel group: [kDrivePanelId].
//
//   header   = grabber row (16) + dock row (72): drag it up/down, tap it to toggle Dock <-> Medium. Buttons inside the dock row are
//              deeper in the tree, so they win the tap; the rest of the header is the handle (>= 44 pt high everywhere).
//   medium   = scrolling content below the header. It scrolls only at Medium and hands the drag to the panel at offset 0.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../design/map_panel.dart';
import '../../design/tokens.dart';
import 'drive_panel_controller.dart';
import 'panel_physics.dart';

/// The Drive panel's id in its map's MapPanelGroup. Its state is never saved: it always starts at the Dock.
const String kDrivePanelId = 'drive.main';

class DrivePanel extends StatelessWidget {
  final DrivePanelController controller;

  /// The dock row content (72 pt high): hero, Ping, Stop / Start.
  final Widget dock;

  /// Medium content, scrolled inside the panel.
  final List<Widget> mediumChildren;

  /// The reserved strip (plan 4.12, 28 pt) at the top of the panel surface: GPS / radio / permission help with its one fix.
  /// Null = no strip. It is part of the surface, so it rides with the panel and never moves the dock buttons.
  final Widget? strip;

  /// Floating card (iPad / landscape phone): width and left edge. Null = the full-width phone panel.
  final double? cardWidth;
  final double cardLeft;

  /// The panel is not drawn (idle Immersive shows only the Start pill); a drag or spring brings it back.
  final bool hidden;
  const DrivePanel({super.key, required this.controller, required this.dock, this.mediumChildren = const [], this.strip, this.cardWidth, this.cardLeft = 16, this.hidden = false});

  /// The shared state of a detent (design/map_panel.dart). Immersive has none: it is this panel's own "Hidden".
  static MapPanelState? stateOf(PanelDetent d) => switch (d) {
        PanelDetent.immersive => null,
        PanelDetent.dock => MapPanelState.collapsed,
        PanelDetent.medium => MapPanelState.open,
      };

  /// The words for a detent: the same state names as every map panel.
  static String detentLabel(PanelDetent d) => switch (stateOf(d)) {
        null => 'Hidden',
        final s => mapPanelStateLabel(s),
      };

  @override
  Widget build(BuildContext context) {
    final g = controller.geometry;
    if (g == null || hidden) return const SizedBox.shrink();
    return ValueListenableBuilder<double>(
      valueListenable: controller.extent,
      builder: (context, extent, _) {
        final h = g.panelHeightAt(extent);
        final stripH = strip == null ? 0.0 : kPanelStripHeight;
        final below = extent - h; // > 0 only while dragged below the dock: the panel rides over the tab bar zone
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: cardWidth == null ? 0 : cardLeft,
              right: cardWidth == null ? 0 : null,
              width: cardWidth,
              bottom: below,
              height: h + stripH,
              child: _Surface(controller: controller, dock: dock, mediumChildren: mediumChildren, height: h, strip: strip, floating: cardWidth != null),
            ),
          ],
        );
      },
    );
  }
}

class _Surface extends StatelessWidget {
  final DrivePanelController controller;
  final Widget dock;
  final List<Widget> mediumChildren;
  final double height;
  final Widget? strip;
  final bool floating;
  const _Surface({required this.controller, required this.dock, required this.mediumChildren, required this.height, this.strip, this.floating = false});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.fromTheme(Theme.of(context));
    final dockH = controller.geometry?.dockHeight ?? kPanelDockHeight;
    // Opaque to touches: nothing under the panel (the map) is reached through it.
    return Listener(
      key: const Key('drive-panel'),
      behavior: HitTestBehavior.opaque,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: floating ? BorderRadius.circular(20) : const BorderRadius.vertical(top: Radius.circular(20)),
          border: floating ? Border.all(color: c.outline.withValues(alpha: 0.5)) : Border(top: BorderSide(color: c.outline.withValues(alpha: 0.5))),
          boxShadow: floating ? const [BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 4))] : null,
        ),
        child: ClipRRect(
          borderRadius: floating ? BorderRadius.circular(20) : const BorderRadius.vertical(top: Radius.circular(20)),
          child: Column(
            children: [
              if (strip != null) SizedBox(key: const Key('drive-panel-strip'), height: kPanelStripHeight, child: strip),
              _Header(controller: controller, dock: dock),
              if (height > dockH + 1)
                Expanded(
                  child: Opacity(
                    opacity: ((height - dockH) / 40).clamp(0.0, 1.0),
                    child: _MediumScroll(controller: controller, children: mediumChildren),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The dock row height the content is laid out for: the AX row at text scale >= 2 (as DriveDock.isAx), else the geometry's.
double _rowFor(BuildContext context, PanelGeometry g) =>
    MediaQuery.textScalerOf(context).scale(16) / 16 >= 2.0 ? math.max(g.dockRow, kPanelDockRowAx) : g.dockRow;

class _Header extends StatelessWidget {
  final DrivePanelController controller;
  final Widget dock;
  const _Header({required this.controller, required this.dock});

  @override
  Widget build(BuildContext context) {
    final g = controller.geometry!;
    void step(int dir) {
      final ds = g.detents;
      final i = ds.indexOf(controller.detent);
      controller.settleTo(ds[(i + dir).clamp(0, ds.length - 1)]);
    }

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Panel',
      value: DrivePanel.detentLabel(controller.detent),
      increasedValue: DrivePanel.detentLabel(PanelDetent.medium),
      decreasedValue: DrivePanel.detentLabel(PanelDetent.dock),
      onIncrease: () => step(1),
      onDecrease: () => step(-1),
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Open'): () => controller.settleTo(PanelDetent.medium),
        const CustomSemanticsAction(label: 'Collapse'): () => controller.settleTo(PanelDetent.dock),
        if (g.hasImmersive) const CustomSemanticsAction(label: 'Hide'): () => controller.settleTo(PanelDetent.immersive),
      },
      child: GestureDetector(
        key: const Key('drive-panel-header'),
        behavior: HitTestBehavior.opaque,
        onTap: controller.toggle,
        onVerticalDragStart: (_) => controller.dragStart(),
        onVerticalDragUpdate: (d) => controller.dragUpdate(d.delta.dy),
        onVerticalDragEnd: (d) => controller.dragEnd(d.velocity.pixelsPerSecond.dy),
        onVerticalDragCancel: controller.dragCancel,
        child: SizedBox(
          height: g.dockHeight,
          child: Column(
            children: [
              SizedBox(
                height: kPanelHeaderHeight,
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const MapPanelGrabber(key: Key('drive-panel-grabber')),
                    // The same chevron as every map panel, in the grabber row so the dock row keeps its width.
                    Positioned(
                      right: 12,
                      top: 0,
                      bottom: 0,
                      child: MapPanelChevron(key: const Key('drive-panel-chevron'), collapsed: controller.detent != PanelDetent.medium, size: 16),
                    ),
                  ],
                ),
              ),
              // The row height follows the text size one frame after it changes (the geometry is set after layout): clip that
              // one frame instead of overflowing. When the two agree the dock fits and nothing is clipped.
              SizedBox(
                height: g.dockRow,
                child: ClipRect(child: OverflowBox(alignment: Alignment.topCenter, minHeight: _rowFor(context, g), maxHeight: _rowFor(context, g), child: dock)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Medium's scroll view. Bouncing physics; at offset 0 a downward drag belongs to the panel (nested scroll hand-off).
class _MediumScroll extends StatefulWidget {
  final DrivePanelController controller;
  final List<Widget> children;
  const _MediumScroll({required this.controller, required this.children});
  @override
  State<_MediumScroll> createState() => _MediumScrollState();
}

class _MediumScrollState extends State<_MediumScroll> {
  final ScrollController _sc = ScrollController();
  final VelocityTracker _vt = VelocityTracker.withKind(PointerDeviceKind.touch);
  bool _owns = false;

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  void _move(PointerMoveEvent e) {
    final atTop = !_sc.hasClients || _sc.offset <= 0.5;
    if (_owns) {
      _vt.addPosition(e.timeStamp, e.position);
      widget.controller.dragUpdate(e.delta.dy);
    } else if (atTop && e.delta.dy > 0 && widget.controller.detent == PanelDetent.medium && !widget.controller.settling) {
      _owns = true;
      widget.controller.dragStart();
      _vt.addPosition(e.timeStamp, e.position);
      widget.controller.dragUpdate(e.delta.dy);
    }
  }

  void _end(PointerEvent e) {
    if (!_owns) return;
    _owns = false;
    widget.controller.dragEnd(_vt.getVelocity().pixelsPerSecond.dy);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) => _vt.addPosition(e.timeStamp, e.position),
      onPointerMove: _move,
      onPointerUp: _end,
      onPointerCancel: _end,
      child: ListView(
        key: const Key('drive-panel-medium'),
        controller: _sc,
        // Frozen while the panel owns the drag, and while the panel is not at Medium (nothing scrolls under a moving panel).
        physics: _OwnedPhysics(() => _owns || widget.controller.dragging || widget.controller.detent != PanelDetent.medium),
        padding: EdgeInsets.fromLTRB(Layout.screenMargin, 4, Layout.screenMargin, MediaQuery.paddingOf(context).bottom * 0 + 16),
        children: widget.children,
      ),
    );
  }
}

class _OwnedPhysics extends BouncingScrollPhysics {
  final bool Function() frozen;
  const _OwnedPhysics(this.frozen, {super.parent});
  @override
  _OwnedPhysics applyTo(ScrollPhysics? ancestor) => _OwnedPhysics(frozen, parent: buildParent(ancestor));
  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) => frozen() ? 0 : super.applyPhysicsToUserOffset(position, offset);
  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => !frozen() && super.shouldAcceptUserOffset(position);
}
