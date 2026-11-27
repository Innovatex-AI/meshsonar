// Plain-language delivery text for a direct message: the one-line status under a bubble, and the full explanation in the
// message details. Pure Dart so the conversation screen and the details sheet share one wording.
//
// Build 77: whether a try went direct or by flood is what the RADIO reported for that try (rule 11), never a guess from
// the phone's copy of the route; "Probably delivered" and the "saved route was cleared" wording are gone with the
// features they described.
import '../core/time_format.dart' as tf;
import 'db/outbox_repository.dart';
import 'models.dart';

/// "3 tries" / "1 try".
String _tries(int n) => '$n ${n == 1 ? 'try' : 'tries'}';

String _seconds(int ms) {
  if (ms < 950) return '$ms ms';
  final s = ms / 1000;
  return s < 10 ? '${s.toStringAsFixed(1)} s' : '${s.round()} s';
}

/// The short line under an outgoing DM. [maxAttempts] is how many tries the message gets (the "m" of "try n of m").
String deliveryLabel(ChatMessage m, {int? maxAttempts}) {
  final of = maxAttempts == null ? '' : ' of $maxAttempts';
  switch (m.state) {
    case MessageState.queued:
      return 'Waiting to send';
    case MessageState.sending:
      return m.attempt > 1 ? 'Sending (try ${m.attempt}$of)' : 'Sending';
    case MessageState.sent:
      return m.attempt > 1 ? 'Waiting for confirmation (try ${m.attempt}$of)' : 'Waiting for confirmation';
    case MessageState.retrying:
      return 'Trying again (try ${m.attempt + 1}$of)';
    case MessageState.acked:
      final t = m.ackMs == null ? '' : ' in ${_seconds(m.ackMs!)}';
      return 'Delivered$t';
    case MessageState.heard:
      return m.repeatsHeard == 1 ? 'Heard once' : 'Heard ${m.repeatsHeard} times';
    case MessageState.likelyDelivered: // removed in build 77; an old row reads as what was proved
    case MessageState.failed:
      return 'Not delivered';
    case MessageState.received:
      return '';
  }
}

/// Why a DM was given up, with what was tried. [attempts] is the log from [OutboxRepository.attemptsFor] (all sends of the
/// message; the newest send is described).
String describeFailure(ChatMessage m, List<DeliveryAttempt> attempts) {
  final r = m.failReason;
  if (r == null) return 'Not delivered.';
  if (r != FailReason.noAck) return r.describe();
  final round = attempts.isEmpty ? 0 : attempts.last.round;
  final mine = [for (final a in attempts) if (a.round == round) a];
  final n = mine.isEmpty ? m.attempt : mine.length;
  final direct = mine.where((a) => a.routeKnown && a.route == Route.direct).length;
  final flood = mine.where((a) => a.routeKnown && a.route == Route.flood).length;
  final String how;
  if (direct > 0 && flood > 0) {
    how = '$direct direct along the route your radio had, then $flood by flood to everyone nearby';
  } else if (direct > 0) {
    how = 'all direct along the route your radio had';
  } else if (flood > 0) {
    how = 'all by flood to everyone nearby (your radio has no route to them)';
  } else {
    how = 'your radio did not say how they went';
  }
  return 'No confirmation came back after ${_tries(n)}: $how. They may be out of range or switched off, or they may not have you as a '
      'contact. Try again sends it as a new message.';
}

/// "Via 2 repeaters via a1b2 then c3d4" / "No route yet ..." / "Direct neighbour ...". The route shown is the phone's
/// mirror of what the radio holds.
String describeRoute(Contact c) {
  if (!c.hasPath) return 'No saved route: the first message searches, and the radio learns the route from the reply';
  final hops = c.pathHops ?? 0;
  if (hops == 0) return 'Direct neighbour, no repeater in between';
  final ids = c.routeIds;
  final via = ids.isEmpty ? '' : ' via ${ids.join(' then ')}';
  return 'Via $hops ${hops == 1 ? 'repeater' : 'repeaters'}$via';
}

/// The time of a try, through the one app time formatter: the phone's own time by default, UTC (and labelled) when
/// Settings > Time zone says so; 12 or 24 hour as the phone is set. (Build 76 hard-coded 24-hour local time here.)
String _clock(int ms) => tf.timeOfDay(DateTime.fromMillisecondsSinceEpoch(ms), seconds: true);

/// How a try went out, in the radio's own words: "direct" / "flood", or "route not reported" when its reply was lost.
String describeTryRoute(DeliveryAttempt a) => !a.routeKnown ? 'route not reported' : (a.route == Route.flood ? 'flood' : 'direct');

/// What became of a try, in plain words. [m] is its message and [last] marks the newest try (for rows from before build 77,
/// which have no stored outcome).
String describeTryOutcome(DeliveryAttempt a, ChatMessage m, {required bool last}) {
  switch (a.outcome) {
    case TryOutcome.sending:
      return 'handing it to the radio';
    case TryOutcome.waiting:
      return 'waiting for confirmation';
    case TryOutcome.confirmed:
      final t = a.tripMs ?? m.ackMs;
      return t == null ? 'confirmed' : 'confirmed after ${_seconds(t)}';
    case TryOutcome.noConfirmation:
      return 'no confirmation';
    case TryOutcome.radioNoAnswer:
      return 'the radio did not answer; it may have gone out';
    case TryOutcome.cancelled:
      return 'cancelled';
    case TryOutcome.interrupted:
      return 'interrupted (the app stopped)';
    case null:
      // A try stored before build 77.
      if (m.state == MessageState.acked && a.expectedAck != null && a.expectedAck == m.expectedAck) {
        return m.ackMs == null ? 'confirmed' : 'confirmed after ${_seconds(m.ackMs!)}';
      }
      if (last && (m.state == MessageState.sent || m.state == MessageState.retrying || m.state == MessageState.sending)) return 'waiting for confirmation';
      return 'no confirmation';
  }
}

/// One line of the tries list in the message details: "Try 2 · direct · 09:41:19 · confirmed after 1.8 s". [n] is the
/// number to show when the row has none of its own (rows before build 77); [formatTime] overrides how the time is
/// written (the default is lib/core/time_format.dart `timeOfDay` with seconds). [acked] is true for the try the
/// confirmation was for.
({String text, bool acked}) describeAttempt(DeliveryAttempt a, int n, ChatMessage m, {required bool last, String Function(int ms)? formatTime}) {
  final outcome = describeTryOutcome(a, m, last: last);
  final acked = a.outcome == TryOutcome.confirmed || (a.outcome == null && outcome.startsWith('confirmed'));
  final num = a.outcome == null ? n : a.attempt;
  final reset = a.resetBefore ? ' · after reset path' : '';
  return (text: 'Try $num · ${describeTryRoute(a)}$reset · ${(formatTime ?? _clock)(a.sentAtMs)} · $outcome', acked: acked);
}
