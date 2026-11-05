// The five delivery states a person sees (chat plan 4.2): Queued, Sent, Heard, Delivered, Failed. Pure Dart.
//
// Honest by construction: a state says what the mesh actually proved. A channel message has no acknowledgement, so a channel
// never reaches Delivered (it caps at Heard). Every state has a glyph AND a word on the conversation screen.
import 'models.dart';

enum DeliveryStage { queued, sent, heard, delivered, failed }

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

  /// Queued and Failed are shown on any bubble; the others only on the last own message of a run.
  bool get alwaysVisible => stage == DeliveryStage.queued || stage == DeliveryStage.failed;

  const DeliveryUi(this.stage, this.glyph, this.word, this.detail, {this.pending = false});
}

String _repeaters(int n) => n == 1 ? '1 repeater' : '$n repeaters';

String _seconds(int ms) {
  if (ms < 950) return '$ms ms';
  final s = ms / 1000;
  return s < 10 ? '${s.toStringAsFixed(1)} s' : '${s.round()} s';
}

/// After this long in Sent the caption admits the mesh is slow.
const int slowAfterMs = 20000;

/// [maxAttempts] is how many tries the outbox makes for this message (3 flood, 5 with a saved route); [nowMs] the clock.
/// [viaText] is the optional "via 2 repeaters" tail for Delivered.
DeliveryUi deliveryUi(
  ChatMessage m, {
  required bool radioConnected,
  int? maxAttempts,
  required int nowMs,
  String? viaText,
}) {
  final channel = m.convKind == ConvKind.channel;
  switch (m.state) {
    case MessageState.queued:
    case MessageState.sending:
      return DeliveryUi(DeliveryStage.queued, DeliveryGlyph.clock, 'Waiting',
          radioConnected ? 'Waiting for the radio' : 'Will send when your radio connects',
          pending: true);
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
    case MessageState.failed:
      return DeliveryUi(DeliveryStage.failed, DeliveryGlyph.exclamationCircleFill, 'Not delivered',
          channel ? 'No repeater heard it. Tap to try again.' : (m.failReason?.describe() ?? 'It could not be sent.'));
    case MessageState.received:
      return const DeliveryUi(DeliveryStage.sent, DeliveryGlyph.checkmark, '', '');
  }
}

DeliveryUi _heard(ChatMessage m) {
  final n = m.repeatsHeard < 1 ? 1 : m.repeatsHeard;
  return DeliveryUi(DeliveryStage.heard, DeliveryGlyph.antenna, 'Heard by ${_repeaters(n)}', 'Sent. Heard by ${_repeaters(n)}. Channels have no delivery receipts.');
}

DeliveryUi _sent(ChatMessage m, {required bool channel, int? maxAttempts, required int nowMs}) {
  if (channel) {
    return const DeliveryUi(DeliveryStage.sent, DeliveryGlyph.checkmark, 'Sent', 'Sent over the air. Channels have no delivery receipts.');
  }
  final tries = m.attempt < 1 ? 1 : m.attempt;
  final of = maxAttempts == null ? '' : ' of $maxAttempts';
  final lastTry = maxAttempts != null && tries > 1 && tries >= maxAttempts;
  final slow = tries > 1 || nowMs - m.tsLocalMs > slowAfterMs;
  if (lastTry) {
    return DeliveryUi(DeliveryStage.sent, DeliveryGlyph.checkmark, 'Trying a wider search', 'Trying a wider search (try $tries$of).', pending: true);
  }
  if (slow) {
    return DeliveryUi(DeliveryStage.sent, DeliveryGlyph.checkmark, 'Mesh is slow, still trying (try $tries$of)',
        'Mesh is slow, still trying (try $tries$of).',
        pending: true);
  }
  return const DeliveryUi(DeliveryStage.sent, DeliveryGlyph.checkmark, 'Sent', 'Sent over the air');
}
