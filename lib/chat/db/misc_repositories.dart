import 'package:sqlite3/sqlite3.dart';

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
INSERT INTO adverts_seen(radio_id, pubkey, type, name, lat, lon, first_ts_ms, last_ts_ms, count, path_len, snr, advert_ts) VALUES (?,?,?,?,?,?,?,?,1,?,?,?)
ON CONFLICT(radio_id, pubkey) DO UPDATE SET type = coalesce(excluded.type, type), name = CASE WHEN excluded.name = '' THEN name ELSE excluded.name END, lat = coalesce(excluded.lat, lat),
  lon = coalesce(excluded.lon, lon), last_ts_ms = max(last_ts_ms, excluded.last_ts_ms), count = count + 1, path_len = excluded.path_len, snr = excluded.snr,
  advert_ts = coalesce(excluded.advert_ts, advert_ts)
''', [a.radioId, a.publicKey.toLowerCase(), a.type?.code, a.name, a.lat, a.lon, a.firstTsMs, a.lastTsMs, a.pathLen, a.snr, a.advertTs]);
  }

  static AdvertSeen _row(Row r) => AdvertSeen(
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
      snr: (r['snr'] as num?)?.toDouble(),
      advertTs: r['advert_ts'] as int?,
      ignored: (r['ignored'] as int) != 0);

  AdvertSeen? get(String radioId, String key) {
    final r = db.raw.select('SELECT * FROM adverts_seen WHERE radio_id = ? AND pubkey = ?', [radioId, key.toLowerCase()]);
    return r.isEmpty ? null : _row(r.first);
  }

  /// "New nodes nearby": heard, named, not a contact yet, not ignored. Newest first.
  List<AdvertSeen> nearby(String radioId, {int limit = 200}) => db.raw
      .select('''
SELECT a.* FROM adverts_seen a
WHERE a.radio_id = ? AND a.ignored = 0 AND a.name <> ''
  AND NOT EXISTS (SELECT 1 FROM contacts c WHERE c.radio_id = a.radio_id AND c.pubkey = a.pubkey)
ORDER BY a.last_ts_ms DESC LIMIT ?''', [radioId, limit])
      .map(_row)
      .toList();

  List<AdvertSeen> ignoredList(String radioId) => db.raw
      .select('SELECT * FROM adverts_seen WHERE radio_id = ? AND ignored = 1 ORDER BY last_ts_ms DESC', [radioId])
      .map(_row)
      .toList();

  void setIgnored(String radioId, String key, bool v) =>
      db.raw.execute('UPDATE adverts_seen SET ignored = ? WHERE radio_id = ? AND pubkey = ?', [v ? 1 : 0, radioId, key.toLowerCase()]);

  void remove(String radioId, String key) => db.raw.execute('DELETE FROM adverts_seen WHERE radio_id = ? AND pubkey = ?', [radioId, key.toLowerCase()]);

  List<AdvertSeen> list(String radioId, {int limit = 500}) =>
      db.raw.select('SELECT * FROM adverts_seen WHERE radio_id = ? ORDER BY last_ts_ms DESC LIMIT ?', [radioId, limit]).map(_row).toList();

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
