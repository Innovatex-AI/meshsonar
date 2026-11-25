// What kind of network the phone is on, as the OS reports it. Pure Dart; the platform side is
// lib/platform/network_monitor.dart. The map uses it to stop asking for tiles the moment the phone has no connection.
enum NetworkKind { wifi, cellular, offline, unknown }

/// Platform-injected connectivity (tests fake it).
abstract class NetworkMonitor {
  Future<NetworkKind> current();
  Stream<NetworkKind> get changes;
}
