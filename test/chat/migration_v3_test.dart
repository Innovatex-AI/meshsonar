import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/db/chat_database.dart';
import 'package:meshsonar/chat/db/migrations.dart';
import 'package:sqlite3/sqlite3.dart';

Set<String> cols(Database db, String t) => db.select('PRAGMA table_info($t)').map((r) => r['name'] as String).toSet();
Set<String> objects(Database db, String type) =>
    db.select("SELECT name FROM sqlite_master WHERE type = ?", [type]).map((r) => r['name'] as String).toSet();

/// A database exactly as v2 shipped, with rows in every table the migration touches.
Database v2Fixture() {
  final raw = sqlite3.openInMemory();
  migrateDatabase(raw, chatMigrations.take(2).toList());
  raw.execute("INSERT INTO contacts(radio_id, pubkey, type, name, force_flood) VALUES ('r1', '${'a' * 64}', 1, 'Maya', 1)");
  raw.execute("INSERT INTO contacts(radio_id, pubkey, type, name, force_flood) VALUES ('r1', '${'b' * 64}', 1, 'Alex', 0)");
  raw.execute("INSERT INTO conversations(conv_key, radio_id, kind, unread, pinned) VALUES ('d:aaaaaaaaaaaa', 'r1', 'dm', 3, 1)");
  raw.execute('''
INSERT INTO messages(id, radio_id, conv_kind, conv_key, direction, ts_sender, ts_local_ms, text, state, dedupe_key)
VALUES ('m1', 'r1', 'dm', 'd:aaaaaaaaaaaa', 'in', 1, 1000, 'hello', 'received', 'k1')''');
  return raw;
}

/// The newest schema version: v3's checks must hold for every later version too.
final int latest = chatMigrations.last.version;

void main() {
  test('chatMigrations includes v3 and later versions build on it', () {
    expect(chatMigrations[2].version, 3);
    expect(chatMigrations.last.version, greaterThanOrEqualTo(3));
  });

  test('v2 database upgrades to v3: new columns, tables, indexes, and old data intact', () {
    final raw = v2Fixture();
    expect(raw.select('PRAGMA user_version').first.values.first, 2);
    expect(migrateDatabase(raw, chatMigrations), latest);
    expect(raw.select('PRAGMA user_version').first.values.first, latest);

    expect(cols(raw, 'messages'), containsAll(['rssi', 'path_hashes', 'hash_size', 'air_ms']));
    expect(cols(raw, 'contacts'),
        containsAll(['path_mode', 'pinned_path', 'pinned_hash_size', 'path_learned_ms', 'last_ping_ms', 'last_ping_rtt_ms', 'last_ping_ok', 'fw_level', 'last_login_role']));
    expect(cols(raw, 'conversations'), containsAll(['marked_unread', 'last_state', 'draft_preview']));
    expect(cols(raw, 'path_history'), containsAll(['contact_key', 'ts_ms', 'kind', 'hops', 'hash_size', 'rtt_ms', 'ok']));
    expect(cols(raw, 'ping_results'),
        containsAll(['id', 'contact_key', 'ts_ms', 'kind', 'ok', 'rtt_ms', 'hops', 'snr_json', 'path_out', 'path_back', 'fail_reason']));
    expect(cols(raw, 'remote_stats_history'),
        containsAll(['contact_key', 'ts_ms', 'battery_mv', 'noise_floor', 'uptime_s', 'tx_air_s', 'rx_air_s', 'recv', 'sent', 'last_rssi', 'last_snr_x4', 'errors', 'queue']));
    expect(objects(raw, 'index'), containsAll(['conversations_last', 'path_history_contact', 'ping_results_contact', 'remote_stats_contact']));

    // old data untouched, defaults applied
    expect(raw.select("SELECT text, rssi FROM messages WHERE id = 'm1'").first.values, ['hello', null]);
    final cv = raw.select("SELECT unread, pinned, marked_unread, last_state FROM conversations").first;
    expect([cv['unread'], cv['pinned'], cv['marked_unread'], cv['last_state']], [3, 1, 0, null]);
  });

  test('force_flood backfills path_mode: flood for 1, auto for 0', () {
    final raw = v2Fixture();
    migrateDatabase(raw, chatMigrations);
    final m = {for (final r in raw.select('SELECT name, path_mode FROM contacts')) r['name']: r['path_mode']};
    expect(m, {'Maya': 'flood', 'Alex': 'auto'});
  });

  test('running v3 again changes nothing and does not undo a later route choice', () {
    final raw = v2Fixture();
    migrateDatabase(raw, chatMigrations);
    raw.execute("UPDATE contacts SET path_mode = 'fixed', pinned_path = 'aabb' WHERE name = 'Maya'");
    final before = raw.select("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name").map((r) => r['sql']).toList();
    // The user_version is lost (restore, manual reset): v3 must apply again without a duplicate-column failure.
    raw.execute('PRAGMA user_version = 2');
    expect(migrateDatabase(raw, chatMigrations), latest);
    final after = raw.select("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name").map((r) => r['sql']).toList();
    expect(after.length, before.length);
    final maya = raw.select("SELECT path_mode, pinned_path FROM contacts WHERE name = 'Maya'").first;
    expect([maya['path_mode'], maya['pinned_path']], ['fixed', 'aabb']);
    // and a plain reopen at v3 is a no-op
    expect(migrateDatabase(raw, chatMigrations), latest);
  });

  test('a crash in the middle of v3 rolls back everything and leaves v2 intact', () {
    final raw = v2Fixture();
    final broken = [
      ...chatMigrations.take(2),
      Migration(3, 'crashes after applying', (d) {
        chatMigrations[2].apply(d);
        throw StateError('power cut');
      }),
    ];
    expect(() => migrateDatabase(raw, broken), throwsStateError);
    expect(raw.select('PRAGMA user_version').first.values.first, 2);
    expect(cols(raw, 'contacts').contains('path_mode'), isFalse);
    expect(cols(raw, 'messages').contains('rssi'), isFalse);
    expect(objects(raw, 'table').contains('path_history'), isFalse);
    expect(objects(raw, 'index').contains('conversations_last'), isFalse);
    // then the real migration succeeds from there
    expect(migrateDatabase(raw, chatMigrations), latest);
    expect(raw.select("SELECT path_mode FROM contacts WHERE name = 'Maya'").first['path_mode'], 'flood');
  });

  test('a fresh database opens at the latest version through ChatDatabase', () {
    final db = ChatDatabase.inMemory();
    expect(db.schemaVersion, latest);
    expect(cols(db.raw, 'conversations'), contains('marked_unread'));
  });
}
