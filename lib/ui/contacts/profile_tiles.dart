// Which quick-action tiles a contact profile shows (chat plan 4.6) and when each is available. Pure Dart apart from the
// symbol constants, so the matrix (type x radio connected x firmware) is a plain unit test.
//
// Rules:
//  * Person: Message, Ping, Route, Stats. Repeater: Dashboard, Ping, Route. Room: Open room, Ping, Route.
//    Sensor: Telemetry, Ping, Route.
//  * A tile whose feature has not landed yet is shown and opens a sheet that says it is coming (never a dead button).
//    Today that is Stats and Telemetry. Route always works: its sheet holds the real "Always search" switch and "Reset route".
//  * A tile that works but needs the radio right now is shown dimmed with a one-line reason.
import '../../chat/models.dart';
import '../../radio/caps.dart';
import '../design/app_symbols.dart';

enum ProfileTileId { message, openRoom, dashboard, telemetry, ping, route, stats }

class ProfileTile {
  final ProfileTileId id;
  final String label;
  final AppSymbol symbol;

  /// False = drawn dimmed; [reason] says why (one short line).
  final bool enabled;
  final String? reason;

  /// True for a tile whose feature is not built yet; it opens a "coming" sheet.
  final bool comingSoon;

  /// True when a long press (and a VoiceOver custom action) offers more choices (Ping: Direct only, hash size).
  final bool hasOptions;
  const ProfileTile(this.id, this.label, this.symbol, {this.enabled = true, this.reason, this.comingSoon = false, this.hasOptions = false});

  @override
  String toString() => '${id.name}${enabled ? '' : '(off: $reason)'}${comingSoon ? '(soon)' : ''}';
}

/// The tiles of [c], in display order.
///
/// [canMessage] / [canAdmin] say whether the host wired a conversation / the remote-admin screen; [connected] is the radio
/// link; [caps] the radio's firmware capabilities.
List<ProfileTile> profileTiles(
  Contact c, {
  required bool connected,
  required RadioCaps caps,
  required bool canMessage,
  required bool canAdmin,
}) {
  const needRadio = 'Connect your radio to use this.';
  final out = <ProfileTile>[];

  ProfileTile ping() {
    // A person is pinged by route discovery (CMD 52); everything else by a trace (works on every firmware).
    final person = c.type == ContactType.companion;
    final fwOk = !person || caps.hasPathDiscovery;
    return ProfileTile(
      ProfileTileId.ping,
      'Ping',
      AppSymbols.antenna,
      enabled: connected && fwOk,
      reason: !connected ? needRadio : (!fwOk ? 'This radio\'s firmware cannot search for routes.' : null),
      hasOptions: !person,
    );
  }

  const route = ProfileTile(ProfileTileId.route, 'Route', AppSymbols.route);

  switch (c.type) {
    case ContactType.companion:
      if (canMessage) out.add(const ProfileTile(ProfileTileId.message, 'Message', AppSymbols.messageFill));
      out.add(ping());
      out.add(route);
      out.add(ProfileTile(ProfileTileId.stats, 'Stats', AppSymbols.chartBar,
          enabled: connected, reason: connected ? null : needRadio, comingSoon: true));
    case ContactType.repeater:
      if (canAdmin) {
        out.add(ProfileTile(ProfileTileId.dashboard, 'Dashboard', AppSymbols.gauge,
            enabled: connected, reason: connected ? null : 'Connect your radio to log in.'));
      }
      out.add(ping());
      out.add(route);
    case ContactType.room:
      if (canMessage) out.add(const ProfileTile(ProfileTileId.openRoom, 'Open room', AppSymbols.bubbles));
      out.add(ping());
      out.add(route);
    case ContactType.sensor:
      out.add(ProfileTile(ProfileTileId.telemetry, 'Telemetry', AppSymbols.thermometer,
          enabled: connected, reason: connected ? null : needRadio, comingSoon: true));
      out.add(ping());
      out.add(route);
  }
  return out;
}
