// Build 78 (builder A): who owns the MeshSonar radio controller (lib/core/msradio/ms_controller.dart).
//
// One controller per connected radio key, made the first time More > Radio is shown with a MeshSonar radio connected, and
// disposed when that radio disconnects (or another radio connects). With a stock MeshCore radio nothing is made: the caps
// gate (RadioCaps.isMeshSonar) runs before any of lib/core/msradio is constructed, so no request goes to any local address.
//
// The app's Simulator (lib/app/build_flags.dart simulatorAvailable, RadioKind.simulator): the simulated MeshSonar radio's
// Wi-Fi side is a FakeMsRadio inside the app (no sockets), signing over the simulated Bluetooth link with the same key.
import 'package:flutter/widgets.dart';

import '../../app/app_state.dart' show AppState, RadioKind;
import '../../app/build_flags.dart' show simulatorAvailable;
import '../../core/msradio/msradio.dart';
import '../../platform/ms_service_browser.dart' show BonsoirMsServiceBrowser;
import '../../platform/secure_storage.dart' show KeychainMsSecretKv;
import '../../radio/caps.dart';
import '../../radio/companion_link.dart' show MeshCoreCompanionLink;
import '../app.dart' show AppScope;

/// What the host needs to know about the connected radio.
class MsRadioLink {
  final RadioCaps caps;

  /// The radio's public key (lower-case 64 hex) from SELF_INFO; null before it is known.
  final String? key;

  /// CMD_SIGN_* over Bluetooth.
  final MsSigner? sign;

  /// The app's Simulator radio.
  final bool simulator;
  const MsRadioLink({required this.caps, this.key, this.sign, this.simulator = false});

  /// The connected radio, or null when none is connected (or the link is not a MeshCore companion link).
  static MsRadioLink? of(AppState s) {
    final link = s.radioSessions.link;
    if (link is! MeshCoreCompanionLink || !link.isConnected) return null;
    return MsRadioLink(
      caps: link.radioCaps,
      key: link.selfPublicKey,
      sign: link.sign,
      simulator: simulatorAvailable && s.radioKind == RadioKind.simulator,
    );
  }
}

class MsRadioHost {
  MsRadioHost._();
  static final MsRadioHost instance = MsRadioHost._();

  /// Tests: the connected radio instead of the app state's link.
  static MsRadioLink? Function(BuildContext context)? debugLink;

  /// Tests: builds the controller (only ever called for a MeshSonar radio with a key).
  static MsRadioController? Function(MsRadioLink link)? debugMake;

  /// How many controllers were made (tests: none for a stock radio).
  int made = 0;

  MsRadioController? _c;
  String? _key;
  AppState? _watched;

  /// The controller of the connected MeshSonar radio, or null (stock radio, no radio, no key yet).
  MsRadioController? of(BuildContext context) {
    final test = debugLink;
    final AppState? s = test == null ? AppScope.maybeOf(context) : null;
    final link = test != null ? test(context) : (s == null ? null : MsRadioLink.of(s));
    final key = link?.key?.toLowerCase();
    if (link == null || !link.caps.isMeshSonar || key == null) {
      if (test == null) _drop();
      return null;
    }
    if (_c != null && _key == key) return _c;
    _drop();
    final c = (debugMake ?? _make)(link);
    if (c == null) return null;
    made++;
    _c = c;
    _key = key;
    if (s != null) {
      _watched = s;
      s.addListener(_check);
    }
    return c;
  }

  static MsRadioController? _make(MsRadioLink link) {
    if (link.simulator) {
      final radio = FakeMsRadio(name: 'MeshSonar Sim')..latency = const Duration(milliseconds: 250);
      return MsRadioController.forCaps(link.caps,
          radioKey: link.key, sign: link.sign, client: radio.client, browser: radio.browser, secrets: InMemoryMsSecretKv());
    }
    return MsRadioController.forCaps(link.caps,
        radioKey: link.key, sign: link.sign, secrets: KeychainMsSecretKv(), browser: const BonsoirMsServiceBrowser());
  }

  /// The radio disconnected or another one connected: the controller goes.
  void _check() {
    final s = _watched;
    if (s == null) return;
    final link = MsRadioLink.of(s);
    if (link == null || !link.caps.isMeshSonar || link.key?.toLowerCase() != _key) _drop();
  }

  void _drop() {
    _watched?.removeListener(_check);
    _watched = null;
    _c?.dispose();
    _c = null;
    _key = null;
  }

  /// Tests.
  void debugReset() {
    _drop();
    made = 0;
    debugLink = null;
    debugMake = null;
  }
}
