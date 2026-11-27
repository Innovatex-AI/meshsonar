// The outbox: queued messages, the tries of a direct message, confirmation matching, give-up with a reason.
//
// Build 77 (redesign round 3 part 1): direct-message delivery is the official MeshCore flow, nothing extra, nothing less.
// The reference is the firmware (companion v1.18.0), meshcore_py send_msg_with_retry and MeshCore One
// MessageService+DMRetry.swift; the official app's defaults are in its changelog (v1.51.0).
//
//   * One message = one sender timestamp. Every try carries it; only the try number changes (0, 1, 2 ... 7), and the radio
//     turns each try number into a different packet. Nothing here cuts or rewrites the try number.
//   * The radio alone decides direct or flood: direct while it holds a route to the contact, flood when it does not. The
//     app reads which one it was from the radio's SENT reply and shows that. It never decides or assumes it.
//   * Tries: [DeliverySettings.directTries] (4), then ONE reset path, then [DeliverySettings.floodTries] (4). When the
//     radio has no route every try is a flood by the radio's own decision and no reset is sent.
//   * After each try the wait for the confirmation is the radio's own estimate x 1.2. No minimums, no padding of ours.
//   * The confirmation code of each try is computed on the phone BEFORE the try goes out (protocol.dart expectedDmAck), so
//     a confirmation is matched even when the radio's reply to the send was lost, and one that arrives late.
//   * A confirmation for ANY try of a message means delivered: an earlier try, or after the message was marked failed.
//   * A manual retry is a new send: new timestamp, tries from 0. Cancel stops a message that is still retrying.
//
// All state lives in SQLite (messages + outbox + delivery_attempts), so a restart loses nothing. Deterministic: no timers
// in here. Call [tick] when [nextDueMs] arrives (ChatService does that), and [onAck] on SEND_CONFIRMED.
import 'dart:convert';
import 'dart:math';

import '../radio/crypto.dart' show sha256;
import '../radio/protocol.dart' show expectedDmAck, maxDmTextBytesFor, maxDmTextBytesLateTry, maxDmWireAttempt;
import 'db/outbox_repository.dart';
import 'delivery_settings.dart';
import 'events.dart';
import 'message_log.dart';
import 'models.dart';
import 'radio_bridge.dart';
import 'store.dart';

class RetryPolicy {
  /// The wait for a confirmation is the radio's estimate (RESP_CODE_SENT est_timeout) times this: 1.2, as meshcore_py
  /// (`suggested_timeout / 1000 * 1.2`) and MeshCore One (`dmAckTimeoutHeadroom`) do.
  final double ackWaitFactor;

  /// The wait used only when the radio gave NO estimate for a try (its reply to the send was lost) and no earlier try of
  /// the message has one either.
  final int noEstimateWaitMs;

  /// Extra random wait added to each confirmation wait, 0..jitterMs. 0 = none (the default).
  final int jitterMs;

  /// The radio said "busy" (no free packet): ask again after base, 2 x base, 4 x base, then give up (MeshCore One
  /// withPoolBackoff: 3 tries, 0.5 s base, x 2).
  final int busyBaseMs;
  final int maxBusyRetries;

  /// How long to wait before looking again when the radio is not connected (tries are not used up).
  final int notConnectedRecheckMs;

  /// A message older than this is dropped (never sent: notConnected; sent but unanswered: expired).
  final int maxQueueAgeMs;

  /// Minimum gap between two sends from the same app (the official app waits 1 s between sends, v1.40.0).
  final int minGapMs;

  const RetryPolicy({
    this.ackWaitFactor = 1.2,
    this.noEstimateWaitMs = 5000,
    this.jitterMs = 0,
    this.busyBaseMs = 500,
    this.maxBusyRetries = 3,
    this.notConnectedRecheckMs = 10000,
    this.maxQueueAgeMs = 6 * 3600 * 1000,
    this.minGapMs = 1000,
  });

  /// How long to wait for the confirmation of one try: the radio's estimate x [ackWaitFactor]. [estTimeoutMs] null or 0 =
  /// the radio gave none.
  int ackWaitMs(int? estTimeoutMs, Random rnd) {
    final est = (estTimeoutMs == null || estTimeoutMs <= 0) ? null : estTimeoutMs;
    final w = est == null ? noEstimateWaitMs : (est * ackWaitFactor).round();
    return w + (jitterMs > 0 ? rnd.nextInt(jitterMs) : 0);
  }

  int busyDelayMs(int n) => busyBaseMs * (1 << (n - 1).clamp(0, 10));
}

typedef OutboxNotify = void Function(ChatEvent e);

/// Where a message is in its tries, for "try n of m" and the message details.
class DeliveryProgress {
  /// The try being made or last made, 1-based; 0 before the first.
  final int tryNumber;

  /// How many tries the message gets in all. Null when it is no longer known (the message is finished).
  final int? tryCount;

  /// Of [tryCount], how many come before the one reset path.
  final int? directTries;

  /// Every try of the current send (the newest round), oldest first.
  final List<DeliveryAttempt> tries;

  /// Tries of earlier sends of the same message (before a manual retry), oldest first.
  final List<DeliveryAttempt> earlierTries;

  /// The message is still being tried (it can be cancelled).
  final bool active;
  const DeliveryProgress({required this.tryNumber, this.tryCount, this.directTries, this.tries = const [], this.earlierTries = const [], this.active = false});
}

class Outbox {
  final ChatStore store;
  final OutboundMessageSink sink;
  final int Function() nowMs;
  final RetryPolicy policy;
  final Random rnd;
  final OutboxNotify notify;

  /// The tries a NEW message gets (read when it is queued; a message on its way keeps its plan).
  final DeliverySettings Function() settings;

  /// The message log (null = none). Never given message text.
  final MessageLog? log;
  int _lastSendMs = 0;
  bool _running = false;

  /// Messages whose contact was put on the radio once already after "not a contact": not done twice for one message.
  final Set<String> _addedToRadio = {};

  Outbox({
    required this.store,
    required this.sink,
    required this.nowMs,
    this.policy = const RetryPolicy(),
    Random? random,
    required this.notify,
    DeliverySettings Function()? settings,
    this.log,
  })  : rnd = random ?? Random(),
        settings = settings ?? (() => DeliverySettings.defaults);

  DeliveryRadioControl? get _control => sink is DeliveryRadioControl ? sink as DeliveryRadioControl : null;

  void _say(String text, {String? id}) => log?.addChat(text, messageId: id);

  /// Call once at startup (before the first [tick]). A message left in `sending` by a crash may or may not have reached the
  /// radio. It is queued again with the same try number and the same sender timestamp: if that try did go out, the mesh
  /// drops the identical packet and its confirmation still matches (the code was stored before the send).
  int recover() {
    var n = 0;
    store.db.transaction(() {
      for (final m in store.messages.byState([MessageState.sending])) {
        store.outbox.closeOpenAttempts(m.id, TryOutcome.interrupted);
        store.messages.update(m.id, state: m.attempt > 1 ? MessageState.retrying : MessageState.queued, attempt: m.attempt > 0 ? m.attempt - 1 : 0);
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

  /// Registers a freshly stored outgoing message for sending. [forceFlood]: the person chose flood for this one message
  /// (long-press Send), done the official way: one reset path before the first try, then the normal send. [hasPath] is
  /// ignored since build 77 (the phone's copy of a route decides nothing); it stays for callers written against build 76.
  void enqueue(ChatMessage m, {bool hasPath = false, bool forceFlood = false, int round = 0}) {
    final now = nowMs();
    if (m.convKind == ConvKind.channel) {
      store.outbox.enqueue(OutboxEntry(messageId: m.id, dueAtMs: now, maxAttempts: 1, createdMs: now));
      return;
    }
    final s = settings();
    var total = min(s.totalTries, maxDmWireAttempt + 1);
    // Tries 5 and up carry 158 bytes at most (the radio appends the try number to the packet): a longer text gets the
    // tries that can carry it.
    if (utf8.encode(m.text).length > maxDmTextBytesLateTry) total = min(total, 4);
    total = max(1, total);
    store.outbox.enqueue(OutboxEntry(
      messageId: m.id,
      dueAtMs: now,
      maxAttempts: total,
      createdMs: now,
      forceFlood: forceFlood,
      directTries: s.directTries,
      round: round,
    ));
    _say('queued: $total tries (${min(s.directTries, total)} before the reset, fallback ${s.floodFallback ? 'on' : 'off'})${forceFlood ? ', flood chosen' : ''}, send $round', id: m.id);
  }

  /// Sends a channel message again that no repeater relayed (Resend). Same text; the radio stamps the time. The copies heard
  /// so far (none) stay with it.
  bool resendChannel(String messageId) {
    final m = store.messages.get(messageId);
    if (m == null || !m.isOutgoing || m.convKind != ConvKind.channel || m.isPending || m.repeatsHeard > 0) return false;
    if (m.state != MessageState.sent && m.state != MessageState.failed) return false;
    store.db.transaction(() {
      store.messages.update(m.id, state: MessageState.queued, attempt: 0, clearFailReason: true);
      enqueue(m);
    });
    notify(ChatEvent.updated(m.convKey, m.id));
    return true;
  }

  int? get nextDueMs => store.outbox.nextDueMs();
  int get pending => store.outbox.count();

  /// Where [messageId] is in its tries ("try n of m") and every try with its route and outcome as the radio reported them.
  DeliveryProgress progress(String messageId) {
    final m = store.messages.get(messageId);
    final e = store.outbox.get(messageId);
    final all = store.outbox.attemptsFor(messageId);
    final round = e?.round ?? (all.isEmpty ? 0 : all.last.round);
    final now = [for (final a in all) if (a.round == round) a];
    final before = [for (final a in all) if (a.round != round) a];
    return DeliveryProgress(
      tryNumber: m?.attempt ?? now.length,
      tryCount: e?.maxAttempts,
      directTries: e == null ? null : min(e.directTries, e.maxAttempts),
      tries: now,
      earlierTries: before,
      active: e != null && m != null && m.state != MessageState.failed && m.state != MessageState.acked,
    );
  }

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
        m.state == MessageState.received ||
        m.state == MessageState.failed) {
      store.outbox.remove(e.messageId);
      return;
    }
    if (now - e.createdMs > policy.maxQueueAgeMs) {
      store.outbox.closeOpenAttempts(m.id, TryOutcome.noConfirmation);
      if (m.convKind != ConvKind.channel) _say('gave up: it waited too long', id: m.id);
      _fail(m, m.attempt == 0 ? FailReason.notConnected : FailReason.expired);
      return;
    }
    if (m.convKind == ConvKind.channel) {
      await _processChannel(e, m, now);
      return;
    }
    // Woke up with a try in flight and no confirmation: that try's wait is over.
    if (m.state == MessageState.sent) {
      // While the phone is not linked to the radio a confirmation cannot arrive (the firmware drops the push when no app is
      // connected): the wait is not over until the link is back.
      if (!sink.canSend) {
        store.outbox.reschedule(m.id, now + policy.notConnectedRecheckMs);
        return;
      }
      final closed = store.outbox.closeOpenAttempts(m.id, TryOutcome.noConfirmation);
      if (closed > 0) _say('try ${m.attempt} of ${e.maxAttempts}: no confirmation within the wait', id: m.id);
    }
    if (m.attempt >= e.maxAttempts) {
      _say('not delivered: no confirmation after ${m.attempt} ${m.attempt == 1 ? 'try' : 'tries'}', id: m.id);
      _fail(m, FailReason.noAck);
      return;
    }
    if (!sink.canSend) {
      _setState(m, m.attempt > 0 ? MessageState.retrying : MessageState.queued);
      store.outbox.reschedule(m.id, now + policy.notConnectedRecheckMs);
      return;
    }
    final c = store.contacts.byPrefix(m.radioId, ConvKey.body(m.convKey));
    if (c == null) {
      _say('stopped: the contact is no longer in the phone\'s book', id: m.id);
      _fail(m, FailReason.unknownContact);
      return;
    }
    final contactKey = c.publicKey;
    final attemptNo = m.attempt + 1; // the "n" of "try n of m"
    final wire = attemptNo - 1; // the try number the radio gets, untouched
    final bytes = utf8.encode(m.text).length;
    if (bytes > maxDmTextBytesFor(wire)) {
      // Cannot happen with the plan made in [enqueue]; said as it is if it ever does.
      _say('stopped: $bytes bytes do not fit try $attemptNo (${maxDmTextBytesFor(wire)} bytes)', id: m.id);
      store.outbox.closeOpenAttempts(m.id, TryOutcome.noConfirmation);
      _fail(m, m.attempt == 0 ? FailReason.textTooLong : FailReason.noAck);
      return;
    }

    store.messages.update(m.id, state: MessageState.sending, attempt: attemptNo);
    notify(ChatEvent.updated(m.convKey, m.id));
    _lastSendMs = now;

    // The one reset path of this message (rule 9): before try 1 when the person chose flood; otherwise after the direct
    // tries are used up, and only when the radio was sending direct (with no route it floods already: nothing to reset).
    var resetNow = false;
    if (!e.didReset) {
      if (e.forceFlood && attemptNo == 1) {
        resetNow = true;
      } else if (!e.forceFlood && e.maxAttempts > e.directTries && wire >= e.directTries) {
        final known = store.outbox.attemptsOfRound(m.id, e.round).where((a) => a.routeKnown).toList();
        if (known.isNotEmpty && known.every((a) => a.route == Route.flood)) {
          store.outbox.setDidReset(m.id);
          _say('no reset path before try $attemptNo: the radio has no route and floods already', id: m.id);
        } else {
          resetNow = true;
        }
      }
    }
    if (resetNow) {
      store.outbox.setDidReset(m.id);
      final ctl = _control;
      if (ctl == null) {
        resetNow = false;
      } else {
        try {
          final ok = await ctl.resetPath(radioId: m.radioId, contactPublicKey: contactKey);
          _say('reset path before try $attemptNo: ${ok ? 'OK' : 'the radio does not have this contact'}', id: m.id);
        } on RadioNotConnected {
          if (_settledMeanwhile(m.id)) return;
          _backToWaiting(m, now + policy.notConnectedRecheckMs);
          return;
        } catch (err) {
          // As the reference does: a reset that failed does not stop the send.
          _say('reset path before try $attemptNo failed (${err.runtimeType}); sending anyway', id: m.id);
        }
        if (_settledMeanwhile(m.id)) return;
      }
    }

    // The code the confirmation will carry, stored with the try BEFORE the send: a confirmation that races the radio's
    // reply, or whose reply was lost, still finds its try.
    int? predicted;
    try {
      predicted = expectedDmAck(sha256, timestamp: m.tsSender, attempt: wire, text: m.text, senderPublicKey: fromHex(m.radioId));
    } catch (_) {
      predicted = null; // a radio id that is not a key: the radio's own code is used when it answers
    }
    final tryId = store.outbox.addAttempt(DeliveryAttempt(
      messageId: m.id,
      attempt: attemptNo,
      sentAtMs: now,
      route: Route.flood,
      routeKnown: false,
      expectedAck: predicted,
      wireAttempt: wire,
      round: e.round,
      tsSender: m.tsSender,
      outcome: TryOutcome.sending,
      resetBefore: resetNow,
    ));
    _say('try $attemptNo of ${e.maxAttempts} (try number $wire, ts ${m.tsSender}, ${bytes}b)${predicted == null ? '' : ' expects ack=${MessageLog.code(predicted)}'}', id: m.id);

    try {
      final r = await sink.sendDirect(radioId: m.radioId, contactPublicKey: contactKey, text: m.text, timestamp: m.tsSender, attempt: wire, forceFlood: false);
      final route = r.flood ? Route.flood : Route.direct;
      final ack2 = (r.expectedAck != 0 && r.expectedAck != predicted) ? r.expectedAck : null;
      final wait = policy.ackWaitMs(r.estTimeoutMs, rnd);
      _say('try $attemptNo sent ${route.name} (the radio said so), est ${r.estTimeoutMs}ms, waiting ${wait}ms${ack2 == null ? '' : ', radio ack=${MessageLog.code(ack2)}'}', id: m.id);
      // While this try was being handed to the radio, a confirmation for an earlier try (or a cancel) may have settled the
      // message. Record what the radio said, but never overwrite a settled state with "sent".
      final now2 = store.messages.get(m.id);
      if (now2 == null || now2.state != MessageState.sending) {
        store.outbox.updateAttempt(tryId, route: route, routeKnown: true, estTimeoutMs: r.estTimeoutMs, ack2: ack2, outcome: _settledOutcome(now2, tryId));
        return;
      }
      // Sent direct: the radio used the route it held, which the phone mirrors in the contact. Kept with the message so
      // details show the route this message took. A flood has no route.
      final used = (route == Route.direct && c.hasPath) ? c : null;
      store.db.transaction(() {
        store.outbox.updateAttempt(tryId, route: route, routeKnown: true, estTimeoutMs: r.estTimeoutMs, ack2: ack2, outcome: TryOutcome.waiting);
        store.messages.update(
          m.id,
          state: MessageState.sent,
          route: route,
          expectedAck: ack2 ?? predicted ?? r.expectedAck,
          sentPath: used?.routeIds.join(),
          sentHashSize: used?.pathHashBytes,
          clearSentPath: used == null,
        );
        store.outbox.reschedule(m.id, now + wait, busyRetries: 0);
      });
    } on RadioNotConnected {
      store.outbox.removeAttempt(tryId);
      if (_settledMeanwhile(m.id)) return;
      _say('try $attemptNo not made: the radio is not connected', id: m.id);
      _backToWaiting(m, now + policy.notConnectedRecheckMs);
      return;
    } on RadioNoAnswer {
      // The radio did not answer the command: it may still have sent the packet. The try counts as made (MeshCore One does
      // the same on a command timeout); its confirmation still matches by the computed code.
      if (_settledMeanwhile(m.id)) {
        store.outbox.updateAttempt(tryId, outcome: _settledOutcome(store.messages.get(m.id), tryId));
        return;
      }
      final wait = policy.ackWaitMs(_lastEstimate(m.id, e.round), rnd);
      _say('try $attemptNo: the radio did not answer the send; it may have gone out. Waiting ${wait}ms', id: m.id);
      store.db.transaction(() {
        store.outbox.updateAttempt(tryId, outcome: TryOutcome.radioNoAnswer);
        store.messages.update(m.id, state: MessageState.sent, expectedAck: predicted);
        store.outbox.reschedule(m.id, now + wait, busyRetries: 0);
      });
    } on RadioBusy {
      store.outbox.removeAttempt(tryId);
      if (_settledMeanwhile(m.id)) return;
      final n = e.busyRetries + 1;
      if (n > policy.maxBusyRetries) {
        _say('stopped: the radio stayed busy (no free packet)', id: m.id);
        _fail(m, FailReason.radioBusy);
      } else {
        _say('try $attemptNo not made: the radio is busy (no free packet); asking again in ${policy.busyDelayMs(n)}ms', id: m.id);
        _backToWaiting(m, now + policy.busyDelayMs(n), busyRetries: n);
      }
      return;
    } on RadioContactsFull {
      store.outbox.removeAttempt(tryId);
      if (_settledMeanwhile(m.id)) return;
      _say('stopped: the radio\'s contact list is full', id: m.id);
      _fail(m, FailReason.contactListFull);
      return;
    } on RadioTargetMissing {
      store.outbox.removeAttempt(tryId);
      if (_settledMeanwhile(m.id)) return;
      await _notAContact(m, contactKey, attemptNo, now);
      return;
    } on RadioRejected catch (err) {
      store.outbox.removeAttempt(tryId);
      if (_settledMeanwhile(m.id)) return;
      _say('stopped: the radio refused the send (${err.message})', id: m.id);
      _fail(m, FailReason.radioRejected);
      return;
    } catch (err) {
      store.outbox.removeAttempt(tryId);
      if (_settledMeanwhile(m.id)) return;
      // Unknown error from the adapter: treat like busy so a bug there cannot drop a message silently.
      final n = e.busyRetries + 1;
      if (n > policy.maxBusyRetries) {
        _say('stopped: unexpected error from the radio layer (${err.runtimeType})', id: m.id);
        _fail(m, FailReason.radioRejected);
      } else {
        _say('try $attemptNo not made: unexpected error (${err.runtimeType}); asking again', id: m.id);
        _backToWaiting(m, now + policy.busyDelayMs(n), busyRetries: n);
      }
      return;
    }
    notify(ChatEvent.updated(m.convKey, m.id));
  }

  /// The radio answered "not a contact" (ERR NOT_FOUND): it cannot send to someone it does not hold. Handled as what it is:
  /// the contact is put on the radio once as a new contact (route unknown) and the same try is made again; a full list or a
  /// second "not a contact" ends the message with that reason. Nothing is taken off the radio to make room (decision D1).
  Future<void> _notAContact(ChatMessage m, String contactKey, int attemptNo, int now) async {
    final ctl = _control;
    if (ctl == null || !_addedToRadio.add(m.id)) {
      _say('stopped: the radio says this is not one of its contacts', id: m.id);
      _fail(m, FailReason.unknownContact);
      return;
    }
    _say('try $attemptNo: the radio says "not a contact"; adding the contact to the radio', id: m.id);
    try {
      await ctl.addContactToRadio(radioId: m.radioId, contactPublicKey: contactKey);
    } on RadioContactsFull {
      if (_settledMeanwhile(m.id)) return;
      _say('stopped: the radio\'s contact list is full', id: m.id);
      _fail(m, FailReason.contactListFull);
      return;
    } on RadioNotConnected {
      if (_settledMeanwhile(m.id)) return;
      _addedToRadio.remove(m.id);
      _backToWaiting(m, now + policy.notConnectedRecheckMs);
      return;
    } catch (err) {
      if (_settledMeanwhile(m.id)) return;
      _say('stopped: the contact could not be added to the radio (${err.runtimeType})', id: m.id);
      _fail(m, FailReason.unknownContact);
      return;
    }
    if (_settledMeanwhile(m.id)) return;
    _say('contact added to the radio; making try $attemptNo again', id: m.id);
    _backToWaiting(m, now);
  }

  Future<void> _processChannel(OutboxEntry e, ChatMessage m, int now) async {
    if (m.attempt >= e.maxAttempts) {
      _fail(m, FailReason.noAck);
      return;
    }
    if (!sink.canSend) {
      _setState(m, m.attempt > 0 ? MessageState.retrying : MessageState.queued);
      store.outbox.reschedule(m.id, now + policy.notConnectedRecheckMs);
      return;
    }
    final id = int.tryParse(ConvKey.body(m.convKey));
    final ch = id == null ? null : store.channels.getById(id);
    final slot = ch?.slot;
    if (slot == null) {
      _fail(m, FailReason.unknownChannel);
      return;
    }
    final attemptNo = m.attempt + 1;
    store.messages.update(m.id, state: MessageState.sending, attempt: attemptNo);
    notify(ChatEvent.updated(m.convKey, m.id));
    _lastSendMs = now;
    try {
      final usedTs = await sink.sendChannel(radioId: m.radioId, slot: slot, text: m.text, timestamp: m.tsSender);
      if (usedTs != m.tsSender) store.messages.retimestamp(m.id, usedTs, dedupeKeyFor(m.convKey, usedTs, m.text));
      // repeats_heard is the count of message_repeats rows (ChatService._applyCopy); a resend keeps the copies heard so far.
      store.messages.update(m.id, state: MessageState.sent, route: Route.flood);
      store.outbox.remove(m.id);
      store.outbox.addAttempt(DeliveryAttempt(messageId: m.id, attempt: attemptNo, sentAtMs: now, route: Route.flood));
    } on RadioNotConnected {
      if (_settledMeanwhile(m.id)) return;
      _backToWaiting(m, now + policy.notConnectedRecheckMs);
      return;
    } on RadioTargetMissing {
      if (_settledMeanwhile(m.id)) return;
      _fail(m, FailReason.unknownChannel);
      return;
    } on RadioRejected {
      if (_settledMeanwhile(m.id)) return;
      _fail(m, FailReason.radioRejected);
      return;
    } catch (_) {
      // Busy, no answer, or an unknown error: ask again a few times, then give up. A channel message has one try.
      if (_settledMeanwhile(m.id)) return;
      final n = e.busyRetries + 1;
      if (n > policy.maxBusyRetries) {
        _fail(m, FailReason.radioBusy);
      } else {
        _backToWaiting(m, now + policy.busyDelayMs(n), busyRetries: n);
      }
      return;
    }
    notify(ChatEvent.updated(m.convKey, m.id));
  }

  /// The try was not made: the message goes back to waiting with the try number it had.
  void _backToWaiting(ChatMessage m, int dueMs, {int? busyRetries}) {
    store.messages.update(m.id, state: m.attempt > 0 ? MessageState.retrying : MessageState.queued, attempt: m.attempt);
    store.outbox.reschedule(m.id, dueMs, busyRetries: busyRetries);
    notify(ChatEvent.updated(m.convKey, m.id));
  }

  /// The newest estimate the radio gave for a try of this send, or null.
  int? _lastEstimate(String messageId, int round) {
    for (final a in store.outbox.attemptsOfRound(messageId, round).reversed) {
      final e = a.estTimeoutMs;
      if (e != null && e > 0) return e;
    }
    return null;
  }

  /// What to write on a try whose message was settled while the try was being handed over.
  TryOutcome _settledOutcome(ChatMessage? now, int tryId) {
    if (now == null) return TryOutcome.cancelled;
    if (now.state == MessageState.acked) {
      // The confirmation that settled it may have been for this very try ([onAck] marked it) or an earlier one.
      final mine = store.outbox.attemptsFor(now.id).where((a) => a.id == tryId).firstOrNull;
      return mine?.outcome == TryOutcome.confirmed ? TryOutcome.confirmed : TryOutcome.noConfirmation;
    }
    return TryOutcome.cancelled;
  }

  /// SEND_CONFIRMED. Matches any try of any outgoing message that is not delivered yet, whatever its state now (waiting,
  /// between tries, queued again after a retry, cancelled, failed): a confirmation always wins (rule 8). [tripMs] is the
  /// radio's own round trip (PUSH_CODE_SEND_CONFIRMED bytes 5-8); without it the time since that try was handed over is
  /// used. Every confirmation is written to the message log with its code and whether it matched. Returns the message id,
  /// or null when the code matched nothing.
  String? onAck(String radioId, int ackCode, {int? tripMs}) {
    final a = store.outbox.findByAck(radioId, ackCode);
    final m = a == null ? null : store.messages.get(a.messageId);
    if (a == null || m == null) {
      final dup = store.outbox.findDeliveredByAck(radioId, ackCode);
      if (dup != null) {
        _say('confirmation ack=${MessageLog.code(ackCode)}: again for an already delivered message (try ${dup.attempt}); ignored', id: dup.messageId);
      } else {
        log?.addChat('confirmation ack=${MessageLog.code(ackCode)} NOT matched: no try of any message has this code');
      }
      return null;
    }
    final trip = tripMs != null && tripMs > 0 ? tripMs : max(0, nowMs() - a.sentAtMs);
    final was = m.state;
    final earlier = a.attempt < m.attempt || a.round < store.outbox.lastRound(m.id);
    store.db.transaction(() {
      store.outbox.closeOpenAttempts(m.id, TryOutcome.noConfirmation);
      store.outbox.updateAttempt(a.id, outcome: TryOutcome.confirmed, tripMs: trip);
      store.messages.update(
        m.id,
        state: MessageState.acked,
        ackMs: trip,
        expectedAck: ackCode, // the try that got through (the details sheet marks it)
        clearFailReason: true,
        route: a.routeKnown ? a.route : null,
      );
      store.outbox.remove(m.id);
    });
    // Rule 16: this contact has now confirmed a message from us (so they have us as a contact).
    final c = m.convKind == ConvKind.channel ? null : store.contacts.byPrefix(m.radioId, ConvKey.body(m.convKey));
    final first = c != null && store.contacts.markConfirmed(m.radioId, c.publicKey, nowMs());
    _addedToRadio.remove(m.id);
    _say(
        'confirmation ack=${MessageLog.code(ackCode)} matched try ${a.attempt}${earlier ? ' (an earlier try)' : ''}, trip ${trip}ms: Delivered'
        '${was == MessageState.failed ? ' (it had been marked not delivered)' : ''}',
        id: m.id);
    notify(ChatEvent.updated(m.convKey, m.id));
    if (first) notify(const ChatEvent.contacts());
    return m.id;
  }

  /// REMOVED in build 77 (decision D2): a reply from the contact no longer marks anything "Probably delivered". Kept as a
  /// no-op for callers written against build 76; always returns an empty list.
  List<String> onReply(String radioId, String convKey, int atMs) => const [];

  /// The person pressed retry on a failed message. Official behaviour: a NEW send. The message gets a new sender timestamp
  /// and its tries start again from try number 0 with today's [DeliverySettings]. (Build 76 restarted at try 0 with the OLD
  /// timestamp, so every retry was a packet the mesh had already seen and dropped.) The tries of the earlier send stay in
  /// the log, and a late confirmation for one of them still marks the message delivered. [hasPath] is ignored.
  bool retryFailed(String messageId, {bool hasPath = false, bool forceFlood = false}) {
    final m = store.messages.get(messageId);
    if (m == null || m.state != MessageState.failed) return false;
    final now = nowMs();
    store.db.transaction(() {
      if (m.convKind == ConvKind.channel) {
        store.messages.update(m.id, state: MessageState.queued, attempt: 0, clearFailReason: true);
        enqueue(m);
        return;
      }
      var ts = max(now ~/ 1000, m.tsSender + 1);
      var key = dedupeKeyFor(m.convKey, ts, m.text);
      while (store.messages.existsDedupe(m.radioId, key)) {
        ts++;
        key = dedupeKeyFor(m.convKey, ts, m.text);
      }
      store.messages.retimestamp(m.id, ts, key);
      store.messages.update(m.id, state: MessageState.queued, attempt: 0, clearFailReason: true);
      _say('retry by the person: a new send with a new timestamp (ts $ts)', id: m.id);
      enqueue(store.messages.get(m.id)!, forceFlood: forceFlood, round: store.outbox.lastRound(m.id) + 1);
    });
    _addedToRadio.remove(m.id);
    notify(ChatEvent.updated(m.convKey, m.id));
    return true;
  }

  /// Cancel: stops a message that is still queued, between tries, or waiting for a confirmation. No more tries are made.
  /// A confirmation that still arrives for a try already made marks it delivered all the same.
  bool cancel(String messageId) {
    final m = store.messages.get(messageId);
    if (m == null || !(m.isPending || (m.state == MessageState.sent && store.outbox.get(m.id) != null))) return false;
    store.outbox.closeOpenAttempts(m.id, TryOutcome.cancelled);
    if (m.convKind != ConvKind.channel) _say('cancelled by the person after ${m.attempt} ${m.attempt == 1 ? 'try' : 'tries'}', id: m.id);
    _fail(m, FailReason.cancelled);
    return true;
  }

  /// True when, during an await on the radio, the message stopped being "sending" (delivered, cancelled, deleted).
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
    _addedToRadio.remove(m.id);
    notify(ChatEvent.updated(m.convKey, m.id));
  }
}
