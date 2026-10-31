// The outbox: queued messages, client-side retries for DMs, ACK matching, give-up with a reason.
// All state lives in SQLite (messages + outbox + delivery_attempts), so a restart loses nothing.
// Deterministic: no timers in here. Call [tick] when [nextDueMs] arrives (ChatService does that), and [onAck] on SEND_CONFIRMED.
import 'dart:math';

import 'db/outbox_repository.dart';
import 'events.dart';
import 'models.dart';
import 'radio_bridge.dart';
import 'store.dart';

class RetryPolicy {
  /// Attempts for a DM that goes by flood / by a known path (official app: 3, and 5 with a direct path; changelog v1.4.0, v1.14.0).
  final int floodAttempts;
  final int directAttempts;

  /// Ack wait = estTimeout * factor + slack + random jitter, clamped.
  final double timeoutFactor;
  final int slackMs;
  final int jitterMs;
  final int minWaitMs;
  final int maxWaitMs;

  /// Busy back-off: base * 2^n, capped; give up after [maxBusyRetries].
  final int busyBaseMs;
  final int busyMaxMs;
  final int maxBusyRetries;

  /// How long to wait before looking again when the radio is not connected (attempts are not consumed).
  final int notConnectedRecheckMs;

  /// A message older than this is dropped (never sent: notConnected; sent but unanswered: expired).
  final int maxQueueAgeMs;

  /// Minimum gap between two sends from the same app (the official app waits 1 s between user sends, v1.40.0).
  final int minGapMs;

  const RetryPolicy({
    this.floodAttempts = 3,
    this.directAttempts = 5,
    this.timeoutFactor = 1.25,
    this.slackMs = 800,
    this.jitterMs = 2000,
    this.minWaitMs = 3000,
    this.maxWaitMs = 90000,
    this.busyBaseMs = 2000,
    this.busyMaxMs = 30000,
    this.maxBusyRetries = 8,
    this.notConnectedRecheckMs = 10000,
    this.maxQueueAgeMs = 6 * 3600 * 1000,
    this.minGapMs = 1000,
  });

  int attemptsFor({required bool hasPath}) => hasPath ? directAttempts : floodAttempts;

  int ackWaitMs(int estTimeoutMs, Random rnd) {
    final w = (estTimeoutMs * timeoutFactor).round() + slackMs + (jitterMs > 0 ? rnd.nextInt(jitterMs) : 0);
    return w.clamp(minWaitMs, maxWaitMs);
  }

  int busyDelayMs(int n) => min(busyMaxMs, busyBaseMs * (1 << min(n, 10)));
}

typedef OutboxNotify = void Function(ChatEvent e);

class Outbox {
  final ChatStore store;
  final OutboundMessageSink sink;
  final int Function() nowMs;
  final RetryPolicy policy;
  final Random rnd;
  final OutboxNotify notify;
  int _lastSendMs = 0;
  bool _running = false;

  Outbox({required this.store, required this.sink, required this.nowMs, this.policy = const RetryPolicy(), Random? random, required this.notify})
      : rnd = random ?? Random();

  /// Call once at startup (before the first [tick]). A message left in `sending` by a crash may or may not have reached the
  /// radio. It is requeued with the same sender timestamp, so if it did go out the receiver's dedupe collapses the repeat.
  int recover() {
    var n = 0;
    store.db.transaction(() {
      for (final m in store.messages.byState([MessageState.sending])) {
        store.messages.update(m.id, state: m.attempt > 0 ? MessageState.retrying : MessageState.queued, attempt: m.attempt > 0 ? m.attempt - 1 : 0);
        store.outbox.reschedule(m.id, nowMs());
        n++;
      }
      // Messages whose outbox row is missing (should not happen) are not left dangling.
      for (final m in store.messages.byState([MessageState.queued, MessageState.retrying])) {
        if (store.outbox.get(m.id) == null) _fail(m, FailReason.cancelled);
      }
    });
    return n;
  }

  /// Registers a freshly stored outgoing message for sending.
  void enqueue(ChatMessage m, {required bool hasPath}) {
    final now = nowMs();
    store.outbox.enqueue(OutboxEntry(
        messageId: m.id,
        dueAtMs: now,
        maxAttempts: m.convKind == ConvKind.channel ? 1 : policy.attemptsFor(hasPath: hasPath),
        createdMs: now));
  }

  int? get nextDueMs => store.outbox.nextDueMs();
  int get pending => store.outbox.count();

  /// Processes everything due now. Safe to call often; never re-enters.
  Future<void> tick() async {
    if (_running) return;
    _running = true;
    try {
      var guard = 0;
      while (guard++ < 200) {
        final due = store.outbox.due(nowMs(), limit: 1);
        if (due.isEmpty) break;
        final gap = _lastSendMs + policy.minGapMs - nowMs();
        if (gap > 0 && _lastSendMs != 0) {
          // Respect the minimum spacing: look again when it has passed.
          store.outbox.reschedule(due.first.messageId, nowMs() + gap);
          // others behind it are also later than now+gap in effect; stop for this tick
          break;
        }
        await _process(due.first);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _process(OutboxEntry e) async {
    final m = store.messages.get(e.messageId);
    final now = nowMs();
    if (m == null || m.state == MessageState.acked || m.state == MessageState.heard || m.state == MessageState.received) {
      store.outbox.remove(e.messageId);
      return;
    }
    if (m.state == MessageState.failed) {
      store.outbox.remove(e.messageId);
      return;
    }
    if (now - e.createdMs > policy.maxQueueAgeMs) {
      _fail(m, m.attempt == 0 ? FailReason.notConnected : FailReason.expired);
      return;
    }
    // Woke up with an attempt in flight and no ack: either send the next attempt or give up.
    if (m.attempt >= e.maxAttempts) {
      _fail(m, FailReason.noAck);
      return;
    }
    if (!sink.canSend) {
      _setState(m, m.attempt > 0 ? MessageState.retrying : MessageState.queued);
      store.outbox.reschedule(m.id, now + policy.notConnectedRecheckMs);
      return;
    }
    // Resolve the target.
    String? contactKey;
    int? slot;
    if (m.convKind == ConvKind.channel) {
      final id = int.tryParse(ConvKey.body(m.convKey));
      final ch = id == null ? null : store.channels.getById(id);
      if (ch == null || ch.slot == null) {
        _fail(m, FailReason.unknownChannel);
        return;
      }
      slot = ch.slot;
    } else {
      final c = store.contacts.byPrefix(m.radioId, ConvKey.body(m.convKey));
      if (c == null) {
        _fail(m, FailReason.unknownContact);
        return;
      }
      contactKey = c.publicKey;
    }
    final attemptNo = m.attempt + 1;
    final contact = contactKey == null ? null : store.contacts.get(m.radioId, contactKey);
    // Direct if a path is known, except the last attempt which floods (the path may have gone stale).
    final hasPath = contact?.hasPath ?? false;
    final forceFlood = !hasPath || (contact?.forceFlood ?? false) || (attemptNo >= e.maxAttempts && e.maxAttempts > 1 && attemptNo > 1);
    store.messages.update(m.id, state: MessageState.sending, attempt: attemptNo);
    notify(ChatEvent.updated(m.convKey, m.id));
    _lastSendMs = now;
    try {
      if (m.convKind == ConvKind.channel) {
        final usedTs = await sink.sendChannel(radioId: m.radioId, slot: slot!, text: m.text, timestamp: m.tsSender);
        if (usedTs != m.tsSender) store.messages.retimestamp(m.id, usedTs, dedupeKeyFor(m.convKey, usedTs, m.text));
        store.messages.update(m.id, state: MessageState.sent, route: Route.flood, repeatsHeard: 0);
        store.outbox.remove(m.id);
        store.outbox.addAttempt(DeliveryAttempt(messageId: m.id, attempt: attemptNo, sentAtMs: now, route: Route.flood));
      } else {
        final r = await sink.sendDirect(
            radioId: m.radioId, contactPublicKey: contactKey!, text: m.text, timestamp: m.tsSender, attempt: attemptNo - 1, forceFlood: forceFlood);
        final route = r.flood ? Route.flood : Route.direct;
        store.db.transaction(() {
          if (forceFlood && hasPath) store.contacts.setPath(m.radioId, contactKey!, null, -1); // the flood relearns the route
          store.outbox.addAttempt(DeliveryAttempt(
              messageId: m.id, attempt: attemptNo, sentAtMs: now, route: route, expectedAck: r.expectedAck, estTimeoutMs: r.estTimeoutMs));
          store.messages.update(m.id, state: MessageState.sent, route: route, expectedAck: r.expectedAck);
          store.outbox.reschedule(m.id, now + policy.ackWaitMs(r.estTimeoutMs, rnd), busyRetries: 0);
        });
      }
    } on RadioNotConnected {
      store.messages.update(m.id, state: m.attempt > 0 ? MessageState.retrying : MessageState.queued, attempt: m.attempt);
      store.outbox.reschedule(m.id, now + policy.notConnectedRecheckMs);
    } on RadioBusy {
      final n = e.busyRetries + 1;
      if (n > policy.maxBusyRetries) {
        _fail(m, FailReason.radioBusy);
      } else {
        store.messages.update(m.id, state: m.attempt > 0 ? MessageState.retrying : MessageState.queued, attempt: m.attempt);
        store.outbox.reschedule(m.id, now + policy.busyDelayMs(n), busyRetries: n);
      }
    } on RadioContactsFull {
      _fail(m, FailReason.contactListFull);
    } on RadioTargetMissing {
      _fail(m, m.convKind == ConvKind.channel ? FailReason.unknownChannel : FailReason.unknownContact);
    } on RadioRejected {
      _fail(m, FailReason.radioRejected);
    } catch (_) {
      // Unknown error from the adapter: treat like busy so a bug there cannot drop a message silently.
      final n = e.busyRetries + 1;
      if (n > policy.maxBusyRetries) {
        _fail(m, FailReason.radioRejected);
      } else {
        store.messages.update(m.id, state: m.attempt > 0 ? MessageState.retrying : MessageState.queued, attempt: m.attempt);
        store.outbox.reschedule(m.id, now + policy.busyDelayMs(n), busyRetries: n);
      }
    }
    notify(ChatEvent.updated(m.convKey, m.id));
  }

  /// SEND_CONFIRMED. Matches any attempt of any waiting (or just-failed) message. Returns the message id, or null if unknown.
  String? onAck(String radioId, int ackCode) {
    final a = store.outbox.findByAck(radioId, ackCode);
    if (a == null) return null;
    final m = store.messages.get(a.messageId);
    if (m == null) return null;
    store.db.transaction(() {
      store.messages.update(m.id, state: MessageState.acked, ackMs: max(0, nowMs() - a.sentAtMs), clearFailReason: true, route: a.route);
      store.outbox.remove(m.id);
    });
    notify(ChatEvent.updated(m.convKey, m.id));
    return m.id;
  }

  /// User pressed retry on a failed message: starts again from attempt 0. The sender timestamp is kept, so if an earlier
  /// attempt did reach the contact their side dedupes it instead of showing the text twice.
  bool retryFailed(String messageId, {required bool hasPath}) {
    final m = store.messages.get(messageId);
    if (m == null || m.state != MessageState.failed) return false;
    store.db.transaction(() {
      store.messages.update(m.id, state: MessageState.queued, attempt: 0, clearFailReason: true);
      enqueue(m, hasPath: hasPath);
    });
    notify(ChatEvent.updated(m.convKey, m.id));
    return true;
  }

  /// Stops a message that is still queued or still waiting for an ack (no more retries).
  bool cancel(String messageId) {
    final m = store.messages.get(messageId);
    if (m == null || !(m.isPending || (m.state == MessageState.sent && store.outbox.get(m.id) != null))) return false;
    _fail(m, FailReason.cancelled);
    return true;
  }

  void _setState(ChatMessage m, MessageState s) {
    if (m.state != s) {
      store.messages.update(m.id, state: s);
      notify(ChatEvent.updated(m.convKey, m.id));
    }
  }

  void _fail(ChatMessage m, FailReason r) {
    store.db.transaction(() {
      store.messages.update(m.id, state: MessageState.failed, failReason: r);
      store.outbox.remove(m.id);
    });
    notify(ChatEvent.updated(m.convKey, m.id));
  }
}
