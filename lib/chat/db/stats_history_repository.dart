// remote_stats_history (migration v3): one row per successful status read of a repeater, for the dashboard sparklines.
// Trimmed on every insert: nothing older than 7 days and at most 2000 rows per repeater. Pure Dart.
import 'chat_database.dart';

/// One stored status reading. Fields the repeater's firmware did not send are 0 (never null) as in the wire decode.
class StatsPoint {
  final int tsMs;
  final int batteryMv;
  final int noiseFloor;
  final int uptimeS;
  final int txAirS;
  final int rxAirS;
  final int recv;
  final int sent;
  final int lastRssi;
  final int lastSnrX4;
  final int errors;
  final int queue;
  const StatsPoint({
    required this.tsMs,
    required this.batteryMv,
    required this.noiseFloor,
    required this.uptimeS,
    required this.txAirS,
    required this.rxAirS,
    this.recv = 0,
    this.sent = 0,
    this.lastRssi = 0,
    this.lastSnrX4 = 0,
    this.errors = 0,
    this.queue = 0,
  });

  /// Transmit airtime as a percentage of the uptime (0 when the uptime is unknown).
  double get txAirPct => uptimeS > 0 ? txAirS * 100 / uptimeS : 0;
}

class RemoteStatsHistoryRepository {
  static const Duration maxAge = Duration(days: 7);
  static const int maxRows = 2000;

  final ChatDatabase db;
  RemoteStatsHistoryRepository(this.db);

  /// Stores [p] for [contactKey] (64 hex) and trims that repeater's history.
  void insert(String contactKey, StatsPoint p) {
    final key = contactKey.toLowerCase();
    db.transaction(() {
      db.raw.execute(
          'INSERT INTO remote_stats_history(contact_key, ts_ms, battery_mv, noise_floor, uptime_s, tx_air_s, rx_air_s, recv, sent, last_rssi, last_snr_x4, errors, queue) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [key, p.tsMs, p.batteryMv, p.noiseFloor, p.uptimeS, p.txAirS, p.rxAirS, p.recv, p.sent, p.lastRssi, p.lastSnrX4, p.errors, p.queue]);
      db.raw.execute('DELETE FROM remote_stats_history WHERE contact_key = ? AND ts_ms < ?', [key, p.tsMs - maxAge.inMilliseconds]);
      db.raw.execute(
          'DELETE FROM remote_stats_history WHERE contact_key = ? AND rowid NOT IN (SELECT rowid FROM remote_stats_history WHERE contact_key = ? ORDER BY ts_ms DESC, rowid DESC LIMIT ?)',
          [key, key, maxRows]);
    });
  }

  /// The last 7 days before [nowMs], oldest first.
  List<StatsPoint> recent(String contactKey, {required int nowMs}) {
    final rows = db.raw.select(
        'SELECT * FROM remote_stats_history WHERE contact_key = ? AND ts_ms >= ? ORDER BY ts_ms ASC, rowid ASC', [contactKey.toLowerCase(), nowMs - maxAge.inMilliseconds]);
    int i(Object? v) => (v as int?) ?? 0;
    return [
      for (final r in rows)
        StatsPoint(
            tsMs: i(r['ts_ms']),
            batteryMv: i(r['battery_mv']),
            noiseFloor: i(r['noise_floor']),
            uptimeS: i(r['uptime_s']),
            txAirS: i(r['tx_air_s']),
            rxAirS: i(r['rx_air_s']),
            recv: i(r['recv']),
            sent: i(r['sent']),
            lastRssi: i(r['last_rssi']),
            lastSnrX4: i(r['last_snr_x4']),
            errors: i(r['errors']),
            queue: i(r['queue']))
    ];
  }

  int count(String contactKey) => db.raw.select('SELECT count(*) AS n FROM remote_stats_history WHERE contact_key = ?', [contactKey.toLowerCase()]).first['n'] as int;

  void clear(String contactKey) => db.raw.execute('DELETE FROM remote_stats_history WHERE contact_key = ?', [contactKey.toLowerCase()]);
}
