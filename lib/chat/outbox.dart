// The outbox: queued messages, client-side retries for DMs, ACK matching, give-up with a reason.
// All state lives in SQLite (messages + outbox + delivery_attempts), so a restart loses nothing.
// A reply from the contact marks an unconfirmed DM likely delivered ([onReply]).
// Deterministic: no timers in here. Call [tick] when [nextDueMs] arrives (ChatService does that), and [onAck] on SEND_CONFIRMED.
import 'dart:math';

import '../radio/path_tools.dart';
import 'db/outbox_repository.dart';
import 'events.dart';
import 'models.dart';
import 'radio_bridge.dart';
import 'store.dart';

class RetryPolicy {
  /// Attempts for a DM that goes by flood / by a known path (official app: 3, and 5 with a direct path; changelog v1.4.0, v1.14.0).
  final int floodAttempts;
  final int directAttempts;

  /// Ack wait per try = the radio's estimate (RESP_CODE_SENT est_timeout) * factor + slack + random jitter, clamped. The
  /// firmware's estimate is one-way-ish (flood: 500 ms + 16 x airtime, MyMesh.cpp calcFloodTimeoutMillisFor); the ack has to
  /// come all the way back, by flood when there is no route (a PATH return carrying the ack). A multi-hop flood round trip
  /// routinely takes longer than the estimate, so flood waits get more room than direct ones (DM delivery fix, Nov 8 2026:
  /// the old 1.25x / 3 s floor gave up on a 3-try flood in ~20 s while the ack was still on its way).
  final double timeoutFactor;
  final double floodTimeoutFactor;
  final int slackMs;
  final int jitterMs;
  final int minWaitMs;
  final int minFloodWaitMs;
  final int maxWaitMs;

  /// After the LAST try, wait at least this long (and twice the normal wait) before saying Not delivered. A late ack still
  /// upgrades the message afterwards; this only keeps the red state from showing while the ack is plausibly in flight.
  final int lastTryGraceMs;

  /// A direct message from the contact within this long after our first try marks our unconfirmed DM as likely delivered.
  final int replyWindowMs;

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
    this.timeoutFactor = 1.5,
    this.floodTimeoutFactor = 2.0,
    this.slackMs = 1500,
    this.jitterMs = 2000,
    this.minWaitMs = 6000,
    this.minFloodWaitMs = 12000,
    this.maxWaitMs = 120000,
    this.lastTryGraceMs = 30000,
    this.replyWindowMs = 30 * 60 * 1000,
    this.busyBaseMs = 2000,
    this.busyMaxMs = 30000,
    this.maxBusyRetries = 8,
    this.notConnectedRecheckMs = 10000,
    this.maxQueueAgeMs = 6 * 3600 * 1000,
    this.minGapMs = 1000,
  });

  int attemptsFor({required bool hasPath}) => hasPath ? directAttempts : floodAttempts;

  /// How long to wait for the ack of one try. [flood]: the try (and so its ack) went by flood. [lastTry]: no try follows, so
  /// this is the wait before Not delivered.
  int ackWaitMs(int estTimeoutMs, Random rnd, {bool flood = false, bool lastTry = false}) {
    final factor = flood ? floodTimeoutFactor : timeoutFactor;
    var w = (estTimeoutMs * factor).round() + slackMs + (jitterMs > 0 ? rnd.nextInt(jitterMs) : 0);
    w = max(w, flood ? minFloodWaitMs : minWaitMs);
    if (lastTry) w = max(w * 2, lastTryGraceMs);
    return min(w, maxWaitMs);
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

  /// Writes the pinned route back to the radio before a send in Keep-this-route mode when the radio no longer holds it
  /// (spike S13: any incoming PATH packet overwrites it). Null, or returning false, means "cannot": the send goes on as it is.
  /// Stays null until the set-path radio write is verified on a real radio (AppFlags.routeWriteVerified).
  final Future<bool> Function(Contact contact)? restorePath;
  int _lastSendMs = 0;
  bool _running = false;

  Outbox({
    required this.store,
    required this.sink,
    required this.nowMs,
    this.policy = const RetryPolicy(),
    Random? random,
    required this.notify,
    this.restorePath,
  }) : rnd = random ?? Random();

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

  /// Registers a freshly stored outgoing message for sending. [forceFlood]: the person chose "Send by flood" for this one
  /// message, so every try floods (a flood also lets the radio learn a fresh route).
  void enqueue(ChatMessage m, {required bool hasPath, bool forceFlood = false}) {
    final now = nowMs();
    final flood = forceFlood && m.convKind != ConvKind.channel;
    store.outbox.enqueue(
      OutboxEntry(
        messageId: m.id,
        dueAtMs: now,
        maxAttempts: m.convKind == ConvKind.channel ? 1 : policy.attemptsFor(hasPath: hasPath && !flood),
        createdMs: now,
        forceFlood: flood,
      ),
    );
  }

  /// Sends a channel message again that no repeater relayed (Resend). Same text; the radio stamps the time. The copies heard
  /// so far (none) stay with it.
  bool resendChannel(String messageId) {
    final m = store.messages.get(messageId);
    if (m == null || !m.isOutgoing || m.convKind != ConvKind.channel || m.isPending || m.repeatsHeard > 0) return false;
    if (m.state != MessageState.sent && m.state != MessageState.failed) return false;
    store.db.transaction(() {
      store.messages.update(m.id, state: MessageState.queued, attempt: 0, clearFailReason: true);
      enqueue(m, hasPath: false);
    });
    notify(ChatEvent.updated(m.convKey, m.id));
    return true;
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
    if (m == null ||
        m.state == MessageState.acked ||
        m.state == MessageState.likelyDelivered ||
        m.state == MessageState.heard ||
        m.state == MessageState.received) {
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
    // Woke up with an attempt in flight and no ack: either send the next attempt or give up. When the phone is not linked to
    // the radio right now, the ack may have come while it was away: the firmware drops PUSH_CODE_SEND_CONFIRMED when no app
    // is connected (SerialBLEInterface::writeFrame). Do not call that "no ack"; wait for the link and allow one more try.
    if (m.attempt >= e.maxAttempts && m.state == MessageState.sent && !sink.canSend) {
      store.outbox.setMaxAttempts(m.id, m.attempt + 1);
      store.outbox.reschedule(m.id, now + policy.notConnectedRecheckMs);
      return;
    }
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
    var contact = contactKey == null ? null : store.contacts.get(m.radioId, contactKey);
    final mode = contact?.pathMode ?? PathMode.auto;
    // Keep this route: the pinned route is what the radio must hold. Put it back first when the radio lost or changed it.
    if (mode == PathMode.fixed && contact != null && restorePath != null) {
      final pinned = pinnedRouteOf(contact);
      if (pinned != null && decodePath(contact.outPathLen, contact.outPath ?? const []) != pinned) {
        try {
          if (await restorePath!(contact)) contact = store.contacts.get(m.radioId, contactKey!) ?? contact;
        } catch (_) {}
      }
    }
    final hasPath = contact?.hasPath ?? false;
    // Automatic: direct if a path is known, except the last attempt which floods (the path may have gone stale).
    // Always search: every attempt floods. Keep this route: never the last-try flood, never clears the path.
    final forceFlood =
        e.forceFlood || !hasPath || mode == PathMode.flood || (mode == PathMode.auto && attemptNo >= e.maxAttempts && e.maxAttempts > 1 && attemptNo > 1);
    store.messages.update(m.id, state: MessageState.sending, attempt: attemptNo);
    notify(ChatEvent.updated(m.convKey, m.id));
    _lastSendMs = now;
    try {
      if (m.convKind == ConvKind.channel) {
        final usedTs = await sink.sendChannel(radioId: m.radioId, slot: slot!, text: m.text, timestamp: m.tsSender);
        if (usedTs != m.tsSender) store.messages.retimestamp(m.id, usedTs, dedupeKeyFor(m.convKey, usedTs, m.text));
        // repeats_heard is the count of message_repeats rows (ChatService._applyCopy); a resend keeps the copies heard so far.
        store.messages.update(m.id, state: MessageState.sent, route: Route.flood);
        store.outbox.remove(m.id);
        store.outbox.addAttempt(DeliveryAttempt(messageId: m.id, attempt: attemptNo, sentAtMs: now, route: Route.flood));
      } else {
        final r = await sink.sendDirect(
          radioId: m.radioId,
          contactPublicKey: contactKey!,
          text: m.text,
          timestamp: m.tsSender,
          attempt: attemptNo - 1,
          forceFlood: forceFlood,
        );
        final route = r.flood ? Route.flood : Route.direct;
        // While this try was being handed to the radio, an ack for an earlier try (or a reply from them, or a cancel) may have
        // settled the message. Log the try, but never overwrite a settled state with "sent" (that left it stuck waiting).
        final now2 = store.messages.get(m.id);
        if (now2 == null || now2.state != MessageState.sending) {
          store.outbox.addAttempt(
            DeliveryAttempt(messageId: m.id, attempt: attemptNo, sentAtMs: now, route: route, expectedAck: r.expectedAck, estTimeoutMs: r.estTimeoutMs),
          );
          return;
        }
        // Sent direct: the radio used the route it held, which the phone mirrors in the contact. Keep it with the message so
        // details show the route this message took, not whatever the contact's route is later. A flood has no route.
        final used = (route == Route.direct && contact != null && contact.hasPath) ? contact : null;
        store.db.transaction(() {
          if (forceFlood && hasPath && mode != PathMode.fixed) store.contacts.setPath(m.radioId, contactKey!, null, -1); // the flood relearns the route
          store.outbox.addAttempt(
            DeliveryAttempt(messageId: m.id, attempt: attemptNo, sentAtMs: now, route: route, expectedAck: r.expectedAck, estTimeoutMs: r.estTimeoutMs),
          );
          store.messages.update(
            m.id,
            state: MessageState.sent,
            route: route,
            expectedAck: r.expectedAck,
            sentPath: used?.routeIds.join(),
            sentHashSize: used?.pathHashBytes,
            clearSentPath: used == null,
          );
          store.outbox.reschedule(m.id, now + policy.ackWaitMs(r.estTimeoutMs, rnd, flood: r.flood, lastTry: attemptNo >= e.maxAttempts), busyRetries: 0);
        });
      }
    } on RadioNotConnected {
      if (_settledMeanwhile(m.id)) return;
      store.messages.update(m.id, state: m.attempt > 0 ? MessageState.retrying : MessageState.queued, attempt: m.attempt);
      store.outbox.reschedule(m.id, now + policy.notConnectedRecheckMs);
    } on RadioBusy {
      if (_settledMeanwhile(m.id)) return;
      final n = e.busyRetries + 1;
      if (n > policy.maxBusyRetries) {
        _fail(m, FailReason.radioBusy);
      } else {
        store.messages.update(m.id, state: m.attempt > 0 ? MessageState.retrying : MessageState.queued, attempt: m.attempt);
        store.outbox.reschedule(m.id, now + policy.busyDelayMs(n), busyRetries: n);
      }
    } on RadioContactsFull {
      if (_settledMeanwhile(m.id)) return;
      _fail(m, FailReason.contactListFull);
    } on RadioTargetMissing {
      if (_settledMeanwhile(m.id)) return;
      _fail(m, m.convKind == ConvKind.channel ? FailReason.unknownChannel : FailReason.unknownContact);
    } on RadioRejected {
      if (_settledMeanwhile(m.id)) return;
      _fail(m, FailReason.radioRejected);
    } catch (_) {
      if (_settledMeanwhile(m.id)) return;
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

  /// SEND_CONFIRMED. Matches any attempt of any unconfirmed outgoing message, whatever its state now (waiting, between tries,
  /// queued again after Retry, failed, likely delivered): a confirmation always wins. [tripMs] is the radio's own round trip
  /// for that try (PUSH_CODE_SEND_CONFIRMED bytes 5-8); without it the time since that try was handed over is used. Returns
  /// the message id, or null if the code is unknown.
  String? onAck(String radioId, int ackCode, {int? tripMs}) {
    final a = store.outbox.findByAck(radioId, ackCode);
    if (a == null) return null;
    final m = store.messages.get(a.messageId);
    if (m == null) return null;
    store.db.transaction(() {
      store.messages.update(
        m.id,
        state: MessageState.acked,
        ackMs: tripMs != null && tripMs > 0 ? tripMs : max(0, nowMs() - a.sentAtMs),
        expectedAck: a.expectedAck, // the try that got through (the details sheet marks it)
        clearFailReason: true,
        route: a.route,
      );
      store.outbox.remove(m.id);
    });
    notify(ChatEvent.updated(m.convKey, m.id));
    return m.id;
  }

  /// The contact sent us a direct message at [atMs]. Every DM of ours to them that went out (at least one try) within
  /// [RetryPolicy.replyWindowMs] before that, and is still unconfirmed, is marked likely delivered: no further tries (no
  /// duplicates on their side), and no red Not delivered. Never sent ones (queued, failed before any try) are left alone, as are
  /// messages given up for a reason other than a missing ack. Returns the ids changed.
  List<String> onReply(String radioId, String convKey, int atMs) {
    if (ConvKey.kindOf(convKey) != ConvKind.dm) return const [];
    final changed = <String>[];
    final candidates = store.messages
        .byState(const [MessageState.queued, MessageState.sending, MessageState.sent, MessageState.retrying, MessageState.failed])
        .where((m) => m.radioId == radioId && m.convKey == convKey);
    store.db.transaction(() {
      for (final m in candidates) {
        if (m.state == MessageState.failed && m.failReason != FailReason.noAck && m.failReason != FailReason.expired) continue;
        final first = store.outbox.firstSentMs(m.id);
        if (first == null || first > atMs || atMs - first > policy.replyWindowMs) continue;
        store.messages.update(m.id, state: MessageState.likelyDelivered, clearFailReason: true);
        store.outbox.remove(m.id);
        changed.add(m.id);
      }
    });
    for (final id in changed) {
      notify(ChatEvent.updated(convKey, id));
    }
    return changed;
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

  /// True when, during an await on the radio, the message stopped being "sending" (acked, likely delivered, cancelled).
  bool _settledMeanwhile(String id) => store.messages.get(id)?.state != MessageState.sending;

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

/// The route Keep-this-route pins for [c], or null when none is stored.
PathRoute? pinnedRouteOf(Contact c) {
  final p = c.pinnedPath;
  if (c.pathMode != PathMode.fixed || p == null || p.isEmpty) return null;
  try {
    return PathRoute.fromHex(splitHexHops(p));
  } catch (_) {
    return null;
  }
}
