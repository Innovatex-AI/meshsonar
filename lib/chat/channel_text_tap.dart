// ChannelTextTap: a hook that sees every inbound channel text BEFORE chat stores it, and may take it out of chat.
// MeshTrack (meshsonar-infra docs/planning/meshtrack-plan-2026-11-16.md section 6 "Not stored as chat") registers one so
// its position / request / meet-up / stop messages never become bubbles, notifications, unread counts, backup rows or
// search hits. The tap is generic: it knows nothing about MeshTrack's wire format. Pure Dart.
import 'models.dart';

/// What a tap answers for one channel text.
enum TapVerdict {
  /// Normal chat: the message is stored and announced as today (the next tap is asked first).
  pass,

  /// Taken out of chat: not stored, not notified, no unread change, not in backup/export or search. Later taps are not asked.
  consume,
}

/// One inbound channel text as a tap sees it. [body] is the text after the "name: " prefix (the whole text when there is
/// no prefix, then [senderName] is null), clamped to chat's inbound limit.
class ChannelTextEvent {
  final String radioId;

  /// The phone's channel row id (Channel.id) and the radio slot it arrived on.
  final int channelId;
  final int channelSlot;
  final ChannelKind channelKind;
  final String convKey;
  final String? senderName;
  final String body;

  /// Sender clock, unix seconds (not trustworthy: the sender's clock may be wrong).
  final int senderTs;
  final double? snr;

  /// Hops; null when it arrived direct or unknown.
  final int? pathLen;
  final int? rssi;

  /// When this phone took it off the radio, epoch ms.
  final int receivedMs;

  /// True when the message most likely waited in the radio's offline queue (a backlog synced on connect): the sender's
  /// clock is more than [ChannelTextEvent.backlogAfterSec] behind the receive time. The radio frame carries no explicit
  /// flag, so this is the best signal there is; the consumer still checks the sender time is plausible.
  final bool backlog;

  static const int backlogAfterSec = 60;

  const ChannelTextEvent({
    required this.radioId,
    required this.channelId,
    required this.channelSlot,
    required this.channelKind,
    required this.convKey,
    required this.senderName,
    required this.body,
    required this.senderTs,
    required this.snr,
    required this.pathLen,
    required this.rssi,
    required this.receivedMs,
    required this.backlog,
  });

  /// [backlog] as computed from the two clocks.
  static bool looksBacklogged(int senderTs, int receivedMs) => senderTs > 0 && receivedMs ~/ 1000 - senderTs > backlogAfterSec;
}

/// A registered inbound hook (ChatService.addChannelTextTap). A tap that throws is treated as [TapVerdict.pass].
abstract interface class ChannelTextTap {
  TapVerdict onChannelText(ChannelTextEvent e);

  /// A tap from a plain function.
  factory ChannelTextTap.of(TapVerdict Function(ChannelTextEvent e) fn) = _FnTap;
}

class _FnTap implements ChannelTextTap {
  final TapVerdict Function(ChannelTextEvent e) fn;
  _FnTap(this.fn);
  @override
  TapVerdict onChannelText(ChannelTextEvent e) => fn(e);
}

/// Why a silent (no chat bubble) channel send did not go.
enum SilentSendStatus {
  /// Accepted by the radio.
  sent,

  /// Refused by the transmit arbiter (budget, region cap or gap): NOT queued; ask again at the next fix.
  skipped,

  /// Could not be sent (no radio, unknown channel, too long, radio error).
  failed,
}

/// The answer of ChatService.sendChannelTextSilently.
class SilentSendResult {
  final SilentSendStatus status;

  /// The timestamp that went into the packet ([SilentSendStatus.sent] only).
  final int? timestamp;

  /// Body bytes sent or asked for.
  final int bytes;

  /// [SilentSendStatus.skipped]: the arbiter's reason name ('budget', 'regionCap', 'gap') and whether it is an airtime
  /// limit ("Sharing slower: airtime limit").
  final String? skipReason;
  final bool airtimeLimited;

  /// One plain line (no message text in it), for diagnostics.
  final String detail;

  const SilentSendResult.sent(int this.timestamp, this.bytes)
      : status = SilentSendStatus.sent,
        skipReason = null,
        airtimeLimited = false,
        detail = 'sent';
  const SilentSendResult.skipped(String this.skipReason, this.detail, this.bytes, {this.airtimeLimited = false})
      : status = SilentSendStatus.skipped,
        timestamp = null;
  const SilentSendResult.failed(this.detail, this.bytes)
      : status = SilentSendStatus.failed,
        timestamp = null,
        skipReason = null,
        airtimeLimited = false;

  bool get sent => status == SilentSendStatus.sent;

  @override
  String toString() => 'SilentSendResult(${status.name}${skipReason == null ? '' : ': $skipReason'}, $bytes bytes)';
}
