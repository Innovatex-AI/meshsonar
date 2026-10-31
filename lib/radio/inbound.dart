// Plain Dart types the radio layer hands to the chat layer (lib/chat) and takes back from it. No Flutter, no frames:
// the chat code never sees a protocol byte except [InboundMessage.raw], kept for debugging and export.
//
// Frame layouts (all little endian), MeshCore firmware examples/companion_radio/MyMesh.cpp at 81dbae5 (MIT):
//  - contact message V3  queueMessage() lines 441-469:  [0x10][snr i8 x4][0][0][sender pubkey prefix x6][path_len]
//    [txt_type][timestamp u32]([signer prefix x4] when txt_type = 2)[text]; legacy [0x07] has no snr / reserved bytes.
//  - channel message V3  onChannelMessageRecv() lines 558-585: [0x11][snr i8 x4][0][0][channel_idx][path_len]
//    [txt_type][timestamp u32][text]; legacy [0x08] has no snr / reserved bytes.
//  - path_len is `pkt->isRouteFlood() ? pkt->path_len : 0xFF`: 0xFF means the packet came over a direct route.
//  - A channel message carries NO sender key; the sender's name is the text prefix "name: text" (BaseChatMesh.cpp ~523).
import 'dart:typed_data';

/// What kind of conversation an [InboundMessage] belongs to.
enum InboundKind { channel, contact }

/// One text message the radio delivered (from its offline queue, drained with SYNC_NEXT_MESSAGE).
class InboundMessage {
  final InboundKind kind;

  /// Channel slot on the radio; null for a contact message.
  final int? channelIndex;

  /// Channel messages: the sender's name, parsed from the "name: " text prefix; null when the text has no such prefix.
  final String? senderName;

  /// Contact messages: the sender's public key prefix, 12 lower-case hex characters (6 bytes). Null for channels.
  final String? senderPrefixHex;

  /// For a signed message (txt_type 2): the 4-byte signer prefix as 8 hex characters.
  final String? signerPrefixHex;

  /// The message body. For channel messages the "name: " prefix is removed when [senderName] was parsed.
  final String text;

  /// The text exactly as the radio delivered it (channel messages: including the "name: " prefix).
  final String fullText;

  /// 0 plain, 1 CLI data (a repeater's reply to a command), 2 signed plain. Chat shows 0 and 2; 1 belongs to admin tools.
  final int txtType;

  /// The sender's clock, epoch seconds. Not trustworthy for ordering across senders; part of the dedupe key.
  final int senderTimestamp;

  /// When this phone took the message off the radio.
  final DateTime receivedAt;

  /// SNR (dB) at which the radio heard the packet; null for legacy frames that carry none.
  final double? snrDb;

  /// Hops the packet travelled when flooded, or 0xFF when it came over a direct route.
  final int pathLen;

  /// The whole frame as received (code byte included).
  final Uint8List raw;

  const InboundMessage({
    required this.kind,
    this.channelIndex,
    this.senderName,
    this.senderPrefixHex,
    this.signerPrefixHex,
    required this.text,
    required this.fullText,
    required this.txtType,
    required this.senderTimestamp,
    required this.receivedAt,
    this.snrDb,
    required this.pathLen,
    required this.raw,
  });

  bool get wasDirect => pathLen == 0xFF;

  /// Hops of a flooded packet; null when it came direct.
  int? get hops => wasDirect ? null : pathLen;

  /// "ch:3" or "dm:aabbccddeeff": which conversation this belongs to, stable across app runs.
  String get conversationKey => kind == InboundKind.channel ? 'ch:$channelIndex' : 'dm:$senderPrefixHex';

  /// The input of the dedupe key (hash it, or use as is): conversation, sender clock, delivered text. The radio gives a
  /// message no id, and a retried DM arrives again with the same three values (docs/PROTOCOL.md 8.4).
  String get contentKey => '$conversationKey|$senderTimestamp|$fullText';

  @override
  String toString() => 'InboundMessage($conversationKey, "$text")';
}

/// How [RadioSession.sendChannelMessage] / [RadioSession.sendContactMessage] ended.
enum SendStatus {
  /// The radio took the message and will transmit it. Channel: RESP_CODE_OK. Contact: RESP_CODE_SENT, with the
  /// [SendResult.expectedAck] that a later [SendConfirmedEvent] reports.
  accepted,

  /// The command went out but the radio did not answer within the timeout. The message may still be transmitted: do not
  /// resend blindly (a timeout does not mean "not sent"); show it as sending and let the user retry.
  queued,

  /// Nothing was sent; see [SendResult.failure].
  failed,
}

enum SendFailure {
  /// No radio link.
  notConnected,

  /// The text does not fit in one packet (see [RadioSession.maxChannelTextBytes], [maxDirectTextBytes]).
  tooLong,

  /// The channel slot does not exist (or, for the firmware's single error code, the radio was busy twice in a row).
  noSuchChannel,

  /// The radio does not have this contact. Add it with [RadioSession.addOrUpdateContact] first.
  noSuchContact,

  /// The radio's outbound packet pool is full (ERR_CODE_TABLE_FULL).
  radioBusy,

  /// The firmware refuses this command or text type.
  unsupported,

  /// Any other radio error code.
  radioError,
}

class SendResult {
  final SendStatus status;
  final SendFailure? failure;
  final String? detail;

  /// The timestamp (epoch seconds) put in the packet; part of the receivers' dedupe key, so keep it for retries.
  final int timestamp;

  /// Contact messages: the ack tag the radio expects (RESP_CODE_SENT bytes 2-5). Null for channels (no ACK exists).
  final int? expectedAck;

  /// Contact messages: the radio's estimate of the round trip, ms (500 + 16 x airtime for flood).
  final int? estTimeoutMs;

  /// Contact messages: true when the packet goes out as a flood, false when along a known path.
  final bool? flood;

  /// The DM attempt number (0-3) that was sent.
  final int attempt;

  const SendResult._(this.status, this.timestamp, {this.failure, this.detail, this.expectedAck, this.estTimeoutMs, this.flood, this.attempt = 0});

  const SendResult.accepted(int timestamp, {int? expectedAck, int? estTimeoutMs, bool? flood, int attempt = 0})
      : this._(SendStatus.accepted, timestamp, expectedAck: expectedAck, estTimeoutMs: estTimeoutMs, flood: flood, attempt: attempt);

  const SendResult.queued(int timestamp, {String? detail, int attempt = 0}) : this._(SendStatus.queued, timestamp, detail: detail, attempt: attempt);

  const SendResult.failed(SendFailure failure, {String? detail, int timestamp = 0, int attempt = 0})
      : this._(SendStatus.failed, timestamp, failure: failure, detail: detail, attempt: attempt);

  bool get isAccepted => status == SendStatus.accepted;
  bool get isFailed => status == SendStatus.failed;

  @override
  String toString() => 'SendResult(${status.name}${failure == null ? '' : ' ${failure!.name}'}${detail == null ? '' : ': $detail'})';
}

/// Which flood scope (region) a flood send goes out under. Scope is global radio state in the firmware; the session sets
/// it right before every flood send (SET_FLOOD_SCOPE_KEY, MyMesh.cpp 1978-1992), so one conversation's scope never
/// leaks into another's.
sealed class FloodScope {
  const FloodScope();

  /// Leave the radio's own default scope in force (clear any per-connection override). What a ping uses.
  static const FloodScope radioDefault = _RadioDefaultScope();

  /// Send unscoped even when the radio has a default scope (firmware v12+).
  static const FloodScope unscoped = _UnscopedScope();

  /// A region key (16 bytes, the transport key of the region).
  factory FloodScope.key(Uint8List key16) = KeyedFloodScope;
}

class _RadioDefaultScope extends FloodScope {
  const _RadioDefaultScope();
  @override
  String toString() => 'FloodScope.radioDefault';
}

class _UnscopedScope extends FloodScope {
  const _UnscopedScope();
  @override
  String toString() => 'FloodScope.unscoped';
}

class KeyedFloodScope extends FloodScope {
  final Uint8List key16;
  KeyedFloodScope(this.key16) {
    if (key16.length != 16) throw ArgumentError('a flood scope key is 16 bytes');
  }
  @override
  bool operator ==(Object other) => other is KeyedFloodScope && _same(other.key16, key16);
  @override
  int get hashCode => Object.hashAll(key16);
  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A contact as the radio stores it (RESP_CODE_CONTACT, writeContactRespFrame MyMesh.cpp 171-193, 148 bytes).
class RadioContact {
  /// 64 lower-case hex characters.
  final String publicKeyHex;

  /// AdvType (protocol.dart): 1 chat, 2 repeater, 3 room, 4 sensor.
  final int type;
  final int flags;

  /// Hops of the stored outbound path; 0xFF = unknown (the next message floods).
  final int outPathLen;

  /// The stored outbound path (outPathLen bytes of hash prefixes), empty when unknown.
  final Uint8List outPath;
  final String name;

  /// Epoch seconds of the last advert heard from this contact.
  final int lastAdvert;

  /// Degrees; null when the contact advertises no position (0,0).
  final double? lat;
  final double? lon;

  /// Epoch seconds of the last change on the radio; the cursor of the incremental sync.
  final int lastMod;

  const RadioContact({
    required this.publicKeyHex,
    required this.type,
    this.flags = 0,
    this.outPathLen = 0xFF,
    required this.outPath,
    required this.name,
    this.lastAdvert = 0,
    this.lat,
    this.lon,
    this.lastMod = 0,
  });

  String get prefixHex => publicKeyHex.substring(0, 12);
  bool get pathKnown => outPathLen != 0xFF;
}

/// The answer to GET_CONTACTS: CONTACTS_START (total on the radio), the changed contacts, END_OF_CONTACTS (cursor).
class ContactListing {
  /// Contacts on the radio in total (NOT only the ones sent, which `since` filters).
  final int totalOnRadio;
  final List<RadioContact> contacts;

  /// Pass this as `since` next time to get only what changed (END_OF_CONTACTS payload; 0 when nothing was sent).
  final int mostRecentLastMod;
  const ContactListing({required this.totalOnRadio, required this.contacts, required this.mostRecentLastMod});
}

/// One channel slot on the radio.
class RadioChannel {
  final int index;
  final String name;
  final Uint8List secret;
  const RadioChannel(this.index, this.name, this.secret);
  bool get isEmpty => name.isEmpty && secret.every((b) => b == 0);
}

/// What DEVICE_INFO / SELF_INFO say about the radio's limits (MyMesh.cpp 1056-1075). Null where the firmware is too old.
class DeviceLimits {
  /// DEVICE_INFO reports MAX_CONTACTS / 2; this is already doubled.
  final int? maxContacts;
  final int? maxChannels;
  final int? firmwareVerCode;

  /// The radio's outgoing packet pool is 16 and its offline message queue 16 by default, 256 on many variants; neither is
  /// readable from the radio. Plan for [assumedOfflineQueue].
  final int assumedOfflineQueue;
  const DeviceLimits({this.maxContacts, this.maxChannels, this.firmwareVerCode, this.assumedOfflineQueue = 16});
}

/// Things the radio tells us that are not a message.
sealed class RadioEvent {
  final DateTime at;
  const RadioEvent(this.at);
}

/// PUSH_CODE_SEND_CONFIRMED (0x82, processAck MyMesh.cpp 417-436): [0x82][ack u32][trip time ms u32]. The DM with this
/// ack tag was delivered. The same ACK can arrive more than once; the session reports it once.
class SendConfirmedEvent extends RadioEvent {
  final int ack;
  final int tripMs;

  /// The contact the DM went to, when the session still remembers the send (its table holds 8, like the radio's).
  final String? contactKeyHex;
  const SendConfirmedEvent(super.at, {required this.ack, required this.tripMs, this.contactKeyHex});
}

/// PUSH_CODE_PATH_UPDATED (0x81, onContactPathUpdated MyMesh.cpp 409-415): [0x81][pub_key x32]. The radio learned a new
/// path to this contact.
class PathUpdatedEvent extends RadioEvent {
  final String publicKeyHex;
  const PathUpdatedEvent(super.at, this.publicKeyHex);
}

/// PUSH_CODE_ADVERT (0x80, a known contact advertised: [0x80][pub_key x32]) or PUSH_CODE_NEW_ADVERT (0x8A, a contact the
/// radio did not have: the full contact frame, in [contact]). onDiscoveredContact MyMesh.cpp 358-407.
class AdvertHeardEvent extends RadioEvent {
  final String publicKeyHex;
  final bool isNew;
  final RadioContact? contact;
  const AdvertHeardEvent(super.at, this.publicKeyHex, {required this.isNew, this.contact});
}

/// PUSH_CODE_CONTACT_DELETED (0x8F: the radio overwrote its oldest contact) and PUSH_CODE_CONTACTS_FULL (0x90).
class ContactTableEvent extends RadioEvent {
  final bool full;
  final String? deletedKeyHex;
  const ContactTableEvent(super.at, {required this.full, this.deletedKeyHex});
}
