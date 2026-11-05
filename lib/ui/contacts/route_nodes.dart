// Turns a route (hash hops) into HopChain nodes: repeater names where exactly one known repeater has that hash, "unknown"
// otherwise. Shared by the Route screen, the ping sheet and Message details.
import 'package:flutter/widgets.dart';

import '../../chat/models.dart';
import '../../radio/path_tools.dart';
import '../design/hop_chain.dart';
import '../tools/tools_host.dart';
import '../app.dart';
import '../../radio/tools/radio_tools.dart';

/// Name of the one repeater/room whose key starts with [hash]; null when none or several share it.
String? repeaterNameForHash(String hash, Iterable<Contact> repeaters) {
  final hits = [
    for (final r in repeaters)
      if ((r.type == ContactType.repeater || r.type == ContactType.room) && r.publicKey.startsWith(hash.toLowerCase())) r
  ];
  return hits.length == 1 ? hits.first.displayName : null;
}

/// Nodes "You > hops > [targetName]". [snr] has one value per link (hops + 1) when known (a trace).
List<HopNode> routeNodes({
  required String targetName,
  required PathRoute? route,
  Iterable<Contact> repeaters = const [],
  List<double> snr = const [],
  String youLabel = 'You',
}) {
  final hops = route?.hexHops ?? const <String>[];
  LinkQuality? q(int i) => i < snr.length ? linkQualityOfSnr(snr[i]) : null;
  final nodes = <HopNode>[HopNode(youLabel, linkToNext: q(0))];
  for (var i = 0; i < hops.length; i++) {
    final name = repeaterNameForHash(hops[i], repeaters);
    nodes.add(HopNode(name ?? hops[i], detail: hops[i], unknown: name == null, linkToNext: q(i + 1)));
  }
  nodes.add(HopNode(targetName));
  return nodes;
}

/// The radio tools of the connected radio (null when none), looked up the same way the Stats sheet does.
RadioTools? radioToolsOf(BuildContext context) {
  final scope = context.getInheritedWidgetOfExactType<ToolsHostScope>();
  if (scope != null) return scope.host.tools;
  final app = AppScope.maybeOf(context);
  return app == null ? null : AppStateToolsHost.of(app).tools;
}

