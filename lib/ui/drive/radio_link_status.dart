// ONE place that says how the radio link looks on the Drive tab (Andy, Nov 12 2026: "when I collapse it goes to a stupid BT icon.
// We need consistency"). The Dock, the collapsed pill, the mini drive bar and the app-bar connection chip all read this helper, so
// the same state always has the same icon, the same words and the same colour. The mapping table is in docs/FEATURES.md
// ("Radio link: one look on every surface"); a change here is a change to that table and to test/ui/drive/radio_link_status_test.dart.
//
//   state          icon                  action label (Dock, pill)   status label (title, chip, mini bar)   colour
//   notConnected   bluetooth_disabled    Connect radio               Not connected                          muted (textMuted)
//   connecting     spinner               Connecting…                 Connecting…                            warning
//   reconnecting   spinner               Reconnecting…               Reconnecting…                          warning
//   connected      bluetooth_connected   Start drive                 Connected (the chip shows the name)    ok
//   simulator      science (flask)       Start drive                 Simulator                              warning (not a real radio)
// The map capsule is the compact form of the status label: "No radio" / "Connecting…" / "Reconnecting…" / "Radio".
//
// "Reconnecting" is both the mid-drive reconnect (AppState.reconnecting while driving) and the automatic reconnect after launch
// (LaunchReconnect, lib/alerts/launch_reconnect.dart), which AppState does not know about.
import 'package:flutter/material.dart';

import '../../alerts/alerts_runtime.dart';
import '../../app/app_state.dart';
import '../design/tokens.dart' show AppColors;

enum RadioLink { notConnected, connecting, reconnecting, connected, simulator }

class RadioLinkStatus {
  final RadioLink link;
  const RadioLinkStatus(this.link);

  static const String connectLabel = 'Connect radio';
  static const String connectingLabel = 'Connecting…';
  static const String reconnectingLabel = 'Reconnecting…';
  static const String startLabel = 'Start drive';

  /// The state of [s]'s radio link. [launchReconnecting] defaults to the automatic reconnect that runs after launch.
  factory RadioLinkStatus.of(AppState s, {bool? launchReconnecting}) {
    final launch = launchReconnecting ?? launchReconnectActive();
    if (s.connecting) return RadioLinkStatus(launch ? RadioLink.reconnecting : RadioLink.connecting);
    if (s.reconnecting && s.driving) return const RadioLinkStatus(RadioLink.reconnecting);
    if (s.connected) return RadioLinkStatus(s.radioKind == RadioKind.simulator ? RadioLink.simulator : RadioLink.connected);
    if (launch) return const RadioLinkStatus(RadioLink.reconnecting);
    return const RadioLinkStatus(RadioLink.notConnected);
  }

  /// True while the automatic reconnect after launch (or a foreground return) is working.
  static bool launchReconnectActive() => AlertsHost.runtime.value?.reconnect?.active ?? false;

  /// What to rebuild on: the app state and the automatic reconnect.
  static Listenable listenable(AppState s) => Listenable.merge([s, AlertsHost.runtime, AlertsHost.runtime.value?.reconnect]);

  /// True for the two "working on it" states (a spinner replaces the icon).
  bool get working => link == RadioLink.connecting || link == RadioLink.reconnecting;
  bool get connected => link == RadioLink.connected || link == RadioLink.simulator;

  /// null = a spinner.
  IconData? get icon => switch (link) {
        RadioLink.notConnected => Icons.bluetooth_disabled_rounded,
        RadioLink.connecting || RadioLink.reconnecting => null,
        RadioLink.connected => Icons.bluetooth_connected_rounded,
        RadioLink.simulator => Icons.science_rounded,
      };

  /// The one wording for the affordance on every surface.
  String get label => switch (link) {
        RadioLink.notConnected => connectLabel,
        RadioLink.connecting => connectingLabel,
        RadioLink.reconnecting => reconnectingLabel,
        RadioLink.connected || RadioLink.simulator => startLabel,
      };

  /// The status wording (a chip or a title that says where the link stands, not what to tap).
  String get statusLabel => switch (link) {
        RadioLink.notConnected => 'Not connected',
        RadioLink.connecting => connectingLabel,
        RadioLink.reconnecting => reconnectingLabel,
        RadioLink.connected => 'Connected',
        RadioLink.simulator => 'Simulator',
      };

  Color color(AppColors c) => switch (link) {
        RadioLink.notConnected => c.textMuted,
        RadioLink.connecting || RadioLink.reconnecting || RadioLink.simulator => c.warning,
        RadioLink.connected => c.ok,
      };

  /// The icon, or the spinner for the working states, at [size] in [color] (default: this state's colour).
  Widget leading(BuildContext context, {double size = 20, Color? color}) {
    final col = color ?? this.color(AppColors.fromTheme(Theme.of(context)));
    final i = icon;
    if (i == null) return SizedBox(width: size, height: size, child: CircularProgressIndicator(strokeWidth: size > 16 ? 2.5 : 2, color: col));
    return Icon(i, size: size, color: col);
  }
}
