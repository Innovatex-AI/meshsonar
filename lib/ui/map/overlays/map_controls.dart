// MapControlColumn (Drive plan 5.5): the thumb-zone column on the right edge. 48 pt round buttons on an opaque surface with a 1 px
// outline, 12 pt gaps, FIXED SLOTS measured from the bottom: Recenter / heading at the bottom, Layers above it, Compass above that.
// A hidden button keeps its space (fade, no reflow), so Layers never moves under the thumb. Nothing is FittedBox-scaled here; the
// host only scales the whole column on a pane too short to hold it (phone landscape, handled by WP3c).
import 'package:flutter/material.dart';

import '../../design/tokens.dart';

const double kControlButton = 48;
const double kControlGap = 12;

/// Where the single Recenter / heading button is: not following (tap = follow, north-up), following north-up (tap = heading-up),
/// following heading-up (tap = north-up). Apple Maps' three-state location button.
enum RecenterMode { notFollowing, followingNorthUp, followingHeadingUp }

class MapControlButton extends StatelessWidget {
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final bool visible;
  const MapControlButton({super.key, required this.icon, required this.label, required this.onPressed, this.visible = true});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.fromTheme(Theme.of(context));
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: IgnorePointer(
        ignoring: !visible,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          onTap: visible ? onPressed : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: Container(
              width: kControlButton,
              height: kControlButton,
              decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle, border: Border.all(color: c.outline)),
              child: Center(child: IconTheme(data: IconThemeData(color: c.textPrimary, size: 24), child: icon)),
            ),
          ),
        ),
      ),
    );
  }
}

class MapControlColumn extends StatelessWidget {
  /// Layers is always present.
  final VoidCallback onLayers;

  /// The compass slot: shown only while the bearing is not north-up (and the map is rotatable).
  final bool compassVisible;
  final double compassRotation;
  final VoidCallback onCompass;

  /// The recenter slot: shown when a position exists.
  final bool recenterVisible;
  final RecenterMode recenterMode;
  final VoidCallback onRecenter;
  const MapControlColumn({
    super.key,
    required this.onLayers,
    required this.compassVisible,
    required this.compassRotation,
    required this.onCompass,
    required this.recenterVisible,
    required this.recenterMode,
    required this.onRecenter,
  });

  static String recenterLabel(RecenterMode m) => switch (m) {
        RecenterMode.notFollowing => 'Follow my location',
        RecenterMode.followingNorthUp => 'Following, north up. Tap for heading up',
        RecenterMode.followingHeadingUp => 'Following, heading up. Tap for north up',
      };

  @override
  Widget build(BuildContext context) {
    final c = AppColors.fromTheme(Theme.of(context));
    // Follows the system text size to 1.6x only through labels; the glyphs are fixed, so the slots never move.
    return Column(
      key: const Key('map-control-column'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        MapControlButton(
          key: const Key('map-compass'),
          visible: compassVisible,
          label: 'Compass. Turn map north up',
          onPressed: onCompass,
          icon: Transform.rotate(angle: compassRotation * 3.141592653589793 / 180, child: Icon(Icons.navigation_rounded, color: c.danger)),
        ),
        const SizedBox(height: kControlGap),
        MapControlButton(key: const Key('drive-map-layers'), label: 'Map layers', onPressed: onLayers, icon: const Icon(Icons.layers_rounded)),
        const SizedBox(height: kControlGap),
        MapControlButton(
          key: const Key('map-recenter'),
          visible: recenterVisible,
          label: recenterLabel(recenterMode),
          onPressed: onRecenter,
          icon: Icon(switch (recenterMode) {
            RecenterMode.notFollowing => Icons.near_me_outlined,
            RecenterMode.followingNorthUp => Icons.near_me,
            RecenterMode.followingHeadingUp => Icons.navigation_rounded,
          }),
        ),
      ],
    );
  }
}
