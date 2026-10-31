// The seam between chat and the radio layer. Chat codes against these interfaces only; lib/radio's RadioSession adapts to
// them (a small adapter: map ChannelMsgFrame / ContactTextFrame / SendConfirmed push / advert push to the events below, and
// sendDirect / sendChannel to the companion commands). No radio type is imported here.
import 'dart:typed_data';

import 'models.dart';

sealed class InboundEvent {
  /// The radio's own public key, 64 hex (identifies which radio heard it).
  final String radioId;
  const InboundEvent(this.radioId);
}

/// A channel message synced from the radio (RESP_CHANNEL_MSG_RECV). [text] is the raw "sender: body" text.
class InboundChannelText extends InboundEvent {
  final int channelSlot;
  final int timestamp; // sender clock, unix seconds
  final String text;
  final double? snr;

  /// Hops; null when it arrived direct / unknown (0xFF on the wire).
  final int? pathLen;
  final int txtType;
  const InboundChannelText({required String radioId, required this.channelSlot, required this.timestamp, required this.text, this.snr, this.pathLen, this.txtType = 0}) : super(radioId);
}

/// A direct or room message (RESP_CONTACT_MSG_RECV). [senderPrefix] is 12 hex characters.
/// txtType 0 plain, 1 CLI data (repeater replies: consumed by the claim/admin flows, ignored by chat), 2 signed room post.
class InboundDirectText extends InboundEvent {
  final String senderPrefix;
  final int timestamp;
  final String text;
  final double? snr;
  final int? pathLen;
  final int txtType;

  /// 8 hex characters of the author for a signed room post.
  final String? signerPrefix;
  const InboundDirectText(
      {required String radioId, required this.senderPrefix, required this.timestamp, required this.text, this.snr, this.pathLen, this.txtType = 0, this.signerPrefix})
      : super(radioId);
}

/// PUSH_CODE_SEND_CONFIRMED: the ack for an earlier DM. [ackCode] is the 4-byte code from the SENT reply.
class InboundAck extends InboundEvent {
  final int ackCode;
  const InboundAck({required String radioId, required this.ackCode}) : super(radioId);
}

/// The radio heard a repeater rebroadcast one of our channel messages (echo recognised by the radio layer).
class InboundRepeatHeard extends InboundEvent {
  final int channelSlot;
  final int timestamp;
  final String text;
  const InboundRepeatHeard({required String radioId, required this.channelSlot, required this.timestamp, required this.text}) : super(radioId);
}

/// A node advertised (PUSH_CODE_ADVERT / NEW_ADVERT), already decoded.
class InboundAdvert extends InboundEvent {
  final String publicKey;
  final ContactType? type;
  final String name;
  final double? lat;
  final double? lon;
  final int? advertTimestamp;
  final int? pathLen;
  final double? snr;

  /// True when the radio has stored it as a contact (PUSH_CODE_ADVERT) rather than only heard it (NEW_ADVERT).
  final bool isContact;
  const InboundAdvert(
      {required String radioId, required this.publicKey, this.type, required this.name, this.lat, this.lon, this.advertTimestamp, this.pathLen, this.snr, this.isContact = false})
      : super(radioId);
}

/// PUSH_CODE_PATH_UPDATED: a route to a contact was learned.
class InboundPathUpdate extends InboundEvent {
  final String publicKey;
  final Uint8List? path;
  final int pathLen;
  const InboundPathUpdate({required String radioId, required this.publicKey, this.path, required this.pathLen}) : super(radioId);
}

abstract interface class InboundMessageSource {
  /// Broadcast stream. May replay frames (a reconnect re-syncs): consumers must be idempotent, and ChatService is.
  Stream<InboundEvent> get events;
}

/// What the radio said about an accepted send (RESP_CODE_SENT).
class SendReceipt {
  final bool flood;
  final int expectedAck;
  final int estTimeoutMs;
  const SendReceipt({required this.flood, required this.expectedAck, required this.estTimeoutMs});
}

sealed class OutboundFailure implements Exception {
  final String message;
  const OutboundFailure(this.message);
  @override
  String toString() => '$runtimeType: $message';
}

/// No radio link right now. Not the message's fault: it stays queued.
class RadioNotConnected extends OutboundFailure {
  const RadioNotConnected([super.message = 'radio not connected']);
}

/// The radio's queue is full or it answered NOT_FOUND on a known-good target. Worth retrying shortly.
class RadioBusy extends OutboundFailure {
  const RadioBusy([super.message = 'radio busy']);
}

/// The radio refused for a reason that will not change (bad arguments, too long).
class RadioRejected extends OutboundFailure {
  const RadioRejected([super.message = 'radio rejected the message']);
}

/// The radio does not have this channel slot / contact (any more). Will not fix itself: the message fails.
class RadioTargetMissing extends OutboundFailure {
  const RadioTargetMissing([super.message = 'target not on the radio']);
}

/// A batch of contacts read from the radio (GET_CONTACTS), mapped to chat [Contact]s. The phone is the master copy: chat
/// merges the radio's fields in and keeps its own favourite / blocked / custom name / notes.
class InboundContactSnapshot extends InboundEvent {
  final List<Contact> contacts;
  const InboundContactSnapshot({required String radioId, required this.contacts}) : super(radioId);
}

abstract interface class OutboundMessageSink {
  /// True when a send would be attempted now (linked and past setup).
  bool get canSend;

  /// CMD_SEND_TXT_MSG. [forceFlood] must make the radio flood even if it holds a path. [attempt] is 0-based (only the low 2
  /// bits go on air). Throws an [OutboundFailure].
  Future<SendReceipt> sendDirect(
      {required String radioId, required String contactPublicKey, required String text, required int timestamp, required int attempt, required bool forceFlood});

  /// CMD_SEND_CHANNEL_TXT_MSG. Channel messages have no ack: success is just "accepted". [text] is the body; the firmware
  /// prepends "name: ". Returns the timestamp that went into the packet (a session may stamp its own; chat adopts it so
  /// echo recognition and receivers' dedupe agree). Throws an [OutboundFailure].
  Future<int> sendChannel({required String radioId, required int slot, required String text, required int timestamp});
}
