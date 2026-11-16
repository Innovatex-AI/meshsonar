// How the MeshTrack screens reach the app: the one MeshTrackService (core), the group operations (app wiring), the units,
// the phone's position, my radio name and the chat controller. The app builds it from AppState; widget tests put a
// [MeshTrackScope] above the screen instead. Null = MeshTrack is off in this build (AppFlags.meshTrack false): the chip,
// the Settings section and the channel-detail row are then hidden.
import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

import '../../app/app_state.dart';
import '../../app/chat_controller.dart';
import '../../app/chat_wiring.dart';
import '../../core/meshtrack/meshtrack_service.dart';
import '../../core/units.dart';
import '../app.dart';
import '../map/main_map_focus.dart';
import '../nodes/node_actions.dart' show shellControllerFor;
import 'meshtrack_copy.dart' show MtLatLon;
import 'mt_contract_stub.dart';

export '../../core/meshtrack/meshtrack_service.dart';
export 'meshtrack_copy.dart' show MtLatLon;
export 'mt_contract_stub.dart';

class MeshTrackBinding {
  final MeshTrackService service;
  final MeshTrackGroupOps ops;
  final Units units;

  /// The phone's best-known position (distance and compass point to friends); null when never located.
  final MtLatLon? Function() here;

  /// My radio's name (the default group name, and who a request is for).
  final String? Function() selfName;

  /// The chat controller (Message, Make room); null before chat is up.
  final ChatController? Function() chat;

  /// Row tap in the Group sheet: centre the Drive map on a friend. Null = [centreDriveMap].
  final void Function(BuildContext context, double lat, double lon)? onCentre;
  const MeshTrackBinding({
    required this.service,
    required this.ops,
    this.units = Units.metric,
    required this.here,
    required this.selfName,
    required this.chat,
    this.onCentre,
  });
}

/// Tests (and previews) provide the binding directly.
class MeshTrackScope extends InheritedWidget {
  final MeshTrackBinding binding;
  const MeshTrackScope({super.key, required this.binding, required super.child});

  @override
  bool updateShouldNotify(MeshTrackScope old) => !identical(old.binding, binding);
}

abstract final class MeshTrackUi {
  /// The binding for the screen at [context]: a [MeshTrackScope] above it, else the app's ([forState]).
  static MeshTrackBinding? of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<MeshTrackScope>();
    if (scope != null) return scope.binding;
    final s = AppScope.maybeOf(context);
    return s == null ? null : forState(s);
  }

  /// Same as [of] without listening (button handlers).
  static MeshTrackBinding? read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<MeshTrackScope>();
    if (scope != null) return scope.binding;
    final s = context.getInheritedWidgetOfExactType<AppScope>()?.notifier;
    return s == null ? null : forState(s);
  }

  /// The app's binding, from AppState (`meshTrack` / `meshTrackGroups` of the wiring, contract section "AppState").
  /// Tests that build the whole app set [debugForState].
  static MeshTrackBinding? forState(AppState s) => debugForState?.call(s) ?? _fromAppState(s);

  static MeshTrackBinding? Function(AppState s)? debugForState;

  // Until lib/app/meshtrack_wiring.dart is merged AppState has no MeshTrack getters: MeshTrack stays off.
  static MeshTrackBinding? _fromAppState(AppState s) => null;

  /// Builds the binding parts that come from AppState and the chat wiring (used by the AppState resolver).
  static MeshTrackBinding bindingFor(AppState s, MeshTrackService service, MeshTrackGroupOps ops) => MeshTrackBinding(
        service: service,
        ops: ops,
        units: s.units,
        here: () {
          final f = s.phoneFix?.fix;
          return f == null ? null : (lat: f.lat, lon: f.lon);
        },
        selfName: () => s.selfInfo?.name,
        chat: () => ChatWiring.controller.value,
      );
}

/// Row tap = centre the Drive tab's map on [lat], [lon] (the same request the chat "Open on map" uses). The sheet over it is
/// closed so the friend is in view.
void centreDriveMap(BuildContext context, double lat, double lon) {
  final shell = shellControllerFor(context);
  Navigator.maybeOf(context, rootNavigator: true)?.popUntil((r) => r.isFirst);
  MainMapFocus.request(LatLng(lat, lon), 15);
  shell?.openDrive();
}
