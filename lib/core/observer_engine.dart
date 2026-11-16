// The observer-engine slot (release 0.38, observer-everywhere-mqtt-plan-2026-11-15.md section 3.4): what AppState hands
// to an engine that feeds outside MQTT sites from this phone. AppState owns the rules (lib/app/observer_wiring.dart):
//   * [ObserverEngine.update] runs whenever sharing, the radio link, the app's foreground state or the slots change;
//   * [ObserverEngine.onPublicPacket] gets ONLY packets that already passed the observer privacy filter
//     (TelemetryRecord.fromRx: ADVERT, TRACE, PATH, Public / proven `#name` group packets), and only while this phone is
//     an observer (`AppState.observerSharing`). The filter is the single gate; an engine never sees anything else.
// MeshSonar's own HTTPS feed (lib/core/telemetry_uploader.dart) is not an engine and does not depend on one.
// The real engine is built by lib/core/mqtt/observer_engine_factory.dart; [NoObserverEngine] is the engine of tests and
// of builds without MQTT.
// Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:typed_data';

import '../radio/radio_api.dart' show RxPacket;
import 'mqtt_contract.dart';
import 'telemetry.dart' show TelemetryRecord;

/// The connected radio signs [data] with its own identity key (CMD_SIGN_START / DATA / FINISH): 64-byte Ed25519
/// signature. Throws when the radio is busy or its firmware cannot sign.
typedef ObserverSigner = Future<Uint8List> Function(Uint8List data);

/// Everything an engine needs to decide what to run.
class ObserverEngineState {
  /// This phone is an observer: the master switch (Share with MeshSonar) is on, a real radio, the disclosure was seen and
  /// the driver key is approved (`AppState.observerSharing`).
  final bool sharing;

  /// A radio link is up.
  final bool connected;

  /// The app is in front (iOS suspends sockets behind; an engine says "paused in background" honestly).
  final bool foreground;

  /// The connected radio's public key, lower-case hex (64 chars); null when none.
  final String? radioPublicKey;

  /// The radio's model and firmware for a status message; null when unknown.
  final String? radioModel;
  final String? firmware;

  /// The region the phone is in (code, e.g. `CMH`); its airport code is the default topic IATA.
  final String? regionCode;

  /// The MQTT feed slots from Settings (each off unless turned on).
  final List<MqttSlotSettings> slots;

  /// Signs with the connected radio; null when no radio can sign.
  final ObserverSigner? sign;

  const ObserverEngineState({
    this.sharing = false,
    this.connected = false,
    this.foreground = true,
    this.radioPublicKey,
    this.radioModel,
    this.firmware,
    this.regionCode,
    this.slots = const [],
    this.sign,
  });

  /// Feeds may run.
  bool get active => sharing && connected;
}

/// What one slot is doing, for Settings > Observer.
enum ObserverFeedState {
  off('Off'),
  waitingForRadio('Waiting for radio'),
  connecting('Connecting'),
  connected('Connected'),
  authFailed('Auth failed'),
  radioCantSign("Radio can't sign"),
  pausedInBackground('Paused in background'),
  error('Error');

  final String label;
  const ObserverFeedState(this.label);
}

class ObserverFeedStatus {
  final String slotId;
  final ObserverFeedState state;

  /// Packets published in the last 24 hours.
  final int sent24h;

  /// The last error in plain words; null when none.
  final String? lastError;
  final DateTime? at;
  const ObserverFeedStatus({required this.slotId, required this.state, this.sent24h = 0, this.lastError, this.at});
}

abstract class ObserverEngine {
  /// The state changed (also called once right after the app loads). Idempotent: the same state twice changes nothing.
  void update(ObserverEngineState state);

  /// One packet that passed the privacy filter while this phone is an observer. [rx] carries its raw bytes, SNR and
  /// RSSI; [record] is the filter's verdict (type, route, channel). Never blocks: engines queue and drop the oldest.
  void onPublicPacket(TelemetryRecord record, RxPacket rx);

  /// Per slot status, in slot order.
  List<ObserverFeedStatus> get statuses;

  /// Emits whenever [statuses] change.
  Stream<List<ObserverFeedStatus>> get statusChanges;

  /// Settings > Observer > Test: connect [slot] once and publish a status message only (never a packet).
  Future<ObserverFeedStatus> test(MqttSlotSettings slot);

  Future<void> dispose();
}

/// The engine that runs nothing: every slot reads Off. Used in tests and wherever no MQTT engine is built.
class NoObserverEngine implements ObserverEngine {
  const NoObserverEngine();

  @override
  void update(ObserverEngineState state) {}

  @override
  void onPublicPacket(TelemetryRecord record, RxPacket rx) {}

  @override
  List<ObserverFeedStatus> get statuses => const [];

  @override
  Stream<List<ObserverFeedStatus>> get statusChanges => const Stream.empty();

  @override
  Future<ObserverFeedStatus> test(MqttSlotSettings slot) async =>
      ObserverFeedStatus(slotId: slot.id, state: ObserverFeedState.error, lastError: 'MQTT feeds are not available in this build.');

  @override
  Future<void> dispose() async {}
}
