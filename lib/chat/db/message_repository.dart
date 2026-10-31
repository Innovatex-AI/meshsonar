import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import 'chat_database.dart';

class MessageCursor {
  final int tsLocalMs;
  final int seq;
  const MessageCursor(this.tsLocalMs, this.seq);
}

class MessagePage {
  /// Newest first.
  final List<ChatMessage> messages;

  /// Pass back to [MessageRepository.page] for the next older page; null when there are no older messages.
  final MessageCursor? next;
  const MessagePage(this.messages, this.next);
}

/// Messages, conversation rows (denormalised last message and unread count), search and deletion.
/// Every write that changes a conversation updates its row in the same call, so the list never scans messages.
class MessageRepository {
  final ChatDatabase db;
  MessageRepository(this.db);

  static const int previewChars = 120;

  late final PreparedStatement _insert = db.raw.prepare('''
INSERT OR IGNORE INTO messages(id, radio_id, conv_kind, conv_key, direction, sender_name, sender_prefix, ts_sender, ts_local_ms, text, snr, path_len,
  route, state, attempt, expected_ack, ack_ms, repeats_heard, fail_reason, dedupe_key, read, txt_type)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
''');

  late final PreparedStatement _upsertConv = db.raw.prepare('''
INSERT INTO conversations(conv_key, radio_id, kind, last_msg_id, last_ts_ms, last_preview, unread) VALUES (?,?,?,?,?,?,?)
ON CONFLICT(conv_key) DO UPDATE SET
  last_msg_id = CASE WHEN excluded.last_ts_ms >= coalesce(last_ts_ms, 0) THEN excluded.last_msg_id ELSE last_msg_id END,
  last_preview = CASE WHEN excluded.last_ts_ms >= coalesce(last_ts_ms, 0) THEN excluded.last_preview ELSE last_preview END,
  last_ts_ms = max(coalesce(last_ts_ms, 0), excluded.last_ts_ms),
  unread = unread + excluded.unread
''');

  static ChatMessage fromRow(Row r) => ChatMessage(
        id: r['id'] as String,
        seq: r['seq'] as int,
        radioId: r['radio_id'] as String,
        convKind: ConvKind.values.firstWhere((k) => k.name == r['conv_kind']),
        convKey: r['conv_key'] as String,
        direction: r['direction'] == 'out' ? Direction.outgoing : Direction.incoming,
        senderName: r['sender_name'] as String?,
        senderPrefix: r['sender_prefix'] as String?,
        tsSender: r['ts_sender'] as int,
        tsLocalMs: r['ts_local_ms'] as int,
        text: r['text'] as String,
        snr: (r['snr'] as num?)?.toDouble(),
        pathLen: r['path_len'] as int?,
        route: r['route'] == null ? null : Route.values.firstWhere((x) => x.name == r['route']),
        state: MessageState.values.firstWhere((s) => s.name == r['state']),
        attempt: r['attempt'] as int,
        expectedAck: r['expected_ack'] as int?,
        ackMs: r['ack_ms'] as int?,
        repeatsHeard: r['repeats_heard'] as int,
        failReason: r['fail_reason'] == null ? null : FailReason.values.firstWhere((x) => x.name == r['fail_reason'], orElse: () => FailReason.cancelled),
        dedupeKey: r['dedupe_key'] as String,
        read: (r['read'] as int) != 0,
        txtType: r['txt_type'] as int,
      );

  /// Inserts [m] unless (radioId, dedupeKey) already exists. Returns true when a new row was written.
  /// The conversation row is updated in the same transaction.
  bool insert(ChatMessage m) {
    return db.transaction(() {
      _insert.execute([
        m.id, m.radioId, m.convKind.name, m.convKey, m.isOutgoing ? 'out' : 'in', m.senderName, m.senderPrefix, m.tsSender, m.tsLocalMs, m.text,
        m.snr, m.pathLen, m.route?.name, m.state.name, m.attempt, m.expectedAck, m.ackMs, m.repeatsHeard, m.failReason?.name, m.dedupeKey,
        m.read ? 1 : 0, m.txtType,
      ]);
      if (db.raw.updatedRows == 0) return false;
      final preview = m.text.length > previewChars ? m.text.substring(0, previewChars) : m.text;
      _upsertConv.execute([m.convKey, m.radioId, m.convKind.name, m.id, m.tsLocalMs, preview, m.read ? 0 : 1]);
      return true;
    });
  }

  ChatMessage? get(String id) {
    final r = db.raw.select('SELECT * FROM messages WHERE id = ?', [id]);
    return r.isEmpty ? null : fromRow(r.first);
  }

  bool existsDedupe(String radioId, String dedupeKey) =>
      db.raw.select('SELECT 1 FROM messages WHERE radio_id = ? AND dedupe_key = ? LIMIT 1', [radioId, dedupeKey]).isNotEmpty;

  /// Keyset paging, newest first. Cost is independent of how deep the page is.
  MessagePage page(String convKey, {MessageCursor? before, int limit = 50}) {
    final lim = limit.clamp(1, 500);
    final rows = before == null
        ? db.raw.select('SELECT * FROM messages WHERE conv_key = ? ORDER BY ts_local_ms DESC, seq DESC LIMIT ?', [convKey, lim + 1])
        : db.raw.select(
            'SELECT * FROM messages WHERE conv_key = ? AND (ts_local_ms < ? OR (ts_local_ms = ? AND seq < ?)) ORDER BY ts_local_ms DESC, seq DESC LIMIT ?',
            [convKey, before.tsLocalMs, before.tsLocalMs, before.seq, lim + 1]);
    final list = rows.take(lim).map(fromRow).toList();
    final more = rows.length > lim;
    return MessagePage(list, more ? MessageCursor(list.last.tsLocalMs, list.last.seq) : null);
  }

  /// Updates delivery fields of one message. Only passed fields change.
  void update(String id, {MessageState? state, int? attempt, Route? route, int? expectedAck, int? ackMs, int? repeatsHeard, FailReason? failReason, bool clearFailReason = false}) {
    final sets = <String>[];
    final args = <Object?>[];
    void add(String col, Object? v) {
      sets.add('$col = ?');
      args.add(v);
    }

    if (state != null) add('state', state.name);
    if (attempt != null) add('attempt', attempt);
    if (route != null) add('route', route.name);
    if (expectedAck != null) add('expected_ack', expectedAck);
    if (ackMs != null) add('ack_ms', ackMs);
    if (repeatsHeard != null) add('repeats_heard', repeatsHeard);
    if (failReason != null) add('fail_reason', failReason.name);
    if (clearFailReason) add('fail_reason', null);
    if (sets.isEmpty) return;
    args.add(id);
    db.raw.execute('UPDATE messages SET ${sets.join(', ')} WHERE id = ?', args);
  }

  /// A session may stamp its own timestamp when it sends; adopt it so echo matching and receivers agree.
  /// If the new dedupe key is taken (cannot happen in practice) the old one is kept.
  void retimestamp(String id, int tsSender, String dedupeKey) {
    db.raw.execute('UPDATE OR IGNORE messages SET ts_sender = ?, dedupe_key = ? WHERE id = ?', [tsSender, dedupeKey, id]);
  }

  /// Newest outgoing channel message in [convKey] with this sender timestamp and text (to attach a heard-repeat).
  ChatMessage? findOutgoing(String convKey, int tsSender, String text) {
    final r = db.raw.select(
        "SELECT * FROM messages WHERE conv_key = ? AND direction = 'out' AND ts_sender = ? AND text = ? ORDER BY seq DESC LIMIT 1", [convKey, tsSender, text]);
    return r.isEmpty ? null : fromRow(r.first);
  }

  List<ChatMessage> byState(Iterable<MessageState> states, {int limit = 1000}) {
    final marks = List.filled(states.length, '?').join(',');
    return db.raw
        .select("SELECT * FROM messages WHERE direction = 'out' AND state IN ($marks) ORDER BY seq LIMIT ?", [...states.map((s) => s.name), limit])
        .map(fromRow)
        .toList();
  }

  // ------------------------------------------------------------------ conversations

  void ensureConversation(String convKey, String radioId) {
    final kind = ConvKey.kindOf(convKey);
    if (kind == null) throw ArgumentError('bad conversation key $convKey');
    db.raw.execute('INSERT OR IGNORE INTO conversations(conv_key, radio_id, kind) VALUES (?,?,?)', [convKey, radioId, kind.name]);
  }

  static const String _listSql = '''
SELECT cv.*,
  CASE WHEN cv.kind = 'channel' THEN (SELECT name FROM channels WHERE 'c:' || id = cv.conv_key)
       ELSE (SELECT coalesce(nullif(custom_name, ''), name) FROM contacts WHERE radio_id = cv.radio_id AND substr(pubkey, 1, 12) = substr(cv.conv_key, 3) LIMIT 1) END AS title,
  (SELECT kind FROM channels WHERE 'c:' || id = cv.conv_key) AS channel_kind
FROM conversations cv
''';

  static ConversationSummary _summary(Row r) {
    final key = r['conv_key'] as String;
    final kind = ConvKind.values.firstWhere((k) => k.name == r['kind']);
    return ConversationSummary(
      key: key,
      kind: kind,
      radioId: r['radio_id'] as String,
      title: (r['title'] as String?) ?? (kind == ConvKind.channel ? 'Channel ${ConvKey.body(key)}' : ConvKey.body(key)),
      lastPreview: r['last_preview'] as String?,
      lastTsMs: r['last_ts_ms'] as int?,
      unread: r['unread'] as int,
      notifyMode: NotifyMode.values.firstWhere((n) => n.name == r['notify_mode'], orElse: () => NotifyMode.all),
      mutedUntilMs: r['muted_until_ms'] as int?,
      pinned: (r['pinned'] as int) != 0,
      retentionDays: r['retention_days'] as int?,
      isSystem: r['channel_kind'] == 'system',
    );
  }

  /// Conversation list: pinned first, then newest. System (wardrive) conversations are excluded unless asked for.
  /// Conversations with no messages are included only when [includeEmpty] (e.g. a muted contact with no history).
  List<ConversationSummary> conversations({String? radioId, bool includeSystem = false, bool includeEmpty = false}) {
    final all = db.raw
        .select('$_listSql ${radioId == null ? '' : 'WHERE cv.radio_id = ?'} ORDER BY cv.pinned DESC, coalesce(cv.last_ts_ms, 0) DESC', [?radioId])
        .map(_summary)
        .where((c) => (includeSystem || !c.isSystem) && (includeEmpty || c.lastTsMs != null));
    return all.toList();
  }

  ConversationSummary? conversation(String convKey) {
    final r = db.raw.select('$_listSql WHERE cv.conv_key = ?', [convKey]);
    return r.isEmpty ? null : _summary(r.first);
  }

  /// Badge value: number of conversations with unread messages, excluding muted, blocked-contact and system ones.
  int unreadConversationCount({required int nowMs}) {
    final r = db.raw.select('''
SELECT count(*) c FROM conversations cv
WHERE cv.unread > 0
  AND NOT (cv.notify_mode = 'muted' AND (cv.muted_until_ms IS NULL OR cv.muted_until_ms > ?))
  AND NOT EXISTS (SELECT 1 FROM channels ch WHERE 'c:' || ch.id = cv.conv_key AND ch.kind = 'system')
''', [nowMs]);
    return r.first['c'] as int;
  }

  int unreadCount(String convKey) {
    final r = db.raw.select('SELECT unread FROM conversations WHERE conv_key = ?', [convKey]);
    return r.isEmpty ? 0 : r.first['unread'] as int;
  }

  /// Marks every message in the conversation read. Returns how many changed.
  int markConversationRead(String convKey) => db.transaction(() {
        db.raw.execute('UPDATE messages SET read = 1 WHERE conv_key = ? AND read = 0', [convKey]);
        final n = db.raw.updatedRows;
        db.raw.execute('UPDATE conversations SET unread = 0 WHERE conv_key = ?', [convKey]);
        return n;
      });

  void setNotify(String convKey, String radioId, NotifyMode mode, {int? mutedUntilMs}) {
    ensureConversation(convKey, radioId);
    db.raw.execute('UPDATE conversations SET notify_mode = ?, muted_until_ms = ? WHERE conv_key = ?',
        [mode.name, mode == NotifyMode.muted ? mutedUntilMs : null, convKey]);
  }

  void setPinned(String convKey, String radioId, bool pinned) {
    ensureConversation(convKey, radioId);
    db.raw.execute('UPDATE conversations SET pinned = ? WHERE conv_key = ?', [pinned ? 1 : 0, convKey]);
  }

  void setRetentionDays(String convKey, String radioId, int? days) {
    ensureConversation(convKey, radioId);
    db.raw.execute('UPDATE conversations SET retention_days = ? WHERE conv_key = ?', [days, convKey]);
  }

  /// Recomputes last message and unread from the messages table (after deletes, or as a repair).
  void rebuildConversation(String convKey) {
    final last = db.raw.select('SELECT id, ts_local_ms, text FROM messages WHERE conv_key = ? ORDER BY ts_local_ms DESC, seq DESC LIMIT 1', [convKey]);
    final unread = db.raw.select('SELECT count(*) c FROM messages WHERE conv_key = ? AND read = 0', [convKey]).first['c'] as int;
    if (last.isEmpty) {
      db.raw.execute('UPDATE conversations SET last_msg_id = NULL, last_ts_ms = NULL, last_preview = NULL, unread = 0 WHERE conv_key = ?', [convKey]);
    } else {
      final t = last.first['text'] as String;
      db.raw.execute('UPDATE conversations SET last_msg_id = ?, last_ts_ms = ?, last_preview = ?, unread = ? WHERE conv_key = ?',
          [last.first['id'], last.first['ts_local_ms'], t.length > previewChars ? t.substring(0, previewChars) : t, unread, convKey]);
    }
  }

  void rebuildAllConversations() {
    db.transaction(() {
      for (final r in db.raw.select('SELECT conv_key FROM conversations')) {
        rebuildConversation(r['conv_key'] as String);
      }
    });
  }

  // ------------------------------------------------------------------ deletion

  /// Deletes every message of the conversation (keeps mute/pin settings). Pending outgoing messages are removed from the outbox too.
  int deleteHistory(String convKey) => db.transaction(() {
        _dropOutboxFor("conv_key = ?", [convKey]);
        db.raw.execute('DELETE FROM messages WHERE conv_key = ?', [convKey]);
        final n = db.raw.updatedRows;
        rebuildConversation(convKey);
        return n;
      });

  /// Deletes one message (and its outbox entry and attempts). Returns false if it did not exist.
  bool deleteMessage(String id) => db.transaction(() {
        final m = get(id);
        if (m == null) return false;
        _dropOutboxFor('id = ?', [id]);
        db.raw.execute('DELETE FROM messages WHERE id = ?', [id]);
        rebuildConversation(m.convKey);
        return true;
      });

  /// Deletes the conversation completely: messages, draft and settings.
  int deleteConversation(String convKey) => db.transaction(() {
        final n = deleteHistory(convKey);
        db.raw.execute('DELETE FROM conversations WHERE conv_key = ?', [convKey]);
        db.raw.execute('DELETE FROM drafts WHERE conv_key = ?', [convKey]);
        return n;
      });

  /// Deletes messages older than [cutoffMs] (local time) in one conversation. Pending sends are never deleted.
  int deleteOlderThan(String convKey, int cutoffMs) => db.transaction(() {
        db.raw.execute("DELETE FROM messages WHERE conv_key = ? AND ts_local_ms < ? AND state NOT IN ('queued','sending','retrying')", [convKey, cutoffMs]);
        final n = db.raw.updatedRows;
        if (n > 0) rebuildConversation(convKey);
        return n;
      });

  /// Keeps only the newest [keep] messages of a conversation (used to bound system-channel traffic).
  int pruneToNewest(String convKey, int keep) => db.transaction(() {
        db.raw.execute('''
DELETE FROM messages WHERE conv_key = ? AND seq NOT IN (SELECT seq FROM messages WHERE conv_key = ? ORDER BY ts_local_ms DESC, seq DESC LIMIT ?)
  AND state NOT IN ('queued','sending','retrying')
''', [convKey, convKey, keep]);
        final n = db.raw.updatedRows;
        if (n > 0) rebuildConversation(convKey);
        return n;
      });

  void _dropOutboxFor(String where, List<Object?> args) {
    db.raw.execute('DELETE FROM outbox WHERE message_id IN (SELECT id FROM messages WHERE $where)', args);
    db.raw.execute('DELETE FROM delivery_attempts WHERE message_id IN (SELECT id FROM messages WHERE $where)', args);
  }

  /// Removes everything chat knows about messages (history of all conversations).
  void deleteAllHistory() => db.transaction(() {
        db.raw.execute('DELETE FROM outbox');
        db.raw.execute('DELETE FROM delivery_attempts');
        db.raw.execute('DELETE FROM messages');
        rebuildAllConversations();
      });

  int count({String? convKey}) =>
      (convKey == null ? db.raw.select('SELECT count(*) c FROM messages') : db.raw.select('SELECT count(*) c FROM messages WHERE conv_key = ?', [convKey])).first['c'] as int;

  // ------------------------------------------------------------------ search

  static String _likeEscape(String s) => s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  /// Substring search, case-insensitive, diacritics folded, any script. Terms are AND-ed. Terms of 3+ characters use the
  /// FTS5 trigram index; shorter terms use LIKE (ASCII case-insensitive). Never throws on odd input: quotes, operators and
  /// control characters are neutralised. System (wardrive) traffic is excluded unless [includeSystem].
  List<ChatMessage> search(String query, {String? convKey, int limit = 50, int offset = 0, bool includeSystem = false}) {
    final terms = query.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ').split(RegExp(r'\s+')).where((t) => t.isNotEmpty).take(8).toList();
    if (terms.isEmpty) return const [];
    final fts = terms.where((t) => t.runes.length >= 3).toList();
    final like = terms.where((t) => t.runes.length < 3).toList();
    final where = <String>[];
    final args = <Object?>[];
    if (fts.isNotEmpty) {
      where.add('m.seq IN (SELECT rowid FROM fts_messages WHERE fts_messages MATCH ?)');
      args.add(fts.map((t) => '"${t.replaceAll('"', '""')}"').join(' '));
    }
    for (final t in like) {
      where.add("(m.text LIKE ? ESCAPE '\\' OR coalesce(m.sender_name, '') LIKE ? ESCAPE '\\')");
      final p = '%${_likeEscape(t)}%';
      args..add(p)..add(p);
    }
    if (convKey != null) {
      where.add('m.conv_key = ?');
      args.add(convKey);
    }
    if (!includeSystem) where.add("NOT EXISTS (SELECT 1 FROM channels ch WHERE 'c:' || ch.id = m.conv_key AND ch.kind = 'system')");
    args..add(limit.clamp(1, 500))..add(offset < 0 ? 0 : offset);
    return db.raw
        .select('SELECT m.* FROM messages m WHERE ${where.join(' AND ')} ORDER BY m.ts_local_ms DESC, m.seq DESC LIMIT ? OFFSET ?', args)
        .map(fromRow)
        .toList();
  }

  /// All messages for export, oldest first, in chunks so memory stays bounded.
  Iterable<ChatMessage> allForExport({int chunk = 1000}) sync* {
    var after = 0;
    while (true) {
      final rows = db.raw.select('SELECT * FROM messages WHERE seq > ? ORDER BY seq LIMIT ?', [after, chunk]);
      if (rows.isEmpty) return;
      for (final r in rows) {
        yield fromRow(r);
      }
      after = rows.last['seq'] as int;
    }
  }
}
