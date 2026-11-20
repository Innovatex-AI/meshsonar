// "My radio" (AZ-3.2): the packets the connected radio has heard this session, from the app's existing Rx log
// (lib/radio/tools/rx_log.dart: PUSH_CODE_LOG_RX_DATA, a ring of the last 500 packets in memory, forgotten when the app
// closes), decoded on the phone into the same PacketDetail the network detail uses, and matched to the network by
// packet hash (the firmware hash is the same at every observer: route, transport codes and path are not hashed).
//
// What the Rx log keeps: the parsed packet (header, transport codes, path, payload), so every valid packet's bytes are
// rebuilt exactly (MeshPacket.toBytes). What it does not keep: the bytes of a packet that did not parse (only its
// length) and anything heard while the log was paused (only a count). Those are said, never faked.
// Pure Dart: no Flutter imports.
import '../../radio/tools/rx_log.dart';
import 'local_decoder.dart';
import 'packet_models.dart';

/// One packet the radio heard, ready for the list.
class MyRadioPacket {
  final RxLogEntry entry;

  /// Null when the bytes did not parse (only the length was kept).
  final PacketDetail? detail;

  /// Why there is no [detail].
  final String? problem;
  const MyRadioPacket(this.entry, this.detail, this.problem);

  String? get hash => detail?.hash;
}

final Expando<MyRadioPacket> _decoded = Expando('myRadioPacket');

/// [e] decoded with the Public key and [hashtagKeys] (cached per entry).
MyRadioPacket decodeRxEntry(RxLogEntry e, {List<LocalChannelKey> hashtagKeys = const []}) {
  final cached = _decoded[e];
  if (cached != null) return cached;
  final p = e.packet;
  MyRadioPacket out;
  if (p == null) {
    out = MyRadioPacket(e, null, 'Not a valid MeshCore packet (${e.length} bytes); the radio log keeps only its length, not its bytes.');
  } else {
    try {
      out = MyRadioPacket(
          e, decodePacketLocally(p.toBytes(), source: PacketSource.myRadio, hashtagKeys: hashtagKeys, heardAt: e.at, snr: e.snrDb, rssi: e.rssiDbm), null);
    } on LocalDecodeError catch (err) {
      out = MyRadioPacket(e, null, err.message);
    }
  }
  _decoded[e] = out;
  return out;
}

/// The radio's packets, newest first.
List<MyRadioPacket> myRadioPackets(RxLog log, {List<LocalChannelKey> hashtagKeys = const []}) =>
    [for (final e in log.entries()) decodeRxEntry(e, hashtagKeys: hashtagKeys)];

/// Every time the radio heard [hash] this session (newest first); empty when it did not.
List<MyRadioPacket> radioHeard(RxLog? log, String hash, {List<LocalChannelKey> hashtagKeys = const []}) {
  if (log == null) return const [];
  final h = hash.toLowerCase();
  return [for (final p in myRadioPackets(log, hashtagKeys: hashtagKeys)) if (p.hash == h) p];
}
