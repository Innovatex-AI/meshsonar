// Drive context (stream 7 WP2): the measurements that explain a drive's RF numbers, stored on the phone BESIDE the
// drive, never inside it.
//
//   PingContext    per ping, keyed by ping id (ctx.jsonl): altitude, course, accuracies, phone barometer, phone and
//                  radio battery at the moment of the ping.
//   DriveSample    per session, time series (samples.jsonl), NO coordinates: radio health from the companion's
//                  GET_STATS / GET_BATT_AND_STORAGE replies, phone battery and barometer.
//   SessionContext per session (context.json): phone/app details and the radio's identity beyond Drive Format v1.
//
// None of this is part of DrivePing / DriveSession / DriveBatch, so the upload and export bytes are unchanged
// (golden: test/core/antenna_profile_test.dart). Uploading it is stream 7 WP5, behind a server capability.
//
// Rules: unmeasured = absent (null), never 0 or a guess; every value is range-checked on the way in AND on the way
// back from disk, out of range becomes null. Every stored key belongs to one category in data_categories.dart so a
// category opt-out can strip it ([PingContext.without], [DriveSample.without], [SessionContext.without]).
//
// Pure Dart: no Flutter imports.
import 'data_categories.dart';

const int _u32Max = 0xFFFFFFFF;

double? _dbl(Object? v, double min, double max, {bool minExclusive = false, bool maxExclusive = false}) {
  if (v is! num) return null;
  final d = v.toDouble();
  if (!d.isFinite) return null;
  if (minExclusive ? d <= min : d < min) return null;
  if (maxExclusive ? d >= max : d > max) return null;
  return d;
}

int? _int(Object? v, int min, int max) {
  if (v is! num) return null;
  if (v is double && (!v.isFinite || v != v.roundToDouble())) return null;
  final i = v.toInt();
  return (i < min || i > max) ? null : i;
}

String? _str(Object? v, int maxLen, [RegExp? allowed]) {
  if (v is! String) return null;
  final s = v.trim();
  if (s.isEmpty) return null;
  final cut = s.length > maxLen ? s.substring(0, maxLen).trim() : s;
  if (allowed != null && !allowed.hasMatch(cut)) return null;
  return cut;
}

double? _n(Object? v) => v is num ? v.toDouble() : null;
String? _s(Object? v) => v is String ? v : null;

Map<String, dynamic> _withoutKeys(Map<String, dynamic> j, String scope, Set<String> offCategories) {
  if (offCategories.isEmpty) return j;
  return {
    for (final e in j.entries)
      if (!offCategories.contains(fieldCategory['$scope.${e.key}'])) e.key: e.value,
  };
}

// ------------------------------------------------------------------ per ping

/// Context of one ping. Every field null = not measured (or its category is off).
class PingContext {
  /// GPS altitude in metres (iOS: above mean sea level), -500..9000.
  final double? altM;

  /// Vertical accuracy, metres, > 0 (0 or negative from the platform = unknown).
  final double? altAccM;

  /// Course over ground (direction of travel, not compass heading), degrees 0..<360.
  final double? courseDeg;
  final double? courseAccDeg;
  final double? speedAccMps;

  /// Phone barometer, hPa, 300..1100. Cabin pressure, labelled "phone barometer", never "outside air pressure".
  final double? pressureHpa;
  final int? phoneBattPct;

  /// Radio battery from the most recent radio sample, millivolts 1..10000 (0 from the firmware = no battery sense).
  final int? radioBattMv;

  /// Range-checks every value; anything outside its range is dropped to null.
  factory PingContext({
    double? altM,
    double? altAccM,
    double? courseDeg,
    double? courseAccDeg,
    double? speedAccMps,
    double? pressureHpa,
    int? phoneBattPct,
    int? radioBattMv,
  }) =>
      PingContext._(
        altM: _dbl(altM, -500, 9000),
        altAccM: _dbl(altAccM, 0, 10000, minExclusive: true),
        courseDeg: _dbl(courseDeg, 0, 360, maxExclusive: true),
        courseAccDeg: _dbl(courseAccDeg, 0, 180, minExclusive: true),
        speedAccMps: _dbl(speedAccMps, 0, 150, minExclusive: true),
        pressureHpa: _dbl(pressureHpa, 300, 1100),
        phoneBattPct: _int(phoneBattPct, 0, 100),
        radioBattMv: _int(radioBattMv, 1, 10000),
      );

  const PingContext._({
    this.altM,
    this.altAccM,
    this.courseDeg,
    this.courseAccDeg,
    this.speedAccMps,
    this.pressureHpa,
    this.phoneBattPct,
    this.radioBattMv,
  });

  bool get isEmpty => toJson().isEmpty;

  /// Only the measured keys (absent = not measured).
  Map<String, dynamic> toJson() => {
        if (altM != null) 'alt_m': altM,
        if (altAccM != null) 'alt_acc_m': altAccM,
        if (courseDeg != null) 'course_deg': courseDeg,
        if (courseAccDeg != null) 'course_acc_deg': courseAccDeg,
        if (speedAccMps != null) 'speed_acc_mps': speedAccMps,
        if (pressureHpa != null) 'pressure_hpa': pressureHpa,
        if (phoneBattPct != null) 'phone_batt_pct': phoneBattPct,
        if (radioBattMv != null) 'radio_batt_mv': radioBattMv,
      };

  /// Unknown keys are ignored; out-of-range values become null.
  factory PingContext.fromJson(Map<String, dynamic> j) => PingContext(
        altM: _n(j['alt_m']),
        altAccM: _n(j['alt_acc_m']),
        courseDeg: _n(j['course_deg']),
        courseAccDeg: _n(j['course_acc_deg']),
        speedAccMps: _n(j['speed_acc_mps']),
        pressureHpa: _n(j['pressure_hpa']),
        phoneBattPct: _int(j['phone_batt_pct'], 0, 100),
        radioBattMv: _int(j['radio_batt_mv'], 1, 10000),
      );

  /// A copy without the keys of the [offCategories].
  PingContext without(Set<String> offCategories) => PingContext.fromJson(_withoutKeys(toJson(), 'ctx', offCategories));
}

// ------------------------------------------------------------------ time series

enum SampleSource { radio, phone }

enum PhoneBatteryState { charging, full, unplugged, unknown }

/// Cumulative packet counters from GET_STATS type 2 (since radio boot; they wrap at 2^32).
class PacketCounters {
  final int recv, sent, floodTx, directTx, floodRx, directRx;

  /// Null on firmware that sends the 26-byte frame without it.
  final int? recvErrors;
  const PacketCounters({
    required this.recv,
    required this.sent,
    required this.floodTx,
    required this.directTx,
    required this.floodRx,
    required this.directRx,
    this.recvErrors,
  });

  Map<String, dynamic> toJson() => {
        'recv': recv,
        'sent': sent,
        'flood_tx': floodTx,
        'direct_tx': directTx,
        'flood_rx': floodRx,
        'direct_rx': directRx,
        if (recvErrors != null) 'recv_errors': recvErrors,
      };

  /// Null unless all six required counters are present and in 0..2^32-1.
  static PacketCounters? fromJson(Object? v) {
    if (v is! Map) return null;
    int? c(String k) => _int(v[k], 0, _u32Max);
    final recv = c('recv'), sent = c('sent'), ft = c('flood_tx'), dt = c('direct_tx'), fr = c('flood_rx'), dr = c('direct_rx');
    if (recv == null || sent == null || ft == null || dt == null || fr == null || dr == null) return null;
    return PacketCounters(
        recv: recv, sent: sent, floodTx: ft, directTx: dt, floodRx: fr, directRx: dr, recvErrors: c('recv_errors'));
  }
}

/// One line of samples.jsonl. Radio samples fill the radio fields, phone samples the phone fields. There are no
/// coordinates in a sample, by construction: it joins the track by time.
class DriveSample {
  final DateTime ts; // UTC
  final SampleSource src;

  // radio (category radio_health)
  final int? battMv;
  final int? uptimeS;

  /// The firmware's Dispatcher `_err_flags` bitmask (bit 0 queue full, bit 1 CAD timeout, bit 2 start-RX timeout),
  /// sticky since boot. A bitmask, not a counter.
  final int? errFlags;
  final int? queue;
  final int? txAirS;
  final int? rxAirS;
  final int? lastRssi;
  final double? lastSnr;
  final int? noiseDbm;
  final PacketCounters? pkts;
  final int? storageUsedKb;
  final int? storageTotalKb;

  /// BLE signal phone <-> companion, dBm.
  final int? bleRssi;

  // phone (categories phone_battery, barometer)
  final int? battPct;
  final PhoneBatteryState? battState;
  final bool? lowPower;
  final double? pressureHpa;

  /// Range-checks every value; anything outside its range is dropped to null.
  factory DriveSample({
    required DateTime ts,
    required SampleSource src,
    int? battMv,
    int? uptimeS,
    int? errFlags,
    int? queue,
    int? txAirS,
    int? rxAirS,
    int? lastRssi,
    double? lastSnr,
    int? noiseDbm,
    PacketCounters? pkts,
    int? storageUsedKb,
    int? storageTotalKb,
    int? bleRssi,
    int? battPct,
    PhoneBatteryState? battState,
    bool? lowPower,
    double? pressureHpa,
  }) {
    final total = _int(storageTotalKb, 1, _u32Max);
    final used = total == null ? null : _int(storageUsedKb, 0, total);
    return DriveSample._(
      ts: ts.toUtc(),
      src: src,
      battMv: _int(battMv, 1, 10000),
      uptimeS: _int(uptimeS, 0, _u32Max),
      errFlags: _int(errFlags, 0, 0xFFFF),
      queue: _int(queue, 0, 255),
      txAirS: _int(txAirS, 0, _u32Max),
      rxAirS: _int(rxAirS, 0, _u32Max),
      lastRssi: _int(lastRssi, -160, -1),
      lastSnr: _dbl(lastSnr, -40, 40),
      noiseDbm: _int(noiseDbm, -160, -1),
      pkts: pkts == null ? null : PacketCounters.fromJson(pkts.toJson()),
      storageUsedKb: used,
      storageTotalKb: used == null ? null : total,
      bleRssi: _int(bleRssi, -127, -1),
      battPct: _int(battPct, 0, 100),
      battState: battState,
      lowPower: lowPower,
      pressureHpa: _dbl(pressureHpa, 300, 1100),
    );
  }

  const DriveSample._({
    required this.ts,
    required this.src,
    this.battMv,
    this.uptimeS,
    this.errFlags,
    this.queue,
    this.txAirS,
    this.rxAirS,
    this.lastRssi,
    this.lastSnr,
    this.noiseDbm,
    this.pkts,
    this.storageUsedKb,
    this.storageTotalKb,
    this.bleRssi,
    this.battPct,
    this.battState,
    this.lowPower,
    this.pressureHpa,
  });

  /// True when nothing but ts/src would be stored.
  bool get isEmpty => toJson().length <= 2;

  Map<String, dynamic> toJson() => {
        'ts': ts.toUtc().toIso8601String(),
        'src': src.name,
        if (battMv != null) 'batt_mv': battMv,
        if (uptimeS != null) 'uptime_s': uptimeS,
        if (errFlags != null) 'err_flags': errFlags,
        if (queue != null) 'queue': queue,
        if (txAirS != null) 'tx_air_s': txAirS,
        if (rxAirS != null) 'rx_air_s': rxAirS,
        if (lastRssi != null) 'last_rssi': lastRssi,
        if (lastSnr != null) 'last_snr': lastSnr,
        if (noiseDbm != null) 'noise_dbm': noiseDbm,
        if (pkts != null) 'pkts': pkts!.toJson(),
        if (storageTotalKb != null) 'storage_kb': {'used': storageUsedKb, 'total': storageTotalKb},
        if (bleRssi != null) 'ble_rssi': bleRssi,
        if (battPct != null) 'batt_pct': battPct,
        if (battState != null) 'batt_state': battState!.name,
        if (lowPower != null) 'low_power': lowPower,
        if (pressureHpa != null) 'pressure_hpa': pressureHpa,
      };

  /// Throws [FormatException] for a line without a valid ts/src; ignores unknown keys; out of range -> null.
  factory DriveSample.fromJson(Map<String, dynamic> j) {
    final ts = DateTime.tryParse(j['ts'] is String ? j['ts'] as String : '');
    final src = SampleSource.values.where((s) => s.name == j['src']).firstOrNull;
    if (ts == null || src == null) throw const FormatException('sample needs ts and src');
    final st = j['storage_kb'];
    final bs = j['batt_state'];
    return DriveSample(
      ts: ts,
      src: src,
      battMv: _int(j['batt_mv'], 1, 10000),
      uptimeS: _int(j['uptime_s'], 0, _u32Max),
      errFlags: _int(j['err_flags'], 0, 0xFFFF),
      queue: _int(j['queue'], 0, 255),
      txAirS: _int(j['tx_air_s'], 0, _u32Max),
      rxAirS: _int(j['rx_air_s'], 0, _u32Max),
      lastRssi: _int(j['last_rssi'], -160, -1),
      lastSnr: _n(j['last_snr']),
      noiseDbm: _int(j['noise_dbm'], -160, -1),
      pkts: PacketCounters.fromJson(j['pkts']),
      storageUsedKb: st is Map ? _int(st['used'], 0, _u32Max) : null,
      storageTotalKb: st is Map ? _int(st['total'], 1, _u32Max) : null,
      bleRssi: _int(j['ble_rssi'], -127, -1),
      battPct: _int(j['batt_pct'], 0, 100),
      battState: PhoneBatteryState.values.where((s) => s.name == bs).firstOrNull,
      lowPower: j['low_power'] is bool ? j['low_power'] as bool : null,
      pressureHpa: _n(j['pressure_hpa']),
    );
  }

  /// A copy without the keys of the [offCategories] (may become [isEmpty]).
  DriveSample without(Set<String> offCategories) =>
      DriveSample.fromJson(_withoutKeys(toJson(), 'sample', offCategories));
}

// ------------------------------------------------------------------ per session

/// Phone and app details (category `device`). Hardware model identifier only (e.g. `iPhone15,2`): never the user's
/// device name, identifierForVendor, advertising id, IP, locale.
class DeviceDetails {
  final String? os;
  final String? osVersion;
  final String? model;
  final String? appBuild;
  factory DeviceDetails({String? os, String? osVersion, String? model, String? appBuild}) => DeviceDetails._(
        _str(os, 10, RegExp(r'^[a-z]+$')),
        _str(osVersion, 20),
        _str(model, 40, RegExp(r'^[A-Za-z0-9 ,._-]+$')),
        _str(appBuild, 10, RegExp(r'^[A-Za-z0-9._-]+$')),
      );
  const DeviceDetails._(this.os, this.osVersion, this.model, this.appBuild);

  bool get isEmpty => toJson().isEmpty;
  Map<String, dynamic> toJson() => {
        if (os != null) 'os': os,
        if (osVersion != null) 'os_version': osVersion,
        if (model != null) 'model': model,
        if (appBuild != null) 'app_build': appBuild,
      };
  factory DeviceDetails.fromJson(Map<String, dynamic> j) => DeviceDetails(
      os: _s(j['os']), osVersion: _s(j['os_version']), model: _s(j['model']), appBuild: _s(j['app_build']));
}

/// The radio's identity beyond Drive Format v1 `companion` (category `radio_config`), from DEVICE_INFO / SELF_INFO.
class CompanionDetails {
  /// DEVICE_INFO manufacturer string, which MeshCore fills with the board model (e.g. "Heltec V4.3 OLED").
  final String? model;
  final int? fwCode;
  final String? fwBuild;
  final int? maxTxDbm;
  final int? pathHashMode;
  factory CompanionDetails({String? model, int? fwCode, String? fwBuild, int? maxTxDbm, int? pathHashMode}) =>
      CompanionDetails._(
        _str(model, 40),
        _int(fwCode, 0, 255),
        _str(fwBuild, 12),
        _int(maxTxDbm, -10, 40),
        _int(pathHashMode, 0, 3),
      );
  const CompanionDetails._(this.model, this.fwCode, this.fwBuild, this.maxTxDbm, this.pathHashMode);

  bool get isEmpty => toJson().isEmpty;
  Map<String, dynamic> toJson() => {
        if (model != null) 'model': model,
        if (fwCode != null) 'fw_code': fwCode,
        if (fwBuild != null) 'fw_build': fwBuild,
        if (maxTxDbm != null) 'max_tx_dbm': maxTxDbm,
        if (pathHashMode != null) 'path_hash_mode': pathHashMode,
      };
  factory CompanionDetails.fromJson(Map<String, dynamic> j) => CompanionDetails(
        model: _s(j['model']),
        fwCode: _int(j['fw_code'], 0, 255),
        fwBuild: _s(j['fw_build']),
        maxTxDbm: _int(j['max_tx_dbm'], -10, 40),
        pathHashMode: _int(j['path_hash_mode'], 0, 3),
      );
}

/// context.json of one session.
class SessionContext {
  final DeviceDetails? device;
  final CompanionDetails? companionExt;
  SessionContext({DeviceDetails? device, CompanionDetails? companionExt})
      : device = (device == null || device.isEmpty) ? null : device,
        companionExt = (companionExt == null || companionExt.isEmpty) ? null : companionExt;

  bool get isEmpty => device == null && companionExt == null;

  Map<String, dynamic> toJson() => {
        if (device != null) 'device': device!.toJson(),
        if (companionExt != null) 'companion_ext': companionExt!.toJson(),
      };

  factory SessionContext.fromJson(Map<String, dynamic> j) {
    Map<String, dynamic>? m(Object? v) => v is Map ? v.cast<String, dynamic>() : null;
    final d = m(j['device']), c = m(j['companion_ext']);
    return SessionContext(
      device: d == null ? null : DeviceDetails.fromJson(d),
      companionExt: c == null ? null : CompanionDetails.fromJson(c),
    );
  }

  SessionContext without(Set<String> offCategories) =>
      SessionContext.fromJson(_withoutKeys(toJson(), 'session', offCategories));
}

// ------------------------------------------------------------------ storage contract

/// What was removed by a category strip.
class ContextStripResult {
  final int pingContexts;
  final int samples;
  final bool session;
  const ContextStripResult({this.pingContexts = 0, this.samples = 0, this.session = false});
  bool get changed => pingContexts > 0 || samples > 0 || session;
}

/// Context storage beside a drive. [JsonlDriveStore] implements it (files ctx.jsonl, samples.jsonl, context.json in
/// the session's folder), crash-safe the same way as pings.jsonl.
abstract class DriveContextLedger {
  /// Appends samples durably (flushed before the future completes). Empty samples are not written.
  Future<void> appendSamples(String sessionId, Iterable<DriveSample> samples);

  /// Records [ctx] for [pingId] (a later record for the same ping replaces it on read). Empty contexts are not written.
  Future<void> appendPingContext(String sessionId, String pingId, PingContext ctx);

  /// Replaces context.json atomically (an empty context deletes it).
  Future<void> writeSessionContext(String sessionId, SessionContext ctx);

  Future<List<DriveSample>> samples(String sessionId);

  /// Ping id -> context, last record per ping wins.
  Future<Map<String, PingContext>> pingContexts(String sessionId);
  Future<SessionContext?> sessionContext(String sessionId);

  /// Removes every key of [categoryIds] from this session's stored context, rewriting each file atomically (temp file
  /// + rename). Samples and contexts left empty are dropped. Used when a category is switched off.
  Future<ContextStripResult> stripCategories(String sessionId, Set<String> categoryIds);
}

/// Strips [categoryIds] from every session in [sessionIds]; returns the sessions that changed. A failure on one
/// session does not stop the others (it is retried the next time the caller runs it).
Future<List<String>> stripContextCategories(
    DriveContextLedger ledger, Iterable<String> sessionIds, Set<String> categoryIds) async {
  final changed = <String>[];
  if (categoryIds.isEmpty) return changed;
  for (final id in sessionIds) {
    try {
      if ((await ledger.stripCategories(id, categoryIds)).changed) changed.add(id);
    } catch (_) {}
  }
  return changed;
}
