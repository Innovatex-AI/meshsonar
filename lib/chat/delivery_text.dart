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
    return 'No acknowledgement after ${_tries(n)}, each flooded through the mesh. They may be out of range or switched off, '
        'or there may be no repeater between you. Try again later, or check the contact is still on air.';
  }
  return 'No acknowledgement after ${_tries(n)}: $direct along the saved route and the rest flooded. '
      'The repeater path to them may have changed. The saved route was cleared, so the next message floods and finds a new one.';
}

/// "Direct, 2 hops via a1b2 then c3d4" / "Flooded" / "Neighbour (direct, no repeater)".
String describeRoute(Contact c) {
  if (!c.hasPath) return 'No saved route: the first message floods, and the radio learns the route from the reply';
  final hops = c.pathHops ?? 0;
  if (hops == 0) return 'Direct neighbour, no repeater in between';
  final ids = c.routeIds;
  final via = ids.isEmpty ? '' : ' via ${ids.join(' then ')}';
  return 'Direct, $hops ${hops == 1 ? 'hop' : 'hops'}$via';
}
