// RadioSession: the one owner of a radio link. Everything that talks to the radio (the wardrive engine, the chat layer,
// claims, health sampling) goes through it, so there is one command queue, one transmit arbiter and one airtime ledger
// per radio. Design: meshsonar-infra/docs/planning/meshsonar-one-app-one-radio-design-2026-10-31.md section 3.
//
// This file is the interface the chat layer (lib/chat) codes against. The implementation is in
// radio_session_impl.dart (a session over a CompanionLink) and the manager that connects and reconnects is in
// session_manager.dart. Pure Dart.
import 'dart:async';
import 'dart:typed_data';

import 'claim_radio.dart';
import 'inbound.dart';
import 'ping_gate.dart';
import 'radio_api.dart';

/// The state of the link to the radio.
enum LinkState {
  /// No radio.
  disconnected,

  /// Scanning / connecting / running the start sequence.
  connecting,

  /// Connected and started.
  connected,

  /// The link dropped and the manager is getting it back (a drive stays open meanwhile).
  reconnecting,

  /// The user gave the radio to another app on purpose: nothing reconnects until they say so.
  handedOver,
}

/// Longest text one packet carries, bytes (BaseChatMesh.h MAX_TEXT_LEN = 10 x CIPHER_BLOCK_SIZE).
const int maxDirectTextBytes = 160;

abstract class RadioSession implements ClaimRadio {
  /// This session's current link state (a session object lives as long as one link; the manager hands out a new session
  /// after a reconnect, see [RadioSessionManager.sessions]).
  LinkState get linkState;
  Stream<LinkState> get linkStates;

  SelfInfo? get selfInfo;

  /// Contacts / channels limits from DEVICE_INFO; null before the session started.
  DeviceLimits? get limits;

  @override
  bool get isConnected;

  // ------------------------------------------------------------ inbound (radio -> phone)

  /// Every text message drained from the radio. Persist-first: the persister set with [setInboundPersister] has
  /// completed for a message BEFORE it appears here and before the next SYNC_NEXT_MESSAGE is sent (the radio's queue is
  /// destructive). Duplicates (the same conversation, sender timestamp and text) are dropped. Broadcast stream; polling
  /// the radio for messages every few seconds starts with the first listener (the radio -> phone BLE queue is lossy, so
  /// PUSH_MSG_WAITING can be lost).
  Stream<InboundMessage> get inbound;

  /// Pushes that are not messages: DM delivery confirmations, path updates, adverts, contact table notices.
  Stream<RadioEvent> get events;

  /// The chat store's insert. Awaited for every message before the next one is requested from the radio. One persister
  /// per session; null removes it. It must be idempotent (the same message twice is possible after a crash).
  void setInboundPersister(Future<void> Function(InboundMessage message)? persist);

  /// Drains the radio's offline queue now (on connect, after a timeout, on a user pull-to-refresh).
  Future<void> syncMessagesNow();

  // ------------------------------------------------------------ outbound (phone -> radio), priority P0

  /// Text bytes a channel message may have: 160 minus "name: " for this radio's name.
  int get maxChannelTextBytes;

  /// Sends [text] on channel slot [channelIndex] as a user message (priority P0: never delayed by the airtime budget).
  /// [scope] is set on the radio right before the flood is queued; null leaves scope alone. A channel send has no ACK in
  /// the protocol: [SendStatus.accepted] means the radio will transmit it, nothing more.
  Future<SendResult> sendChannelMessage(int channelIndex, String text, {FloodScope? scope});

  /// Sends a direct message to the contact [publicKeyHex] (64 hex chars; the radio must have the contact, see
  /// [addOrUpdateContact]). The result carries the ack tag; a [SendConfirmedEvent] with that tag on [events] means
  /// delivered. [attempt] is 0-3 (only attempt & 3 is in the packet); a retry reuses [timestamp] of the first try so
  /// the receiver can tell it is the same message.
  Future<SendResult> sendContactMessage(String publicKeyHex, String text, {int attempt = 0, int? timestamp, FloodScope? scope});

  // ------------------------------------------------------------ contacts and channels

  /// GET_CONTACTS. [since] is the cursor ([ContactListing.mostRecentLastMod]) of the previous call, 0 for everything.
  /// Throws StateError when the link is down; a second call while one runs waits its turn (the firmware answers
  /// ERR_BAD_STATE to an overlapping iteration, so the session serialises them).
  Future<ContactListing> getContacts({int since = 0});

  /// [getContacts] that reports each contact as its frame arrives ([onContact]: the contact, the count so far, the total the
  /// radio announced), so a caller can save progress during a long list and keep it if the link drops half way.
  Future<ContactListing> downloadContacts({int since = 0, void Function(RadioContact contact, int received, int total)? onContact});

  /// The radio's own copy of one contact (GET_CONTACT_BY_KEY); null when it does not have it.
  Future<RadioContact?> getContact(String publicKeyHex);

  /// REMOVE_CONTACT: frees a slot in the radio's table. False when the radio no longer had it. Never touches the phone's copy.
  Future<bool> removeContact(String publicKeyHex);

  /// RESET_PATH: the next message to the contact floods. False when the radio does not have the contact.
  Future<bool> resetContactPath(String publicKeyHex);

  /// The advert packet the radio last HEARD from the contact (EXPORT_CONTACT), or null (a contact written by the phone has none).
  Future<Uint8List?> exportContactAdvert(String publicKeyHex);

  /// IMPORT_CONTACT: lets the radio process an advert packet as if heard. With "ask before adding" on, the radio does not add
  /// it but pushes NEW_ADVERT ([AdvertHeardEvent] with isNew).
  Future<void> importContactAdvert(Uint8List packet);

  /// SHARE_CONTACT: the radio broadcasts the contact's stored advert zero-hop. False when it cannot.
  Future<bool> shareContactZeroHop(String publicKeyHex);

  /// What the radio does with nodes it hears (see [ContactPolicy]).
  Future<ContactPolicy> getContactPolicy();
  Future<void> setContactPolicy(ContactPolicy policy);

  /// Adds the contact to the radio or updates it (ADD_UPDATE_CONTACT with every field).
  Future<void> addOrUpdateContact(RadioContact contact);

  /// All channel slots 0..maxChannels-1 that exist (empty slots included, [RadioChannel.isEmpty]).
  Future<List<RadioChannel>> listChannels();

  /// SET_CHANNEL: writes name and 16-byte secret into slot [index].
  Future<void> setChannel(int index, String name, Uint8List secret16);

  /// Clears slot [index] (empty name and zero secret, the firmware's delete).
  Future<void> deleteChannel(int index);

  /// Index of the named channel, joined into the first empty slot when the radio has not got it (hashtag channels).
  Future<int> ensureChannel(String name);

  // ------------------------------------------------------------ wardrive / radio

  Stream<RxPacket> get rxPackets;

  /// What the wardrive engine asks before every ping.
  PingGate get pingGate;

  /// Turns on the rules chat needs: the radio-queue probe before a ping and the airtime budgets. Off by default so a
  /// session that never chats behaves exactly like a wardrive-only one. The chat layer sets it when chat is in use.
  bool get chatActive;
  set chatActive(bool value);

  /// Ends the session and closes the link.
  Future<void> close();
}
