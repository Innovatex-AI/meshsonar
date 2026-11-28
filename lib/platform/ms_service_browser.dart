// The real DNS-SD browser for MeshSonar radios (`_meshsonar._tcp`, lib/core/msradio/ms_discovery.dart MsServiceBrowser),
// on Bonjour (iOS / macOS) and Android NSD through package:bonsoir (MIT). iOS needs NSBonjourServices `_meshsonar._tcp` and
// NSLocalNetworkUsageDescription in Info.plist (the first browse shows the Local Network prompt); Android needs
// CHANGE_WIFI_MULTICAST_STATE (bonsoir's manifest adds it). Only ever constructed for a MeshSonar radio.
import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import '../core/msradio/ms_discovery.dart';

class BonsoirMsServiceBrowser implements MsServiceBrowser {
  const BonsoirMsServiceBrowser();

  @override
  Future<List<MsFoundService>> browse(String type, {Duration timeout = const Duration(seconds: 5)}) async {
    final found = <String, MsFoundService>{};
    final discovery = BonsoirDiscovery(type: type, printLogs: false);
    StreamSubscription<BonsoirDiscoveryEvent>? sub;
    try {
      await discovery.initialize();
      sub = discovery.eventStream?.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            // TXT and addresses come with the resolve
            unawaited(Future.sync(() => event.service.resolve(discovery.serviceResolver)).catchError((Object _) {}));
          case BonsoirDiscoveryServiceResolvedEvent():
            found[event.service.name] = _toFound(event.service);
          case BonsoirDiscoveryServiceUpdatedEvent():
            found[event.service.name] = _toFound(event.service);
          case BonsoirDiscoveryServiceLostEvent():
            found.remove(event.service.name);
          default:
            break;
        }
      });
      await discovery.start();
      await Future<void>.delayed(timeout);
    } catch (_) {
      // no DNS-SD here (permission refused, Wi-Fi off): discovery goes on with the other steps
    } finally {
      await sub?.cancel();
      try {
        await discovery.stop();
      } catch (_) {}
    }
    return found.values.toList();
  }

  static MsFoundService _toFound(BonsoirService s) => MsFoundService(
        name: s.name,
        addresses: s.hostAddresses,
        hostname: s.hostname,
        port: s.port,
        txt: {for (final e in s.attributes.entries) e.key.toLowerCase(): e.value},
      );
}
