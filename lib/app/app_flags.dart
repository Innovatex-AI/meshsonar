// Feature flags: the set-path write gate and MeshTrack. The Chat redesign flag is gone (plan D23, removed in Chat WP15) and so is
// the Drive redesign switch (build 70, item 70-2): the map with the bottom panel is the only Drive screen, the old footer layout
// and its More > Developer switch were deleted. Older builds saved those switches in `redesign_flags.json`; [AppFlags.load]
// still accepts that file and ignores every key in it (a saved `driveRedesign:false` or `chatRedesign` changes nothing).
import 'dart:io';

import 'package:flutter/foundation.dart';

abstract final class AppFlags {
  /// The set-path radio write (Chat WP7): ADD_UPDATE_CONTACT with a chosen route ("Choose repeaters yourself" > Save) and the
  /// outbox rewrite of a path the radio forgot in Keep this route. Hidden until Andy's real-radio test passes (spikes S3/S13,
  /// HANDOFF checklist). Everything else about routes (display, mode, discovery, trace, ping, reset) is live.
  static const bool routeWriteVerified = false;

  /// MeshTrack (friends on the map over a private channel; meshsonar-infra docs/planning/meshtrack-plan-2026-11-16.md section
  /// 11). ON in build 67 TestFlight; a build made with `--dart-define=MESHSONAR_MESHTRACK=false` hides the chip, the Friends
  /// layer and the settings section and constructs nothing (`AppState.meshTrack` is null).
  static const bool meshTrack = bool.fromEnvironment('MESHSONAR_MESHTRACK', defaultValue: true);

  /// Tests only: overrides [meshTrack] for AppStates created afterwards (null = the build's value).
  @visibleForTesting
  static bool? debugMeshTrack;

  /// What AppState reads: [debugMeshTrack] in tests, else [meshTrack].
  static bool get meshTrackOn => debugMeshTrack ?? meshTrack;

  /// Reads `redesign_flags.json` from older builds. Nothing in it is a live flag any more, so every key is ignored (a missing or
  /// damaged file is fine too); kept so the startup call stays harmless.
  static Future<void> load(File? file) async {}
}
