// MapOverlayHost: the one place overlays sit on a map (Drive plan 9.3, 4.19). Fixed slots, each clipped to its measured rect and
// bounded by the space the other slots leave; there is NO bottom-leading slot, so nothing can be parked in the lower-left
// corner (the corner rule is enforced in code, and [MapSlot.values] is what the containment test enumerates).
//
//   banner        top edge, full width (the GPS health line)
//   topLeading    under the banner, left (heard box)
//   topTrailing   under the banner, right (button column)
//   toast         under the banner, centred
//   controls      bottom-right column of round buttons, directly above the attribution
//   attribution   bottom-right, the AttributionLine (never clipped, always present)
//   bottom        full width above the attribution (hint, report card, result flash, inspector panel)
//
// Layout is a single CustomMultiChildLayout pass, so the banner height needs no probe widget and no shared notifier: the
// slots under it are placed from the banner's size in the same layout. The resulting insets are published once, after the
// frame, through [MapInsetsNotifier] (only when they changed).
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/map_insets.dart';

enum MapSlot { banner, topLeading, topTrailing, toast, controls, attribution, bottom }

const double kOverlayMargin = 8;

/// Below this host height the button column can reach the bottom stack and the controls (the old compact-pane behaviour).
const double kCompactPane = 380;

class MapOverlayHost extends StatefulWidget {
  /// The map engine, filling the host.
  final Widget map;
  final Widget attribution;
  final Widget? banner;
  final Widget? topLeading;
  final Widget? topTrailing;
  final Widget? toast;
  final Widget? controls;
  final Widget? bottom;

  /// Keys on the slot contents' wrappers (the map keeps label names out from under them).
  final Map<MapSlot, GlobalKey> slotKeys;

  /// Receives the insets when they settle (also available through [MapInsets]).
  final MapInsetsNotifier? insets;
  const MapOverlayHost({
    super.key,
    required this.map,
    required this.attribution,
    this.banner,
    this.topLeading,
    this.topTrailing,
    this.toast,
    this.controls,
    this.bottom,
    this.slotKeys = const {},
    this.insets,
  });

  @override
  State<MapOverlayHost> createState() => _MapOverlayHostState();
}

class _MapOverlayHostState extends State<MapOverlayHost> {
  MapInsetsNotifier? _own;
  MapInsetsNotifier get _insets => widget.insets ?? (_own ??= MapInsetsNotifier());
  EdgeInsets? _pending;
  bool _scheduled = false;

  void _laidOut(EdgeInsets next) {
    _pending = next;
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final p = _pending;
      if (!mounted || p == null) return;
      _insets.publish(p);
    });
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  /// A slot's content is scaled down (never up) to the room the layout left it, so a slot can neither overflow nor paint outside
  /// its rect; the rect is clipped as well.
  Widget? _slot(MapSlot s, Widget? child, {bool fit = true, bool fullWidth = false, Alignment align = Alignment.topLeft, bool clip = true}) {
    if (child == null) return null;
    Widget c = KeyedSubtree(key: widget.slotKeys[s], child: child);
    if (fit) {
      final inner = c;
      c = LayoutBuilder(
        builder: (context, box) => box.maxWidth <= 0 || box.maxHeight <= 0 ? const SizedBox.shrink() : FittedBox(
          fit: BoxFit.scaleDown,
          alignment: align,
          child: fullWidth && box.hasBoundedWidth ? SizedBox(width: box.maxWidth, child: inner) : inner,
        ),
      );
    }
    // The clip is the slot's rect plus room for a drop shadow (never more than 8 pt), so elevated buttons are not cut off.
    if (clip) c = ClipRect(clipper: const _SlotClip(), child: c);
    return LayoutId(id: s, child: c);
  }

  @override
  Widget build(BuildContext context) {
    final slots = <Widget>[
      ?_slot(MapSlot.banner, widget.banner, fit: false),
      ?_slot(MapSlot.topLeading, widget.topLeading),
      ?_slot(MapSlot.topTrailing, widget.topTrailing, align: Alignment.topRight),
      ?_slot(MapSlot.toast, widget.toast, align: Alignment.topCenter),
      ?_slot(MapSlot.controls, widget.controls, align: Alignment.bottomRight),
      ?_slot(MapSlot.bottom, widget.bottom, fullWidth: true, align: Alignment.bottomLeft),
      ?_slot(MapSlot.attribution, widget.attribution, fit: false, clip: false),
    ];
    return MapInsets(
      notifier: _insets,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.map,
          CustomMultiChildLayout(delegate: _OverlayLayout(_laidOut), children: slots),
        ],
      ),
    );
  }
}

class _SlotClip extends CustomClipper<Rect> {
  const _SlotClip();
  @override
  Rect getClip(Size size) => Rect.fromLTRB(-8, -8, size.width + 8, size.height + 8);
  @override
  bool shouldReclip(_SlotClip old) => false;
}

class _OverlayLayout extends MultiChildLayoutDelegate {
  final void Function(EdgeInsets) onInsets;
  _OverlayLayout(this.onInsets);

  @override
  void performLayout(Size size) {
    const m = kOverlayMargin;
    Size lay(MapSlot s, BoxConstraints c) => hasChild(s) ? layoutChild(s, c) : Size.zero;
    void put(MapSlot s, Offset o) {
      if (hasChild(s)) positionChild(s, o);
    }

    final w = size.width, h = size.height;
    // Banner: the top edge, full width.
    // Unbounded height: a banner that is a Column asks for its own height, not the pane's (it is clipped to the pane below).
    final bannerRaw = lay(MapSlot.banner, BoxConstraints(minWidth: w, maxWidth: w));
    final banner = Size(bannerRaw.width, bannerRaw.height > h ? h : bannerRaw.height);
    put(MapSlot.banner, Offset.zero);
    final topY = banner.height + m;

    // Attribution: the bottom-right corner (first: it is never squeezed).
    final attr = lay(MapSlot.attribution, BoxConstraints(maxWidth: (w - 2 * m).clamp(0.0, w)));
    final attrTop = h - m - attr.height;
    put(MapSlot.attribution, Offset(w - m - attr.width, attrTop));

    // The button column (top-trailing) keeps the whole height it had before: its tap targets matter most while driving, and it
    // scales itself down to fit. On a pane short enough that it reaches the bottom stack (under [kCompactPane]) the bottom stack
    // and the controls sit over / beside its lower end, as they always did; on any taller pane every slot is disjoint.
    final room = (attrTop - 4 - topY).clamp(0.0, h);
    final colW = (w - 2 * m).clamp(0.0, w);
    final trail = lay(MapSlot.topTrailing, BoxConstraints(maxWidth: colW, maxHeight: room));
    put(MapSlot.topTrailing, Offset(w - m - trail.width, topY));
    final trailBottom = trail.height > 0 ? topY + trail.height : topY;

    final ctrl = lay(MapSlot.controls, BoxConstraints(maxWidth: colW, maxHeight: room / 2));
    final ctrlTop = attrTop - 4 - ctrl.height;
    // A tall column leaves the controls the corner; a column that reaches them moves them left of its buttons.
    final ctrlShift = trailBottom + 4 > ctrlTop && trail.width > 0 ? (trail.width < 52 ? trail.width : 52.0) + 6 : 0.0;
    put(MapSlot.controls, Offset(w - 12 - ctrl.width - ctrlShift, ctrlTop));
    final bottomMaxW = (w - 2 * m - (ctrl.width > 0 ? ctrl.width + ctrlShift + m : 0)).clamp(0.0, w);
    final bottom = lay(MapSlot.bottom, BoxConstraints(maxWidth: bottomMaxW, maxHeight: room / 2));
    final bottomTop = attrTop - 4 - bottom.height;
    put(MapSlot.bottom, Offset(m, bottomTop));

    final leadH = ((bottom.height > 0 ? bottomTop : attrTop) - 4 - topY).clamp(0.0, h);
    final lead = lay(MapSlot.topLeading, BoxConstraints(maxWidth: colW, maxHeight: leadH));
    put(MapSlot.topLeading, Offset(m, topY));
    final toast = lay(MapSlot.toast, BoxConstraints(maxWidth: colW, maxHeight: leadH));
    put(MapSlot.toast, Offset((w - toast.width) / 2, topY));
    assert(lead.height >= 0 && toast.height >= 0);

    var coveredBottomTop = attrTop;
    if (bottom.height > 0 && bottomTop < coveredBottomTop) coveredBottomTop = bottomTop;
    if (ctrl.height > 0 && ctrlTop < coveredBottomTop) coveredBottomTop = ctrlTop;
    final right = ctrl.width + ctrlShift > trail.width ? ctrl.width + ctrlShift : trail.width;
    onInsets(EdgeInsets.fromLTRB(0, banner.height, right > 0 ? right + m : 0, h - coveredBottomTop));
  }

  @override
  bool shouldRelayout(_OverlayLayout old) => true;
}
