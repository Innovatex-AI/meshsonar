// "Replay on map" (build 77, Round 2 N-U1): the one entry into Network > Live for ONE reception of a packet. The packet page's
// "Who heard it" gives every copy (one observation) a "Replay on map" button; it calls [openLiveReplay], which opens Network >
// Live with only that copy drawn and animated from the sender through each hop to that observer, with "Play again" on the
// drawn packet's panel.
//
// The observation id travels beside the existing "show this packet on the live map" request (NetworkRequest.mapPacket), so old
// requests, deep links and the website's replay links are unchanged: [LiveReplayRequests] holds it until the Live map that opens
// for the packet takes it.
import 'package:flutter/widgets.dart';

import '../packets/packet_detail_screen.dart' show showPacketOnLiveMap;

/// The observation ids waiting for the Live map that is opening for their packet (hash, lower case).
abstract final class LiveReplayRequests {
  static final Map<String, String> _pending = {};

  /// Remembers that the Live map opening for [packetHash] should draw only [observationId].
  static void put(String packetHash, String observationId) => _pending[packetHash.toLowerCase()] = observationId;

  /// The observation id asked for [packetHash], once (null when none).
  static String? take(String packetHash) => _pending.remove(packetHash.toLowerCase());

  @visibleForTesting
  static void clear() => _pending.clear();
}

/// Opens Network > Live with only the copy of [packetHash] heard as [observationId] drawn, animated sender -> each hop ->
/// observer, with "Play again". Closes the pages above the Network tab, as "Show the path on the live map" does.
void openLiveReplay(BuildContext context, {required String packetHash, required String observationId}) {
  LiveReplayRequests.put(packetHash, observationId);
  showPacketOnLiveMap(context, hash: packetHash);
}
