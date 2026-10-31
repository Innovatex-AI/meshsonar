import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/db/chat_database.dart';
import 'package:meshsonar/chat/db/migrations.dart';
import 'package:sqlite3/sqlite3.dart';

List<String> tables(Database db) =>
    db.select("SELECT name FROM sqlite_master WHERE type IN ('table') AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'fts_messages_%' ORDER BY name").map((r) => r['name'] as String).toList();

void main() {
  test('v1 creates every table, indexes and the FTS table', () {
    final db = ChatDatabase.inMemory();
    expect(db.schemaVersion, chatMigrations.last.version);
    expect(tables(db.raw), containsAll(['contacts', 'channels', 'messages', 'conversations', 'delivery_attempts', 'outbox', 'drafts', 'adverts_seen', 'system_stats', 'settings', 'fts_messages']));
    final idx = db.raw.select("SELECT name FROM sqlite_master WHERE type = 'index'").map((r) => r['name']).toSet();
    expect(idx, containsAll(['messages_conv', 'messages_unread', 'attempts_ack', 'outbox_due']));
    expect(db.raw.select('PRAGMA user_version').first.values.first, chatMigrations.last.version);
  });

  test('opening twice does not re-run migrations', () {
    final dir = Directory.systemTemp.createTempSync('chat_db');
    addTearDown(() => dir.deleteSync(recursive: true));
    final p = '${dir.path}/c.db';
    var db = ChatDatabase.open(sqlite3.open(p));
    db.putSetting('k', 'v');
    db.close();
    db = ChatDatabase.open(sqlite3.open(p));
    expect(db.setting('k'), 'v');
    db.close();
  });

  test('upgrade path: a v1 database gets v2 and keeps its data', () {
    final dir = Directory.systemTemp.createTempSync('chat_db');
    addTearDown(() => dir.deleteSync(recursive: true));
    final p = '${dir.path}/c.db';
    var db = ChatDatabase.open(sqlite3.open(p));
    db.raw.execute("INSERT INTO drafts(conv_key, text, updated_ms) VALUES ('d:aaaaaaaaaaaa', 'keep me', 1)");
    db.close();
    final v2 = Migration(2, 'test: add a column', (d) {
      d.execute('ALTER TABLE drafts ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
    });
    db = ChatDatabase.open(sqlite3.open(p), migrations: [...chatMigrations, v2]);
    expect(db.schemaVersion, 2);
    final r = db.raw.select('SELECT text, pinned FROM drafts').first;
    expect(r['text'], 'keep me');
    expect(r['pinned'], 0);
    db.close();
  });

  test('a failing migration rolls back completely and leaves the old version', () {
    final dir = Directory.systemTemp.createTempSync('chat_db');
    addTearDown(() => dir.deleteSync(recursive: true));
    final p = '${dir.path}/c.db';
    ChatDatabase.open(sqlite3.open(p)).close();
    final bad = Migration(2, 'half applied', (d) {
      d.execute('CREATE TABLE half(x)');
      d.execute('THIS IS NOT SQL');
    });
    expect(() => ChatDatabase.open(sqlite3.open(p), migrations: [...chatMigrations, bad]), throwsA(isA<SqliteException>()));
    final raw = sqlite3.open(p);
    expect(raw.select('PRAGMA user_version').first.values.first, 1);
    expect(tables(raw), isNot(contains('half')));
    raw.close();
  });

  test('a database from a newer app is refused, not damaged', () {
    final raw = sqlite3.openInMemory();
    raw.execute('PRAGMA user_version = 99');
    expect(() => ChatDatabase.open(raw), throwsA(isA<ChatDatabaseTooNew>()));
  });

  test('migration list must be contiguous', () {
    expect(() => ChatDatabase.open(sqlite3.openInMemory(), migrations: [Migration(2, 'x', (_) {})]), throwsStateError);
  });

  test('nested transactions: inner failure rolls back only the inner part', () {
    final db = ChatDatabase.inMemory();
    db.transaction(() {
      db.putSetting('a', '1');
      try {
        db.transaction(() {
          db.putSetting('b', '2');
          throw StateError('boom');
        });
      } on StateError {
        // swallowed
      }
    });
    expect(db.setting('a'), '1');
    expect(db.setting('b'), isNull);
  });

  test('FTS stays consistent with messages across insert and delete', () {
    final db = ChatDatabase.inMemory();
    for (var i = 0; i < 5; i++) {
      db.raw.execute(
          "INSERT INTO messages(id, radio_id, conv_kind, conv_key, direction, ts_sender, ts_local_ms, text, state, dedupe_key) VALUES ('m$i','r','dm','d:x','in',$i,$i,'needle $i','received','k$i')");
    }
    int hits() => db.raw.select("SELECT count(*) c FROM fts_messages WHERE fts_messages MATCH '\"needle\"'").first['c'] as int;
    expect(hits(), 5);
    db.raw.execute("DELETE FROM messages WHERE id IN ('m1','m2')");
    expect(hits(), 3);
    db.raw.execute("INSERT INTO fts_messages(fts_messages) VALUES ('integrity-check')"); // throws if the index drifted
    db.compact();
    expect(hits(), 3);
  });
}
