// Modelled airtime of a region's packet mix: the Dart twin of src/lib/region/packet-analytics.ts + the Semtech time on air of
// src/lib/tools/airtime.ts (meshcore-insights). The numbers are pinned by test/core/airtime_share_test.dart against the website's
// own (GOLDEN values); change one side, change both.
//   frame bytes = 1 header + [4 on transport routes] + 1 path length + hops x hash size + the payload assumed for the packet type
//   time on air = Semtech AN1200.13, explicit header, CRC on, MeshCore preamble (32 symbols at SF <= 8, else 16) + 4.25
// Packets heard by outside live feeds carry no text, so a wardrive ping cannot be told from other group text: the group-text share
// is the ceiling for the wardrive share. Pure Dart: no Flutter imports.
import 'dart:math' as math;

class LoraRadio {
  final int sf;
  final double bwKhz;
  final int cr; // 5..8 = coding rate 4/5..4/8
  const LoraRadio(this.sf, this.bwKhz, this.cr);

  /// MeshCore's US default, the maths baseline where a region has no preset on file.
  static const meshcoreUs = LoraRadio(7, 62.5, 5);
}

/// Total time on air of a frame of [bytes], in seconds.
double timeOnAirSeconds(int bytes, LoraRadio r) {
  final crIdx = (r.cr - 4).clamp(1, 4).toInt();
  final tsymMs = math.pow(2, r.sf) / r.bwKhz;
  final de = tsymMs >= 16 ? 1 : 0;
  final preambleSymbols = (r.sf <= 8 ? 32 : 16) + 4.25;
  final num = 8 * math.max(0, bytes) - 4 * r.sf + 28 + 16;
  final payloadSymbols = 8 + math.max((num / (4 * (r.sf - 2 * de))).ceil() * (crIdx + 4), 0);
  return (preambleSymbols + payloadSymbols) * tsymMs / 1000;
}

class MixRow {
  final int type, hops, hashSize, count;
  final bool transport;
  const MixRow(this.type, this.transport, this.hops, this.hashSize, this.count);
}

class PayloadAssumption {
  final int type, payloadBytes;
  final String label, basis;
  const PayloadAssumption(this.type, this.label, this.payloadBytes, this.basis);
}

const groupTextType = 5;

/// The payload sizes the website assumes (the server sends them too; these are the fallback and the test reference).
const defaultPayloadAssumptions = <PayloadAssumption>[
  PayloadAssumption(0, 'Request', 20, 'dest, src, MAC and one 16 B cipher block'),
  PayloadAssumption(1, 'Response', 20, 'dest, src, MAC and one 16 B cipher block'),
  PayloadAssumption(2, 'Direct message', 52, 'direct text of 40 characters'),
  PayloadAssumption(3, 'Ack', 4, 'ack CRC'),
  PayloadAssumption(4, 'Advert', 121, 'advert with a 12 byte name and a position'),
  PayloadAssumption(5, 'Group text', 35, 'a ping-sized group text; chat is longer, so this is a floor'),
  PayloadAssumption(6, 'Group data', 35, 'sized like a ping-sized group text'),
  PayloadAssumption(7, 'Anonymous request', 51, 'dest, sender key, MAC and one 16 B cipher block'),
  PayloadAssumption(8, 'Path', 20, 'dest, src, MAC and one 16 B cipher block'),
  PayloadAssumption(9, 'Trace', 9, 'tag, auth code and flags'),
  PayloadAssumption(10, 'Multipart', 20, 'one small fragment'),
  PayloadAssumption(11, 'Control', 12, 'a short control frame'),
  PayloadAssumption(15, 'Raw custom', 20, 'a short custom frame'),
];

const airtimeNote =
    'Packets heard by outside live feeds carry no text, so a wardrive ping cannot be told from other group text. The group-text share is '
    'the ceiling for the wardrive share. Airtime is modelled, not measured: the frame is header + path + an assumed payload per type.';

int frameBytes(int type, int hops, int hashSize, bool transport, List<PayloadAssumption> assumptions) {
  final a = assumptions.where((x) => x.type == type).firstOrNull ?? assumptions.where((x) => x.type == 15).firstOrNull;
  final payload = a?.payloadBytes ?? 20;
  final hs = hashSize >= 1 && hashSize <= 3 ? hashSize : 1;
  return 1 + (transport ? 4 : 0) + 1 + hops * hs + payload;
}

class TypeAirtime {
  final int type;
  final String label;
  final int transmissions;
  final double airtimeS, txShare, airtimeShare;
  const TypeAirtime(this.type, this.label, this.transmissions, this.airtimeS, this.txShare, this.airtimeShare);
}

class AirtimeModel {
  final int transmissions;
  final double airtimeS;
  final List<TypeAirtime> byType;
  final double? groupTextTxShare, groupTextAirtimeShare;
  final double groupTextAirtimeS;
  const AirtimeModel(this.transmissions, this.airtimeS, this.byType, this.groupTextTxShare, this.groupTextAirtimeShare, this.groupTextAirtimeS);
}

double _r4(double v) => (v * 1e4).round() / 1e4;
double _r3(double v) => (v * 1e3).round() / 1e3;

AirtimeModel modelAirtime(List<MixRow> rows, LoraRadio radio, [List<PayloadAssumption> assumptions = defaultPayloadAssumptions]) {
  final toa = <int, double>{};
  double sec(int b) => toa.putIfAbsent(b, () => timeOnAirSeconds(b, radio));
  final per = <int, ({int n, double s})>{};
  var n = 0;
  var s = 0.0;
  for (final r in rows) {
    if (r.count <= 0) continue;
    final air = r.count * sec(frameBytes(r.type, r.hops, r.hashSize, r.transport, assumptions));
    final e = per[r.type] ?? (n: 0, s: 0.0);
    per[r.type] = (n: e.n + r.count, s: e.s + air);
    n += r.count;
    s += air;
  }
  String label(int t) => assumptions.where((a) => a.type == t).firstOrNull?.label ?? 'Type $t';
  final entries = per.entries.toList()
    ..sort((a, b) {
      final c = b.value.s.compareTo(a.value.s);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  final byType = [
    for (final e in entries) TypeAirtime(e.key, label(e.key), e.value.n, _r3(e.value.s), _r4(e.value.n / n), _r4(e.value.s / s)),
  ];
  final g = per[groupTextType];
  return AirtimeModel(
    n,
    _r3(s),
    byType,
    n > 0 ? _r4((g?.n ?? 0) / n) : null,
    s > 0 ? _r4((g?.s ?? 0) / s) : null,
    _r3(g?.s ?? 0),
  );
}
