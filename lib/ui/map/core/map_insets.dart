// MapInsets: how much of the map the overlays cover (top: banner, bottom: attribution and the bottom slot, right: control
// column). Published once per settled layout by MapOverlayHost (never per animation frame); consumers (camera follow
// anchor, fitTo padding, label avoid rects) read it instead of measuring render objects. Drive plan 5.6 / 9.3.
import 'package:flutter/widgets.dart';

/// Holds the current insets. A value that equals the last one is not re-published, so listeners fire once per real change.
class MapInsetsNotifier extends ValueNotifier<EdgeInsets> {
  MapInsetsNotifier() : super(EdgeInsets.zero);

  /// How many times a changed value was published (tests assert "published once").
  int publishCount = 0;

  /// Publishes [next] if it differs from the current value.
  void publish(EdgeInsets next) {
    if (next == value) return;
    publishCount++;
    value = next;
  }
}

class MapInsets extends InheritedNotifier<MapInsetsNotifier> {
  const MapInsets({super.key, required MapInsetsNotifier notifier, required super.child}) : super(notifier: notifier);

  /// The insets in effect here, or zero when there is no overlay host above.
  static EdgeInsets of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<MapInsets>();
    return w?.notifier?.value ?? EdgeInsets.zero;
  }

  /// The notifier, for reading without depending (e.g. in a camera callback).
  static MapInsetsNotifier? maybeNotifier(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MapInsets>()?.notifier;
}
