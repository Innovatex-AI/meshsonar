// LoRa time-on-air and MeshCore channel-load maths, a line-for-line port of the website's
// meshcore-insights `src/lib/tools/airtime.ts` (Semtech AN1200.13; MeshCore wire format). Golden tests in
// test/core/plan/airtime_calc_test.dart read numbers generated FROM the website's functions by
// meshcore-insights `scripts/plan-tools-golden.ts` (test/fixtures/plan_tools_golden.json). Pure Dart, no I/O: it runs
// on the phone with no network. Read-only: nothing here talks to a radio.
import 'dart:math' as math;

class AirRadio {
  final int sf;
  final double bwKHz;

  /// 5..8 = coding rate 4/5..4/8.
  final int cr;

  /// Preamble symbols; null = MeshCore's (32 at SF <= 8, 16 above). Set only to compare with a reference calculator.
  final int? preamble;
  const AirRadio({required this.sf, required this.bwKHz, required this.cr, this.preamble});

  AirRadio copyWith({int? sf, double? bwKHz, int? cr}) => AirRadio(sf: sf ?? this.sf, bwKHz: bwKHz ?? this.bwKHz, cr: cr ?? this.cr);
}

/// MeshCore's US default radio (website `MESHCORE_US`): the maths reference where a region has no preset on file.
const AirRadio meshcoreUs = AirRadio(sf: 7, bwKHz: 62.5, cr: 5);
const double meshcoreUsFreqMhz = 910.525;

const List<int> sfOptions = [7, 8, 9, 10, 11, 12];
const List<double> bwOptions = [62.5, 125, 250];
const List<int> crOptions = [5, 6, 7, 8];

/// MeshCore firmware limits (MAX_TRANS_UNIT, MAX_PACKET_PAYLOAD, MAX_PATH_SIZE).
const int maxPacketBytes = 255;
const int maxPayloadBytes = 184;
const int maxPathBytes = 64;

int meshcorePreamble(int sf) => sf <= 8 ? 32 : 16;

/// Symbol time in ms: 2^SF / BW(kHz).
double symbolMs(int sf, double bwKHz) => math.pow(2, sf) / bwKHz;

class ToA {
  final int bytes;
  final double tsymMs;
  final bool ldro;
  final double preambleSymbols;
  final int payloadSymbols;
  final double preambleMs, payloadMs, totalMs;
  const ToA({
    required this.bytes,
    required this.tsymMs,
    required this.ldro,
    required this.preambleSymbols,
    required this.payloadSymbols,
    required this.preambleMs,
    required this.payloadMs,
    required this.totalMs,
  });
}

ToA timeOnAir(num bytes, [AirRadio radio = meshcoreUs]) {
  final sf = radio.sf;
  final crIdx = math.min(math.max(radio.cr.round() - 4, 1), 4);
  final tsym = symbolMs(sf, radio.bwKHz);
  final ldro = tsym >= 16;
  final de = ldro ? 1 : 0;
  final pl = math.max(0, bytes.round());
  final preambleSymbols = (radio.preamble ?? meshcorePreamble(sf)) + 4.25;
  final num_ = 8 * pl - 4 * sf + 28 + 16; // CRC on, explicit header
  final int payloadSymbols = 8 + math.max((num_ / (4 * (sf - 2 * de))).ceil() * (crIdx + 4), 0).toInt();
  final preambleMs = preambleSymbols * tsym;
  final payloadMs = payloadSymbols * tsym;
  return ToA(
    bytes: pl,
    tsymMs: tsym,
    ldro: ldro,
    preambleSymbols: preambleSymbols,
    payloadSymbols: payloadSymbols,
    preambleMs: preambleMs,
    payloadMs: payloadMs,
    totalMs: preambleMs + payloadMs,
  );
}

double toaSeconds(num bytes, [AirRadio radio = meshcoreUs]) => timeOnAir(bytes, radio).totalMs / 1000;

// ---------------------------------------------------------------- packet builder
enum PayloadKind { ack, group, direct, advert, custom }

class PacketSpec {
  final PayloadKind kind;

  /// group/direct: characters of text as sent (group text includes the "Name: " prefix the app adds).
  final int? chars;

  /// advert: node name length in bytes.
  final int? nameLen;

  /// advert: include the 8-byte lat/lon.
  final bool withLocation;

  /// custom: payload bytes after the path.
  final int? customBytes;
  final int hops;
  final int hashSize;

  /// Transport-code routes add 4 bytes.
  final bool transport;
  const PacketSpec(
    this.kind, {
    this.chars,
    this.nameLen,
    this.withLocation = true,
    this.customBytes,
    this.hops = 0,
    this.hashSize = 1,
    this.transport = false,
  });

  PacketSpec withHops(int h) => PacketSpec(kind,
      chars: chars, nameLen: nameLen, withLocation: withLocation, customBytes: customBytes, hops: h, hashSize: hashSize, transport: transport);
}

class PacketBytes {
  final int header, transport, pathLen, path, payload, total;

  /// Firmware limits exceeded (payload > 184, path > 64 or total > 255); null when fine.
  final String? overLimit;
  const PacketBytes(
      {required this.header, required this.transport, required this.pathLen, required this.path, required this.payload, required this.total, this.overLimit});
}

int _ceil16(int n) => (math.max(n, 1) / 16).ceil() * 16;

int payloadBytes(PacketSpec s) {
  switch (s.kind) {
    case PayloadKind.ack:
      return 4;
    case PayloadKind.group:
      return 1 + 2 + _ceil16(4 + 1 + math.max(0, s.chars ?? 0));
    case PayloadKind.direct:
      return 1 + 1 + 2 + _ceil16(4 + 1 + math.max(0, s.chars ?? 0));
    case PayloadKind.advert:
      return 32 + 4 + 64 + 1 + (s.withLocation ? 8 : 0) + math.max(0, s.nameLen ?? 0);
    case PayloadKind.custom:
      return math.max(0, (s.customBytes ?? 0).round());
  }
}

PacketBytes packetBytes(PacketSpec s) {
  final hops = math.max(0, s.hops.round());
  final transport = s.transport ? 4 : 0;
  final path = hops * s.hashSize;
  final payload = payloadBytes(s);
  final total = 1 + transport + 1 + path + payload;
  final over = payload > maxPayloadBytes
      ? 'payload $payload B exceeds the $maxPayloadBytes B firmware limit'
      : path > maxPathBytes
          ? 'path $path B exceeds the $maxPathBytes B firmware limit'
          : total > maxPacketBytes
              ? 'packet $total B exceeds the $maxPacketBytes B LoRa frame'
              : null;
  return PacketBytes(header: 1, transport: transport, pathLen: 1, path: path, payload: payload, total: total, overLimit: over);
}

// ---------------------------------------------------------------- flood, duty cycle, relay delay
class FloodStep {
  final int hop, bytes;
  final double ms;
  const FloodStep(this.hop, this.bytes, this.ms);
}

class FloodAirtime {
  final List<FloodStep> steps;
  final double totalMs;
  const FloodAirtime(this.steps, this.totalMs);
}

/// Airtime of one flood: the originator transmits with `spec.hops` in its path, then each of [relays] repeaters
/// retransmits once, appending its hash.
FloodAirtime floodAirtime(PacketSpec spec, int relays, [AirRadio radio = meshcoreUs]) {
  final start = math.max(0, spec.hops.round());
  final steps = <FloodStep>[];
  for (var i = 0; i <= math.max(0, relays.round()); i++) {
    final b = packetBytes(spec.withHops(start + i)).total;
    steps.add(FloodStep(start + i, b, timeOnAir(b, radio).totalMs));
  }
  return FloodAirtime(steps, steps.fold(0.0, (s, x) => s + x.ms));
}

/// MeshCore repeater airtime budget: firmware v1.15+ sets `dutycycle` in percent (default 50); older firmware used the
/// airtime factor `af`, cap = 100 / (af + 1) %.
double dutyCyclePct(double af) => 100 / (math.max(0, af) + 1);
double afFromDutyCycle(double pct) => 100 / math.min(math.max(pct, 1), 100) - 1;
const double dutyCycleDefaultPct = 50;
const double txDelayFloodDefault = 0.5;

class RelayDelay {
  final double tMs, maxMs, meanMs;
  const RelayDelay(this.tMs, this.maxMs, this.meanMs);
}

/// MeshCore retransmit delay (Mesh::getRetransmitDelay): t = ToA(path + payload + 2) x txdelay, drawn uniformly 0..5t.
RelayDelay relayDelayWindow(PacketBytes pkt, {double txdelay = txDelayFloodDefault, AirRadio radio = meshcoreUs}) {
  final t = timeOnAir(pkt.path + pkt.payload + 2, radio).totalMs * math.max(0, txdelay);
  return RelayDelay(t, 5 * t, 2.5 * t);
}

// ---------------------------------------------------------------- wire parsing
const Map<int, String> payloadTypes = {
  0: 'REQ', 1: 'RESPONSE', 2: 'TXT_MSG', 3: 'ACK', 4: 'ADVERT', 5: 'GRP_TXT', 6: 'GRP_DATA',
  7: 'ANON_REQ', 8: 'PATH', 9: 'TRACE', 10: 'MULTIPART', 11: 'CONTROL', 15: 'RAW_CUSTOM',
};

class RawHeader {
  final int bytes, routeType, payloadType, hashSize, hopCount;
  const RawHeader({required this.bytes, required this.routeType, required this.payloadType, required this.hashSize, required this.hopCount});
}

/// Header + path_len byte of a raw MeshCore frame (hex). path_len: low 6 bits = hops, high 2 = hash size - 1.
RawHeader? parseRawHeader(String rawHex) {
  final hex = rawHex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (hex.length < 4) return null;
  final h = int.parse(hex.substring(0, 2), radix: 16);
  final routeType = h & 3;
  final off = 1 + (routeType == 0 || routeType == 3 ? 4 : 0);
  if (hex.length < (off + 1) * 2) return null;
  final pl = int.parse(hex.substring(off * 2, off * 2 + 2), radix: 16);
  return RawHeader(bytes: hex.length >> 1, routeType: routeType, payloadType: (h >> 2) & 0xf, hashSize: (pl >> 6) + 1, hopCount: pl & 0x3f);
}

int observationBytes(RawHeader raw, int obsHops, [int? obsHashSize]) => raw.bytes - raw.hopCount * raw.hashSize + obsHops * (obsHashSize ?? raw.hashSize);

/// Pure-ALOHA collision probability for offered load [g] (fraction of channel time): 1 - e^(-2G).
double alohaCollision(double g) => 1 - math.exp(-2 * math.max(0, g));

// ---------------------------------------------------------------- what-if (website `projectLoad`)
/// One observer's airtime components (seconds over the window) that the what-if scales.
class LoadMix {
  /// Direct-routed traffic (incl. zero-hop adverts), unchanged by repeater density or flood.max.
  final double fixedS;

  /// Flood-routed non-advert traffic by hop index (0 = the originator's own send), and flood adverts the same way.
  final List<double> floodByHopS, advertByHopS;
  const LoadMix({required this.fixedS, required this.floodByHopS, required this.advertByHopS});
}

class WhatIf {
  final int repeaters, addRepeaters;

  /// Observed links between repeaters (may be fractional when derived from per-repeater neighbour counts).
  final num links;

  /// flood.max: repeaters do not retransmit beyond this many hops; 64 or more = no cap.
  final int floodMax;
  final double advertIntervalH, baselineAdvertIntervalH;
  const WhatIf({
    required this.repeaters,
    required this.links,
    required this.addRepeaters,
    required this.floodMax,
    required this.advertIntervalH,
    required this.baselineAdvertIntervalH,
  });
}

double meanNeighbors(int repeaters, num links) => repeaters > 0 ? (2 * links) / repeaters : 0;

class ProjectedLoad {
  final double k, kNew, rho, total, flood, advert, fixed;
  const ProjectedLoad(this.k, this.kNew, this.rho, this.total, this.flood, this.advert, this.fixed);
}

/// Projected airtime (same units as the mix): new repeaters have the network's mean neighbour count so every node's k grows
/// and each relayed flood is repeated by (k'+1)/(k+1) as many relays; their adverts scale in proportion; hops beyond
/// flood.max are removed; advert airtime scales with baseline/new interval.
ProjectedLoad projectLoad(LoadMix mix, WhatIf w) {
  final k = meanNeighbors(w.repeaters, w.links);
  final r = math.max(1, w.repeaters);
  final kNew = k * (1 + w.addRepeaters / r);
  final rho = k > 0 ? (kNew + 1) / (k + 1) : 1.0;
  final nodes = (r + w.addRepeaters) / r;
  final adv = w.advertIntervalH > 0 ? w.baselineAdvertIntervalH / w.advertIntervalH : 1.0;
  double sum(List<double> a, double Function(int h) scale) {
    var s = 0.0;
    for (var h = 0; h < a.length; h++) {
      if (h <= w.floodMax) s += a[h] * scale(h);
    }
    return s;
  }

  final flood = sum(mix.floodByHopS, (h) => h >= 1 ? rho : 1);
  final advert = sum(mix.advertByHopS, (h) => (h >= 1 ? rho : 1) * nodes * adv);
  return ProjectedLoad(k, kNew, rho, mix.fixedS + flood + advert, flood, advert, mix.fixedS);
}
