// Feedback moments on the map (build 77, Round 1 N7): a brief flash when a new cell of the drive is painted, a ring (and a
// success tap) the first time a repeater is heard on a drive, and a short fade when a layer or the base map changes. Under
// Reduce Motion nothing moves: the flash and the ring are not drawn and layers appear at once (the haptic still plays).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// How long a map layer takes to fade in when it is switched on or the base map changes.
const Duration kMapFadeIn = Duration(milliseconds: 150);

/// Fades its child in once, when it is first built (a layer switched on, a new base map). Keyed by the caller per layer.
class MapFadeIn extends StatelessWidget {
  final Widget child;
  const MapFadeIn({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: kMapFadeIn,
      // Always an Opacity (1.0 paints the child directly, no layer), so the child's state survives the end of the fade.
      builder: (context, v, child) => Opacity(opacity: v, child: child),
      child: child,
    );
  }
}

/// One new cell's flash: its outline drawn bright and fading out over 700 ms.
class NewCellFlash {
  final String id;
  final List<LatLng> outline;
  const NewCellFlash(this.id, this.outline);
}

/// The flashes of the cells painted since the last frames. Each fades out on its own, then draws nothing.
class NewCellFlashLayer extends StatelessWidget {
  final List<NewCellFlash> flashes;
  final Color color;
  const NewCellFlashLayer({super.key, required this.flashes, required this.color});

  @override
  Widget build(BuildContext context) {
    if (flashes.isEmpty || MediaQuery.disableAnimationsOf(context)) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final f in flashes)
          TweenAnimationBuilder<double>(
            key: ValueKey('cell-flash-${f.id}'),
            tween: Tween(begin: 1, end: 0),
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeOut,
            builder: (context, a, _) => a <= 0
                ? const SizedBox.shrink()
                : PolygonLayer(polygons: [
                    Polygon(points: f.outline, color: color.withValues(alpha: 0.35 * a), borderColor: color.withValues(alpha: a), borderStrokeWidth: 2.5),
                  ]),
          ),
      ],
    );
  }
}

/// A repeater heard for the first time on this drive: one expanding ring at its place.
class FirstHeard {
  final String key;
  final LatLng at;
  const FirstHeard(this.key, this.at);
}

class FirstHeardRingLayer extends StatelessWidget {
  final List<FirstHeard> rings;
  final Color color;
  const FirstHeardRingLayer({super.key, required this.rings, required this.color});

  @override
  Widget build(BuildContext context) {
    if (rings.isEmpty || MediaQuery.disableAnimationsOf(context)) return const SizedBox.shrink();
    return MarkerLayer(
      markers: [
        for (final r in rings)
          Marker(
            point: r.at,
            width: 80,
            height: 80,
            child: IgnorePointer(
              child: TweenAnimationBuilder<double>(
                key: ValueKey('first-heard-${r.key}'),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 1200),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) => v >= 1
                    ? const SizedBox.shrink()
                    : Center(
                        child: Container(
                          width: 24 + 52 * v,
                          height: 24 + 52 * v,
                          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color.withValues(alpha: 1 - v), width: 3)),
                        ),
                      ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The success tap of a first-heard repeater (tests count it).
@visibleForTesting
int debugFirstHeardTaps = 0;

void firstHeardTap() {
  debugFirstHeardTaps++;
  HapticFeedback.mediumImpact();
}

/// A one-time tip on the map (Round 1 N8), in the toast slot under the banner: one plain line and a close button.
class MapTipPill extends StatelessWidget {
  final String text;
  final VoidCallback onClose;
  const MapTipPill({super.key, required this.text, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.inverseSurface,
      borderRadius: BorderRadius.circular(18),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Semantics(liveRegion: true, child: Text(text, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onInverseSurface)))),
            IconButton(
              key: const Key('map-tip-close'),
              tooltip: 'Close tip',
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: Icon(Icons.close_rounded, size: 18, color: t.colorScheme.onInverseSurface),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
