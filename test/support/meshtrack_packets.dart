// Real encrypted MeshTrack packets for the privacy pin tests (MT-8): a GRP_TXT on a private group channel, built with the
// shipped channel crypto (lib/radio/packet.dart buildGroupTextPayload: AES-128 + MAC under the channel key).
import 'dart:typed_data';

import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';

/// The "Saturday crew" test group key (fixed, 16 bytes; the simulator's friends use the same one).
final Uint8List meshTrackTestKey = Uint8List.fromList(List<int>.generate(16, (i) => 0x51 + i));

/// A MeshTrack position as it goes on air.
const String meshTrackTestPosition = 'MT1 @87G8Q2X5+7F2 s34 c270';

/// A flood GRP_TXT on [key] carrying `name: text`, heard after [pathLen] repeaters (0 = direct; > 0 = for our own send,
/// heard back through the mesh).
RxPacket meshTrackRx({
  List<int>? key,
  int pathLen = 0,
  String name = 'KE4BFI',
  String text = meshTrackTestPosition,
  int timestamp = 1763300000,
  DateTime? at,
}) =>
    RxPacket(
      at: at ?? DateTime.utc(2026, 11, 16, 18),
      raw: MeshPacket(
        header: makeHeader(RouteType.flood, PayloadType.grpTxt),
        pathLenByte: pathLen,
        path: [for (var i = 0; i < pathLen; i++) Uint8List.fromList([0xa1 + i])],
        payload: buildGroupTextPayload(key ?? meshTrackTestKey, timestamp, name, text),
      ).toBytes(),
      snrDb: 6.5,
      rssiDbm: -97,
    );
