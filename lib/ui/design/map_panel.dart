// MapPanel: the one panel that sits on a map (build 71). Twin of the site's float-panel.
// Rules (meshsonar-infra docs/planning/app-build-71-gateway-plan.md, "One shared panel"):
//   1. Bottom-anchored, directly above the tab bar. Only the person moves it; a connection or data event never does.
//      The ONLY automatic moves in the app are the two driving-safety rules: the Drive panel collapses from Open at speed
//      (lib/ui/drive/panel/auto_collapse.dart) and the map inspector clears itself 12 s after the last touch while driving
//      (MapInfoPanel.autoClear). Nothing else may move a panel.
//   2. The header is always visible and at least 44 pt: grabber, title, one status or count, chevron. Collapsed = header only.
//   3. Tap the header or drag it to toggle. Same state names everywhere: Collapsed, Open (at most 60 % of the height), Full
//      (work panels only: Planner, Drive stats).
//   4. Never modal: no barrier, no dimming; the map under it pans and zooms.
//   5. One open panel per map ([MapPanelGroup]).
//   6. Starts collapsed on a phone; the open state is remembered per [MapPanel.id] ([MapPanelStore]).
//   7. Connection wording and icon come from lib/ui/drive/radio_link_status.dart on every surface.
//   8. A header shows a status or a count of its own content, never a message count.
//   9. Forms (filters, settings, pickers) stay modal sheets; things that sit on a map are a MapPanel.
//
// Layout: put a MapPanel in a `Positioned.fill` of the map's Stack (or in a MapPanelHost, anchored_sheet.dart). It aligns
// itself to the bottom, takes only the height it needs and lets every touch outside its surface through to the map.
//
// Header, 56 pt (72 pt at text scale >= 2): an 8 pt grabber zone, then a 48 pt (64 pt) row, so the close button keeps the
// 48 pt target the Drive plan asks for while the car moves:
//   [leading 20] [title, 1 line] [status, 1 line] [action, optional] [chevron] [close 48x48, transient panels]
//
// Keys: 'map-panel-<id>', 'map-panel-<id>-header', 'map-panel-<id>-body', 'map-panel-<id>-close' (each can be overridden).
import 'package:flutter/material.dart';

import '../../core/map_prefs.dart';
import 'tokens.dart';

/// Same state names on every map. [full] is only for work panels (Planner, Drive stats).
enum MapPanelState { collapsed, open, full }

/// The one wording for a panel state (headers, VoiceOver, the Drive panel and the Planner sheet use it too).
String mapPanelStateLabel(MapPanelState s) => switch (s) {
      MapPanelState.collapsed => 'Collapsed',
      MapPanelState.open => 'Open',
      MapPanelState.full => 'Full',
    };

const double kMapPanelGrabberZone = 8;
const double kMapPanelRow = 48;
const double kMapPanelRowAx = 64;

/// Header height at normal text sizes (grabber zone + row).
const double kMapPanelHeader = kMapPanelGrabberZone + kMapPanelRow;

/// Open never takes more than this share of the height; Full takes [kMapPanelFull].
const double kMapPanelOpen = 0.6;
const double kMapPanelFull = 0.92;

/// An Open panel always leaves at least this much of the map visible above it (short screens, landscape).
const double kMapPanelMinMap = 150;

/// From this width up a panel is a floating card (iPad, landscape phone) and may start open.
const double kMapPanelWide = 700;
const double kMapPanelCardWidth = 380;
const double kMapPanelRadius = 20;

/// The header height for the text size in [context].
double mapPanelHeaderHeight(BuildContext context) =>
    kMapPanelGrabberZone + (MediaQuery.textScalerOf(context).scale(16) / 16 >= 2.0 ? kMapPanelRowAx : kMapPanelRow);

/// Remembers the state of each panel id. Written only when the person moves a panel. Kept with the other map choices
/// (MapPrefs, `map_prefs.json`, page `panels`), so it is in memory in tests and on disk in the app.
abstract final class MapPanelStore {
  static const String _page = 'panels';

  /// Work panels that always start collapsed on a cold launch (Andy, Nov 12 2026: a panel left open must never cover the map
  /// when the app opens). Their state is not saved.
  static const Set<String> alwaysStartCollapsed = {'drive.main', 'plan.main'};

  static MapPanelState? read(String id) {
    if (alwaysStartCollapsed.contains(id)) return null;
    final v = MapPrefs.shared.layerPrefs(_page).modes[id];
    for (final s in MapPanelState.values) {
      if (s.name == v) return s;
    }
    return null;
  }

  static void write(String id, MapPanelState s) {
    if (alwaysStartCollapsed.contains(id)) return;
    final p = MapPrefs.shared.layerPrefs(_page);
    if (p.modes[id] == s.name) return;
    MapPrefs.shared.setLayerPrefs(_page, p.copyWith(modes: {...p.modes, id: s.name}));
  }

  /// Forgets every remembered state (tests).
  static void clear() => MapPrefs.shared.setLayerPrefs(_page, LayerPrefs.empty);
}

/// One per map: at most one panel is open. Opening a panel collapses the other one to its header.
class MapPanelGroup extends ChangeNotifier {
  String? _openId;
  bool _disposed = false;

  /// The id of the open panel, or null when every panel is collapsed.
  String? get openId => _openId;

  /// [id] was opened by the person: it is now the one open panel.
  void claim(String id) {
    if (_disposed || _openId == id) return;
    _openId = id;
    notifyListeners();
  }

  /// [id] was collapsed or removed.
  void release(String id) {
    if (_disposed || _openId != id) return;
    _openId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Hands the map's [MapPanelGroup] to the panels under it.
class MapPanelScope extends InheritedNotifier<MapPanelGroup> {
  const MapPanelScope({super.key, required MapPanelGroup group, required super.child}) : super(notifier: group);

  /// The group, without listening to it.
  static MapPanelGroup? maybeRead(BuildContext context) => context.getInheritedWidgetOfExactType<MapPanelScope>()?.notifier;
}

/// The grabber every panel shows at the top of its header.
class MapPanelGrabber extends StatelessWidget {
  const MapPanelGrabber({super.key});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.fromTheme(Theme.of(context));
    // An opaque fill (map surfaces are never translucent): the muted text colour at half strength over the surface.
    final fill = Color.alphaBlend(c.textMuted.withValues(alpha: 0.5), c.surface);
    return Container(width: 36, height: 5, decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(3)));
  }
}

/// The chevron every panel shows: up when the panel can open further, down when a tap collapses it.
class MapPanelChevron extends StatelessWidget {
  final bool collapsed;
  final double size;
  const MapPanelChevron({super.key, required this.collapsed, this.size = 22});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Icon(collapsed ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: size, color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
}

/// The surface every panel is drawn on: opaque, rounded at the top (all round when [floating]), a hairline instead of a shadow.
class MapPanelSurface extends StatelessWidget {
  final Widget child;
  final bool floating;
  const MapPanelSurface({super.key, required this.child, this.floating = false});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.fromTheme(Theme.of(context));
    final radius = floating ? BorderRadius.circular(kMapPanelRadius) : const BorderRadius.vertical(top: Radius.circular(kMapPanelRadius));
    final line = BorderSide(color: c.outline.withValues(alpha: 0.5));
    return Material(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: floating ? RoundedRectangleBorder(borderRadius: radius, side: line) : _TopLine(radius: radius, side: line),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// Rounded top corners with a hairline along the top edge only.
class _TopLine extends RoundedRectangleBorder {
  const _TopLine({required BorderRadius radius, required super.side}) : super(borderRadius: radius);
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final r = (borderRadius as BorderRadius).toRRect(rect);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(rect.left, rect.top, rect.right, rect.top + r.tlRadiusY + 1));
    canvas.drawRRect(r.deflate(side.width / 2), side.toPaint());
    canvas.restore();
  }
}

class MapPanel extends StatefulWidget {
  /// Stable id; the remembered state is stored under it.
  final String id;
  final String title;

  /// One status or count of the panel's own content, shown in the header.
  final Widget? status;
  final Widget child;

  /// Work panels may go to [MapPanelState.full]; every other panel stops at open (at most 60 % of the height).
  final bool allowFull;

  /// A 20 pt glyph or dot before the title.
  final Widget? leading;

  /// A marker right after the title (a small chip), shown in every state.
  final Widget? badge;

  /// At most one header button (at least 44 x 44), usable while the panel is collapsed.
  final Widget? action;

  /// Transient panels (an inspector, a legend, layers): shows a close button. Their state is not remembered.
  final VoidCallback? onClose;

  /// The state a transient panel is shown in, and the first state of a panel nobody has moved yet. Null = collapsed on a
  /// phone, open on a wide screen (transient panels: open).
  final MapPanelState? initialState;

  /// Stays at its header: a tap or drag does not open it (the inspector while the car moves).
  final bool locked;

  /// The share of the height Open may take.
  final double openFraction;

  /// False when something else already keeps the panel clear of the home indicator and the tab bar (a panel that sits on top
  /// of another panel).
  final bool bottomSafe;

  /// Told about every state change, whoever caused it.
  final ValueChanged<MapPanelState>? onStateChanged;

  /// Told the panel's resting height when it changes (header only when collapsed), for the map's overlay clearance.
  final ValueChanged<double>? onExtent;

  /// Key overrides (older tests and semantics ids of the surfaces that became a MapPanel).
  final Key? headerKey, bodyKey, closeKey;

  const MapPanel({
    super.key,
    required this.id,
    required this.title,
    required this.child,
    this.status,
    this.allowFull = false,
    this.leading,
    this.badge,
    this.action,
    this.onClose,
    this.initialState,
    this.locked = false,
    this.openFraction = kMapPanelOpen,
    this.bottomSafe = true,
    this.onStateChanged,
    this.onExtent,
    this.headerKey,
    this.bodyKey,
    this.closeKey,
  });

  @override
  State<MapPanel> createState() => _MapPanelState();
}

class _MapPanelState extends State<MapPanel> {
  MapPanelState? _state;
  MapPanelGroup? _group;
  double _drag = 0;
  double? _extent;

  bool get _transient => widget.onClose != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final g = MapPanelScope.maybeRead(context);
    if (!identical(g, _group)) {
      _group?.removeListener(_groupChanged);
      _group = g?..addListener(_groupChanged);
    }
    if (_state == null) _restore();
  }

  /// The first state of this id: what the person left it at, else [MapPanel.initialState], else collapsed on a phone.
  void _restore() {
    final wide = MediaQuery.sizeOf(context).width >= kMapPanelWide;
    final first = widget.initialState ?? (_transient || wide ? MapPanelState.open : MapPanelState.collapsed);
    _state = _clamp(_transient ? first : (MapPanelStore.read(widget.id) ?? first));
    // A panel that starts open is the map's open panel; told after this frame, so no listener rebuilds during build.
    if (_state != MapPanelState.collapsed && !widget.locked) {
      final id = widget.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.id == id && _state != MapPanelState.collapsed) _group?.claim(id);
      });
    }
  }

  @override
  void didUpdateWidget(MapPanel old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) {
      // Another panel took this place in the tree: it has its own state.
      final g = _group, was = old.id;
      if (g != null) WidgetsBinding.instance.addPostFrameCallback((_) => g.release(was));
      _restore();
    }
    if (!widget.allowFull && _state == MapPanelState.full) _state = MapPanelState.open;
  }

  @override
  void dispose() {
    final g = _group;
    if (g != null) {
      g.removeListener(_groupChanged);
      final id = widget.id;
      // Not during the tree's teardown: listeners of the group may be going away in the same frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => g.release(id));
    }
    super.dispose();
  }

  MapPanelState _clamp(MapPanelState s) => s == MapPanelState.full && !widget.allowFull ? MapPanelState.open : s;

  /// Another panel on this map was opened: this one goes back to its header. Its remembered state is left alone.
  void _groupChanged() {
    final open = _group?.openId;
    if (!mounted || open == null || open == widget.id || _state == MapPanelState.collapsed) return;
    setState(() => _state = MapPanelState.collapsed);
    widget.onStateChanged?.call(MapPanelState.collapsed);
  }

  /// The person moved the panel.
  void _set(MapPanelState next) {
    next = _clamp(next);
    if (widget.locked || next == _state) return;
    setState(() => _state = next);
    if (!_transient) MapPanelStore.write(widget.id, next);
    next == MapPanelState.collapsed ? _group?.release(widget.id) : _group?.claim(widget.id);
    widget.onStateChanged?.call(next);
  }

  void _toggle() => _set(_state == MapPanelState.collapsed ? MapPanelState.open : MapPanelState.collapsed);

  void _step(int by) {
    final order = [MapPanelState.collapsed, MapPanelState.open, if (widget.allowFull) MapPanelState.full];
    _set(order[(order.indexOf(_state!) + by).clamp(0, order.length - 1)]);
  }

  void _dragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final moved = _drag;
    _drag = 0;
    if (moved < -20 || v < -300) {
      _step(1);
    } else if (moved > 20 || v > 300) {
      _step(-1);
    }
  }

  void _report(double extent) {
    if (widget.onExtent == null || _extent == extent) return;
    _extent = extent;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onExtent?.call(extent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.locked ? MapPanelState.collapsed : _state!;
    final collapsed = state == MapPanelState.collapsed;
    final mq = MediaQuery.of(context);
    final headerH = mapPanelHeaderHeight(context);
    return LayoutBuilder(
      builder: (context, box) {
        final avail = box.hasBoundedHeight ? box.maxHeight : mq.size.height;
        final wide = box.hasBoundedWidth && box.maxWidth >= kMapPanelWide;
        final safe = widget.bottomSafe ? mq.padding.bottom : 0.0;
        final share = state == MapPanelState.full ? kMapPanelFull : widget.openFraction;
        // Open also leaves at least [kMapPanelMinMap] of map on a short screen (Full is a work panel: it may cover the map).
        var panelMax = avail * share;
        if (state != MapPanelState.full && avail - panelMax < kMapPanelMinMap) panelMax = avail - kMapPanelMinMap;
        final bodyMax = (panelMax - headerH - (wide ? 0 : safe)).clamp(0.0, avail);
        _report(headerH + (wide ? 16 + safe : safe));
        final column = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, state, headerH),
            // Never taller than the room there is: when the area above the persistent panel shrinks while this panel is still
            // animating (the person opened the other panel), the body is cut to fit instead of overflowing.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: (avail - headerH - (wide ? 16 + safe : safe)).clamp(0.0, double.infinity)),
              child: AnimatedSize(
              duration: Motion.of(context, Motion.sheet),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: collapsed
                  ? const SizedBox(width: double.infinity)
                  : ConstrainedBox(
                      key: widget.bodyKey ?? Key('map-panel-${widget.id}-body'),
                      constraints: state == MapPanelState.full ? BoxConstraints.tightFor(height: bodyMax) : BoxConstraints(maxHeight: bodyMax),
                      child: widget.child,
                    ),
              ),
            ),
            // The surface runs down behind the tab bar / home indicator, the content stops above it.
            if (!wide && safe > 0) SizedBox(height: safe),
          ],
        );
        return Align(
          alignment: wide ? Alignment.bottomLeft : Alignment.bottomCenter,
          child: Padding(
            padding: wide ? EdgeInsets.only(left: 16 + mq.padding.left, bottom: 16 + safe) : EdgeInsets.zero,
            child: SizedBox(
              key: Key('map-panel-${widget.id}'),
              width: wide ? kMapPanelCardWidth : null,
              child: MapPanelSurface(floating: wide, child: column),
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, MapPanelState state, double height) {
    final t = Theme.of(context);
    final collapsed = state == MapPanelState.collapsed;
    final muted = t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final order = [MapPanelState.collapsed, MapPanelState.open, if (widget.allowFull) MapPanelState.full];
    final at = order.indexOf(state);
    final canUp = !widget.locked && at < order.length - 1, canDown = !widget.locked && at > 0;
    final row = Padding(
      padding: const EdgeInsets.only(left: Layout.screenMargin, right: 4),
      child: Row(
        children: [
          if (widget.leading != null) ...[SizedBox(width: 20, height: 20, child: Center(child: widget.leading)), const SizedBox(width: 8)],
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Row(
                children: [
                  Flexible(
                    child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  if (widget.badge != null) ...[const SizedBox(width: 6), widget.badge!],
                  if (widget.status != null) ...[
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth * 0.6),
                      child: DefaultTextStyle.merge(style: muted, maxLines: 1, overflow: TextOverflow.ellipsis, child: widget.status!),
                    ),
                  ],
                ],
              ),
            ),
          ),
          ?widget.action,
          if (!widget.locked) Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: MapPanelChevron(collapsed: collapsed)),
          if (widget.onClose != null)
            IconButton(
              key: widget.closeKey ?? Key('map-panel-${widget.id}-close'),
              tooltip: 'Close',
              constraints: const BoxConstraints(minWidth: kMapPanelRow, minHeight: kMapPanelRow),
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: widget.onClose,
            ),
        ],
      ),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      button: !widget.locked,
      label: '${widget.title} panel',
      value: mapPanelStateLabel(state),
      onTap: widget.locked ? null : _toggle,
      increasedValue: canUp ? mapPanelStateLabel(order[at + 1]) : null,
      decreasedValue: canDown ? mapPanelStateLabel(order[at - 1]) : null,
      onIncrease: canUp ? () => _step(1) : null,
      onDecrease: canDown ? () => _step(-1) : null,
      child: GestureDetector(
        key: widget.headerKey ?? Key('map-panel-${widget.id}-header'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.locked ? null : _toggle,
        onVerticalDragStart: (_) => _drag = 0,
        onVerticalDragUpdate: (d) => _drag += d.delta.dy,
        onVerticalDragEnd: _dragEnd,
        onVerticalDragCancel: () => _drag = 0,
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              const SizedBox(height: kMapPanelGrabberZone, child: Align(alignment: Alignment.bottomCenter, child: MapPanelGrabber())),
              Expanded(child: row),
            ],
          ),
        ),
      ),
    );
  }
}
