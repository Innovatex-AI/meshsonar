// Builds the app's observer engine (lib/core/observer_engine.dart) for lib/app/wiring.dart. This is the one place the MQTT
// engine is chosen: the wiring calls [createObserverEngine] and never names an engine class, so the MQTT work
// (lib/core/mqtt/**) plugs in by changing this function only.
//
// Release 0.38 foundation: the MQTT engine is not in this build yet, so the factory returns [NoObserverEngine] (every
// feed slot reads Off and Test says feeds are not available). MeshSonar's own HTTPS feed does not go through here.
// Pure Dart: no Flutter imports.
import '../../chat/secret_store.dart';
import '../observer_engine.dart';

/// [secrets] holds password-auth slots' passwords (Keychain/Keystore; `MqttSlotSettings.secretRef`). [clock] is UTC
/// wall time for token lifetimes.
ObserverEngine createObserverEngine({required SecretStore secrets, required DateTime Function() clock}) =>
    const NoObserverEngine();
