// AnchoredSheetHost (Drive plan 3.4 / 5.7): hosts non-modal sheets INSIDE the Drive tab stack, bounded below by the dock's
// top edge so Start / Stop / Ping are never covered. Used for layers, inspectors and the filter. Modal root-navigator
// sheets stay `showAppSheet`. One sheet at a time: showing a new one replaces the current one (Layers and Inspector are
// mutually exclusive). The map stays interactive: nothing here has a barrier.
import 'package:flutter/material.dart';

import 'tokens.dart';

class AnchoredSheetController extends ChangeNotifier {
  String? _id;
  WidgetBuilder? _builder;
  double _maxFraction = 0.6;
  VoidCallback? _onClosed;

  String? get currentId => _id;
  bool get isOpen => _id != null;

  /// Shows [builder] as sheet [id], replacing any sheet that is open. [maxFraction] caps the height as a fraction of the
  /// host area above the dock.
  void show({required String id, required WidgetBuilder builder, double maxFraction = 0.6, VoidCallback? onClosed}) {
    final previous = _onClosed;
    _id = id;
    _builder = builder;
    _maxFraction = maxFraction;
    _onClosed = onClosed;
    if (previous != null) previous();
    notifyListeners();
  }

  /// Closes the sheet; with [id], only when that sheet is the open one.
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

/// Wraps the Drive tab body. [bottomInset] is the height of the dock (and anything else sheets must stay above).
class AnchoredSheetHost extends StatelessWidget {
  final AnchoredSheetController controller;
  final double bottomInset;
  final Widget child;
  const AnchoredSheetHost({super.key, required this.controller, this.bottomInset = 0, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final b = controller._builder;
            if (b == null) return const SizedBox.shrink();
            return Positioned(
              left: 0,
              right: 0,
              bottom: bottomInset,
              child: LayoutBuilder(
                builder: (context, c) {
                  // The host's height is the Stack's; the sheet may use a fraction of what is above the dock.
                  final h = (MediaQuery.sizeOf(context).height - bottomInset) * controller._maxFraction;
                  return Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: Layout.sheetMaxWidth, maxHeight: h),
                      child: _AnchoredCard(
                        key: ValueKey('anchored-${controller._id}'),
                        onDismiss: () => controller.close(),
                        child: b(context),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }
}

class _AnchoredCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onDismiss;
  const _AnchoredCard({super.key, required this.child, required this.onDismiss});

  @override
  State<_AnchoredCard> createState() => _AnchoredCardState();
}

class _AnchoredCardState extends State<_AnchoredCard> {
  double _drag = 0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    return Transform.translate(
      offset: Offset(0, _drag),
      child: Material(
        color: t.colorScheme.surface,
        elevation: dark ? 0 : 6,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(Corners.card)),
          side: dark ? BorderSide(color: t.colorScheme.outline) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (d) => setState(() => _drag = (_drag + d.delta.dy).clamp(0, 400)),
              onVerticalDragEnd: (d) {
                if (_drag > 80 || (d.primaryVelocity ?? 0) > 700) {
                  widget.onDismiss();
                } else {
                  setState(() => _drag = 0);
                }
              },
              child: SizedBox(
                height: Hit.min,
                width: double.infinity,
                child: Center(
                  child: Container(
                    key: const Key('anchored-grabber'),
                    width: 36,
                    height: 5,
                    decoration: BoxDecoration(color: t.colorScheme.outline, borderRadius: BorderRadius.circular(3)),
                  ),
                ),
              ),
            ),
            Flexible(child: widget.child),
          ],
        ),
      ),
    );
  }
}
