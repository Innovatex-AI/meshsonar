// Builds the app's observer engine (lib/core/observer_engine.dart) for lib/app/wiring.dart. This is the one place the MQTT
// engine is chosen: the wiring calls [createObserverEngine] and never names an engine class.
//
// Release 0.38 (OE2): the MQTT engine (lib/core/mqtt/mqtt_engine.dart) feeds the person's MQTT feed slots over wss with
// radio-signed logins. MeshSonar's own HTTPS feed does not go through here.
// Pure Dart: no Flutter imports.
import '../../chat/secret_store.dart';
import '../observer_engine.dart';
import 'mqtt_engine.dart';

/// [secrets] holds password-auth slots' passwords (Keychain/Keystore; `MqttSlotSettings.secretRef`). [clock] is UTC
/// wall time for token lifetimes.
ObserverEngine createObserverEngine({required SecretStore secrets, required DateTime Function() clock}) =>
    MqttObserverEngine(secrets: secrets, clock: clock);
