// A Dart port of the live server's Drive Format v1.2 rules (meshcore-insights src/lib/drive/context.ts and
// MESHSONAR_DRIVE_FORMAT.md "v1.2"): strict keys in ctx / samples / device / companion / enrich, the ranges, the
// charsets, "bad device/companion/enrich fails the request", "bad ctx rejects that ping", "bad sample goes to
// sampleRejections", dedupe of samples by (session, src, ts), first write wins for ctx, the late-context endpoint and
// the per-category erase. Used by the sync / wire tests so the app is checked against the contract, not against itself.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Bad implements Exception {
  final String reason;
  _Bad(this.reason);
}

final _model = RegExp(r'^[A-Za-z0-9 ,._-]+$');
final _versionish = RegExp(r'^[A-Za-z0-9 ,._:+-]+$');

bool _isObj(Object? v) => v is Map;

void _only(Map o, List<String> allowed, String where) {
  for (final k in o.keys) {
    if (!allowed.contains(k)) throw _Bad('$where: unknown field "$k"');
  }
}

num? _num(Object? v, num lo, num hi, String where, {bool int = false, bool hiExclusive = false}) {
  if (v == null) return null;
  if (v is! num || !v.isFinite || v < lo || (hiExclusive ? v >= hi : v > hi)) throw _Bad('$where is out of range');
  if (int && v != v.truncate()) throw _Bad('$where is out of range');
  return v;
}

String? _str(Object? v, int max, RegExp re, String where) {
  if (v == null) return null;
  if (v is! String) throw _Bad('$where is out of range');
  final s = v.trim();
  if (s.isEmpty) return null;
  if (s.length > max || !re.hasMatch(s)) throw _Bad('$where is out of range');
  return s;
}

const _ctxKeys = ['alt_m', 'alt_acc_m', 'course_deg', 'course_acc_deg', 'speed_acc_mps', 'pressure_hpa', 'phone_batt_pct', 'radio_batt_mv'];

Map<String, dynamic>? readCtx(Object? raw) {
  if (raw == null) return null;
  if (!_isObj(raw)) throw _Bad('ctx must be an object');
  final o = raw as Map;
  _only(o, _ctxKeys, 'ctx');
  final spec = <String, num?>{
    'alt_m': _num(o['alt_m'], -500, 9000, 'ctx.alt_m'),
    'alt_acc_m': _num(o['alt_acc_m'], 0, 10000, 'ctx.alt_acc_m'),
    'course_deg': _num(o['course_deg'], 0, 360, 'ctx.course_deg', hiExclusive: true),
    'course_acc_deg': _num(o['course_acc_deg'], 0, 180, 'ctx.course_acc_deg'),
    'speed_acc_mps': _num(o['speed_acc_mps'], 0, 150, 'ctx.speed_acc_mps'),
    'pressure_hpa': _num(o['pressure_hpa'], 300, 1100, 'ctx.pressure_hpa'),
    'phone_batt_pct': _num(o['phone_batt_pct'], 0, 100, 'ctx.phone_batt_pct', int: true),
    'radio_batt_mv': _num(o['radio_batt_mv'], 0, 10000, 'ctx.radio_batt_mv', int: true),
  };
  final out = <String, dynamic>{for (final e in spec.entries) if (e.value != null) e.key: e.value};
  return out.isEmpty ? null : out;
}

const _radioKeys = ['batt_mv', 'uptime_s', 'err_flags', 'queue', 'tx_air_s', 'rx_air_s', 'last_rssi', 'last_snr', 'noise_dbm', 'mcu_temp_c', 'pkts', 'storage_kb'];
const _phoneKeys = ['batt_pct', 'batt_state', 'low_power', 'pressure_hpa'];
const _pktKeys = ['recv', 'sent', 'flood_tx', 'direct_tx', 'flood_rx', 'direct_rx', 'recv_errors'];
const _u32 = 4294967295;

Map<String, dynamic> readSample(Object? raw, DateTime lo, DateTime hi) {
  if (!_isObj(raw)) throw _Bad('not an object');
  final o = raw as Map;
  _only(o, ['ts', 'src', ..._radioKeys, ..._phoneKeys], 'sample');
  if (o['src'] != 'radio' && o['src'] != 'phone') throw _Bad('src must be radio or phone');
  final src = o['src'] as String;
  final t = o['ts'] is String ? DateTime.tryParse(o['ts'] as String) : null;
  if (t == null) throw _Bad('ts must be an ISO timestamp');
  if (t.isBefore(lo) || t.isAfter(hi)) throw _Bad("ts is outside the drive's window (start - 1 h .. end + 1 h)");
  for (final k in src == 'radio' ? _phoneKeys : _radioKeys) {
    if (o[k] != null) throw _Bad('$k does not belong to a $src sample');
  }
  final data = <String, dynamic>{};
  void put(String k, num? v) {
    if (v != null) data[k] = v;
  }

  if (src == 'radio') {
    put('batt_mv', _num(o['batt_mv'], 1, 10000, 'sample.batt_mv', int: true));
    put('uptime_s', _num(o['uptime_s'], 0, _u32, 'sample.uptime_s', int: true));
    put('err_flags', _num(o['err_flags'], 0, 65535, 'sample.err_flags', int: true));
    put('queue', _num(o['queue'], 0, 255, 'sample.queue', int: true));
    put('tx_air_s', _num(o['tx_air_s'], 0, _u32, 'sample.tx_air_s', int: true));
    put('rx_air_s', _num(o['rx_air_s'], 0, _u32, 'sample.rx_air_s', int: true));
    put('last_rssi', _num(o['last_rssi'], -160, 0, 'sample.last_rssi', int: true));
    put('last_snr', _num(o['last_snr'], -40, 40, 'sample.last_snr'));
    put('noise_dbm', _num(o['noise_dbm'], -160, 0, 'sample.noise_dbm'));
    put('mcu_temp_c', _num(o['mcu_temp_c'], -40, 125, 'sample.mcu_temp_c'));
    if (o['pkts'] != null) {
      if (!_isObj(o['pkts'])) throw _Bad('pkts must be an object');
      final p = o['pkts'] as Map;
      _only(p, _pktKeys, 'sample.pkts');
      final m = <String, num>{};
      for (final k in _pktKeys) {
        final v = _num(p[k], 0, _u32, 'sample.pkts.$k', int: true);
        if (v != null) m[k] = v;
      }
      if (m.isNotEmpty) data['pkts'] = m;
    }
    if (o['storage_kb'] != null) {
      if (!_isObj(o['storage_kb'])) throw _Bad('storage_kb must be an object');
      final p = o['storage_kb'] as Map;
      _only(p, ['used', 'total'], 'sample.storage_kb');
      final m = <String, num>{};
      for (final k in ['used', 'total']) {
        final v = _num(p[k], 0, _u32, 'sample.storage_kb.$k', int: true);
        if (v != null) m[k] = v;
      }
      if (m.isNotEmpty) data['storage_kb'] = m;
    }
  } else {
    put('batt_pct', _num(o['batt_pct'], 0, 100, 'sample.batt_pct', int: true));
    if (o['batt_state'] != null) {
      if (!['charging', 'full', 'unplugged', 'unknown'].contains(o['batt_state'])) throw _Bad('sample.batt_state is out of range');
      data['batt_state'] = o['batt_state'];
    }
    if (o['low_power'] != null) {
      if (o['low_power'] is! bool) throw _Bad('sample.low_power is out of range');
      data['low_power'] = o['low_power'];
    }
    put('pressure_hpa', _num(o['pressure_hpa'], 300, 1100, 'sample.pressure_hpa'));
  }
  if (data.isEmpty) throw _Bad('sample carries no measurement');
  return {'src': src, 'ts': t.toUtc().toIso8601String(), 'data': data};
}

/// What the server holds for one session.
class StoredSession {
  Map<String, dynamic>? device;
  Map<String, dynamic>? companionExt;
  bool enrichWeather = false;
  final Set<String> erased = {};
  final Map<String, Map<String, dynamic>> pingCtx = {};
  final Set<String> pings = {};
  final Map<String, Map<String, dynamic>> samples = {}; // key src|ts
  DateTime startedAt = DateTime.now().toUtc();
  DateTime? endedAt;
}

class V12Server {
  final Map<String, StoredSession> sessions = {};
  final List<Map<String, dynamic>> uploads = []; // drive-upload bodies, in order
  final List<Map<String, dynamic>> lateUploads = []; // drive-context POST bodies
  final List<String> deletes = []; // categories asked to erase
  final Set<String> badPings = {}; // ping ids rejected for a non-context reason
  final Set<String> ctxRefused = {}; // pings whose ctx this server refuses (ping stays valid without it)
  bool rejectV12Whole = false; // answer every v1.2 body with 400
  bool acceptsV12 = true;
  int? failStatus; // answer every request with this status
  int? lateStatus; // answer drive-context POST with this status
  int? deleteStatus;
  bool networkDown = false;

  http.Response _json(Object b, [int s = 200]) => http.Response(jsonEncode(b), s, headers: {'content-type': 'application/json'});

  late final MockClient client = MockClient((req) async {
    if (networkDown) throw http.ClientException('connection reset');
    if (failStatus != null) return _json({'error': 'nope'}, failStatus!);
    final name = req.url.pathSegments.last;
    if (name == 'drive-upload') return _upload(jsonDecode(req.body) as Map<String, dynamic>);
    if (name == 'drive-context' && req.method == 'POST') return _late(jsonDecode(req.body) as Map<String, dynamic>);
    if (name == 'drive-context' && req.method == 'DELETE') return _delete(req.url.queryParameters['category']);
    return _json({'error': 'unexpected ${req.method} $name'}, 500);
  });

  http.Response _upload(Map<String, dynamic> body) {
    uploads.add(body);
    final fmt = body['format'];
    final v12 = fmt == 'meshsonar.drive.v1.2';
    if (v12 && rejectV12Whole) return _json({'error': 'session.device: unknown field "x"'}, 400);
    if (fmt != 'meshsonar.drive.v1' && fmt != 'meshsonar.drive.v1.1' && !(v12 && acceptsV12)) {
      return _json({'error': 'unsupported format'}, 400);
    }
    final s = body['session'] as Map<String, dynamic>;
    final st = sessions.putIfAbsent(s['id'] as String, StoredSession.new);
    st.startedAt = DateTime.parse(s['started_at'] as String);
    st.endedAt = s['ended_at'] == null ? null : DateTime.parse(s['ended_at'] as String);
    Map<String, dynamic>? device, ext;
    bool? weather;
    if (v12) {
      try {
        final d = s['device'];
        if (d != null) {
          if (!_isObj(d)) throw _Bad('session.device must be an object');
          final m = d as Map;
          _only(m, ['os', 'os_version', 'model', 'app_build'], 'session.device');
          if (m['os'] != null && m['os'] != 'ios' && m['os'] != 'android') throw _Bad('session.device.os is out of range');
          device = {
            'os': m['os'],
            'os_version': _str(m['os_version'], 20, _versionish, 'session.device.os_version'),
            'model': _str(m['model'], 40, _model, 'session.device.model'),
            'app_build': _str(m['app_build'], 10, _versionish, 'session.device.app_build'),
          }..removeWhere((_, v) => v == null);
        }
        final c = s['companion'];
        if (c != null) {
          final m = c as Map;
          _only(m, ['public_key', 'name', 'firmware', 'model', 'fw_code', 'fw_build', 'max_tx_dbm', 'path_hash_mode'], 'session.companion');
          ext = {
            'model': _str(m['model'], 40, _model, 'session.companion.model'),
            'fw_code': _num(m['fw_code'], 0, 255, 'session.companion.fw_code', int: true),
            'fw_build': _str(m['fw_build'], 12, _versionish, 'session.companion.fw_build'),
            'max_tx_dbm': _num(m['max_tx_dbm'], -10, 40, 'session.companion.max_tx_dbm'),
            'path_hash_mode': _num(m['path_hash_mode'], 0, 3, 'session.companion.path_hash_mode', int: true),
          }..removeWhere((_, v) => v == null);
        }
        final e = s['enrich'];
        if (e != null) {
          final m = e as Map;
          _only(m, ['weather'], 'session.enrich');
          if (m['weather'] != null && m['weather'] is! bool) throw _Bad('session.enrich.weather is out of range');
          weather = m['weather'] as bool?;
        }
      } on _Bad catch (e) {
        return _json({'error': e.reason}, 400);
      }
      if (body['samples'] != null && (body['samples'] is! List)) return _json({'error': 'samples must be a list'}, 400);
      if (((body['samples'] as List?) ?? const []).length > 2000) return _json({'error': 'at most 2000 samples per request'}, 400);
    }
    final pings = (body['pings'] as List).cast<Map<String, dynamic>>();
    var stored = 0, dup = 0;
    final rejections = <Map<String, dynamic>>[];
    for (final (i, p) in pings.indexed) {
      final id = p['id'] as String;
      if (badPings.contains(id)) {
        rejections.add({'index': i, 'id': id, 'reason': 'lat/lon missing or out of range'});
        continue;
      }
      Map<String, dynamic>? ctx;
      if (v12) {
        if (ctxRefused.contains(id) && p['ctx'] != null) {
          rejections.add({'index': i, 'id': id, 'reason': 'ctx.alt_m is out of range'});
          continue;
        }
        try {
          ctx = readCtx(p['ctx']);
        } on _Bad catch (e) {
          rejections.add({'index': i, 'id': id, 'reason': e.reason});
          continue;
        }
      }
      if (st.pings.add(id)) {
        stored++;
      } else {
        dup++;
      }
      if (ctx != null) {
        final cur = st.pingCtx.putIfAbsent(id, () => {});
        for (final e in ctx.entries) {
          cur.putIfAbsent(e.key, () => e.value); // the stored value of a key wins
        }
      }
    }
    final out = <String, dynamic>{
      'sessionId': s['id'], 'stored': stored, 'duplicate': dup, 'rejected': rejections.length, 'rejections': rejections.take(20).toList(),
    };
    if (v12) {
      if (device != null && !st.erased.contains('device')) st.device = device;
      if (ext != null && !st.erased.contains('radio_config')) st.companionExt = ext;
      if (weather != null && !st.erased.contains('weather')) st.enrichWeather = weather;
      if (weather == null) st.enrichWeather = !st.erased.contains('weather');
      out.addAll(_samples(st, body['samples'], out));
    }
    return _json(out);
  }

  Map<String, dynamic> _samples(StoredSession st, Object? raw, Map<String, dynamic> into) {
    var stored = 0, dup = 0;
    final rej = <Map<String, dynamic>>[];
    final lo = st.startedAt.subtract(const Duration(hours: 1));
    final hi = (st.endedAt ?? DateTime.now().toUtc()).add(const Duration(hours: 1));
    var rejected = 0;
    for (final (i, s) in ((raw as List?) ?? const []).indexed) {
      try {
        final x = readSample(s, lo, hi);
        final key = '${x['src']}|${x['ts']}';
        if (st.samples.containsKey(key)) {
          dup++;
        } else {
          st.samples[key] = x;
          stored++;
        }
      } on _Bad catch (e) {
        rejected++;
        if (rej.length < 20) rej.add({'index': i, 'reason': e.reason});
      }
    }
    return {'samplesStored': stored, 'samplesDuplicate': dup, 'samplesRejected': rejected, 'sampleRejections': rej};
  }

  http.Response _late(Map<String, dynamic> body) {
    lateUploads.add(body);
    if (lateStatus != null) return _json({'error': 'late'}, lateStatus!);
    if (body['format'] != 'meshsonar.drive-context.v1') return _json({'error': 'bad format'}, 400);
    final st = sessions[body['session']];
    if (st == null) return _json({'error': 'no such session'}, 404);
    var updated = 0;
    final rejections = <Map<String, dynamic>>[];
    for (final (i, p) in ((body['pings'] as List?) ?? const []).cast<Map<String, dynamic>>().indexed) {
      final id = p['id'] as String;
      if (!st.pings.contains(id)) {
        rejections.add({'index': i, 'id': id, 'reason': 'unknown ping'});
        continue;
      }
      try {
        final ctx = readCtx(p['ctx']);
        if (ctx != null) {
          final cur = st.pingCtx.putIfAbsent(id, () => {});
          var changed = false;
          for (final e in ctx.entries) {
            if (!cur.containsKey(e.key)) {
              cur[e.key] = e.value;
              changed = true;
            }
          }
          if (changed) updated++;
        }
      } on _Bad catch (e) {
        rejections.add({'index': i, 'id': id, 'reason': e.reason});
      }
    }
    final out = <String, dynamic>{
      'session': body['session'], 'pingsUpdated': updated, 'rejected': rejections.length, 'rejections': rejections,
    };
    out.addAll(_samples(st, body['samples'], out));
    return _json(out);
  }

  http.Response _delete(String? category) {
    if (deleteStatus != null) return _json({'error': 'erase'}, deleteStatus!);
    const cats = ['motion', 'barometer', 'phone_battery', 'device', 'radio_health', 'radio_config', 'weather', 'all'];
    if (!cats.contains(category)) return _json({'error': 'unknown category'}, 400);
    deletes.add(category!);
    var sessionsN = 0, pingsN = 0, samplesN = 0;
    for (final st in sessions.values) {
      sessionsN++;
      pingsN += st.pingCtx.length;
      samplesN += st.samples.length;
      st.erased.addAll(category == 'all' ? cats.where((c) => c != 'all') : [category]);
      if (category == 'all' || category == 'weather') st.enrichWeather = false;
      if (category == 'all' || category == 'device') st.device = null;
      if (category == 'all') {
        st.pingCtx.clear();
        st.samples.clear();
        st.companionExt = null;
      }
    }
    return _json({'category': category, 'sessions': sessionsN, 'pings': pingsN, 'samples': samplesN});
  }
}
