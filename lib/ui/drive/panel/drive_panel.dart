// DrivePanel: the bottom panel of the Drive tab (Drive plan 5.1, 5.4). Hand-rolled, not a DraggableScrollableSheet: its state
// is tied to speed, the tab bar and a pinned dock. The panel is a sibling above the map, never inside the map's gesture arena,
// and it never dims or resizes the map. Dragging only moves the panel (its own relayout boundary); the map is not touched.
//
//   header   = grabber row (16) + dock row (72): drag it up/down, tap it to toggle Dock <-> Medium. Buttons inside the dock row are
//              deeper in the tree, so they win the tap; the rest of the header is the handle (>= 44 pt high everywhere).
//   medium   = scrolling content below the header. It scrolls only at Medium and hands the drag to the panel at offset 0.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../design/tokens.dart';
import 'drive_panel_controller.dart';
import 'panel_physics.dart';

class DrivePanel extends StatelessWidget {
  final DrivePanelController controller;

  /// The dock row content (72 pt high): hero, Ping, Stop / Start.
  final Widget dock;

  /// Medium content, scrolled inside the panel.
  final List<Widget> mediumChildren;

  /// Any touch on the panel (resets the auto-collapse timer).
  final VoidCallback? onTouch;

  /// The reserved strip (plan 4.12, 28 pt) at the top of the panel surface: GPS / radio / permission help with its one fix.
  /// Null = no strip. It is part of the surface, so it rides with the panel and never moves the dock buttons.
  final Widget? strip;
  const DrivePanel({super.key, required this.controller, required this.dock, this.mediumChildren = const [], this.onTouch, this.strip});

  /// Semantics value for a detent.
  static String detentLabel(PanelDetent d) => switch (d) {
        PanelDetent.immersive => 'Hidden',
        PanelDetent.dock => 'Dock',
        PanelDetent.medium => 'Expanded',
      };

  @override
  Widget build(BuildContext context) {
    final g = controller.geometry;
    if (g == null) return const SizedBox.shrink();
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
              left: 0,
              right: 0,
              bottom: below,
              height: h + stripH,
              child: _Surface(controller: controller, dock: dock, mediumChildren: mediumChildren, onTouch: onTouch, height: h, strip: strip),
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
  final VoidCallback? onTouch;
  final double height;
  final Widget? strip;
  const _Surface({required this.controller, required this.dock, required this.mediumChildren, required this.onTouch, required this.height, this.strip});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.fromTheme(Theme.of(context));
    final dockH = controller.geometry?.dockHeight ?? kPanelDockHeight;
    return Listener(
      key: const Key('drive-panel'),
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => onTouch?.call(),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: c.outline.withValues(alpha: 0.5))),
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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

class _Header extends StatelessWidget {
  final DrivePanelController controller;
  final Widget dock;
  const _Header({required this.controller, required this.dock});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.fromTheme(Theme.of(context));
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
      increasedValue: 'Expanded',
      decreasedValue: 'Dock',
      onIncrease: () => step(1),
      onDecrease: () => step(-1),
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Expand'): () => controller.settleTo(PanelDetent.medium),
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
                child: Center(
                  child: Container(
                    key: const Key('drive-panel-grabber'),
                    width: 36,
                    height: 5,
                    decoration: BoxDecoration(color: c.textMuted.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(3)),
                  ),
                ),
              ),
              SizedBox(height: g.dockRow, child: dock),
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
