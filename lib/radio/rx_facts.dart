// Radio facts for a received message: RSSI and the repeater hop hashes (chat redesign WP4, plan section 6).
//
// The V3 message frames (0x10 / 0x11) carry SNR and the packed path_len byte but no RSSI and no hop hashes (spikes doc S2/S3).
// The radio does push every packet it hears as PUSH_CODE_LOG_RX_DATA (0x88: snr, rssi, the raw packet) just before the message
// is queued for us. So: remember the last few 0x88 packets, and when a message is taken off the radio find the one it came
// from. Best effort and deliberately strict, a wrong RSSI is worse than none: the packet must be a text payload (TXT_MSG 2 or
// GRP_TXT 5), carry the same SNR (both are x4 quantised) and the same hop count, and be recent. A match is used once.
// Pure Dart.
import 'dart:collection';
import 'dart:typed_data';

import 'crypto.dart' show toHex;

/// What was read from one logged packet.
class RxFacts {
  final int rssiDbm;
  final double snrDb;

  /// Hop hashes as hex, [hashSize] bytes per hop, first hop first. Empty for a zero-hop packet.
  final String pathHashes;
  final int hashSize;
  final int hops;
  final int payloadType;
  const RxFacts({required this.rssiDbm, required this.snrDb, required this.pathHashes, required this.hashSize, required this.hops, required this.payloadType});
}

/// Mesh packet header (src/Packet.h): [header][transport codes 4 bytes if route type 0 or 3][path_len][path][payload].
/// path_len: low 6 bits = hop count, top 2 bits = hash size - 1. Returns null for anything malformed.
RxFacts? parseRxPacket(Uint8List raw, {required double snrDb, required int rssiDbm}) {
  if (raw.length < 2) return null;
  final header = raw[0];
  final route = header & 3;
  final payloadType = (header >> 2) & 15;
  var i = 1;
  if (route == 0 || route == 3) i += 4;
  if (i >= raw.length) return null;
  final pl = raw[i++];
  final hops = pl & 63;
  final size = (pl >> 6) + 1;
  if (size > 3 || i + hops * size > raw.length) return null;
  final path = raw.sublist(i, i + hops * size);
  return RxFacts(rssiDbm: rssiDbm, snrDb: snrDb, pathHashes: toHex(path), hashSize: size, hops: hops, payloadType: payloadType);
}

class RxCorrelator {
  /// Text payload types: TXT_MSG and GRP_TXT.
  static const Set<int> textTypes = {2, 5};

  final Duration window;
  final int capacity;
  final _entries = ListQueue<({DateTime at, RxFacts facts})>();

  RxCorrelator({this.window = const Duration(seconds: 3), this.capacity = 24});

  int get length => _entries.length;

  void record(DateTime at, Uint8List raw, {required double snrDb, required int rssiDbm}) {
    final f = parseRxPacket(raw, snrDb: snrDb, rssiDbm: rssiDbm);
    if (f == null || !textTypes.contains(f.payloadType)) return;
    _entries.addLast((at: at, facts: f));
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
  }

  /// The logged packet that [at] is the message taken off the radio for: same SNR, same hop count ([hops] null = it arrived
  /// direct, matching a zero-hop packet), newest first. Consumed on a match.
  RxFacts? take({required DateTime at, required double? snrDb, required int? hops}) {
    if (snrDb == null) return null;
    final hop = hops ?? 0;
    for (final e in _entries.toList().reversed) {
      final age = at.difference(e.at);
      if (age > window) break;
      if (age.isNegative) continue;
      if ((e.facts.snrDb - snrDb).abs() > 0.13 || e.facts.hops != hop) continue;
      _entries.remove(e);
      return e.facts;
    }
    return null;
  }

  void clear() => _entries.clear();
}
