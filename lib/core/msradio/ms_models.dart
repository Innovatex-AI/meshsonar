// Typed replies of the MeshSonar radio local API (meshsonar-firmware docs/APP-INTEGRATION.md section 4).
// Parsing is tolerant, in the style of lib/core/person_observers.dart: unknown fields are ignored, a missing or mistyped
// optional field is null (or the documented default), a list row that cannot be read is skipped. Only a reply that is not a
// JSON object at all is an error ([MsRadioError] badReply, thrown by the API client). Keys are lower-cased. A token is
// never printed by toString. Nothing here is ever uploaded by the app. Pure Dart.

// ---------------------------------------------------------------- tolerant readers
String? _s(Object? v, [int max = 400]) => v is String ? (v.length > max ? v.substring(0, max) : v) : null;
String? _sNonEmpty(Object? v, [int max = 400]) {
  final s = _s(v, max);
  return s == null || s.trim().isEmpty ? null : s;
}

int? _i(Object? v) => v is int ? v : (v is double && v.isFinite && v == v.roundToDouble() ? v.toInt() : (v is String ? int.tryParse(v) : null));
double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : (v is String ? double.tryParse(v) : null);
bool? _b(Object? v) => switch (v) {
      bool b => b,
      1 => true,
      0 => false,
      'true' || 'on' || '1' => true,
      'false' || 'off' || '0' => false,
      _ => null,
    };
Map<String, dynamic>? _m(Object? v) => v is Map ? v.map((k, val) => MapEntry('$k', val)) : null;
List<Object?> _l(Object? v) => v is List ? v : const [];
DateTime? _epoch(Object? v) {
  final s = _i(v);
  return s == null || s <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
}

final RegExp _hexKey = RegExp(r'^[0-9a-fA-F]{64}$');
String? _key(Object? v) {
  final s = _s(v, 64);
  return s != null && _hexKey.hasMatch(s) ? s.toLowerCase() : null;
}

String? _hexAny(Object? v, int len) {
  final s = _s(v, len);
  return s != null && s.length == len && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s) ? s.toLowerCase() : null;
}

/// A top-level reply object; null when [j] is not a JSON object.
Map<String, dynamic>? msObject(Object? j) => _m(j);

// ---------------------------------------------------------------- identity
/// `GET /info` (open).
class MsInfo {
  final int? api;
  final String? product;

  /// MeshSonar version, e.g. `0.1.0`.
  final String? fw;

  /// MeshCore version, e.g. `v1.18.0`.
  final String? core;

  /// The DEVICE_INFO string, e.g. `v1.18.0-ms0.1.0`.
  final String? fwString;

  /// Board id, e.g. `heltec_v4_touch`.
  final String? board;
  final String? model;

  /// The radio's public key, lower-case 64 hex; null when the reply had none (then the address is never used).
  final String? key;
  final String? name;

  /// `meshsonar-xxxxxxxx.local`.
  final String? host;
  final String? ip;

  /// Pairing methods the radio offers (`sign`, `approve`).
  final List<String> pair;

  /// True when the request carried a valid token.
  final bool paired;
  final bool webConsole;

  const MsInfo({
    this.api,
    this.product,
    this.fw,
    this.core,
    this.fwString,
    this.board,
    this.model,
    this.key,
    this.name,
    this.host,
    this.ip,
    this.pair = const [],
    this.paired = false,
    this.webConsole = true,
  });

  bool get offersSignedPairing => pair.isEmpty || pair.contains('sign');
  bool get offersApproval => pair.isEmpty || pair.contains('approve');

  /// The first 8 hex of [key] (what the mDNS host and the TXT `pk` carry).
  String? get keyPrefix => key?.substring(0, 8);

  static MsInfo parse(Map<String, dynamic> j) => MsInfo(
        api: _i(j['api']),
        product: _sNonEmpty(j['product'], 80),
        fw: _sNonEmpty(j['fw'], 40),
        core: _sNonEmpty(j['core'], 40),
        fwString: _sNonEmpty(j['fw_string'], 60),
        board: _sNonEmpty(j['board'], 60),
        model: _sNonEmpty(j['model'], 120),
        key: _key(j['key']),
        name: _s(j['name'], 64),
        host: _sNonEmpty(j['host'], 120),
        ip: _sNonEmpty(j['ip'], 64),
        pair: [for (final p in _l(j['pair'])) ?_sNonEmpty(p, 20)],
        paired: _b(j['paired']) ?? false,
        webConsole: _b(j['web_console']) ?? true,
      );
}

// ---------------------------------------------------------------- status and its parts
class MsDevice {
  final String? name, key, fw, core, board, model;
  final int? uptimeS, battMv, battPct;
  final bool? clockSet;

  /// The radio's clock (UTC).
  final DateTime? time;

  /// `GPS`, `NTP`, `phone`, ... as the radio says it.
  final String? clockSource;
  final int? heapInternal, psramFree;
  const MsDevice({
    this.name,
    this.key,
    this.fw,
    this.core,
    this.board,
    this.model,
    this.uptimeS,
    this.battMv,
    this.battPct,
    this.clockSet,
    this.time,
    this.clockSource,
    this.heapInternal,
    this.psramFree,
  });

  static MsDevice? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsDevice(
      name: _s(j['name'], 64),
      key: _key(j['key']),
      fw: _sNonEmpty(j['fw'], 40),
      core: _sNonEmpty(j['core'], 40),
      board: _sNonEmpty(j['board'], 60),
      model: _sNonEmpty(j['model'], 120),
      uptimeS: _i(j['uptime_s']),
      battMv: _i(j['batt_mv']),
      battPct: _i(j['batt_pct']),
      clockSet: _b(j['clock_set']),
      time: _epoch(j['time']),
      clockSource: _sNonEmpty(j['clock_source'], 40),
      heapInternal: _i(j['heap_internal']),
      psramFree: _i(j['psram_free']),
    );
  }
}

/// The mesh radio settings (`status.radio`).
class MsRadioParams {
  final double? freqMhz, bwKhz;
  final int? sf, cr, txDbm, contacts;
  const MsRadioParams({this.freqMhz, this.bwKhz, this.sf, this.cr, this.txDbm, this.contacts});

  static MsRadioParams? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsRadioParams(freqMhz: _d(j['freq']), bwKhz: _d(j['bw']), sf: _i(j['sf']), cr: _i(j['cr']), txDbm: _i(j['tx_dbm']), contacts: _i(j['contacts']));
  }
}

class MsWifi {
  /// Plain text, e.g. `Connected to Home`.
  final String? state;
  final String? ssid, ip, host;
  final int? rssi;
  final bool? mdns, timeSynced;
  const MsWifi({this.state, this.ssid, this.ip, this.host, this.rssi, this.mdns, this.timeSynced});

  static MsWifi? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsWifi(
      state: _sNonEmpty(j['state'], 120),
      ssid: _s(j['ssid'], 64),
      ip: _sNonEmpty(j['ip'], 64),
      host: _sNonEmpty(j['host'], 120),
      rssi: _i(j['rssi']),
      mdns: _b(j['mdns']),
      timeSynced: _b(j['time_synced']),
    );
  }
}

/// The radio's own MeshSonar uplink (`status.uplink`, `GET /uplink`).
class MsUplinkState {
  /// Plain text, e.g. `Connected to MeshSonar (CMH)`.
  final String? state;

  /// Log what the radio hears.
  final bool capture;

  /// Live upload to MeshSonar (by the radio itself).
  final bool share;

  /// A GPS point every 15 s while the fix is valid (needs [capture]).
  final bool wardrive;
  final String? iata;
  final bool? mqtt;

  /// Linked to a MeshSonar account (owner key set).
  final bool? linked;
  const MsUplinkState({this.state, this.capture = false, this.share = false, this.wardrive = false, this.iata, this.mqtt, this.linked});

  static MsUplinkState? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsUplinkState(
      state: _sNonEmpty(j['state'], 120),
      capture: _b(j['capture']) ?? false,
      share: _b(j['share']) ?? false,
      wardrive: _b(j['wardrive']) ?? false,
      iata: _sNonEmpty(j['iata'], 8),
      mqtt: _b(j['mqtt']),
      linked: _b(j['linked']),
    );
  }
}

/// Counters of the on-radio log (`status.log`).
class MsLogCounters {
  final int? heard, heardHour, sent, sentHour, pending, backlogSent, backlogMaxS, dropped, logged, logBytes, gpsPoints;
  final double? bestSnr;
  const MsLogCounters({
    this.heard,
    this.heardHour,
    this.sent,
    this.sentHour,
    this.pending,
    this.backlogSent,
    this.backlogMaxS,
    this.dropped,
    this.logged,
    this.logBytes,
    this.gpsPoints,
    this.bestSnr,
  });

  static MsLogCounters? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsLogCounters(
      heard: _i(j['heard']),
      heardHour: _i(j['heard_hour']),
      sent: _i(j['sent']),
      sentHour: _i(j['sent_hour']),
      pending: _i(j['pending']),
      backlogSent: _i(j['backlog_sent']),
      backlogMaxS: _i(j['backlog_max_s']),
      dropped: _i(j['dropped']),
      logged: _i(j['logged']),
      logBytes: _i(j['log_bytes']),
      gpsPoints: _i(j['gps_points']),
      bestSnr: _d(j['best_snr']),
    );
  }
}

/// `status.ota`.
class MsOtaBrief {
  final String state;
  final bool busy;
  final int progress;
  final bool updateAvailable;
  const MsOtaBrief({this.state = '', this.busy = false, this.progress = 0, this.updateAvailable = false});

  static MsOtaBrief? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsOtaBrief(
        state: _s(j['state'], 40) ?? '', busy: _b(j['busy']) ?? false, progress: _i(j['progress']) ?? 0, updateAvailable: _b(j['update_available']) ?? false);
  }
}

/// A job with progress (`status.maps`).
class MsBusy {
  final bool busy;

  /// 0-100.
  final int progress;
  const MsBusy({this.busy = false, this.progress = 0});

  static MsBusy? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsBusy(busy: _b(j['busy']) ?? false, progress: _i(j['progress']) ?? 0);
  }
}

/// `status.apps`.
class MsAppsBrief {
  final int count;
  final bool running;

  /// The id of the app on the radio's screen; empty when none.
  final String current;
  const MsAppsBrief({this.count = 0, this.running = false, this.current = ''});

  static MsAppsBrief? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsAppsBrief(count: _i(j['count']) ?? 0, running: _b(j['running']) ?? false, current: _s(j['current'], 64) ?? '');
  }
}

/// `status.rf`.
class MsRfBrief {
  final bool scanning;
  final int? txBudgetPct;
  const MsRfBrief({this.scanning = false, this.txBudgetPct});

  static MsRfBrief? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsRfBrief(scanning: _b(j['scanning']) ?? false, txBudgetPct: _i(j['tx_budget_pct']));
  }
}

/// The lock screen PIN state.
class MsLockState {
  /// A PIN is set.
  final bool set;
  final bool locked;
  const MsLockState({this.set = false, this.locked = false});

  static MsLockState? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsLockState(set: _b(j['set']) ?? false, locked: _b(j['locked']) ?? false);
  }
}

/// `GET /status`: everything at a glance. Every part is null when the radio left it out.
class MsStatus {
  final MsDevice? device;
  final MsRadioParams? radio;
  final MsWifi? wifi;
  final MsUplinkState? uplink;
  final MsLogCounters? log;
  final MsOtaBrief? ota;
  final MsBusy? maps;
  final MsAppsBrief? apps;
  final MsRfBrief? rf;
  final MsLockState? lock;
  const MsStatus({this.device, this.radio, this.wifi, this.uplink, this.log, this.ota, this.maps, this.apps, this.rf, this.lock});

  static MsStatus parse(Map<String, dynamic> j) => MsStatus(
        device: MsDevice.tryParse(j['device']),
        radio: MsRadioParams.tryParse(j['radio']),
        wifi: MsWifi.tryParse(j['wifi']),
        uplink: MsUplinkState.tryParse(j['uplink']),
        log: MsLogCounters.tryParse(j['log']),
        ota: MsOtaBrief.tryParse(j['ota']),
        maps: MsBusy.tryParse(j['maps']),
        apps: MsAppsBrief.tryParse(j['apps']),
        rf: MsRfBrief.tryParse(j['rf']),
        lock: MsLockState.tryParse(j['lock']),
      );
}

/// `GET /uplink` and the reply of `POST /uplink`.
class MsUplink {
  final MsUplinkState? uplink;
  final MsLogCounters? log;

  /// The MeshSonar account link (lower-case 64 hex); null when none.
  final String? ownerKey;
  final String? ownerName;
  const MsUplink({this.uplink, this.log, this.ownerKey, this.ownerName});

  static MsUplink parse(Map<String, dynamic> j) => MsUplink(
        // a POST may answer with the uplink fields at the top level
        uplink: MsUplinkState.tryParse(j['uplink']) ?? (j.containsKey('capture') ? MsUplinkState.tryParse(j) : null),
        log: MsLogCounters.tryParse(j['log']),
        ownerKey: _key(j['owner_key']),
        ownerName: _sNonEmpty(j['owner_name'], 64),
      );
}

// ---------------------------------------------------------------- log
enum MsLogWhich { current, old }

class MsLogFile {
  final MsLogWhich which;
  final String path;
  final int size;
  const MsLogFile(this.which, this.path, this.size);

  static MsLogFile? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    final w = switch (j['which']) {
      'current' => MsLogWhich.current,
      'old' => MsLogWhich.old,
      _ => null,
    };
    if (w == null) return null;
    return MsLogFile(w, _s(j['path'], 80) ?? '', _i(j['size']) ?? 0);
  }
}

/// `GET /log`.
class MsLog {
  final MsUplinkState? uplink;
  final MsLogCounters? log;

  /// 24 packet counts, oldest hour first (shorter when the radio sent fewer).
  final List<int> hourly;
  final List<MsLogFile> files;

  /// `mslog-v1`.
  final String? format;
  final int? spiffsUsed, spiffsTotal;
  const MsLog({this.uplink, this.log, this.hourly = const [], this.files = const [], this.format, this.spiffsUsed, this.spiffsTotal});

  MsLogFile? file(MsLogWhich which) {
    for (final f in files) {
      if (f.which == which) return f;
    }
    return null;
  }

  static MsLog parse(Map<String, dynamic> j) => MsLog(
        uplink: MsUplinkState.tryParse(j['uplink']),
        log: MsLogCounters.tryParse(j['log']),
        hourly: [for (final h in _l(j['hourly'])) _i(h) ?? 0],
        files: [for (final f in _l(j['files'])) ?MsLogFile.tryParse(f)],
        format: _sNonEmpty(j['format'], 20),
        spiffsUsed: _i(j['spiffs_used']),
        spiffsTotal: _i(j['spiffs_total']),
      );
}

enum MsRecordKind { packet, gps, probe, unknown }

/// One node that answered a signal probe.
class MsProbeNode {
  /// Key prefix as the radio sends it (8 hex, lower-cased).
  final String key;

  /// MeshCore advert type (2 = repeater).
  final int? type;

  /// SNR we heard them at, and they heard us at.
  final double? snr, snrThem;
  final int? rssi;
  const MsProbeNode({required this.key, this.type, this.snr, this.snrThem, this.rssi});

  static MsProbeNode? tryParse(Object? v) {
    final j = _m(v);
    final k = j == null ? null : _sNonEmpty(j['key'], 64);
    if (j == null || k == null) return null;
    return MsProbeNode(key: k.toLowerCase(), type: _i(j['type']), snr: _d(j['snr']), snrThem: _d(j['snr_them']), rssi: _i(j['rssi']));
  }
}

/// The result part of a probe record.
class MsProbeResult {
  /// `manual`, `auto`, ... as the radio says.
  final String? trigger;
  final int answered;

  /// The repeater ping: `answered`, `silent`, `none`, ...
  final String? ping;
  final int? pingMs;
  final String? pingRepeater;
  final List<MsProbeNode> nodes;
  const MsProbeResult({this.trigger, this.answered = 0, this.ping, this.pingMs, this.pingRepeater, this.nodes = const []});

  static MsProbeResult? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsProbeResult(
      trigger: _sNonEmpty(j['trigger'], 20),
      answered: _i(j['answered']) ?? 0,
      ping: _sNonEmpty(j['ping'], 20),
      pingMs: _i(j['ping_ms']),
      pingRepeater: _sNonEmpty(j['ping_repeater'], 64)?.toLowerCase(),
      nodes: [for (final n in _l(j['nodes'])) ?MsProbeNode.tryParse(n)],
    );
  }
}

/// One decoded record of the on-radio log: a packet heard, a GPS point or a signal probe. NEVER uploaded by the app
/// (packets heard while sharing reach MeshSonar from the radio itself) and never treated as an app ping.
class MsLogRecord {
  final int? seq;
  final MsRecordKind kind;
  final DateTime? time;
  final int ms;

  /// Null when there was no GPS fix.
  final double? lat, lon;
  final double? snr;
  final int? rssi;

  /// The raw MeshCore packet as hex (packet records).
  final String? raw;

  /// Probe records.
  final double? bestSnr;
  final int? bestRssi;
  final MsProbeResult? probe;
  const MsLogRecord({
    this.seq,
    required this.kind,
    this.time,
    this.ms = 0,
    this.lat,
    this.lon,
    this.snr,
    this.rssi,
    this.raw,
    this.bestSnr,
    this.bestRssi,
    this.probe,
  });

  bool get hasPosition => lat != null && lon != null;

  static MsLogRecord? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    final kind = switch (j['kind']) {
      'packet' => MsRecordKind.packet,
      'gps' => MsRecordKind.gps,
      'probe' => MsRecordKind.probe,
      _ => MsRecordKind.unknown,
    };
    final lat = _d(j['lat']), lon = _d(j['lon']);
    final okPos = lat != null && lon != null && lat.abs() <= 90 && lon.abs() <= 180;
    final rssi = _i(j['rssi']);
    return MsLogRecord(
      seq: _i(j['seq']),
      kind: kind,
      time: _epoch(j['ts']),
      ms: _i(j['ms']) ?? 0,
      lat: okPos ? lat : null,
      lon: okPos ? lon : null,
      snr: _d(j['snr']),
      rssi: rssi == 127 ? null : rssi,
      raw: _sNonEmpty(j['raw'], 1200),
      bestSnr: _d(j['best_snr']),
      bestRssi: _i(j['best_rssi']),
      probe: MsProbeResult.tryParse(j['probe']),
    );
  }
}

/// `GET /log/records`: one page. Continue with `off = next` until [end]; stop at [badRecord].
class MsLogPage {
  final MsLogWhich which;
  final int? size;
  final int off;
  final List<MsLogRecord> records;
  final int? next;
  final bool end;

  /// The file has a damaged record at [next]: stop reading this file.
  final bool badRecord;
  const MsLogPage({this.which = MsLogWhich.current, this.size, this.off = 0, this.records = const [], this.next, this.end = true, this.badRecord = false});

  /// More pages can be read.
  bool get hasMore => !end && !badRecord && next != null;

  static MsLogPage parse(Map<String, dynamic> j) => MsLogPage(
        which: j['which'] == 'old' ? MsLogWhich.old : MsLogWhich.current,
        size: _i(j['size']),
        off: _i(j['off']) ?? 0,
        records: [for (final r in _l(j['records'])) ?MsLogRecord.tryParse(r)],
        next: _i(j['next']),
        // a reply without `end` and without `next` cannot be continued
        end: _b(j['end']) ?? (_i(j['next']) == null),
        badRecord: _b(j['bad_record']) ?? false,
      );
}

/// `GET /probes`: the newest probe records, newest first.
class MsProbes {
  final List<MsLogRecord> records;
  final int? total;
  const MsProbes({this.records = const [], this.total});

  static MsProbes parse(Map<String, dynamic> j) {
    final list = j['records'] ?? j['probes'];
    return MsProbes(records: [for (final r in _l(list)) ?MsLogRecord.tryParse(r)], total: _i(j['total']));
  }
}

/// `POST /probe/now`.
class MsProbeStart {
  final bool ok;

  /// How long the radio listens for answers; read `/probes` after about this plus a margin.
  final int? listenS;
  const MsProbeStart({this.ok = false, this.listenS});

  static MsProbeStart parse(Map<String, dynamic> j) => MsProbeStart(ok: _b(j['ok']) ?? false, listenS: _i(j['listen_s']));
}

// ---------------------------------------------------------------- uploads
/// Where an upload goes, as the radio describes it (`upload` objects).
class MsUploadRoute {
  final String method, path, field;
  final String? sizeArg;
  const MsUploadRoute({this.method = 'POST', required this.path, this.field = 'file', this.sizeArg});

  static MsUploadRoute? tryParse(Object? v) {
    final j = _m(v);
    final p = j == null ? null : _sNonEmpty(j['path'], 80);
    if (j == null || p == null || !p.startsWith('/')) return null;
    return MsUploadRoute(
        method: _sNonEmpty(j['method'], 8) ?? 'POST', path: p, field: _sNonEmpty(j['field'], 40) ?? 'file', sizeArg: _sNonEmpty(j['size_arg'], 40));
  }
}

/// The plain-text reply of an upload route (`Done: 3819 KB written...`).
class MsUploadResult {
  final int status;
  final String text;
  const MsUploadResult(this.status, this.text);
}

// ---------------------------------------------------------------- map pack
class MsMapPack {
  final String? name;
  final int? zmin, zmax, zdef, tiles, bytes;
  final double? lat, lon;
  const MsMapPack({this.name, this.zmin, this.zmax, this.zdef, this.tiles, this.bytes, this.lat, this.lon});

  static MsMapPack? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsMapPack(
      name: _s(j['name'], 80),
      zmin: _i(j['zmin']),
      zmax: _i(j['zmax']),
      zdef: _i(j['zdef']),
      tiles: _i(j['tiles']),
      bytes: _i(j['bytes']),
      lat: _d(j['lat']),
      lon: _d(j['lon']),
    );
  }
}

/// `GET /maps`.
class MsMaps {
  /// The radio has a map partition.
  final bool partition;
  final int? spaceKb;
  final bool busy;
  final int progress;
  final String lastResult;

  /// Null when no pack is in the partition (a pack on the R8's microSD card is not listed).
  final MsMapPack? pack;
  final MsUploadRoute? upload;
  const MsMaps({this.partition = false, this.spaceKb, this.busy = false, this.progress = 0, this.lastResult = '', this.pack, this.upload});

  static MsMaps parse(Map<String, dynamic> j) => MsMaps(
        partition: _b(j['partition']) ?? false,
        spaceKb: _i(j['space_kb']),
        busy: _b(j['busy']) ?? false,
        progress: _i(j['progress']) ?? 0,
        lastResult: _s(j['last_result']) ?? '',
        pack: MsMapPack.tryParse(j['pack']),
        upload: MsUploadRoute.tryParse(j['upload']),
      );
}

// ---------------------------------------------------------------- Lua apps
/// An installed Lua app.
class MsLuaApp {
  final String id;
  final String name;
  final String? version;

  /// Up to 2 characters shown as the icon.
  final String? icon;
  final String? desc;

  /// `builtin`, `catalog` or `upload`.
  final String? source;

  /// The app may use the internet.
  final bool http;
  final int? memoryKb, size;
  const MsLuaApp({required this.id, required this.name, this.version, this.icon, this.desc, this.source, this.http = false, this.memoryKb, this.size});

  bool get isBuiltin => source == 'builtin';

  static MsLuaApp? tryParse(Object? v) {
    final j = _m(v);
    final id = j == null ? null : _sNonEmpty(j['id'], 64);
    if (j == null || id == null) return null;
    return MsLuaApp(
      id: id,
      name: _sNonEmpty(j['name'], 64) ?? id,
      version: _sNonEmpty(j['version'], 20),
      icon: _sNonEmpty(j['icon'], 8),
      desc: _sNonEmpty(j['desc'], 400),
      source: _sNonEmpty(j['source'], 20),
      http: _b(j['http']) ?? false,
      memoryKb: _i(j['memory_kb']),
      size: _i(j['size']),
    );
  }
}

/// A catalog entry.
class MsCatalogEntry {
  final String id;
  final String name;
  final String? version, icon, desc;
  final bool http;
  final int? memoryKb, size;

  /// The version installed on the radio; null when not installed.
  final String? installedVersion;
  const MsCatalogEntry({required this.id, required this.name, this.version, this.icon, this.desc, this.http = false, this.memoryKb, this.size, this.installedVersion});

  bool get installed => installedVersion != null;

  /// Installed and the catalog has another version.
  bool get updateAvailable => installedVersion != null && version != null && version != installedVersion;

  static MsCatalogEntry? tryParse(Object? v) {
    final j = _m(v);
    final id = j == null ? null : _sNonEmpty(j['id'], 64);
    if (j == null || id == null) return null;
    return MsCatalogEntry(
      id: id,
      name: _sNonEmpty(j['name'], 64) ?? id,
      version: _sNonEmpty(j['version'], 20),
      icon: _sNonEmpty(j['icon'], 8),
      desc: _sNonEmpty(j['desc'], 400),
      http: _b(j['http']) ?? false,
      memoryKb: _i(j['memory_kb'] ?? j['mem']),
      size: _i(j['size']),
      installedVersion: _sNonEmpty(j['installed_version'], 20),
    );
  }
}

enum MsCatalogState { idle, loading, ok, error }

class MsCatalog {
  final MsCatalogState state;
  final String? note, url;
  final List<MsCatalogEntry> entries;
  const MsCatalog({this.state = MsCatalogState.idle, this.note, this.url, this.entries = const []});

  static MsCatalog? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsCatalog(
      state: switch (j['state']) {
        'loading' => MsCatalogState.loading,
        'ok' => MsCatalogState.ok,
        'error' => MsCatalogState.error,
        _ => MsCatalogState.idle,
      },
      note: _sNonEmpty(j['note']),
      url: _sNonEmpty(j['url']),
      entries: [for (final e in _l(j['entries'])) ?MsCatalogEntry.tryParse(e)],
    );
  }
}

/// `GET /apps`.
class MsApps {
  final List<MsLuaApp> installed;

  /// The id of the running app; null when none.
  final String? running;

  /// The id of an app that failed, and the error text.
  final String? failed, error;
  final MsCatalog? catalog;

  /// An install from the catalog is running (with the id when the radio says which).
  final bool installing;
  final String? installingId;
  final String? installNote;
  final MsUploadRoute? upload;
  const MsApps({
    this.installed = const [],
    this.running,
    this.failed,
    this.error,
    this.catalog,
    this.installing = false,
    this.installingId,
    this.installNote,
    this.upload,
  });

  static MsApps parse(Map<String, dynamic> j) {
    final r = j['running'], inst = j['installing'];
    return MsApps(
      installed: [for (final a in _l(j['installed'])) ?MsLuaApp.tryParse(a)],
      running: r is String && r.isNotEmpty ? _s(r, 64) : null,
      failed: _sNonEmpty(j['failed'], 64),
      error: _sNonEmpty(j['error']),
      catalog: MsCatalog.tryParse(j['catalog']),
      installing: inst == true || (inst is String && inst.isNotEmpty),
      installingId: inst is String && inst.isNotEmpty ? _s(inst, 64) : null,
      installNote: _sNonEmpty(j['install_note']),
      upload: MsUploadRoute.tryParse(j['upload']),
    );
  }
}

// ---------------------------------------------------------------- firmware updates
class MsOtaOffer {
  /// Newer than the running firmware.
  final bool newer;

  /// May be installed (min_version and board checks passed).
  final bool allowed;
  final String? channel, version, sha256, minVersion, notes;
  final int? build, size, checkedSAgo;
  const MsOtaOffer({this.newer = false, this.allowed = false, this.channel, this.version, this.sha256, this.minVersion, this.notes, this.build, this.size, this.checkedSAgo});

  static MsOtaOffer? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsOtaOffer(
      newer: _b(j['newer']) ?? false,
      allowed: _b(j['allowed']) ?? false,
      channel: _sNonEmpty(j['channel'], 20),
      version: _sNonEmpty(j['version'], 40),
      sha256: _sNonEmpty(j['sha256'], 64),
      minVersion: _sNonEmpty(j['min_version'], 40),
      notes: _sNonEmpty(j['notes'], 4000),
      build: _i(j['build']),
      size: _i(j['size']),
      checkedSAgo: _i(j['checked_s_ago']),
    );
  }
}

enum MsOtaState { idle, checking, downloading, receiving, ready, rebooting, unknown }

/// `GET /ota`.
class MsOta {
  final MsOtaState state;

  /// The radio's raw state word (kept for an unknown [state]).
  final String stateWord;
  final String stateText;
  final bool busy;
  final int progress;
  final String lastResult;

  /// Beta channel.
  final bool beta;

  /// Daily check.
  final bool autoCheck;
  final String? feed, fw, board, slot;

  /// The new firmware is kept after it has run for a minute ([validInS] seconds left).
  final bool pendingVerify;
  final int validInS;

  /// Null before a check.
  final MsOtaOffer? offer;
  final MsUploadRoute? upload;
  const MsOta({
    this.state = MsOtaState.idle,
    this.stateWord = 'idle',
    this.stateText = '',
    this.busy = false,
    this.progress = 0,
    this.lastResult = '',
    this.beta = false,
    this.autoCheck = false,
    this.feed,
    this.fw,
    this.board,
    this.slot,
    this.pendingVerify = false,
    this.validInS = 0,
    this.offer,
    this.upload,
  });

  static MsOta parse(Map<String, dynamic> j) {
    final w = _s(j['state'], 40) ?? '';
    return MsOta(
      state: switch (w) {
        '' || 'idle' => MsOtaState.idle,
        'checking' => MsOtaState.checking,
        'downloading' => MsOtaState.downloading,
        'receiving' => MsOtaState.receiving,
        'ready' => MsOtaState.ready,
        'rebooting' => MsOtaState.rebooting,
        _ => MsOtaState.unknown,
      },
      stateWord: w,
      stateText: _s(j['state_text']) ?? '',
      busy: _b(j['busy']) ?? false,
      progress: _i(j['progress']) ?? 0,
      lastResult: _s(j['last_result']) ?? '',
      beta: _b(j['beta']) ?? false,
      autoCheck: _b(j['auto_check']) ?? false,
      feed: _sNonEmpty(j['feed']),
      fw: _sNonEmpty(j['fw'], 40),
      board: _sNonEmpty(j['board'], 60),
      slot: _sNonEmpty(j['slot'], 20),
      pendingVerify: _b(j['pending_verify']) ?? false,
      validInS: _i(j['valid_in_s']) ?? 0,
      offer: MsOtaOffer.tryParse(j['offer']),
      upload: MsUploadRoute.tryParse(j['upload']),
    );
  }
}

// ---------------------------------------------------------------- settings
/// Sounds and alerts.
class MsSounds {
  final bool buzzerBuilt, buzzerFitted;

  /// 1-3.
  final int? volume;
  final bool flash;

  /// Bit mask: bit i = [eventBits] i.
  final int events;

  /// The names of the event bits, in bit order (`dm`, `channel`, `mention`, `delivered`, `not_delivered`, `low_battery`).
  final List<String> eventBits;
  final bool quietOn;

  /// Minutes after local midnight (0-1439).
  final int? quietStart, quietEnd;
  const MsSounds({
    this.buzzerBuilt = false,
    this.buzzerFitted = false,
    this.volume,
    this.flash = false,
    this.events = 0,
    this.eventBits = const [],
    this.quietOn = false,
    this.quietStart,
    this.quietEnd,
  });

  /// Whether the event named [name] is on; false for a name the radio does not list.
  bool eventOn(String name) {
    final i = eventBits.indexOf(name);
    return i >= 0 && (events >> i) & 1 == 1;
  }

  /// [events] with the event [name] switched [on]; unchanged for a name the radio does not list.
  int eventsWith(String name, bool on) {
    final i = eventBits.indexOf(name);
    if (i < 0) return events;
    return on ? events | (1 << i) : events & ~(1 << i);
  }

  static MsSounds? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return MsSounds(
      buzzerBuilt: _b(j['buzzer_built']) ?? false,
      buzzerFitted: _b(j['buzzer_fitted']) ?? false,
      volume: _i(j['volume']),
      flash: _b(j['flash']) ?? false,
      events: _i(j['events']) ?? 0,
      eventBits: [for (final e in _l(j['event_bits'])) ?_sNonEmpty(e, 40)],
      quietOn: _b(j['quiet_on']) ?? false,
      quietStart: _i(j['quiet_start']),
      quietEnd: _i(j['quiet_end']),
    );
  }
}

/// `GET /settings` and the reply of `POST /settings`.
class MsSettings {
  /// The MeshCore node name.
  final String? name;

  /// 5-100.
  final int? brightness;

  /// One of [screenTimeouts]; 0 = never.
  final int? screenTimeoutMs;
  final List<int> screenTimeouts;
  final MsSounds? sounds;
  final MsLockState? lock;
  const MsSettings({this.name, this.brightness, this.screenTimeoutMs, this.screenTimeouts = const [], this.sounds, this.lock});

  static MsSettings parse(Map<String, dynamic> j) => MsSettings(
        name: _s(j['name'], 64),
        brightness: _i(j['brightness']),
        screenTimeoutMs: _i(j['screen_timeout_ms']),
        screenTimeouts: [for (final t in _l(j['screen_timeouts'])) ?_i(t)],
        sounds: MsSounds.tryParse(j['sounds']),
        lock: MsLockState.tryParse(j['lock']),
      );
}

// ---------------------------------------------------------------- owner link
/// `GET /owner`.
class MsOwner {
  final bool linked;

  /// Lower-case 64 hex; null when not linked.
  final String? ownerKey;
  final String? ownerName;

  /// This radio's own key (it cannot be its own owner).
  final String? selfKey;
  final bool? share;
  const MsOwner({this.linked = false, this.ownerKey, this.ownerName, this.selfKey, this.share});

  static MsOwner parse(Map<String, dynamic> j) {
    final k = _key(j['owner_key']);
    return MsOwner(
      linked: _b(j['linked']) ?? (k != null),
      ownerKey: k,
      ownerName: _sNonEmpty(j['owner_name'], 64),
      selfKey: _key(j['self_key']),
      share: _b(j['share']),
    );
  }
}

// ---------------------------------------------------------------- spectrum
class MsSpectrumScan {
  /// MHz.
  final double f0, f1, step;
  final int n, sweeps, seq;

  /// dBm per step; null = not measured yet.
  final List<double?> last, peak;
  const MsSpectrumScan({required this.f0, required this.f1, required this.step, this.n = 0, this.sweeps = 0, this.seq = 0, this.last = const [], this.peak = const []});

  /// The frequency (MHz) of step [i].
  double freqAt(int i) => f0 + i * step;

  static MsSpectrumScan? tryParse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    final f0 = _d(j['f0']), f1 = _d(j['f1']), step = _d(j['step']);
    if (f0 == null || f1 == null || step == null) return null;
    return MsSpectrumScan(
      f0: f0,
      f1: f1,
      step: step,
      n: _i(j['n']) ?? 0,
      sweeps: _i(j['sweeps']) ?? 0,
      seq: _i(j['seq']) ?? 0,
      last: [for (final x in _l(j['last'])) _d(x)],
      peak: [for (final x in _l(j['peak'])) _d(x)],
    );
  }
}

/// `GET /spectrum`.
class MsSpectrum {
  final bool scanning;

  /// False: this firmware does not report scan data yet (and [scan] is null).
  final bool binsAvailable;
  final MsSpectrumScan? scan;
  const MsSpectrum({this.scanning = false, this.binsAvailable = false, this.scan});

  static MsSpectrum parse(Map<String, dynamic> j) =>
      MsSpectrum(scanning: _b(j['scanning']) ?? false, binsAvailable: _b(j['bins_available']) ?? false, scan: MsSpectrumScan.tryParse(j['scan']));
}

// ---------------------------------------------------------------- pairing and tokens
/// `POST /pair/start`.
class MsPairStart {
  /// Lower-case 64 hex.
  final String key;

  /// The radio's nonce, lower-case 32 hex.
  final String nonce;
  final int expiresIn;

  /// What the radio expects to be signed. Only compared with the text the app builds; NEVER signed itself.
  final String? signText;

  /// 128 hex: the radio's signature over the hello text.
  final String radioSig;
  const MsPairStart({required this.key, required this.nonce, this.expiresIn = 120, this.signText, required this.radioSig});

  /// Throws [FormatException] when a required field is missing or malformed.
  static MsPairStart parse(Map<String, dynamic> j) {
    final key = _key(j['key']);
    final nonce = _hexAny(j['nonce'], 32);
    final sig = _hexAny(j['radio_sig'], 128);
    if (key == null) throw const FormatException('no key');
    if (nonce == null) throw const FormatException('bad nonce');
    if (sig == null) throw const FormatException('bad radio_sig');
    return MsPairStart(key: key, nonce: nonce, expiresIn: _i(j['expires_in']) ?? 120, signText: _s(j['sign_text'], 300), radioSig: sig);
  }
}

/// `POST /pair/finish`, or an approved `pair/ask`.
class MsPairToken {
  /// 32 hex. Secret: never log or show it.
  final String token;

  /// `sign` or `approve`.
  final String? via;
  final String? key;
  const MsPairToken({required this.token, this.via, this.key});

  /// Throws [FormatException] when there is no usable token.
  static MsPairToken parse(Map<String, dynamic> j) {
    final t = _hexAny(j['token'], 32);
    if (t == null) throw const FormatException('no token');
    return MsPairToken(token: t, via: _sNonEmpty(j['via'], 20), key: _key(j['key']));
  }

  @override
  String toString() => 'MsPairToken([redacted], via: $via)';
}

/// `POST /pair/ask`.
class MsPairAsk {
  /// 16 hex: the handle to poll with.
  final String n;
  final int expiresIn;
  const MsPairAsk({required this.n, this.expiresIn = 60});

  static MsPairAsk parse(Map<String, dynamic> j) {
    final n = _sNonEmpty(j['n'], 64);
    if (n == null || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(n)) throw const FormatException('no handle');
    return MsPairAsk(n: n.toLowerCase(), expiresIn: _i(j['expires_in']) ?? 60);
  }
}

enum MsAskState { wait, yes, no, locked, unknown }

/// `GET /pair/ask?n=`.
class MsPairAskResult {
  final MsAskState state;

  /// Set once, with [state] yes. Secret.
  final MsPairToken? token;
  const MsPairAskResult(this.state, {this.token});

  static MsPairAskResult parse(Map<String, dynamic> j) {
    final st = switch (j['state']) {
      'wait' => MsAskState.wait,
      'yes' => MsAskState.yes,
      'no' => MsAskState.no,
      'locked' => MsAskState.locked,
      _ => MsAskState.unknown,
    };
    MsPairToken? t;
    if (st == MsAskState.yes) {
      try {
        t = MsPairToken.parse(j);
      } on FormatException {
        t = null;
      }
    }
    return MsPairAskResult(st, token: t);
  }
}

/// One app paired with the radio (`GET /tokens`). Carries no token.
class MsTokenEntry {
  /// Index for `tokens/revoke i=`.
  final int i;
  final String app;

  /// `sign` or `approve`.
  final String? via;
  final DateTime? created;

  /// Seconds since the radio last saw it.
  final int? seenS;

  /// This app.
  final bool me;
  const MsTokenEntry({required this.i, required this.app, this.via, this.created, this.seenS, this.me = false});

  static MsTokenEntry? tryParse(Object? v) {
    final j = _m(v);
    final i = j == null ? null : _i(j['i']);
    if (j == null || i == null) return null;
    return MsTokenEntry(i: i, app: _sNonEmpty(j['app'], 64) ?? 'App', via: _sNonEmpty(j['via'], 20), created: _epoch(j['created']), seenS: _i(j['seen_s']), me: _b(j['me']) ?? false);
  }
}

class MsTokens {
  final List<MsTokenEntry> tokens;
  const MsTokens(this.tokens);

  static MsTokens parse(Map<String, dynamic> j) => MsTokens([for (final t in _l(j['tokens'])) ?MsTokenEntry.tryParse(t)]);
}

/// The reply of an action endpoint (`apps/run`, `ota/check`, `lock`, ...): `ok` when the radio said so, plus the whole object
/// for anything the screens want to read.
class MsActionResult {
  final bool ok;

  /// A message the radio sent (`message`, `note` or `result`), if any.
  final String? message;
  final Map<String, dynamic> raw;
  const MsActionResult({this.ok = true, this.message, this.raw = const {}});

  static MsActionResult parse(Map<String, dynamic> j) =>
      MsActionResult(ok: _b(j['ok']) ?? true, message: _sNonEmpty(j['message']) ?? _sNonEmpty(j['note']) ?? _sNonEmpty(j['result']), raw: j);
}
