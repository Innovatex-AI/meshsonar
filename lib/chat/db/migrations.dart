// Versioned schema migrations for the chat database (PRAGMA user_version is the version).
// Rules: append-only. Never edit a shipped migration; add the next version. Each runs inside one transaction together with
// the user_version bump, so a crash mid-migration leaves the previous version intact.
import 'package:sqlite3/sqlite3.dart';

class Migration {
  final int version;
  final String description;
  final void Function(Database db) apply;
  const Migration(this.version, this.description, this.apply);
}

class ChatDatabaseTooNew implements Exception {
  final int found;
  final int supported;
  const ChatDatabaseTooNew(this.found, this.supported);
  @override
  String toString() => 'chat database is version $found but this app only understands up to $supported';
}

/// Runs [migrations] (ascending, contiguous from 1) on [db]. Returns the resulting version.
int migrateDatabase(Database db, List<Migration> migrations) {
  for (var i = 0; i < migrations.length; i++) {
    if (migrations[i].version != i + 1) throw StateError('migrations must be contiguous from 1 (got ${migrations[i].version} at $i)');
  }
  final current = db.select('PRAGMA user_version').first.values.first as int;
  final latest = migrations.isEmpty ? 0 : migrations.last.version;
  if (current > latest) throw ChatDatabaseTooNew(current, latest);
  for (final m in migrations.where((m) => m.version > current)) {
    db.execute('BEGIN IMMEDIATE');
    try {
      m.apply(db);
      db.execute('PRAGMA user_version = ${m.version}');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  return latest;
}

/// Shipped migrations.
final List<Migration> chatMigrations = [
  Migration(1, 'initial chat schema', _v1),
  Migration(2, 'contacts: radio cache state, flags, last heard, route choice; adverts: ignore + advert time', _v2),
  Migration(3, 'chat redesign: message radio facts, path modes, ping history, stats history, manual unread', _v3),
  Migration(4, 'message repeats (every heard copy of a channel message), route actually used by a sent DM', _v4),
  Migration(5, 'outbox: send this message by flood (long-press Send)', _v5),
];

/// M5 (chat + radio round, CR2): the person chose "Send by flood" for this one message (long-press Send). Idempotent.
void _v5(Database db) => _addColumn(db, 'outbox', 'force_flood', 'INTEGER NOT NULL DEFAULT 0');

/// M4 (chat + radio round, CR3). Idempotent like M3.
///   * message_repeats: one row per distinct copy of a channel message the radio heard on the air, with the path it took.
///     For a message we sent these are the repeats ("heard by N", which repeater relayed it); for one we received, the
///     different paths it arrived by. Same path heard twice = one row. Deleted with the message (trigger).
///   * messages.sent_path / sent_hash_size: for a DM sent direct, the route the radio held at that moment (hex hop hashes),
///     so details show the route that message used, not whatever the contact's route is later.
void _v4(Database db) {
  db.execute('''
CREATE TABLE IF NOT EXISTS message_repeats (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id TEXT NOT NULL,
  heard_ms INTEGER NOT NULL,
  path_hashes TEXT NOT NULL,
  hash_size INTEGER NOT NULL,
  hops INTEGER NOT NULL,
  snr REAL,
  rssi INTEGER,
  UNIQUE (message_id, path_hashes)
);
CREATE INDEX IF NOT EXISTS message_repeats_msg ON message_repeats (message_id, heard_ms);
CREATE TRIGGER IF NOT EXISTS message_repeats_gc AFTER DELETE ON messages BEGIN
  DELETE FROM message_repeats WHERE message_id = OLD.id;
END;
''');
  _addColumn(db, 'messages', 'sent_path', 'TEXT');
  _addColumn(db, 'messages', 'sent_hash_size', 'INTEGER');
}

/// True when [table] already has [column]. Lets v3 be re-run on a database that got part of it some other way (a restored
/// backup, a build that added a column early) without a "duplicate column" failure.
bool _hasColumn(Database db, String table, String column) =>
    db.select('PRAGMA table_info($table)').any((r) => r['name'] == column);

void _addColumn(Database db, String table, String column, String ddl) {
  if (!_hasColumn(db, table, column)) db.execute('ALTER TABLE $table ADD COLUMN $column $ddl');
}

/// M3 (chat redesign, plan section 6). One transaction, idempotent (every step checks before it adds).
///   * messages: what the radio told us about a received message (RSSI, hop hashes, hash size, airtime);
///   * contacts: route mode (`auto` | `fixed` | `flood`, backfilled from the old `force_flood`), the pinned route, when a
///     route was learned, the last ping, the remote's firmware level and the role of the last login;
///   * conversations: manual "Mark unread", the own-last-message delivery state, a denormalised draft preview;
///   * path_history, ping_results, remote_stats_history (trimmed by their writers) and the indexes the merged Chats list uses.
void _v3(Database db) {
  _addColumn(db, 'messages', 'rssi', 'INTEGER');
  _addColumn(db, 'messages', 'path_hashes', 'TEXT');
  _addColumn(db, 'messages', 'hash_size', 'INTEGER');
  _addColumn(db, 'messages', 'air_ms', 'INTEGER');

  final hadPathMode = _hasColumn(db, 'contacts', 'path_mode');
  _addColumn(db, 'contacts', 'path_mode', "TEXT NOT NULL DEFAULT 'auto'");
  _addColumn(db, 'contacts', 'pinned_path', 'TEXT');
  _addColumn(db, 'contacts', 'pinned_hash_size', 'INTEGER');
  _addColumn(db, 'contacts', 'path_learned_ms', 'INTEGER');
  _addColumn(db, 'contacts', 'last_ping_ms', 'INTEGER');
  _addColumn(db, 'contacts', 'last_ping_rtt_ms', 'INTEGER');
  _addColumn(db, 'contacts', 'last_ping_ok', 'INTEGER');
  _addColumn(db, 'contacts', 'fw_level', 'INTEGER');
  _addColumn(db, 'contacts', 'last_login_role', 'TEXT');
  // Backfill only the first time: a contact that was "always search" stays that way. Re-running must not undo a later choice.
  if (!hadPathMode) db.execute("UPDATE contacts SET path_mode = 'flood' WHERE force_flood = 1");

  _addColumn(db, 'conversations', 'marked_unread', 'INTEGER NOT NULL DEFAULT 0');
  _addColumn(db, 'conversations', 'last_state', 'TEXT');
  _addColumn(db, 'conversations', 'draft_preview', 'TEXT');

  db.execute('''
CREATE TABLE IF NOT EXISTS path_history (
  contact_key TEXT NOT NULL,
  ts_ms INTEGER NOT NULL,
  kind TEXT NOT NULL,
  hops TEXT,
  hash_size INTEGER,
  rtt_ms INTEGER,
  ok INTEGER
);
CREATE INDEX IF NOT EXISTS path_history_contact ON path_history (contact_key, ts_ms DESC);

CREATE TABLE IF NOT EXISTS ping_results (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  contact_key TEXT NOT NULL,
  ts_ms INTEGER NOT NULL,
  kind TEXT NOT NULL,
  ok INTEGER NOT NULL,
  rtt_ms INTEGER,
  hops INTEGER,
  snr_json TEXT,
  path_out TEXT,
  path_back TEXT,
  fail_reason TEXT
);
CREATE INDEX IF NOT EXISTS ping_results_contact ON ping_results (contact_key, ts_ms DESC);

CREATE TABLE IF NOT EXISTS remote_stats_history (
  contact_key TEXT NOT NULL,
  ts_ms INTEGER NOT NULL,
  battery_mv INTEGER,
  noise_floor INTEGER,
  uptime_s INTEGER,
  tx_air_s INTEGER,
  rx_air_s INTEGER,
  recv INTEGER,
  sent INTEGER,
  last_rssi INTEGER,
  last_snr_x4 INTEGER,
  errors INTEGER,
  queue INTEGER
);
CREATE INDEX IF NOT EXISTS remote_stats_contact ON remote_stats_history (contact_key, ts_ms DESC);

CREATE INDEX IF NOT EXISTS conversations_last ON conversations (last_ts_ms DESC);
''');
}

/// M2 (contacts and DMs). The phone is the master copy of the contact list; the radio's table is a cache of what is needed,
/// so each contact remembers whether it is on the radio right now (`on_radio`), the radio's own flag byte (bit 0 =
/// favourite, which the radio's "replace oldest" skips), when this phone last heard from it, and whether DMs to it should
/// always flood. A node heard but not added (adverts_seen) keeps the advert's own timestamp (needed to add it to the radio
/// without tripping the radio's replay check) and an "ignored" mark.
void _v2(Database db) {
  db.execute('''
ALTER TABLE contacts ADD COLUMN on_radio INTEGER NOT NULL DEFAULT 0;
ALTER TABLE contacts ADD COLUMN radio_flags INTEGER NOT NULL DEFAULT 0;
ALTER TABLE contacts ADD COLUMN last_heard_ms INTEGER;
ALTER TABLE contacts ADD COLUMN force_flood INTEGER NOT NULL DEFAULT 0;
ALTER TABLE adverts_seen ADD COLUMN advert_ts INTEGER;
ALTER TABLE adverts_seen ADD COLUMN ignored INTEGER NOT NULL DEFAULT 0;
CREATE INDEX contacts_on_radio ON contacts (radio_id, on_radio);
''');
}

void _v1(Database db) {
  db.execute('''
CREATE TABLE contacts (
  radio_id TEXT NOT NULL,
  pubkey TEXT NOT NULL,
  type INTEGER NOT NULL,
  name TEXT NOT NULL,
  custom_name TEXT,
  lat REAL, lon REAL,
  last_advert_ts INTEGER,
  lastmod INTEGER,
  out_path BLOB,
  out_path_len INTEGER NOT NULL DEFAULT -1,
  favourite INTEGER NOT NULL DEFAULT 0,
  blocked INTEGER NOT NULL DEFAULT 0,
  notes TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT 'radio',
  PRIMARY KEY (radio_id, pubkey)
) WITHOUT ROWID;
CREATE INDEX contacts_prefix ON contacts (radio_id, substr(pubkey, 1, 12));

CREATE TABLE channels (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  radio_id TEXT NOT NULL,
  slot INTEGER,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  secret_ref TEXT,
  hash_byte INTEGER,
  region_scope TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  UNIQUE (radio_id, slot)
);

CREATE TABLE messages (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  radio_id TEXT NOT NULL,
  conv_kind TEXT NOT NULL,
  conv_key TEXT NOT NULL,
  direction TEXT NOT NULL,
  sender_name TEXT,
  sender_prefix TEXT,
  ts_sender INTEGER NOT NULL,
  ts_local_ms INTEGER NOT NULL,
  text TEXT NOT NULL,
  snr REAL,
  path_len INTEGER,
  route TEXT,
  state TEXT NOT NULL,
  attempt INTEGER NOT NULL DEFAULT 0,
  expected_ack INTEGER,
  ack_ms INTEGER,
  repeats_heard INTEGER NOT NULL DEFAULT 0,
  fail_reason TEXT,
  dedupe_key TEXT NOT NULL,
  read INTEGER NOT NULL DEFAULT 0,
  txt_type INTEGER NOT NULL DEFAULT 0,
  UNIQUE (radio_id, dedupe_key)
);
CREATE INDEX messages_conv ON messages (conv_key, ts_local_ms, seq);
CREATE INDEX messages_unread ON messages (conv_key) WHERE read = 0;
CREATE INDEX messages_pending ON messages (state) WHERE state IN ('queued','sending','sent','retrying');
CREATE INDEX messages_ts ON messages (ts_local_ms);

CREATE TABLE conversations (
  conv_key TEXT PRIMARY KEY,
  radio_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  last_msg_id TEXT,
  last_ts_ms INTEGER,
  last_preview TEXT,
  unread INTEGER NOT NULL DEFAULT 0,
  notify_mode TEXT NOT NULL DEFAULT 'all',
  muted_until_ms INTEGER,
  retention_days INTEGER,
  pinned INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE delivery_attempts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id TEXT NOT NULL,
  attempt INTEGER NOT NULL,
  sent_at_ms INTEGER NOT NULL,
  route TEXT NOT NULL,
  expected_ack INTEGER,
  est_timeout_ms INTEGER
);
CREATE INDEX attempts_message ON delivery_attempts (message_id);
CREATE INDEX attempts_ack ON delivery_attempts (expected_ack);

CREATE TABLE outbox (
  message_id TEXT PRIMARY KEY,
  due_at_ms INTEGER NOT NULL,
  max_attempts INTEGER NOT NULL,
  busy_retries INTEGER NOT NULL DEFAULT 0,
  created_ms INTEGER NOT NULL
);
CREATE INDEX outbox_due ON outbox (due_at_ms);

CREATE TABLE drafts (
  conv_key TEXT PRIMARY KEY,
  text TEXT NOT NULL,
  updated_ms INTEGER NOT NULL
);

CREATE TABLE adverts_seen (
  radio_id TEXT NOT NULL,
  pubkey TEXT NOT NULL,
  type INTEGER,
  name TEXT NOT NULL,
  lat REAL, lon REAL,
  first_ts_ms INTEGER NOT NULL,
  last_ts_ms INTEGER NOT NULL,
  count INTEGER NOT NULL DEFAULT 1,
  path_len INTEGER,
  snr REAL,
  PRIMARY KEY (radio_id, pubkey)
) WITHOUT ROWID;

CREATE TABLE system_stats (
  channel_id INTEGER PRIMARY KEY,
  pings_sent INTEGER NOT NULL DEFAULT 0,
  last_ping_ms INTEGER,
  heard_others INTEGER NOT NULL DEFAULT 0,
  last_heard_ms INTEGER
);

CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
) WITHOUT ROWID;

-- Message search. Trigram tokenizer: case-insensitive substring match for terms of 3+ characters, any script (CJK
-- included), with diacritics folded ("cafe" finds "Cafe"). Shorter terms fall back to LIKE in MessageRepository.search.
CREATE VIRTUAL TABLE fts_messages USING fts5(
  text, sender_name,
  content='messages', content_rowid='seq',
  tokenize='trigram remove_diacritics 1'
);
CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO fts_messages(rowid, text, sender_name) VALUES (new.seq, new.text, coalesce(new.sender_name, ''));
END;
CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
  INSERT INTO fts_messages(fts_messages, rowid, text, sender_name) VALUES ('delete', old.seq, old.text, coalesce(old.sender_name, ''));
END;
''');
}
