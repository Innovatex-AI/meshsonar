// Real frames from the live research runs of Oct 31 to Nov 1 2026 (meshsonar-infra/docs/planning/research-logs, companion
// MeshCore-KE4BFI fw code 13 talking to repeater/observer INNO-OB-2, key prefix df01). Redacted: the radio's own
// coordinates are not here; the repeater's public key past its logged 8-byte prefix is zero filled where the log keeps only
// the prefix (marked below). Each constant says whether the bytes are RAW from the log or REBUILT byte for byte from the
// decoded fields the log keeps (the runs stored decoded fields for push 0x89 and 0x8E, raw hex for packets and stats).
import 'dart:typed_data';

Uint8List hex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

/// RAW (live-run3.json repeater_adverts_raw): the repeater's zero-hop advert, header 0x12 DIRECT + ADVERT, 1-byte hash size,
/// 0 hops. Heard at SNR -2.5 dB, RSSI -122 dBm. 120 bytes. Name "INNO-OB-2", type repeater, no position.
final Uint8List advertZeroHop = hex(
    '1200df0136c20a99f519286d14e5b95e9d807c9472aa83ffefd9a15f8238afdecd486861e66a67c26711d123691b96e1565c2ce104e7afcf1ba3f5c768b606e5df47a56340fbdf6a5581b1df1434b5c0c6ad914563eb5f694ca2a3c1e49b646e83c24f505106923c4e6402bed40dfb494e4e4f2d4f422d32');

/// RAW (same file): the repeater's scoped flood advert, header 0x10 TRANSPORT_FLOOD + ADVERT, transport code bytes 41 7a
/// (0x7a41), path_len 0x40 (2-byte hashes, 0 hops). SNR -1.5, RSSI -122. 124 bytes. Region scope "#cmh".
final Uint8List advertScopedFlood = hex(
    '10417a000040df0136c20a99f519286d14e5b95e9d807c9472aa83ffefd9a15f8238afdecd487561e66a5dac9a1d3d139d2b2bcfe46847909a5d55b9d69861f021c40945e1c824c1107d8d6cad62f0846a341f918353e205c71b6d73d03419328b5bf18ccf025199f10c923c4e6402bed40dfb494e4e4f2d4f422d32');

const String repeaterKeyPrefixHex = 'df0136c20a99f519';

/// The repeater's name in those adverts.
const String repeaterName = 'INNO-OB-2';

/// RAW (live-run1.json stats_radio_end): GET_STATS radio reply, 14 bytes: noise floor -120 dBm (0xff88), last RSSI -117,
/// last SNR +3.25 dB, TX air 41 s, RX air 116 s.
final Uint8List statsRadioFrame = hex('180188ff8b0d2900000074000000');

/// RAW (live-run1.json stats_packets_end): GET_STATS packets reply, 30 bytes.
final Uint8List statsPacketsFrame = hex('1802aa010000c50000001a000000ab000000f5000000b500000007000000');

/// REBUILT from live-run1.log "PUSH_TRACE_DATA {path_len 1, flags 0, tag 1793481996, auth 0, hashes df, snr_per_hop [0.25],
/// final_snr -0.25}" (0.54 s after the command, est_timeout 2572 ms).
final Uint8List traceReply1Byte = hex('890001000c5de66a00000000df01ff');

/// REBUILT from live-run1.log "PUSH_TRACE_DATA {path_len 2, flags 1, tag 1793481996, auth 0, hashes df01, snr_per_hop [1.0],
/// final_snr 3.25}" (0.36 s, est_timeout 2692 ms).
final Uint8List traceReply2Byte = hex('890002010c5de66a00000000df01040d');

/// REBUILT from live-run4.log: control data push, snr -4.25 dB, rssi -125, path_len 0, 38-byte payload = node_type repeater,
/// their_snr -5.25, tag 1840446589, full key (only the first 8 bytes are logged; the rest is zero filled here).
Uint8List discoverFull() => hex('8eef8300' '92eb7dfcb26ddf0136c20a99f519${'00' * 24}');

/// REBUILT from live-run4.log: prefix-only answer, snr -4.0, rssi -124, 14-byte payload, their_snr -5.25, tag 1840447501.
Uint8List discoverPrefix() => hex('8ef08400' '92eb0d00b36ddf0136c20a99f519');

/// LPP of the repeater's telemetry answer (live-run1: ch1 voltage 3.86 V, ch1 temperature 45.0 C, then zero padding).
/// Big endian: 0x0182 = 386 -> 3.86 V; 0x01C2 = 450 -> 45.0 C.
final Uint8List repeaterTelemetryLpp = hex('0174' '0182' '0167' '01c2' '0000' '0000');
