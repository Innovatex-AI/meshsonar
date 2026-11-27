import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import 'chat_database.dart';

class OutboxEntry {
  final String messageId;
  final int dueAtMs;

  /// How many tries this message gets in all: the "m" of "try n of m".
  final int maxAttempts;
  final int busyRetries;
  final int createdMs;

  /// The person chose "flood" for this one message (long-press Send): one RESET_PATH before the first try, then the
  /// normal send (migration v5; build 77 meaning).
  final bool forceFlood;

  /// Tries made before the one reset path (the direct budget). When [maxAttempts] is not above it there is no fallback.
  final int directTries;

  /// The one reset of this message was done (or decided not needed).
  final bool didReset;

  /// 0 for the first send, +1 for every manual retry (each retry is a new send with a new timestamp).
  final int round;
  const OutboxEntry(
      {required this.messageId,
      required this.dueAtMs,
      required this.maxAttempts,
      this.busyRetries = 0,
      required this.createdMs,
      this.forceFlood = false,
      this.directTries = 4,
      this.didReset = false,
      this.round = 0});
}

/// What became of one try.
enum TryOutcome {
  /// The command is being handed to the radio.
  sending,

  /// The radio took it; waiting for the confirmation.
  waiting,

  /// The confirmation for this try arrived.
  confirmed,

  /// The wait ended without a confirmation.
  noConfirmation,

  /// The radio did not answer the send command (its reply was lost or late); it may still have sent the packet.
  radioNoAnswer,

  /// The person cancelled while this try was open.
  cancelled,

  /// The app stopped while this try was being handed over.
  interrupted;

  static TryOutcome? parse(String? s) {
    for (final o in values) {
      if (o.name == s) return o;
    }
    return null;
  }
}

/// One try of a direct message, as the radio reported it.
class DeliveryAttempt {
  /// Row id; 0 before it is stored.
  final int id;
  final String messageId;

  /// The try number the person sees, 1-based within its [round]: the "n" of "try n of m".
  final int attempt;
  final int sentAtMs;

  /// Direct or flood AS THE RADIO REPORTED IT in its SENT reply. Only meaningful when [routeKnown].
  final Route route;

  /// The confirmation code this try answers to: computed on the phone before the send, so it is there even when the
  /// radio's reply is lost.
  final int? expectedAck;

  /// The radio's estimate of the round trip for this try, ms (RESP_CODE_SENT); the wait is this x 1.2.
  final int? estTimeoutMs;

  /// False while the radio has not said whether this try went direct or flood (its reply was lost).
  final bool routeKnown;

  /// The try number given to the radio, 0..7. Null on rows from before build 77.
  final int? wireAttempt;

  /// Which send of the message this try belongs to (see [OutboxEntry.round]).
  final int round;

  /// The sender timestamp this try carried (the same on every try of a round).
  final int? tsSender;

  /// Null on rows from before build 77.
  final TryOutcome? outcome;

  /// RESET_PATH was sent right before this try.
  final bool resetBefore;

  /// The radio's own code when it differs from the computed one.
  final int? ack2;

  /// The radio's round trip for the confirmation of this try, ms.
  final int? tripMs;
  const DeliveryAttempt(
      {this.id = 0,
      required this.messageId,
      required this.attempt,
      required this.sentAtMs,
      required this.route,
      this.expectedAck,
      this.estTimeoutMs,
      this.routeKnown = true,
      this.wireAttempt,
      this.round = 0,
      this.tsSender,
      this.outcome,
      this.resetBefore = false,
      this.ack2,
      this.tripMs});
}

/// Persistent retry plan and the log of every send attempt (needed to match an ACK that arrives late, after a retry).
class OutboxRepository {
  final ChatDatabase db;
  OutboxRepository(this.db);

  void enqueue(OutboxEntry e) => db.raw.execute(
      'INSERT OR REPLACE INTO outbox(message_id, due_at_ms, max_attempts, busy_retries, created_ms, force_flood, direct_tries, did_reset, round) VALUES (?,?,?,?,?,?,?,?,?)',
      [e.messageId, e.dueAtMs, e.maxAttempts, e.busyRetries, e.createdMs, e.forceFlood ? 1 : 0, e.directTries, e.didReset ? 1 : 0, e.round]);

  OutboxEntry? get(String messageId) {
    final r = db.raw.select('SELECT * FROM outbox WHERE message_id = ?', [messageId]);
    return r.isEmpty ? null : _entry(r.first);
  }

  static OutboxEntry _entry(Row r) => OutboxEntry(
      messageId: r['message_id'] as String,
      dueAtMs: r['due_at_ms'] as int,
      maxAttempts: r['max_attempts'] as int,
      busyRetries: r['busy_retries'] as int,
      createdMs: r['created_ms'] as int,
      forceFlood: (r['force_flood'] as int? ?? 0) != 0,
      directTries: r['direct_tries'] as int? ?? 4,
      didReset: (r['did_reset'] as int? ?? 0) != 0,
      round: r['round'] as int? ?? 0);

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

  /// Sets the number of tries for [messageId].
  void setMaxAttempts(String messageId, int maxAttempts) =>
      db.raw.execute('UPDATE outbox SET max_attempts = ? WHERE message_id = ?', [maxAttempts, messageId]);

  /// The one reset path of [messageId] is done (or was decided not needed).
  void setDidReset(String messageId) => db.raw.execute('UPDATE outbox SET did_reset = 1 WHERE message_id = ?', [messageId]);

  /// When the first try of [messageId] went out, or null when it never went out.
  int? firstSentMs(String messageId) =>
      db.raw.select('SELECT min(sent_at_ms) t FROM delivery_attempts WHERE message_id = ?', [messageId]).first['t'] as int?;

  void remove(String messageId) => db.raw.execute('DELETE FROM outbox WHERE message_id = ?', [messageId]);

  /// Stores one try and returns its row id.
  int addAttempt(DeliveryAttempt a) {
    db.raw.execute(
        'INSERT INTO delivery_attempts(message_id, attempt, sent_at_ms, route, expected_ack, est_timeout_ms, wire_attempt, round, ts_sender, outcome, route_known, ack2, reset_before, trip_ms) '
        'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          a.messageId, a.attempt, a.sentAtMs, a.route.name, a.expectedAck, a.estTimeoutMs, a.wireAttempt, a.round, a.tsSender, a.outcome?.name,
          a.routeKnown ? 1 : 0, a.ack2, a.resetBefore ? 1 : 0, a.tripMs,
        ]);
    return db.raw.lastInsertRowId;
  }

  /// Fills in what the radio said about try [id] (its SENT reply) or what became of it.
  void updateAttempt(int id, {Route? route, bool? routeKnown, int? estTimeoutMs, int? ack2, TryOutcome? outcome, int? tripMs}) {
    final sets = <String>[];
    final args = <Object?>[];
    void add(String col, Object? v) {
      sets.add('$col = ?');
      args.add(v);
    }

    if (route != null) add('route', route.name);
    if (routeKnown != null) add('route_known', routeKnown ? 1 : 0);
    if (estTimeoutMs != null) add('est_timeout_ms', estTimeoutMs);
    if (ack2 != null) add('ack2', ack2);
    if (outcome != null) add('outcome', outcome.name);
    if (tripMs != null) add('trip_ms', tripMs);
    if (sets.isEmpty) return;
    args.add(id);
    db.raw.execute('UPDATE delivery_attempts SET ${sets.join(', ')} WHERE id = ?', args);
  }

  /// Takes back a try that never reached the radio (not connected, radio busy).
  void removeAttempt(int id) => db.raw.execute('DELETE FROM delivery_attempts WHERE id = ?', [id]);

  /// Every try of [messageId] still open (sending or waiting) gets [outcome]. Returns how many.
  int closeOpenAttempts(String messageId, TryOutcome outcome) {
    db.raw.execute("UPDATE delivery_attempts SET outcome = ? WHERE message_id = ? AND outcome IN ('sending','waiting')", [outcome.name, messageId]);
    return db.raw.updatedRows;
  }

  /// The highest round any try of [messageId] has, or -1 when it has none.
  int lastRound(String messageId) =>
      (db.raw.select('SELECT max(round) r FROM delivery_attempts WHERE message_id = ?', [messageId]).first['r'] as int?) ?? -1;

  static DeliveryAttempt _attempt(Row r) => DeliveryAttempt(
      id: r['id'] as int,
      messageId: r['message_id'] as String,
      attempt: r['attempt'] as int,
      sentAtMs: r['sent_at_ms'] as int,
      route: Route.values.firstWhere((x) => x.name == r['route'], orElse: () => Route.flood),
      expectedAck: r['expected_ack'] as int?,
      estTimeoutMs: r['est_timeout_ms'] as int?,
      routeKnown: (r['route_known'] as int? ?? 1) != 0,
      wireAttempt: r['wire_attempt'] as int?,
      round: r['round'] as int? ?? 0,
      tsSender: r['ts_sender'] as int?,
      outcome: TryOutcome.parse(r['outcome'] as String?),
      resetBefore: (r['reset_before'] as int? ?? 0) != 0,
      ack2: r['ack2'] as int?,
      tripMs: r['trip_ms'] as int?);

  /// Every try of [messageId], oldest first (all rounds).
  List<DeliveryAttempt> attemptsFor(String messageId) =>
      db.raw.select('SELECT * FROM delivery_attempts WHERE message_id = ? ORDER BY id', [messageId]).map(_attempt).toList();

  /// The tries of one [round] of [messageId], oldest first.
  List<DeliveryAttempt> attemptsOfRound(String messageId, int round) =>
      db.raw.select('SELECT * FROM delivery_attempts WHERE message_id = ? AND round = ? ORDER BY id', [messageId, round]).map(_attempt).toList();

  /// Finds the try a confirmation code belongs to: the newest try with this code (the phone's computed code or the radio's
  /// own) on an outgoing message that has not been confirmed yet. Any state counts except delivered: waiting, between
  /// tries, queued again after a manual retry, cancelled and failed (round 3 rule 8: a confirmation for ANY earlier try
  /// means delivered, also after the message was marked failed).
  DeliveryAttempt? findByAck(String radioId, int ack) => _findByAck(radioId, ack, "m.state <> 'acked'");

  /// The try of an ALREADY delivered message this code belongs to (a duplicate confirmation), for the message log.
  DeliveryAttempt? findDeliveredByAck(String radioId, int ack) => _findByAck(radioId, ack, "m.state = 'acked'");

  DeliveryAttempt? _findByAck(String radioId, int ack, String stateSql) {
    final r = db.raw.select('''
SELECT a.* FROM delivery_attempts a JOIN messages m ON m.id = a.message_id
WHERE (a.expected_ack = ? OR a.ack2 = ?) AND m.radio_id = ? AND m.direction = 'out' AND m.state <> 'received' AND $stateSql
ORDER BY (a.outcome = 'waiting') DESC, a.id DESC LIMIT 1
''', [ack, ack, radioId]);
    return r.isEmpty ? null : _attempt(r.first);
  }
}
