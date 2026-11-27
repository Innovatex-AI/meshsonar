// The seam between chat and the radio layer. Chat codes against these interfaces only; lib/radio's RadioSession adapts to
// them (a small adapter: map ChannelMsgFrame / ContactTextFrame / SendConfirmed push / advert push to the events below, and
// sendDirect / sendChannel to the companion commands). No radio type is imported here.
import 'dart:typed_data';

import '../radio/command_queue.dart' show CommandPriority;
export '../radio/command_queue.dart' show CommandPriority;

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
  /// Radio facts (migration v3) when the receive path could correlate them: RSSI dBm, hop hashes as hex (hashSize bytes per
  /// hop), hash size in bytes, airtime ms. Null otherwise; the UI then shows what it has.
  final int? rssi;
  final String? pathHashes;
  final int? hashSize;
  final int? airMs;
  const InboundChannelText(
      {required String radioId, required this.channelSlot, required this.timestamp, required this.text, this.snr, this.pathLen, this.txtType = 0, this.rssi, this.pathHashes, this.hashSize, this.airMs})
      : super(radioId);
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
  /// Radio facts (migration v3) when the receive path could correlate them: RSSI dBm, hop hashes as hex (hashSize bytes per
  /// hop), hash size in bytes, airtime ms. Null otherwise; the UI then shows what it has.
  final int? rssi;
  final String? pathHashes;
  final int? hashSize;
  final int? airMs;
  const InboundDirectText(
      {required String radioId,
      required this.senderPrefix,
      required this.timestamp,
      required this.text,
      this.snr,
      this.pathLen,
      this.txtType = 0,
      this.signerPrefix,
      this.rssi,
      this.pathHashes,
      this.hashSize,
      this.airMs})
      : super(radioId);
}

/// PUSH_CODE_SEND_CONFIRMED: the ack for an earlier DM. [ackCode] is the 4-byte code from the SENT reply; [tripMs] the radio's
/// own round trip for that try (null when unknown).
class InboundAck extends InboundEvent {
  final int ackCode;
  final int? tripMs;
  const InboundAck({required String radioId, required this.ackCode, this.tripMs}) : super(radioId);
}

/// The radio heard a copy of a channel message on the air (a group text on one of our channels, decrypted from the radio's
/// rx log). For a message we sent it is a repeat; for one we received, one of the paths it came by. [text] is the on-air
/// text (`<sender name>: <body>`). [pathHashes] is hex, [hashSize] bytes per hop, first hop first; empty = heard direct
/// from the sender (our own transmission, for a message we sent: not a repeat).
class InboundRepeatHeard extends InboundEvent {
  final int channelSlot;
  final int timestamp;
  final String text;
  final String pathHashes;
  final int hashSize;
  final int hops;
  final double? snr;
  final int? rssi;

  /// When the radio heard it, unix ms (0 = now).
  final int heardMs;
  const InboundRepeatHeard(
      {required String radioId,
      required this.channelSlot,
      required this.timestamp,
      required this.text,
      this.pathHashes = '',
      this.hashSize = 1,
      this.hops = 0,
      this.snr,
      this.rssi,
      this.heardMs = 0})
      : super(radioId);
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

/// What the radio said about an accepted send (RESP_CODE_SENT): whether it went by flood or direct (the radio alone
/// decides that), the confirmation code it expects back, and its estimate of the round trip.
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

/// The radio answered "busy" (ERR TABLE_FULL: no free packet). The packet did NOT go out. Worth retrying shortly.
class RadioBusy extends OutboundFailure {
  const RadioBusy([super.message = 'radio busy']);
}

/// The radio did not answer the send command in time (its reply was lost or late). The packet MAY have gone out: the try
/// counts as made, and its confirmation is still matched (the phone computes the confirmation code itself).
class RadioNoAnswer extends OutboundFailure {
  const RadioNoAnswer([super.message = 'no answer from the radio']);
}

/// The radio refused for a reason that will not change (bad arguments, too long).
class RadioRejected extends OutboundFailure {
  const RadioRejected([super.message = 'radio rejected the message']);
}

/// The radio does not have this channel slot / contact (any more). Will not fix itself: the message fails.
class RadioTargetMissing extends OutboundFailure {
  const RadioTargetMissing([super.message = 'target not on the radio']);
}

/// The radio's contact table is full, so it cannot take the recipient (decision D1: nothing is taken off the radio to
/// make room; the person is told the list is full).
class RadioContactsFull extends OutboundFailure {
  const RadioContactsFull([super.message = 'the radio\'s contact list is full']);
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

  /// CMD_SEND_TXT_MSG, and nothing else: no contact write, no reset path, no sync afterwards. [attempt] is the try number
  /// 0..7 and reaches the radio untouched; [timestamp] is the same on every try of a message. Throws an [OutboundFailure]:
  /// [RadioTargetMissing] = the radio says "not a contact", [RadioBusy] = no free packet, [RadioNoAnswer] = the reply was
  /// lost, [RadioRejected] = too long or refused.
  ///
  /// The app never decides direct or flood (build 77); a flood chosen by the person is one [DeliveryRadioControl.resetPath]
  /// before the first try.
  Future<SendReceipt> sendDirect(
      {required String radioId, required String contactPublicKey, required String text, required int timestamp, required int attempt});

  /// CMD_SEND_CHANNEL_TXT_MSG. Channel messages have no ack: success is just "accepted". [text] is the body; the firmware
  /// prepends "name: ". Returns the timestamp that went into the packet (a session may stamp its own; chat adopts it so
  /// echo recognition and receivers' dedupe agree). [priority] is the radio command queue class ([CommandPriority]): a
  /// message the person typed goes at user priority; MeshTrack's silent sends at ping priority. Throws an [OutboundFailure].
  Future<int> sendChannel({required String radioId, required int slot, required String text, required int timestamp, int priority = CommandPriority.user});
}

/// The two radio commands besides the send itself that delivery uses (build 77). A sink that also implements this lets the
/// outbox do them; one that does not (a plain test double) simply sends.
abstract interface class DeliveryRadioControl {
  /// CMD_RESET_PATH for the contact: the radio forgets its route, so the next sends flood and it learns a fresh one. Sent
  /// at most once per message: after the direct tries are used up, or before the first try when the person chose flood.
  /// False when the radio does not hold the contact. Throws an [OutboundFailure] when the radio cannot be asked.
  Future<bool> resetPath({required String radioId, required String contactPublicKey});

  /// The radio answered "not a contact" to a send: put the contact on the radio as a NEW contact (route unknown; the
  /// radio's copy is read first and left alone when it is there after all). Throws [RadioContactsFull] when the radio's
  /// list is full, [RadioTargetMissing] when the phone does not know the contact either, [RadioNotConnected] /
  /// [RadioNoAnswer] when the radio cannot be asked.
  Future<void> addContactToRadio({required String radioId, required String contactPublicKey});
}
