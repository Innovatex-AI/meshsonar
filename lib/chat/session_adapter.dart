// The small adapter between the radio layer (lib/radio/session.dart, agent 1A) and chat. The only chat file that imports
// lib/radio. Wiring: build it with the session and a way to look contacts up, then `adapter.bind(chatService)` after the
// ChatService exists. Persist-first is honoured through RadioSession.setInboundPersister: a message is in SQLite before the
// radio is asked for the next one (the radio's offline queue is destructive).
import 'dart:async';
import 'dart:typed_data';

import '../radio/inbound.dart' as r;
import '../radio/radio_api.dart' show RxPacket;
import '../radio/session.dart' as r;
import 'channel_admin.dart';
import 'channel_copy_listener.dart';
import 'channel_secret.dart';
import 'chat_service.dart';
import 'contact_manager.dart';
import 'contact_port.dart';
import 'models.dart';
import 'radio_bridge.dart';

class RadioSessionChatAdapter implements OutboundMessageSink, DeliveryRadioControl {
  final r.RadioSession session;

  /// Kept for source compatibility with Wave 1B callers; the adapter no longer needs it (ContactManager holds the book).
  final Contact? Function(String publicKeyHex)? lookupContact;

  /// The region (flood scope) the channel in [slot] is limited to, or null for none. The key is derived from the name
  /// like a hashtag key; the session sets it on the radio right before the flood and clears it afterwards (ScopeGuard).
  final String? Function(int slot)? regionScopeForSlot;
  StreamSubscription<r.RadioEvent>? _sub;
  StreamSubscription<RxPacket>? _rxSub;
  ChatService? _chat;

  RadioSessionChatAdapter(this.session, {this.lookupContact, this.regionScopeForSlot});

  String? get radioId => session.selfPublicKey;

  ContactManager? get _contacts => _chat?.contacts;

  /// Starts feeding [chat]. Call once per session; call [dispose] when the session ends.
  void bind(ChatService chat) {
    _chat = chat;
    session.setInboundPersister((m) async {
      final id = radioId;
      if (id == null) throw StateError('radio identity unknown'); // not persisted: the session must not drop it from the radio
      chat.handleInbound(mapInbound(id, m));
    });
    _sub = session.events.listen(_onEvent);
    // Every heard copy of a channel message: repeats of ours, extra paths of theirs (CR3).
    final copies = ChannelCopyListener(
      radioId: () => radioId ?? '',
      channels: (id) => id.isEmpty ? const [] : chat.store.channels.list(id, includeSystem: false),
      secretOf: chat.store.channels.secretOf,
      emit: chat.handleInbound,
    );
    _rxSub = session.rxPackets.listen((rx) => unawaited(copies.onPacket(rx).catchError((Object _) {})), onError: (Object _) {});
    // The message log's link side: every command, reply code, timeout, stray frame and delivery push of this session.
    final link = _delivery;
    if (link != null) {
      link.onLinkLog = chat.log.addLink;
      final ahead = link.radioClockAheadSecs;
      chat.radioClockAheadSecs = (ahead != null && ahead > 0) ? ahead : 0;
    }
    chat.contacts.attach(SessionContactPort(session));
    unawaited(chat.contacts.syncNow(auto: true));
  }

  r.DeliveryLink? get _delivery {
    final s = session;
    return s is r.DeliveryLink ? s as r.DeliveryLink : null;
  }

  Future<void> dispose() async {
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(_rxSub?.cancel());
    _rxSub = null;
    _chat?.contacts.detach();
    _delivery?.onLinkLog = null;
    _chat?.log.flush();
    session.setInboundPersister(null);
  }

  // ---------------------------------------------------------------- inbound

  static InboundEvent mapInbound(String radioId, r.InboundMessage m) {
    if (m.kind == r.InboundKind.channel) {
      return InboundChannelText(
          radioId: radioId, channelSlot: m.channelIndex ?? 0, timestamp: m.senderTimestamp, text: m.fullText, snr: m.snrDb, pathLen: m.hops, txtType: m.txtType,
          rssi: m.rssiDbm, pathHashes: m.pathHashesHex, hashSize: m.hashSize, airMs: m.airMs);
    }
    return InboundDirectText(
        radioId: radioId,
        senderPrefix: m.senderPrefixHex ?? '',
        timestamp: m.senderTimestamp,
        text: m.fullText,
        snr: m.snrDb,
        pathLen: m.hops,
        txtType: m.txtType,
        signerPrefix: m.signerPrefixHex,
        rssi: m.rssiDbm,
        pathHashes: m.pathHashesHex,
        hashSize: m.hashSize,
        airMs: m.airMs);
  }

  /// The radio's contact as chat's [Contact]. The saved route is kept only when the radio has one (0xFF = none).
  static Contact mapContact(String radioId, r.RadioContact c) => Contact(
        radioId: radioId,
        publicKey: c.publicKeyHex.toLowerCase(),
        type: ContactType.fromCode(c.type) ?? ContactType.companion,
        name: c.name,
        lat: c.lat,
        lon: c.lon,
        lastAdvertTs: c.lastAdvert == 0 ? null : c.lastAdvert,
        lastMod: c.lastMod,
        outPath: c.pathKnown ? c.outPath : null,
        outPathLen: c.pathKnown ? c.outPathLen : -1,
        radioFlags: c.flags,
        onRadio: true,
      );

  /// Chat's contact as the radio wants it in ADD_UPDATE_CONTACT. A contact with no route goes out as 0xFF ("unknown"),
  /// never 0 ("direct, zero hops"). ContactManager only ever passes the radio's own copy (an edit) or a new contact with no
  /// route, so a route in here is always the one the radio itself holds.
  static r.RadioContact toRadioContact(Contact c) => r.RadioContact(
        publicKeyHex: c.publicKey,
        type: c.type.code,
        flags: c.radioFlags,
        outPathLen: c.hasPath ? c.outPathLen : 0xFF,
        outPath: c.hasPath ? (c.outPath ?? Uint8List(0)) : Uint8List(0),
        name: c.name,
        lastAdvert: c.lastAdvertTs ?? 0,
        lat: c.lat,
        lon: c.lon,
        lastMod: 0,
      );

  void _onEvent(r.RadioEvent e) {
    final chat = _chat;
    final id = radioId;
    if (chat == null || id == null) return;
    switch (e) {
      case r.SendConfirmedEvent():
        chat.handleInbound(InboundAck(radioId: id, ackCode: e.ack, tripMs: e.tripMs));
        final k = e.contactKeyHex;
        if (k != null) chat.contacts.heardNow(k);
      case r.PathUpdatedEvent():
        unawaited(chat.contacts.pathUpdated(e.publicKeyHex));
      case r.AdvertHeardEvent():
        final c = e.contact;
        chat.handleInbound(InboundAdvert(
            radioId: id,
            publicKey: e.publicKeyHex.toLowerCase(),
            type: c == null ? null : ContactType.fromCode(c.type),
            name: c?.name ?? '',
            lat: c?.lat,
            lon: c?.lon,
            advertTimestamp: c?.lastAdvert,
            isContact: !e.isNew));
        if (!e.isNew) unawaited(chat.contacts.advertHeard(e.publicKeyHex));
      case r.ContactTableEvent():
        if (e.full) {
          chat.contacts.radioFull();
        } else if (e.deletedKeyHex != null) {
          chat.contacts.radioDropped(e.deletedKeyHex!);
        }
    }
  }

  /// Reads contacts changed since the last call. Kept for callers of Wave 1B; the work is ContactManager.syncNow.
  Future<void> syncContacts({bool full = false}) async => _contacts?.syncNow(full: full);

  // ---------------------------------------------------------------- outbound

  @override
  bool get canSend => session.isConnected;

  Never _throw(r.SendResult res) {
    switch (res.failure) {
      case r.SendFailure.notConnected:
        throw const RadioNotConnected();
      case r.SendFailure.radioBusy:
        throw RadioBusy(res.detail ?? 'radio busy');
      case r.SendFailure.tooLong:
        throw RadioRejected(res.detail ?? 'the message is too long');
      case r.SendFailure.noSuchChannel:
      case r.SendFailure.noSuchContact:
        throw RadioTargetMissing(res.detail ?? 'not on the radio');
      case r.SendFailure.unsupported:
      case r.SendFailure.radioError:
      case null:
        throw RadioRejected(res.detail ?? 'radio rejected the message');
    }
  }

  /// CMD_SEND_TXT_MSG and nothing else (round 3 rules 4 and 5). Build 76 did three more things here, all removed: it wrote
  /// the contact to the radio first when the phone believed it was missing, it sent RESET_PATH before any try the PHONE
  /// classed as a flood (wiping routes the radio had learned), and it re-added and resent on "not a contact". The radio's
  /// answer is passed on as what it is.
  @override
  Future<SendReceipt> sendDirect(
      {required String radioId, required String contactPublicKey, required String text, required int timestamp, required int attempt}) async {
    final res = await session.sendContactMessage(contactPublicKey, text, attempt: attempt, timestamp: timestamp);
    if (res.status == r.SendStatus.failed) _throw(res);
    // `queued` = the radio did not answer the command in time: its reply was lost or late, and it may have sent the packet.
    if (res.status == r.SendStatus.queued) throw RadioNoAnswer(res.detail ?? 'no answer from the radio');
    // Direct or flood, the confirmation code and the estimated wait are the radio's own words (rule 11). A reply without
    // them (a firmware that answers differently) is told as it is: flood unknown counts as flood, no estimate as none.
    return SendReceipt(flood: res.flood ?? true, expectedAck: res.expectedAck ?? 0, estTimeoutMs: res.estTimeoutMs ?? 0);
  }

  /// The one RESET_PATH of a message (after its direct tries, or before try 1 when the person chose flood).
  @override
  Future<bool> resetPath({required String radioId, required String contactPublicKey}) async {
    try {
      final ok = await session.resetContactPath(contactPublicKey);
      if (ok) _contacts?.noteRadioPathReset(contactPublicKey); // the phone's mirror follows the radio
      return ok;
    } on TimeoutException {
      throw const RadioNoAnswer('the radio did not answer the reset');
    } on StateError {
      throw const RadioNotConnected();
    }
  }

  /// The radio said "not a contact" to a send: the person is sending to someone their radio does not hold, so the contact
  /// is put on the radio as a new one (ContactManager.ensureOnRadio: read first, route unknown, no eviction).
  @override
  Future<void> addContactToRadio({required String radioId, required String contactPublicKey}) async {
    final cm = _contacts;
    if (cm == null) throw const RadioTargetMissing('this contact is not on the radio');
    try {
      await cm.ensureOnRadio(contactPublicKey, force: true);
    } on RadioUnavailable catch (e) {
      if (e.reason.contains('timeout')) throw const RadioNoAnswer('the radio is slow to answer');
      throw const RadioNotConnected();
    } on ContactTableFull {
      throw const RadioContactsFull();
    } on ArgumentError {
      throw const RadioTargetMissing('this contact is no longer known');
    } on TimeoutException {
      throw const RadioNoAnswer('the radio is slow to answer');
    } on StateError {
      throw const RadioNotConnected();
    }
  }

  @override
  Future<int> sendChannel({required String radioId, required int slot, required String text, required int timestamp, int priority = CommandPriority.user}) async {
    final region = regionScopeForSlot?.call(slot);
    final scope = (region == null || region.trim().isEmpty) ? null : r.FloodScope.key(hashtagSecret16(region));
    final res = await session.sendChannelMessage(slot, text, scope: scope, priority: priority);
    if (res.status == r.SendStatus.failed) _throw(res);
    if (res.status == r.SendStatus.queued) throw RadioBusy(res.detail ?? 'no answer from the radio');
    return res.timestamp == 0 ? timestamp : res.timestamp;
  }
}

/// [ContactRadioPort] over a [r.RadioSession]: maps between chat's Contact and the radio's frames.
class SessionContactPort implements ContactRadioPort {
  final r.RadioSession session;
  SessionContactPort(this.session);

  @override
  String? get radioId => session.selfPublicKey;
  @override
  bool get isConnected => session.isConnected;
  @override
  int? get capacity {
    try {
      return session.limits?.maxContacts;
    } catch (_) {
      return null;
    }
  }

  Never _unavailable(Object e) {
    if (e is TimeoutException) throw const RadioUnavailable('the radio did not answer (timeout)');
    if (e is StateError) throw const RadioUnavailable('the radio is not connected (link)');
    throw RadioUnavailable('$e');
  }

  @override
  Future<ContactDownload> download({required int since, required void Function(Contact contact, int received, int total) onContact}) async {
    final id = radioId;
    if (id == null) throw const RadioUnavailable('radio identity unknown');
    try {
      final l = await session.downloadContacts(since: since, onContact: (c, received, total) => onContact(RadioSessionChatAdapter.mapContact(id, c), received, total));
      return ContactDownload(totalOnRadio: l.totalOnRadio, cursor: l.mostRecentLastMod);
    } on RadioUnavailable {
      rethrow;
    } catch (e) {
      _unavailable(e);
    }
  }

  @override
  Future<Contact?> fetch(String publicKey) async {
    final id = radioId;
    if (id == null) throw const RadioUnavailable('radio identity unknown');
    try {
      final c = await session.getContact(publicKey);
      return c == null ? null : RadioSessionChatAdapter.mapContact(id, c);
    } catch (e) {
      _unavailable(e);
    }
  }

  @override
  Future<void> upload(Contact contact) async {
    try {
      await session.addOrUpdateContact(RadioSessionChatAdapter.toRadioContact(contact));
    } on r.RadioTableFull {
      throw const ContactTableFull();
    } catch (e) {
      _unavailable(e);
    }
  }

  @override
  Future<bool> remove(String publicKey) async {
    try {
      return await session.removeContact(publicKey);
    } catch (e) {
      _unavailable(e);
    }
  }

  @override
  Future<bool> resetPath(String publicKey) async {
    try {
      return await session.resetContactPath(publicKey);
    } catch (e) {
      _unavailable(e);
    }
  }

  @override
  Future<void> importAdvert(Uint8List packet) async {
    try {
      await session.importContactAdvert(packet);
    } catch (e) {
      _unavailable(e);
    }
  }

  @override
  Future<bool> shareZeroHop(String publicKey) async {
    try {
      return await session.shareContactZeroHop(publicKey);
    } catch (e) {
      _unavailable(e);
    }
  }

  @override
  bool get deliveryInFlight {
    final s = session;
    return s is r.DeliveryLink && (s as r.DeliveryLink).awaitingConfirmation;
  }

  @override
  Future<ContactPolicy> getPolicy({bool fresh = true}) {
    final s = session;
    if (!fresh && s is r.DeliveryLink) return (s as r.DeliveryLink).cachedContactPolicy();
    return session.getContactPolicy();
  }
  @override
  Future<void> setPolicy(ContactPolicy policy) => session.setContactPolicy(policy);
}

/// The channel slots of a [r.RadioSession] as chat's [ChannelRadio].
class SessionChannelRadio implements ChannelRadio {
  final r.RadioSession session;
  SessionChannelRadio(this.session);

  @override
  int? get maxChannels => session.limits?.maxChannels;

  @override
  Future<List<RadioSlot>> slots() async => [for (final c in await session.listChannels()) RadioSlot(c.index, c.name, c.secret)];

  @override
  Future<void> write(int slot, String name, Uint8List secret16) => session.setChannel(slot, name, secret16);

  @override
  Future<void> clear(int slot) => session.deleteChannel(slot);
}
