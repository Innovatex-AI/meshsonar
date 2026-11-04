import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import 'chat_database.dart';

class ContactRepository {
  final ChatDatabase db;
  ContactRepository(this.db);

  static Contact fromRow(Row r) => Contact(
        radioId: r['radio_id'] as String,
        publicKey: r['pubkey'] as String,
        type: ContactType.fromCode(r['type'] as int) ?? ContactType.companion,
        name: r['name'] as String,
        customName: r['custom_name'] as String?,
        lat: (r['lat'] as num?)?.toDouble(),
        lon: (r['lon'] as num?)?.toDouble(),
        lastAdvertTs: r['last_advert_ts'] as int?,
        lastMod: r['lastmod'] as int?,
        outPath: r['out_path'] as Uint8List?,
        outPathLen: r['out_path_len'] as int,
        favourite: (r['favourite'] as int) != 0,
        blocked: (r['blocked'] as int) != 0,
        notes: r['notes'] as String,
        source: ContactSource.values.firstWhere((s) => s.name == r['source'], orElse: () => ContactSource.radio),
        onRadio: (r['on_radio'] as int) != 0,
        radioFlags: r['radio_flags'] as int,
        lastHeardMs: r['last_heard_ms'] as int?,
        pathMode: PathMode.parse(r['path_mode'] as String?) == PathMode.auto && (r['force_flood'] as int) != 0
            ? PathMode.flood
            : PathMode.parse(r['path_mode'] as String?),
        pinnedPath: r['pinned_path'] as String?,
        pinnedHashSize: r['pinned_hash_size'] as int?,
        pathLearnedMs: r['path_learned_ms'] as int?,
        lastPingMs: r['last_ping_ms'] as int?,
        lastPingRttMs: r['last_ping_rtt_ms'] as int?,
        lastPingOk: r['last_ping_ok'] == null ? null : (r['last_ping_ok'] as int) != 0,
      );

  /// Inserts or replaces by (radioId, publicKey).
  void upsert(Contact c) {
    db.raw.execute('''
INSERT INTO contacts(radio_id, pubkey, type, name, custom_name, lat, lon, last_advert_ts, lastmod, out_path, out_path_len, favourite, blocked, notes, source,
 on_radio, radio_flags, last_heard_ms, force_flood, path_mode, pinned_path, pinned_hash_size, path_learned_ms, last_ping_ms, last_ping_rtt_ms, last_ping_ok)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(radio_id, pubkey) DO UPDATE SET type=excluded.type, name=excluded.name, custom_name=excluded.custom_name, lat=excluded.lat,
 lon=excluded.lon, last_advert_ts=excluded.last_advert_ts, lastmod=excluded.lastmod, out_path=excluded.out_path,
 out_path_len=excluded.out_path_len, favourite=excluded.favourite, blocked=excluded.blocked, notes=excluded.notes, source=excluded.source,
 on_radio=excluded.on_radio, radio_flags=excluded.radio_flags, last_heard_ms=excluded.last_heard_ms, force_flood=excluded.force_flood,
 path_mode=excluded.path_mode, pinned_path=excluded.pinned_path, pinned_hash_size=excluded.pinned_hash_size, path_learned_ms=excluded.path_learned_ms,
 last_ping_ms=excluded.last_ping_ms, last_ping_rtt_ms=excluded.last_ping_rtt_ms, last_ping_ok=excluded.last_ping_ok
''', [
      c.radioId, c.publicKey.toLowerCase(), c.type.code, c.name, c.customName, c.lat, c.lon, c.lastAdvertTs, c.lastMod, c.outPath,
      c.outPathLen, c.favourite ? 1 : 0, c.blocked ? 1 : 0, c.notes, c.source.name,
      c.onRadio ? 1 : 0, c.radioFlags, c.lastHeardMs, c.forceFlood ? 1 : 0,
      c.pathMode.name, c.pinnedPath, c.pinnedHashSize, c.pathLearnedMs, c.lastPingMs, c.lastPingRttMs, c.lastPingOk == null ? null : (c.lastPingOk! ? 1 : 0),
    ]);
  }

  Contact? get(String radioId, String publicKey) {
    final r = db.raw.select('SELECT * FROM contacts WHERE radio_id = ? AND pubkey = ?', [radioId, publicKey.toLowerCase()]);
    return r.isEmpty ? null : fromRow(r.first);
  }

  /// DM frames carry only a 6-byte prefix (room posts a 4-byte signer prefix). Returns null when unknown or ambiguous.
  Contact? byPrefix(String radioId, String prefixHex) {
    final p = prefixHex.toLowerCase();
    final r = p.length == 12
        ? db.raw.select('SELECT * FROM contacts WHERE radio_id = ? AND substr(pubkey, 1, 12) = ? LIMIT 2', [radioId, p])
        : db.raw.select('SELECT * FROM contacts WHERE radio_id = ? AND substr(pubkey, 1, ?) = ? LIMIT 2', [radioId, p.length, p]);
    return r.length == 1 ? fromRow(r.first) : null;
  }

  List<Contact> list(String radioId, {ContactType? type, bool favouritesOnly = false, bool includeBlocked = true}) {
    final where = StringBuffer('radio_id = ?');
    final args = <Object?>[radioId];
    if (type != null) {
      where.write(' AND type = ?');
      args.add(type.code);
    }
    if (favouritesOnly) where.write(' AND favourite = 1');
    if (!includeBlocked) where.write(' AND blocked = 0');
    return db.raw
        .select('SELECT * FROM contacts WHERE $where ORDER BY favourite DESC, lower(coalesce(nullif(custom_name, \'\'), name)) ASC', args)
        .map(fromRow)
        .toList();
  }

  void setFavourite(String radioId, String key, bool v) =>
      db.raw.execute('UPDATE contacts SET favourite = ? WHERE radio_id = ? AND pubkey = ?', [v ? 1 : 0, radioId, key.toLowerCase()]);

  void setBlocked(String radioId, String key, bool v) =>
      db.raw.execute('UPDATE contacts SET blocked = ? WHERE radio_id = ? AND pubkey = ?', [v ? 1 : 0, radioId, key.toLowerCase()]);

  void setCustomName(String radioId, String key, String? name) =>
      db.raw.execute('UPDATE contacts SET custom_name = ? WHERE radio_id = ? AND pubkey = ?', [name, radioId, key.toLowerCase()]);

  void setNotes(String radioId, String key, String notes) =>
      db.raw.execute('UPDATE contacts SET notes = ? WHERE radio_id = ? AND pubkey = ?', [notes, radioId, key.toLowerCase()]);

  /// Records a learned route (from a path-update push or a successful delivery).
  void setPath(String radioId, String key, Uint8List? path, int pathLen) =>
      db.raw.execute('UPDATE contacts SET out_path = ?, out_path_len = ? WHERE radio_id = ? AND pubkey = ?', [path, pathLen, radioId, key.toLowerCase()]);

  void setForceFlood(String radioId, String key, bool v) =>
      setPathMode(radioId, key, v ? PathMode.flood : PathMode.auto);

  /// Sets the route mode (keeps the legacy `force_flood` column in step) and, for `fixed`, the pinned route.
  void setPathMode(String radioId, String key, PathMode mode, {String? pinnedPath, int? pinnedHashSize, bool keepPinned = false}) {
    if (keepPinned) {
      db.raw.execute('UPDATE contacts SET path_mode = ?, force_flood = ? WHERE radio_id = ? AND pubkey = ?',
          [mode.name, mode == PathMode.flood ? 1 : 0, radioId, key.toLowerCase()]);
    } else {
      db.raw.execute('UPDATE contacts SET path_mode = ?, force_flood = ?, pinned_path = ?, pinned_hash_size = ? WHERE radio_id = ? AND pubkey = ?',
          [mode.name, mode == PathMode.flood ? 1 : 0, mode == PathMode.fixed ? pinnedPath : null, mode == PathMode.fixed ? pinnedHashSize : null, radioId, key.toLowerCase()]);
    }
  }

  void setPathLearned(String radioId, String key, int? ms) =>
      db.raw.execute('UPDATE contacts SET path_learned_ms = ? WHERE radio_id = ? AND pubkey = ?', [ms, radioId, key.toLowerCase()]);

  void setLastPing(String radioId, String key, {required int tsMs, int? rttMs, required bool ok}) => db.raw.execute(
      'UPDATE contacts SET last_ping_ms = ?, last_ping_rtt_ms = ?, last_ping_ok = ? WHERE radio_id = ? AND pubkey = ?',
      [tsMs, rttMs, ok ? 1 : 0, radioId, key.toLowerCase()]);

  void setRadioFlags(String radioId, String key, int flags) =>
      db.raw.execute('UPDATE contacts SET radio_flags = ? WHERE radio_id = ? AND pubkey = ?', [flags, radioId, key.toLowerCase()]);

  void setOnRadio(String radioId, String key, bool v) =>
      db.raw.execute('UPDATE contacts SET on_radio = ? WHERE radio_id = ? AND pubkey = ?', [v ? 1 : 0, radioId, key.toLowerCase()]);

  /// Marks [key] heard now (never moves the time backwards).
  void touchHeard(String radioId, String key, int nowMs) => db.raw.execute(
      'UPDATE contacts SET last_heard_ms = ? WHERE radio_id = ? AND pubkey = ? AND (last_heard_ms IS NULL OR last_heard_ms < ?)',
      [nowMs, radioId, key.toLowerCase(), nowMs]);

  /// After a full listing: every contact NOT in [keysOnRadio] is no longer on the radio.
  int clearOnRadioExcept(String radioId, Set<String> keysOnRadio) {
    var n = 0;
    for (final r in db.raw.select('SELECT pubkey FROM contacts WHERE radio_id = ? AND on_radio = 1', [radioId])) {
      if (!keysOnRadio.contains(r['pubkey'] as String)) {
        setOnRadio(radioId, r['pubkey'] as String, false);
        n++;
      }
    }
    return n;
  }

  int countOnRadio(String radioId) =>
      db.raw.select('SELECT count(*) c FROM contacts WHERE radio_id = ? AND on_radio = 1', [radioId]).first['c'] as int;

  void delete(String radioId, String key) => db.raw.execute('DELETE FROM contacts WHERE radio_id = ? AND pubkey = ?', [radioId, key.toLowerCase()]);

  int count(String radioId) => db.raw.select('SELECT count(*) c FROM contacts WHERE radio_id = ?', [radioId]).first['c'] as int;
}
