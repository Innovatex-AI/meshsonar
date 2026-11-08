// Copies of channel messages heard on the air (chat + radio round, CR3).
//
// The radio pushes every packet it hears (PUSH_CODE_LOG_RX_DATA, 0x88) with SNR and RSSI. A group text (GRP_TXT) on one of
// our channels can be decrypted with that channel's key (the same check the wardrive echo matcher does, packet.dart
// classifyEcho), which gives the sender timestamp and text, and so the chat message it is a copy of. For a message we sent
// that copy is a repeat ("heard by N", which repeater relayed it); for one we received it is one of the paths it came by.
// ChatService attaches it (InboundRepeatHeard). The wardrive (System) channel is skipped: its pings are not chat messages.
import 'dart:typed_data';

import '../radio/packet.dart' show MeshPacket, PayloadType, decryptGroupText;
import '../radio/radio_api.dart' show RxPacket;
import 'models.dart';
import 'radio_bridge.dart';

class ChannelCopyListener {
  final String Function() radioId;

  /// Channels on the radio for [radioId] (slot set), with their on-air hash byte.
  final List<Channel> Function(String radioId) channels;
  final Future<Uint8List?> Function(Channel c) secretOf;
  final void Function(InboundRepeatHeard e) emit;

  /// Secrets by `secretRef:hashByte`, so a re-keyed channel is read again.
  final Map<String, Uint8List?> _secrets = {};

  ChannelCopyListener({required this.radioId, required this.channels, required this.secretOf, required this.emit});

  Future<void> onPacket(RxPacket rx) async {
    final pkt = MeshPacket.tryParse(rx.raw);
    if (pkt == null || pkt.payloadType != PayloadType.grpTxt || !pkt.isFlood || pkt.payload.isEmpty) return;
    final id = radioId();
    final hash = pkt.payload[0];
    for (final ch in channels(id)) {
      if (ch.slot == null || ch.hashByte != hash || ch.isSystem) continue;
      final key = '${ch.secretRef}:${ch.hashByte}';
      final secret = _secrets.containsKey(key) ? _secrets[key] : (_secrets[key] = await secretOf(ch));
      if (secret == null || secret.length < 16) continue;
      final gt = decryptGroupText(secret, pkt.payload);
      if (gt == null) continue; // same hash byte, other key
      emit(InboundRepeatHeard(
        radioId: id,
        channelSlot: ch.slot!,
        timestamp: gt.timestamp,
        text: gt.text,
        pathHashes: pkt.pathHex.join(),
        hashSize: pkt.pathHashSize,
        hops: pkt.hopCount,
        snr: rx.snrDb,
        rssi: rx.rssiDbm?.round(),
        heardMs: rx.at.millisecondsSinceEpoch,
      ));
      return;
    }
  }

  void forgetSecrets() => _secrets.clear();
}
