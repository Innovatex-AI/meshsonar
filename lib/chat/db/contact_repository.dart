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
      );

  /// Inserts or replaces by (radioId, publicKey).
  void upsert(Contact c) {
    db.raw.execute('''
INSERT INTO contacts(radio_id, pubkey, type, name, custom_name, lat, lon, last_advert_ts, lastmod, out_path, out_path_len, favourite, blocked, notes, source)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(radio_id, pubkey) DO UPDATE SET type=excluded.type, name=excluded.name, custom_name=excluded.custom_name, lat=excluded.lat,
 lon=excluded.lon, last_advert_ts=excluded.last_advert_ts, lastmod=excluded.lastmod, out_path=excluded.out_path,
 out_path_len=excluded.out_path_len, favourite=excluded.favourite, blocked=excluded.blocked, notes=excluded.notes, source=excluded.source
''', [
      c.radioId, c.publicKey.toLowerCase(), c.type.code, c.name, c.customName, c.lat, c.lon, c.lastAdvertTs, c.lastMod, c.outPath,
      c.outPathLen, c.favourite ? 1 : 0, c.blocked ? 1 : 0, c.notes, c.source.name,
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

  void delete(String radioId, String key) => db.raw.execute('DELETE FROM contacts WHERE radio_id = ? AND pubkey = ?', [radioId, key.toLowerCase()]);

  int count(String radioId) => db.raw.select('SELECT count(*) c FROM contacts WHERE radio_id = ?', [radioId]).first['c'] as int;
}
