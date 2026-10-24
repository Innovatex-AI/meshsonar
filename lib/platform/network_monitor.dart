// Network kind for the offline-pack download policy (Wi-Fi only), from connectivity_plus (NWPathMonitor on iOS,
// ConnectivityManager on Android). Nothing is sent anywhere: it only reads the OS's own interface state.
// Limits: a phone on a personal hotspot's Wi-Fi reports "wifi" (connectivity_plus does not expose iOS isExpensive).
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../core/offline_packs.dart';

/// Maps connectivity_plus results onto the policy's kinds. Wi-Fi or Ethernet anywhere in the list wins (unmetered),
/// then mobile; "none" alone is offline; anything else (VPN only, Bluetooth, satellite) is unknown and treated
/// like cellular by the policy (the user is asked).
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
      return NetworkKind.unknown; // plugin missing (desktop test host): ask rather than assume Wi-Fi
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
