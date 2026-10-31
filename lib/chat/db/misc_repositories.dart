import '../models.dart';
import 'chat_database.dart';

/// One draft per conversation.
class DraftRepository {
  final ChatDatabase db;
  DraftRepository(this.db);

  /// Empty or whitespace-only text deletes the draft.
  void save(String convKey, String text, int nowMs) {
    if (text.trim().isEmpty) {
      db.raw.execute('DELETE FROM drafts WHERE conv_key = ?', [convKey]);
    } else {
      db.raw.execute('INSERT INTO drafts(conv_key, text, updated_ms) VALUES (?,?,?) ON CONFLICT(conv_key) DO UPDATE SET text = excluded.text, updated_ms = excluded.updated_ms',
          [convKey, text, nowMs]);
    }
  }

  String? load(String convKey) {
    final r = db.raw.select('SELECT text FROM drafts WHERE conv_key = ?', [convKey]);
    return r.isEmpty ? null : r.first['text'] as String;
  }

  Map<String, String> all() => {for (final r in db.raw.select('SELECT conv_key, text FROM drafts')) r['conv_key'] as String: r['text'] as String};

  void clear(String convKey) => db.raw.execute('DELETE FROM drafts WHERE conv_key = ?', [convKey]);
}

/// Nodes heard advertising (the Discover list). One row per key, with a count.
class AdvertRepository {
  final ChatDatabase db;
  AdvertRepository(this.db);

  void record(AdvertSeen a) {
    db.raw.execute('''
INSERT INTO adverts_seen(radio_id, pubkey, type, name, lat, lon, first_ts_ms, last_ts_ms, count, path_len, snr) VALUES (?,?,?,?,?,?,?,?,1,?,?)
ON CONFLICT(radio_id, pubkey) DO UPDATE SET type = coalesce(excluded.type, type), name = CASE WHEN excluded.name = '' THEN name ELSE excluded.name END, lat = coalesce(excluded.lat, lat),
  lon = coalesce(excluded.lon, lon), last_ts_ms = max(last_ts_ms, excluded.last_ts_ms), count = count + 1, path_len = excluded.path_len, snr = excluded.snr
''', [a.radioId, a.publicKey.toLowerCase(), a.type?.code, a.name, a.lat, a.lon, a.firstTsMs, a.lastTsMs, a.pathLen, a.snr]);
  }

  List<AdvertSeen> list(String radioId, {int limit = 500}) => db.raw
      .select('SELECT * FROM adverts_seen WHERE radio_id = ? ORDER BY last_ts_ms DESC LIMIT ?', [radioId, limit])
      .map((r) => AdvertSeen(
          radioId: r['radio_id'] as String,
          publicKey: r['pubkey'] as String,
          type: ContactType.fromCode(r['type'] as int?),
          name: r['name'] as String,
          lat: (r['lat'] as num?)?.toDouble(),
          lon: (r['lon'] as num?)?.toDouble(),
          firstTsMs: r['first_ts_ms'] as int,
          lastTsMs: r['last_ts_ms'] as int,
          count: r['count'] as int,
          pathLen: r['path_len'] as int?,
          snr: (r['snr'] as num?)?.toDouble()))
      .toList();

  /// Keeps the newest [keep] entries.
  void prune(int keep) => db.raw.execute(
      'DELETE FROM adverts_seen WHERE (radio_id, pubkey) NOT IN (SELECT radio_id, pubkey FROM adverts_seen ORDER BY last_ts_ms DESC LIMIT ?)', [keep]);
}

/// Counters for the System section (the wardrive channel).
class SystemStatsRepository {
  final ChatDatabase db;
  SystemStatsRepository(this.db);

  void ping(int channelId, int nowMs) => db.raw.execute('''
INSERT INTO system_stats(channel_id, pings_sent, last_ping_ms) VALUES (?,1,?)
ON CONFLICT(channel_id) DO UPDATE SET pings_sent = pings_sent + 1, last_ping_ms = excluded.last_ping_ms
''', [channelId, nowMs]);

  void heard(int channelId, int nowMs) => db.raw.execute('''
INSERT INTO system_stats(channel_id, heard_others, last_heard_ms) VALUES (?,1,?)
ON CONFLICT(channel_id) DO UPDATE SET heard_others = heard_others + 1, last_heard_ms = excluded.last_heard_ms
''', [channelId, nowMs]);

  ({int pingsSent, int? lastPingMs, int heardOthers, int? lastHeardMs}) get(int channelId) {
    final r = db.raw.select('SELECT * FROM system_stats WHERE channel_id = ?', [channelId]);
    if (r.isEmpty) return (pingsSent: 0, lastPingMs: null, heardOthers: 0, lastHeardMs: null);
    final x = r.first;
    return (pingsSent: x['pings_sent'] as int, lastPingMs: x['last_ping_ms'] as int?, heardOthers: x['heard_others'] as int, lastHeardMs: x['last_heard_ms'] as int?);
  }
}
