// The phone's network kind (Wi-Fi, cellular, none), from connectivity_plus (NWPathMonitor on iOS,
// ConnectivityManager on Android). The map closes its tile gate while the phone has no connection. Nothing is sent anywhere: it only reads the OS's own interface state.
// Limits: a phone on a personal hotspot's Wi-Fi reports "wifi" (connectivity_plus does not expose iOS isExpensive).
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../core/network_kind.dart';

/// Maps connectivity_plus results onto [NetworkKind]. Wi-Fi or Ethernet anywhere in the list wins, then mobile; "none"
/// alone is offline; anything else (VPN only, Bluetooth, satellite) is unknown, which counts as online.
NetworkKind networkKindOf(List<ConnectivityResult> r) {
  if (r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet)) return NetworkKind.wifi;
  if (r.contains(ConnectivityResult.mobile)) return NetworkKind.cellular;
  if (r.isEmpty || r.every((c) => c == ConnectivityResult.none)) return NetworkKind.offline;
  return NetworkKind.unknown;
}

class ConnectivityNetworkMonitor implements NetworkMonitor {
  final Connectivity _c = Connectivity();

  @override
  Future<NetworkKind> current() async {
    try {
      return networkKindOf(await _c.checkConnectivity());
    } catch (_) {
      return NetworkKind.unknown; // plugin missing (desktop test host): not known, so not offline
    }
  }

  @override
  Stream<NetworkKind> get changes {
    try {
      return _c.onConnectivityChanged.map(networkKindOf).handleError((Object _) {});
    } catch (_) {
      return const Stream.empty();
    }
  }
}
