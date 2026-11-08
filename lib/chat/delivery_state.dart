// The five delivery states a person sees (chat plan 4.2): Queued, Sent, Heard, Delivered, Failed. Pure Dart.
//
// Honest by construction: a state says what the mesh actually proved. A channel message has no acknowledgement, so a channel
// never reaches Delivered (it caps at Heard). Every state has a glyph AND a word on the conversation screen.
import 'models.dart';

/// [likely]: no acknowledgement, but the contact replied after it went out (DM delivery fix, Nov 8 2026).
enum DeliveryStage { queued, sent, heard, delivered, likely, failed }

/// Which symbol draws the stage (the UI maps these to AppSymbols; kept here so the table is testable without Flutter).
enum DeliveryGlyph { clock, checkmark, antenna, checkmarkCircleFill, exclamationCircleFill }

class DeliveryUi {
  final DeliveryStage stage;
  final DeliveryGlyph glyph;

  /// The short word on the status line ("Waiting", "Sent", "Heard by 2 repeaters", "Delivered", "Not delivered").
  final String word;

  /// The sentence shown after a tap and read by VoiceOver.
  final String detail;

  /// Still moving (queued, sending, between retries): can be cancelled.
  final bool pending;

  /// A channel message no repeater relayed within [resendAfterMs]: the status offers Resend (CR2).
  final bool canResend;

  /// Queued, Failed and "No repeater heard it" are shown on any bubble; the others only on the last own message of a run.
  bool get alwaysVisible => stage == DeliveryStage.queued || stage == DeliveryStage.failed || canResend;

  const DeliveryUi(this.stage, this.glyph, this.word, this.detail, {this.pending = false, this.canResend = false});
}

String _repeaters(int n) => n == 1 ? '1 repeater' : '$n repeaters';

String _seconds(int ms) {
  if (ms < 950) return '$ms ms';
  final s = ms / 1000;
  return s < 10 ? '${s.toStringAsFixed(1)} s' : '${s.round()} s';
}

/// After this long in Sent the caption admits the mesh is slow.
const int slowAfterMs = 20000;

/// A sent channel message that no repeater relayed after this long offers Resend (CR2; repeats normally come back within a
/// few seconds).
const int resendAfterMs = 30000;

/// The next time (unix ms) [m]'s status words change by the clock alone (Waiting for confirmation > with the try count; channel Sent > No repeater
/// heard it), or null when nothing more will change without an event. The conversation screen wakes once at that time.
int? nextDeliveryChangeMs(ChatMessage m) {
  if (!m.isOutgoing) return null;
  if (m.convKind == ConvKind.channel) {
    return m.state == MessageState.sent && m.repeatsHeard == 0 ? m.tsLocalMs + resendAfterMs : null;
  }
  if (m.state == MessageState.sent || m.state == MessageState.retrying) return m.tsLocalMs + slowAfterMs;
  return null;
}

/// [maxAttempts] is how many tries the outbox makes for this message (3 flood, 5 with a saved route); [nowMs] the clock.
/// [viaText] is the optional "via 2 repeaters" tail for Delivered.
DeliveryUi deliveryUi(ChatMessage m, {required bool radioConnected, int? maxAttempts, required int nowMs, String? viaText}) {
  final channel = m.convKind == ConvKind.channel;
  switch (m.state) {
    case MessageState.queued:
      return DeliveryUi(
        DeliveryStage.queued,
        DeliveryGlyph.clock,
        'Waiting',
        radioConnected ? 'Waiting for the radio' : 'Will send when your radio connects',
        pending: true,
      );
    case MessageState.sending:
      return DeliveryUi(
        DeliveryStage.queued,
        DeliveryGlyph.clock,
        'Sending',
        radioConnected ? 'Handing it to the radio' : 'Will send when your radio connects',
        pending: true,
      );
    case MessageState.sent:
    case MessageState.retrying:
      return _sent(m, channel: channel, maxAttempts: maxAttempts, nowMs: nowMs);
    case MessageState.heard:
      if (!channel) return _sent(m, channel: false, maxAttempts: maxAttempts, nowMs: nowMs);
      return _heard(m);
    case MessageState.acked:
      if (channel) {
        // Cannot happen (no channel ack exists); never claim Delivered for a channel.
        return m.repeatsHeard > 0 ? _heard(m) : _sent(m, channel: true, maxAttempts: maxAttempts, nowMs: nowMs);
      }
      final took = m.ackMs == null ? '' : ' · ${_seconds(m.ackMs!)}';
      return DeliveryUi(DeliveryStage.delivered, DeliveryGlyph.checkmarkCircleFill, 'Delivered', 'Delivered${viaText == null ? '' : ' · $viaText'}$took');
    case MessageState.likelyDelivered:
      if (channel) return m.repeatsHeard > 0 ? _heard(m) : _sent(m, channel: true, maxAttempts: maxAttempts, nowMs: nowMs);
      return const DeliveryUi(
        DeliveryStage.likely,
        DeliveryGlyph.checkmark,
        'Probably delivered (they replied)',
        'No delivery confirmation came back, but they replied after you sent it, so they most likely have it. '
            'Confirmations travel back over the mesh and can be lost on the way.',
      );
    case MessageState.failed:
      return DeliveryUi(
        DeliveryStage.failed,
        DeliveryGlyph.exclamationCircleFill,
        'Not delivered',
        channel ? 'No repeater heard it. Tap to try again.' : (m.failReason?.describe() ?? 'It could not be sent.'),
      );
    case MessageState.received:
      return const DeliveryUi(DeliveryStage.sent, DeliveryGlyph.checkmark, '', '');
  }
}

DeliveryUi _heard(ChatMessage m) {
  final n = m.repeatsHeard < 1 ? 1 : m.repeatsHeard;
  return DeliveryUi(
    DeliveryStage.heard,
    DeliveryGlyph.antenna,
    'Heard by ${_repeaters(n)}',
    'Sent. Heard by ${_repeaters(n)}. Channels have no delivery receipts.',
  );
}

DeliveryUi _sent(ChatMessage m, {required bool channel, int? maxAttempts, required int nowMs}) {
  if (channel) {
    if (m.state == MessageState.sent && m.repeatsHeard == 0 && nowMs - m.tsLocalMs >= resendAfterMs) {
      return const DeliveryUi(
        DeliveryStage.sent,
        DeliveryGlyph.exclamationCircleFill,
        'No repeater heard it',
        'No repeater relayed it within 30 seconds. Resend sends it again.',
        canResend: true,
      );
    }
    return const DeliveryUi(DeliveryStage.sent, DeliveryGlyph.checkmark, 'Sent', 'Sent over the air. Channels have no delivery receipts.');
  }
  final tries = m.attempt < 1 ? 1 : m.attempt;
  final of = maxAttempts == null ? '' : ' of $maxAttempts';
  final lastTry = maxAttempts != null && tries > 1 && tries >= maxAttempts;
  final slow = tries > 1 || nowMs - m.tsLocalMs > slowAfterMs;
  if (lastTry) {
    return DeliveryUi(
      DeliveryStage.sent,
      DeliveryGlyph.checkmark,
      'Waiting for confirmation (last try, wider search)',
      'Sent. Waiting for their radio to confirm (try $tries$of, searching wider).',
      pending: true,
    );
  }
  if (slow) {
    return DeliveryUi(
      DeliveryStage.sent,
      DeliveryGlyph.checkmark,
      'Waiting for confirmation (try $tries$of)',
      'Sent. Waiting for their radio to confirm (try $tries$of). The mesh is slow; confirmations can take a minute.',
      pending: true,
    );
  }
  return const DeliveryUi(DeliveryStage.sent, DeliveryGlyph.checkmark, 'Waiting for confirmation', 'Sent. Waiting for their radio to confirm.', pending: true);
}
