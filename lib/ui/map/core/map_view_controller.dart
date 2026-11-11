// MapViewController: the one camera for the whole app session (Drive plan 9.1 / 9.4 step 5). It owns the flutter_map
// [MapController], the follow state ([CameraFollow]) and the last camera, so the in-tab map and the "full screen" map are
// the same camera: toggling the panel state, a layout change (rotate, large text) or a rebuild of the map widget never loses
// the view. [DriveMapModel] owns one for the app session; a map with no host (drive detail, contact map...) makes its own.
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../../core/camera_follow.dart';

class MapViewController {
  /// The flutter_map controller. Attached to whichever [FlutterMap] is mounted; there is only ever one in the tree.
  final MapController map = MapController();

  /// Follow state: the camera drives itself until the person moves the map (lib/core/camera_follow.dart).
  final CameraFollow follow = CameraFollow();

  /// While following: where the puck sits on the screen (offset from the map widget's centre, screen pixels). Null = take it
  /// from where the puck is now on the next follow frame. Cleared when the person moves the map; Recenter sets the middle.
  ({double dx, double dy})? followOffset;

  /// The one zoom-in to street level on the first GPS fix (an overview map) has been done; never again this session.
  bool firstFixZoomDone = false;

  /// Heading-up rotation, for the compass button.
  final ValueNotifier<double> rotation = ValueNotifier<double>(0);

  /// The zoom the person chose (the speed-based offset is added on top of it) and the current speed offset.
  double userZoom = 14;
  double zoomOffset = 0;

  /// True once a map has mounted and applied its starting state (follow flag): later mounts keep the follow state as it is.
  bool initialised = false;

  bool _disposed = false;
  bool get disposed => _disposed;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    rotation.dispose();
    follow.dispose();
    map.dispose();
  }
}
