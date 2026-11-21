// MapPanelHost: the ONE transient slot of a map (build 71, plan "One shared panel"). A map has one persistent panel (the
// Drive panel, the Live panel, the Planner sheet) and, directly above it, at most one transient MapPanel: an inspector, a
// tapped observer, the layers, the legend, a focused packet. Showing a new one replaces the current one. Nothing here has a
// barrier: the map stays interactive. Modal root-navigator sheets (forms: filters, settings, pickers) stay `showAppSheet`.
//
// A transient panel closes with its X, and when the person taps empty map ([MapPanelHostController.close] from the map's tap).
// Opening one never changes the persistent panel's remembered state (MapPanel only saves what the person did to that panel).
//
// This file replaces the old AnchoredSheetHost (same job, never mounted).
import 'package:flutter/material.dart';

class MapPanelHostController extends ChangeNotifier {
  String? _id;
  WidgetBuilder? _builder;
  VoidCallback? _onClosed;

  String? get currentId => _id;
  bool get isOpen => _id != null;

  /// Shows the panel [builder] returns (a MapPanel with `onClose: () => close(id)` and `bottomSafe: false`) as [id], replacing
  /// the one that is open. [onClosed] runs when it goes away (closed or replaced).
  void show({required String id, required WidgetBuilder builder, VoidCallback? onClosed}) {
    final previous = _onClosed;
    _id = id;
    _builder = builder;
    _onClosed = onClosed;
    previous?.call();
    notifyListeners();
  }

  /// Closes the panel; with [id], only when that panel is the one showing.
  void close([String? id]) {
    if (_id == null || (id != null && id != _id)) return;
    final cb = _onClosed;
    _id = null;
    _builder = null;
    _onClosed = null;
    notifyListeners();
    cb?.call();
  }
}

/// Wraps a map. [bottomInset] is the resting height of the persistent panel under the slot (its header, the tab bar zone and
/// the home indicator included), so a transient panel sits directly on top of it and nothing hides under the tab bar.
class MapPanelHost extends StatelessWidget {
  final MapPanelHostController controller;
  final double bottomInset;
  final Widget child;

  /// A panel the owner builds itself each frame (the map inspector, whose content follows the map's state). Shown when the
  /// controller has nothing to show.
  final Widget? panel;
  const MapPanelHost({super.key, required this.controller, required this.child, this.bottomInset = 0, this.panel});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: child),
        Positioned.fill(
          bottom: bottomInset,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final b = controller._builder;
              final shown = b != null ? KeyedSubtree(key: ValueKey('map-panel-host-${controller._id}'), child: b(context)) : panel;
              return shown ?? const SizedBox.shrink();
            },
          ),
        ),
      ],
    );
  }
}
