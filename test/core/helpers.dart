// Shared builders and a Dart mirror of the Drive Format v1 shape rules (CMAT src/lib/drive/validate.ts) for tests.
import 'package:meshsonar/core/model.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

DriveSession makeSession({String? id, DateTime? startedAt, DateTime? endedAt, String? label = 'Test loop'}) => DriveSession(
      id: id ?? newId(),
      startedAt: startedAt ?? DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      endedAt: endedAt,
      label: label,
      channel: '#wardriving',
      radio: const Radio(freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5, txDbm: 22),
      antenna: const Antenna(type: 'external', gainDbi: 5.8, heightM: 1.8),
      companion: const Companion(publicKey: 'a1b2c3d4', name: 'KE4BFI-v4', firmware: '1.9'),
    );

/// i % 4: 0 heard nothing, 1 direct echo, 2 multi-hop echo with path, 3 neighbor exchange.
DrivePing makePing(int i, {DateTime? ts, String? id}) {
  final t = ts ?? DateTime.now().toUtc().subtract(const Duration(minutes: 50)).add(Duration(seconds: i));
  final base = DrivePing(
    id: id ?? newId(),
    ts: t,
    lat: 40.126 + i * 1e-5,
    lon: -82.93 - i * 1e-5,
    gpsAccuracyM: i.isEven ? 4.0 : null,
    speedMps: i.isEven ? 13.2 : null,
  );
  switch (i % 4) {
    case 1:
      return DrivePing(
          id: base.id, ts: t, lat: base.lat, lon: base.lon, gpsAccuracyM: base.gpsAccuracyM, speedMps: base.speedMps,
          noiseFloorDbm: -94,
          echoes: const [Echo(repeater: 'df0136', snrDb: 12.75, rssiDbm: -71, hops: 1, path: ['df0136'], delayMs: 840)]);
    case 2:
      return DrivePing(id: base.id, ts: t, lat: base.lat, lon: base.lon, echoes: const [
        Echo(repeater: 'ab12', snrDb: -3.5, rssiDbm: null, hops: 2, path: ['ab12', 'cd34'], delayMs: null),
        Echo(repeater: '0e', snrDb: null, rssiDbm: null, hops: null, path: null, delayMs: 1200),
      ]);
    case 3:
      return DrivePing(
          id: base.id, ts: t, lat: base.lat, lon: base.lon,
          neighbor: const Neighbor(repeater: 'df0136', localSnrDb: 8.25, localRssiDbm: -80, remoteSnrDb: null));
    default:
      return base; // heard nothing
  }
}

final _uuidRe = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);
final _hexRe = RegExp(r'^[0-9a-f]{2,64}$');

/// Problems with a Drive Format v1 body, mirroring validate.ts; empty = valid.
List<String> shapeProblems(Object? body) {
  final out = <String>[];
  bool hex(Object? v) => v is String && _hexRe.hasMatch(v) && v.length.isEven;
  bool iso(Object? v) => v is String && DateTime.tryParse(v) != null && v.endsWith('Z');
  bool range(Object? v, num lo, num hi, {bool integer = false}) =>
      v == null || (v is num && v.isFinite && v >= lo && v <= hi && (!integer || v is int || v == v.roundToDouble()));
  if (body is! Map) return ['body not an object'];
  if (body['format'] != 'meshsonar.drive.v1') out.add('format');
  if (body['app'] is! Map) out.add('app');
  final s = body['session'];
  if (s is! Map) {
    out.add('session');
  } else {
    if (!_uuidRe.hasMatch('${s['id']}')) out.add('session.id');
    if (!iso(s['started_at'])) out.add('session.started_at');
    if (s['ended_at'] != null && !iso(s['ended_at'])) out.add('session.ended_at');
    final r = s['radio'] as Map;
    if (!range(r['freq_mhz'], 100, 3000) || !range(r['sf'], 5, 12, integer: true) || !range(r['cr'], 5, 8, integer: true)) {
      out.add('session.radio');
    }
    final c = s['companion'] as Map;
    if (c['public_key'] != null && !hex(c['public_key'])) out.add('session.companion.public_key');
  }
  final pings = body['pings'];
  if (pings is! List) return [...out, 'pings'];
  if (pings.length > 5000) out.add('too many pings');
  for (final (i, p) in pings.indexed) {
    if (p is! Map) {
      out.add('ping $i');
      continue;
    }
    if (!_uuidRe.hasMatch('${p['id']}')) out.add('ping $i id');
    if (!iso(p['ts'])) out.add('ping $i ts');
    if (p['lat'] is! num || p['lon'] is! num) out.add('ping $i lat/lon');
    if (p['kind'] != 'tx' && p['kind'] != 'rx') out.add('ping $i kind');
    if (!range(p['gps_accuracy_m'], 0, 10000) || !range(p['speed_mps'], 0, 150) || !range(p['noise_floor_dbm'], -160, 0)) {
      out.add('ping $i ranges');
    }
    // Drive Format v1.1 (optional): pkt_hash 16 lower-case hex, tx_epoch_s an integer second, tx_dbm −10…40.
    if (p['pkt_hash'] != null && !(p['pkt_hash'] is String && RegExp(r'^[0-9a-f]{16}$').hasMatch(p['pkt_hash'] as String))) {
      out.add('ping $i pkt_hash');
    }
    if (!range(p['tx_epoch_s'], 1420070400, 4294967295, integer: true) || !range(p['tx_dbm'], -10, 40)) out.add('ping $i v1.1');
    final echoes = p['echoes'];
    if (echoes is! List) {
      out.add('ping $i echoes');
      continue;
    }
    for (final e in echoes) {
      if (e is! Map || !hex(e['repeater'])) out.add('ping $i echo repeater');
      if (e is Map) {
        if (e['path'] != null && (e['path'] is! List || !(e['path'] as List).every(hex))) out.add('ping $i echo path');
        if (!range(e['snr_db'], -40, 40) || !range(e['rssi_dbm'], -160, 0) || !range(e['hops'], 0, 64, integer: true)) {
          out.add('ping $i echo ranges');
        }
      }
    }
    final n = p['neighbor'];
    if (n != null && (n is! Map || !hex(n['repeater']))) out.add('ping $i neighbor');
  }
  return out;
}
