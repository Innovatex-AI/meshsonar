// Plain-language delivery text for a direct message: the one-line status under a bubble, and the full explanation in the
// message details. Pure Dart so the conversation screen (agent 2A) and the details sheet share one wording.
import 'db/outbox_repository.dart';
import 'models.dart';

/// "3 tries" / "1 try".
String _tries(int n) => '$n ${n == 1 ? 'try' : 'tries'}';

String _seconds(int ms) {
  if (ms < 950) return '$ms ms';
  final s = ms / 1000;
  return s < 10 ? '${s.toStringAsFixed(1)} s' : '${s.round()} s';
}

/// The short line under an outgoing DM. [maxAttempts] is how many tries the outbox will make (3 flood, 5 with a saved route).
String deliveryLabel(ChatMessage m, {int? maxAttempts}) {
  switch (m.state) {
    case MessageState.queued:
      return 'Waiting to send';
    case MessageState.sending:
      return m.attempt > 1 ? 'Sending, try ${m.attempt}' : 'Sending';
    case MessageState.sent:
      final of = maxAttempts == null ? '' : ' of $maxAttempts';
      return m.attempt > 1 ? 'Sent, waiting for the reply (try ${m.attempt}$of)' : 'Sent, waiting for the reply';
    case MessageState.retrying:
      return 'Trying again';
    case MessageState.acked:
      final t = m.ackMs == null ? '' : ' in ${_seconds(m.ackMs!)}';
      return 'Delivered$t';
    case MessageState.heard:
      return m.repeatsHeard == 1 ? 'Heard once' : 'Heard ${m.repeatsHeard} times';
    case MessageState.failed:
      return 'Not delivered';
    case MessageState.received:
      return '';
  }
}

/// Why a DM was given up, with what was tried. [attempts] is the log from [OutboxRepository.attemptsFor].
String describeFailure(ChatMessage m, List<DeliveryAttempt> attempts) {
  final r = m.failReason;
  if (r == null) return 'Not delivered.';
  if (r != FailReason.noAck) return r.describe();
  final n = attempts.isEmpty ? m.attempt : attempts.length;
  final direct = attempts.where((a) => a.route == Route.direct).length;
  if (direct == 0) {
    return 'No acknowledgement after ${_tries(n)}, each sent to everyone nearby. They may be out of range or switched off, '
        'or there may be no repeater between you. Try again later, or check the contact is still on air.';
  }
  return 'No acknowledgement after ${_tries(n)}: $direct along the saved route and the rest to everyone nearby. '
      'The route to them may have changed. The saved route was cleared, so the next message searches for a new one.';
}

/// "Direct, 2 hops via a1b2 then c3d4" / "Flooded" / "Neighbour (direct, no repeater)".
String describeRoute(Contact c) {
  if (!c.hasPath) return 'No saved route: the first message searches, and the radio learns the route from the reply';
  final hops = c.pathHops ?? 0;
  if (hops == 0) return 'Direct neighbour, no repeater in between';
  final ids = c.routeIds;
  final via = ids.isEmpty ? '' : ' via ${ids.join(' then ')}';
  return 'Via $hops ${hops == 1 ? 'repeater' : 'repeaters'}$via';
}

String _clock(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

/// One line of the attempts list in the message details (outbox attempt text): "Try 2 · saved route · 09:41:19 · acknowledged
/// after 1.8 s". [last] marks the newest try: while the message is still moving it reads "waiting for the reply".
({String text, bool acked}) describeAttempt(DeliveryAttempt a, int n, ChatMessage m, {required bool last}) {
  final acked = m.state == MessageState.acked && a.expectedAck != null && a.expectedAck == m.expectedAck;
  final route = a.route == Route.flood ? 'searched' : 'saved route';
  final String outcome;
  if (acked) {
    outcome = m.ackMs == null ? 'acknowledged' : 'acknowledged after ${_seconds(m.ackMs!)}';
  } else if (last && (m.state == MessageState.sent || m.state == MessageState.retrying || m.state == MessageState.sending)) {
    outcome = 'waiting for the reply';
  } else {
    outcome = 'no reply';
  }
  return (text: 'Try $n · $route · ${_clock(a.sentAtMs)} · $outcome', acked: acked);
}
