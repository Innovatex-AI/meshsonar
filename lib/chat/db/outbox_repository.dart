import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import 'chat_database.dart';

class OutboxEntry {
  final String messageId;
  final int dueAtMs;
  final int maxAttempts;
  final int busyRetries;
  final int createdMs;
  const OutboxEntry({required this.messageId, required this.dueAtMs, required this.maxAttempts, this.busyRetries = 0, required this.createdMs});
}

class DeliveryAttempt {
  final String messageId;
  final int attempt;
  final int sentAtMs;
  final Route route;
  final int? expectedAck;
  final int? estTimeoutMs;
  const DeliveryAttempt({required this.messageId, required this.attempt, required this.sentAtMs, required this.route, this.expectedAck, this.estTimeoutMs});
}

/// Persistent retry plan and the log of every send attempt (needed to match an ACK that arrives late, after a retry).
class OutboxRepository {
  final ChatDatabase db;
  OutboxRepository(this.db);

  void enqueue(OutboxEntry e) => db.raw.execute(
      'INSERT OR REPLACE INTO outbox(message_id, due_at_ms, max_attempts, busy_retries, created_ms) VALUES (?,?,?,?,?)',
      [e.messageId, e.dueAtMs, e.maxAttempts, e.busyRetries, e.createdMs]);

  OutboxEntry? get(String messageId) {
    final r = db.raw.select('SELECT * FROM outbox WHERE message_id = ?', [messageId]);
    return r.isEmpty ? null : _entry(r.first);
  }

  static OutboxEntry _entry(Row r) => OutboxEntry(
      messageId: r['message_id'] as String,
      dueAtMs: r['due_at_ms'] as int,
      maxAttempts: r['max_attempts'] as int,
      busyRetries: r['busy_retries'] as int,
      createdMs: r['created_ms'] as int);

  /// Entries due at [nowMs], oldest message first (so a conversation keeps its order).
  List<OutboxEntry> due(int nowMs, {int limit = 20}) => db.raw
      .select('SELECT o.* FROM outbox o JOIN messages m ON m.id = o.message_id WHERE o.due_at_ms <= ? ORDER BY m.seq LIMIT ?', [nowMs, limit])
      .map(_entry)
      .toList();

  int? nextDueMs() {
    final r = db.raw.select('SELECT min(due_at_ms) d FROM outbox');
    return r.first['d'] as int?;
  }

  int count() => db.raw.select('SELECT count(*) c FROM outbox').first['c'] as int;

  void reschedule(String messageId, int dueAtMs, {int? busyRetries}) {
    if (busyRetries == null) {
      db.raw.execute('UPDATE outbox SET due_at_ms = ? WHERE message_id = ?', [dueAtMs, messageId]);
    } else {
      db.raw.execute('UPDATE outbox SET due_at_ms = ?, busy_retries = ? WHERE message_id = ?', [dueAtMs, busyRetries, messageId]);
    }
  }

  /// Makes every message that is waiting for the radio (queued, or between attempts) due at [nowMs]. Messages already sent and
  /// waiting for an ack keep their ack timer.
  int releaseWaiting(int nowMs) {
    db.raw.execute("UPDATE outbox SET due_at_ms = ? WHERE due_at_ms > ? AND message_id IN (SELECT id FROM messages WHERE state IN ('queued','retrying'))", [nowMs, nowMs]);
    return db.raw.updatedRows;
  }

  void remove(String messageId) => db.raw.execute('DELETE FROM outbox WHERE message_id = ?', [messageId]);

  void addAttempt(DeliveryAttempt a) => db.raw.execute(
      'INSERT INTO delivery_attempts(message_id, attempt, sent_at_ms, route, expected_ack, est_timeout_ms) VALUES (?,?,?,?,?,?)',
      [a.messageId, a.attempt, a.sentAtMs, a.route.name, a.expectedAck, a.estTimeoutMs]);

  List<DeliveryAttempt> attemptsFor(String messageId) => db.raw
      .select('SELECT * FROM delivery_attempts WHERE message_id = ? ORDER BY id', [messageId])
      .map((r) => DeliveryAttempt(
          messageId: r['message_id'] as String,
          attempt: r['attempt'] as int,
          sentAtMs: r['sent_at_ms'] as int,
          route: Route.values.firstWhere((x) => x.name == r['route']),
          expectedAck: r['expected_ack'] as int?,
          estTimeoutMs: r['est_timeout_ms'] as int?))
      .toList();

  /// Finds the attempt an ACK code belongs to: the newest attempt with this code on a message that is still waiting
  /// (or failed for want of an ack: a late ack still counts).
  DeliveryAttempt? findByAck(String radioId, int ack) {
    final r = db.raw.select('''
SELECT a.* FROM delivery_attempts a JOIN messages m ON m.id = a.message_id
WHERE a.expected_ack = ? AND m.radio_id = ? AND m.direction = 'out' AND m.state IN ('sending','sent','retrying','failed')
ORDER BY a.id DESC LIMIT 1
''', [ack, radioId]);
    if (r.isEmpty) return null;
    final x = r.first;
    return DeliveryAttempt(
        messageId: x['message_id'] as String,
        attempt: x['attempt'] as int,
        sentAtMs: x['sent_at_ms'] as int,
        route: Route.values.firstWhere((v) => v.name == x['route']),
        expectedAck: x['expected_ack'] as int?,
        estTimeoutMs: x['est_timeout_ms'] as int?);
  }
}
