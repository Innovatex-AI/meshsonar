// What the drive report shows of a drive's context (stream 7 WP4): series and summaries computed from the context
// stored beside the drive (lib/core/drive_context.dart). Values stay SI (hPa, m, mV, s); the UI formats them through
// Units. Nothing here is interpolated: a gap in samples is a gap.
//
// Pure Dart: no Flutter imports.
import 'drive_context.dart';
import 'model.dart';

/// The firmware's Dispatcher `_err_flags` bits (lib/radio/protocol.dart RadioErrFlag), in words. Sticky since the
/// radio booted: "seen", never a count.
const List<(int, String)> radioErrFlagWords = [
  (1 << 0, 'transmit queue was full'),
  (1 << 1, 'channel-activity check (CAD) timed out'),
  (1 << 2, 'receive start timed out'),
];

/// Words for every set bit of [flags]; unknown bits are listed by number.
List<String> describeErrFlags(int flags) {
  final out = <String>[];
  var rest = flags;
  for (final (bit, words) in radioErrFlagWords) {
    if (flags & bit != 0) out.add(words);
    rest &= ~bit;
  }
  for (var b = 0; b < 16; b++) {
    if (rest & (1 << b) != 0) out.add('flag bit $b');
  }
  return out;
}

typedef TimeValue = (DateTime, double);

/// Pings grouped by the radio's chip temperature at the time (nearest radio sample within [DriveContextReport.tempJoin]).
class TempBand {
  /// Lower edge, °C (bands are [bandWidthC] wide).
  final double fromC;
  final int pings;
  final double? meanNoiseDbm;
  final double? meanBestSnrDb;
  final int snrPings;
  const TempBand(this.fromC, this.pings, this.meanNoiseDbm, this.meanBestSnrDb, this.snrPings);
}

const double bandWidthC = 5;

class DriveContextReport {
  /// Phone barometer, hPa: the phone samples (one-minute medians), or the per-ping values when there are none.
  final List<TimeValue> pressureHpa;
  final List<TimeValue> phoneBatteryPct;
  final Set<PhoneBatteryState> phoneBatteryStates;
  final bool lowPowerSeen;

  /// Radio battery, millivolts.
  final List<TimeValue> radioBatteryMv;

  /// Radio chip (MCU) temperature, °C, from the radio's self telemetry.
  final List<TimeValue> radioTempC;

  /// Noise floor and SNR of the pings by radio temperature band (only bands with pings).
  final List<TempBand> tempBands;

  /// A ping takes the temperature of the nearest radio sample this close in time.
  static const Duration tempJoin = Duration(minutes: 2);

  /// GPS altitude at each ping, metres.
  final List<TimeValue> altitudeM;
  final double? medianAltitudeAccuracyM;

  /// The radio's uptime at the last sample, seconds.
  final int? lastUptimeS;

  /// Every error flag seen in any sample (OR).
  final int? errFlags;

  /// Own-radio airtime (TX + RX from the radio's counters) as a share of wall time between samples, percent. Not
  /// channel utilisation: the firmware does not report that.
  final double? airtimePct;

  /// Packets sent / received by the radio during the drive (counter deltas between samples, reboots skipped).
  final int? packetsSent;
  final int? packetsReceived;
  final int? storageUsedKb, storageTotalKb;
  final int radioSamples, phoneSamples, pingContexts;
  final DeviceDetails? device;
  final CompanionDetails? companion;

  const DriveContextReport({
    this.pressureHpa = const [],
    this.phoneBatteryPct = const [],
    this.phoneBatteryStates = const {},
    this.lowPowerSeen = false,
    this.radioBatteryMv = const [],
    this.radioTempC = const [],
    this.tempBands = const [],
    this.altitudeM = const [],
    this.medianAltitudeAccuracyM,
    this.lastUptimeS,
    this.errFlags,
    this.airtimePct,
    this.packetsSent,
    this.packetsReceived,
    this.storageUsedKb,
    this.storageTotalKb,
    this.radioSamples = 0,
    this.phoneSamples = 0,
    this.pingContexts = 0,
    this.device,
    this.companion,
  });

  bool get isEmpty => radioSamples == 0 && phoneSamples == 0 && pingContexts == 0 && device == null && companion == null;

  static DriveContextReport compute({
    required List<DriveSample> samples,
    required Map<String, PingContext> pingContexts,
    SessionContext? session,
    required List<DrivePing> pings,
  }) {
    final radio = [for (final s in samples) if (s.src == SampleSource.radio) s]..sort((a, b) => a.ts.compareTo(b.ts));
    final phone = [for (final s in samples) if (s.src == SampleSource.phone) s]..sort((a, b) => a.ts.compareTo(b.ts));
    final byId = {for (final p in pings) p.id: p};
    final ctx = [
      for (final e in pingContexts.entries)
        if (byId[e.key] != null) (byId[e.key]!.ts, e.value),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    var pressure = [for (final s in phone) if (s.pressureHpa != null) (s.ts, s.pressureHpa!)];
    if (pressure.isEmpty) pressure = [for (final (t, c) in ctx) if (c.pressureHpa != null) (t, c.pressureHpa!)];
    final accs = [for (final (_, c) in ctx) if (c.altAccM != null) c.altAccM!]..sort();

    int? flags;
    for (final s in radio) {
      if (s.errFlags != null) flags = (flags ?? 0) | s.errFlags!;
    }

    // Airtime and packet deltas between consecutive radio samples whose uptime went up (no reboot in between).
    var air = 0, wall = 0.0, sent = 0, recv = 0;
    var airPairs = 0, pktPairs = 0;
    for (var i = 1; i < radio.length; i++) {
      final a = radio[i - 1], b = radio[i];
      final up = a.uptimeS != null && b.uptimeS != null && b.uptimeS! >= a.uptimeS!;
      if (!up) continue;
      if (a.txAirS != null && a.rxAirS != null && b.txAirS != null && b.rxAirS != null) {
        final d = (b.txAirS! - a.txAirS!) + (b.rxAirS! - a.rxAirS!);
        final w = b.ts.difference(a.ts).inMilliseconds / 1000;
        if (d >= 0 && w > 0) {
          air += d;
          wall += w;
          airPairs++;
        }
      }
      if (a.pkts != null && b.pkts != null) {
        final ds = b.pkts!.sent - a.pkts!.sent, dr = b.pkts!.recv - a.pkts!.recv;
        if (ds >= 0 && dr >= 0) {
          sent += ds;
          recv += dr;
          pktPairs++;
        }
      }
    }
    final temps = [for (final s in radio) if (s.mcuTempC != null) (s.ts, s.mcuTempC!)];
    final bands = <double, List<DrivePing>>{};
    if (temps.isNotEmpty) {
      for (final p in pings) {
        TimeValue? best;
        Duration? gap;
        for (final t in temps) {
          final g = t.$1.difference(p.ts).abs();
          if (g <= tempJoin && (gap == null || g < gap)) {
            best = t;
            gap = g;
          }
        }
        if (best == null) continue;
        final from = (best.$2 / bandWidthC).floorToDouble() * bandWidthC;
        (bands[from] ??= []).add(p);
      }
    }
    double? mean(Iterable<double> v) => v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
    double? bestSnr(DrivePing p) {
      double? b;
      for (final v in [for (final e in p.echoes) e.snrDb, p.neighbor?.localSnrDb]) {
        if (v != null && (b == null || v > b)) b = v;
      }
      return b;
    }

    final tempBands = [
      for (final k in bands.keys.toList()..sort())
        () {
          final ps = bands[k]!;
          final snrs = [for (final p in ps) ?bestSnr(p)];
          return TempBand(k, ps.length, mean([for (final p in ps) ?p.noiseFloorDbm]), mean(snrs), snrs.length);
        }(),
    ];
    final lastStorage = radio.lastWhere((s) => s.storageTotalKb != null, orElse: () => _none);

    return DriveContextReport(
      pressureHpa: pressure,
      phoneBatteryPct: [for (final s in phone) if (s.battPct != null) (s.ts, s.battPct!.toDouble())],
      phoneBatteryStates: {for (final s in phone) if (s.battState != null) s.battState!},
      lowPowerSeen: phone.any((s) => s.lowPower == true),
      radioBatteryMv: [for (final s in radio) if (s.battMv != null) (s.ts, s.battMv!.toDouble())],
      radioTempC: temps,
      tempBands: tempBands,
      altitudeM: [for (final (t, c) in ctx) if (c.altM != null) (t, c.altM!)],
      medianAltitudeAccuracyM: accs.isEmpty ? null : accs[accs.length ~/ 2],
      lastUptimeS: radio.lastWhere((s) => s.uptimeS != null, orElse: () => _none).uptimeS,
      errFlags: flags,
      airtimePct: airPairs == 0 || wall <= 0 ? null : 100 * air / wall,
      packetsSent: pktPairs == 0 ? null : sent,
      packetsReceived: pktPairs == 0 ? null : recv,
      storageUsedKb: lastStorage.storageUsedKb,
      storageTotalKb: lastStorage.storageTotalKb,
      radioSamples: radio.length,
      phoneSamples: phone.length,
      pingContexts: ctx.length,
      device: session?.device,
      companion: session?.companionExt,
    );
  }
}

final DriveSample _none = DriveSample(ts: DateTime.utc(1970), src: SampleSource.radio);
