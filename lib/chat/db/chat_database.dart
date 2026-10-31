// The chat SQLite database (package:sqlite3 directly; see docs/DATA_MODEL.md "Chat database" for why not drift).
// Pure Dart: the caller hands in an open [Database] (in memory for tests, a file from lib/platform/chat_database.dart).
import 'package:sqlite3/sqlite3.dart';

import 'migrations.dart';

class ChatDatabase {
  final Database raw;
  final int schemaVersion;
  int _txDepth = 0;
  bool _closed = false;

  ChatDatabase._(this.raw, this.schemaVersion);

  /// Applies pragmas, then migrations. Throws [ChatDatabaseTooNew] for a database from a newer app.
  factory ChatDatabase.open(Database db, {List<Migration>? migrations, bool wal = false}) {
    if (wal) db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA busy_timeout = 3000');
    final v = migrateDatabase(db, migrations ?? chatMigrations);
    return ChatDatabase._(db, v);
  }

  factory ChatDatabase.inMemory({List<Migration>? migrations}) => ChatDatabase.open(sqlite3.openInMemory(), migrations: migrations);

  /// Runs [f] atomically. Nested calls join the outer transaction through savepoints.
  T transaction<T>(T Function() f) {
    final outer = _txDepth == 0;
    final name = 'sp$_txDepth';
    raw.execute(outer ? 'BEGIN IMMEDIATE' : 'SAVEPOINT $name');
    _txDepth++;
    try {
      final r = f();
      _txDepth--;
      raw.execute(outer ? 'COMMIT' : 'RELEASE $name');
      return r;
    } catch (_) {
      _txDepth--;
      raw.execute(outer ? 'ROLLBACK' : 'ROLLBACK TO $name');
      if (!outer) raw.execute('RELEASE $name');
      rethrow;
    }
  }

  /// Reclaims space after big deletes (delete history, retention). Cannot run inside a transaction.
  void compact() {
    raw.execute("INSERT INTO fts_messages(fts_messages) VALUES ('optimize')");
    raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    raw.execute('VACUUM');
  }

  bool get isClosed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
    raw.close();
  }

  // ---- settings (key/value)

  String? setting(String key) {
    final r = raw.select('SELECT value FROM settings WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void putSetting(String key, String? value) {
    if (value == null) {
      raw.execute('DELETE FROM settings WHERE key = ?', [key]);
    } else {
      raw.execute('INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', [key, value]);
    }
  }
}
