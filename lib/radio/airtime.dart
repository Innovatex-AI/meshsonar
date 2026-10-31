// LoRa time on air, from the Semtech SX127x datasheet formula (section 4.1.1.7 "Time on air") that RadioLib's
// getTimeOnAir implements and MeshCore uses (RadioLibWrappers.cpp ~162). Explicit header, CRC on, MeshCore preamble (32 symbols at SF8 and below, 16 above).
// Low data rate optimisation is on when one symbol lasts more than 16 ms (what RadioLib does).
//
// Pure Dart, no state: the TxArbiter's ledger and the Drive settings readout use it.
import 'dart:math' as math;

/// MeshCore's preamble length for [sf].
int meshcorePreambleSymbols(int sf) => sf <= 8 ? 32 : 16;

/// Time on air in milliseconds (fractional) for a packet of [payloadBytes] bytes.
///
/// [sf] 5-12, [bwKhz] e.g. 62.5, [cr] is the MeshCore/SELF_INFO value 5-8 (denominator of 4/5 .. 4/8).
double loraAirtimeMs({
  required int payloadBytes,
  required int sf,
  required double bwKhz,
  int cr = 5,
  int? preambleSymbols,
  bool crc = true,
  bool explicitHeader = true,
}) {
  assert(sf >= 5 && sf <= 12);
  assert(cr >= 5 && cr <= 8);
  final preamble = preambleSymbols ?? meshcorePreambleSymbols(sf);
  final tSymMs = (1 << sf) / bwKhz; // 2^SF / BW(kHz) = ms
  final de = tSymMs > 16 ? 1 : 0;
  final ih = explicitHeader ? 0 : 1;
  final numer = 8 * payloadBytes - 4 * sf + 28 + (crc ? 16 : 0) - 20 * ih;
  final denom = 4 * (sf - 2 * de);
  final payloadSymbols = 8 + math.max((numer / denom).ceil() * cr, 0);
  final preambleMs = (preamble + 4.25) * tSymMs;
  return preambleMs + payloadSymbols * tSymMs;
}

/// Bytes on air of a flood GRP_TXT (channel text) packet: header(1) + path_len(1) + channel hash(1) + MAC(2) + AES-128
/// blocks of [ts u32][txt_type][text]. [transportCodes] adds the 4-byte region transport code of a scoped flood.
/// Check: "KE4BFI: MS:xxxxxxxxxx" (21 bytes) -> 37, the figure in docs/PROTOCOL.md 5.1 (design doc B section 7).
int groupTextPacketBytes(int textBytesWithSenderPrefix, {bool transportCodes = false}) {
  final plain = 5 + textBytesWithSenderPrefix; // timestamp(4) + txt_type(1) + "name: text"
  final cipher = ((plain + 15) ~/ 16) * 16;
  return 1 + 1 + 1 + 2 + cipher + (transportCodes ? 4 : 0);
}

/// Bytes on air of a flood TXT_MSG (direct message) packet: header(1) + path_len(1) + dest hash(1) + src hash(1) + MAC(2)
/// + blocks of [ts u32][flags/attempt][text].
int directTextPacketBytes(int textBytes, {bool transportCodes = false}) {
  final plain = 5 + textBytes;
  final cipher = ((plain + 15) ~/ 16) * 16;
  return 1 + 1 + 1 + 1 + 2 + cipher + (transportCodes ? 4 : 0);
}
