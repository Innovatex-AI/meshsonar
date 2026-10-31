// The small adapter between the radio layer (lib/radio/session.dart, agent 1A) and chat. The only chat file that imports
// lib/radio. Wiring: build it with the session and a way to look contacts up, then `adapter.bind(chatService)` after the
// ChatService exists. Persist-first is honoured through RadioSession.setInboundPersister: a message is in SQLite before the
// radio is asked for the next one (the radio's offline queue is destructive).
import 'dart:async';
import 'dart:typed_data';

import '../radio/inbound.dart' as r;
import '../radio/session.dart' as r;
import 'channel_admin.dart';
import 'channel_secret.dart';
import 'chat_service.dart';
import 'contact_manager.dart';
import 'contact_port.dart';
import 'models.dart';
import 'radio_bridge.dart';

class RadioSessionChatAdapter implements OutboundMessageSink {
  final r.RadioSession session;

  /// Kept for source compatibility with Wave 1B callers; the adapter no longer needs it (ContactManager holds the book).
  final Contact? Function(String publicKeyHex)? lookupContact;

  /// The region (flood scope) the channel in [slot] is limited to, or null for none. The key is derived from the name
  /// like a hashtag key; the session sets it on the radio right before the flood and clears it afterwards (ScopeGuard).
  final String? Function(int slot)? regionScopeForSlot;
  StreamSubscription<r.RadioEvent>? _sub;
  ChatService? _chat;

  RadioSessionChatAdapter(this.session, {this.lookupContact, this.regionScopeForSlot});

  String? get radioId => session.selfPublicKey;

  ContactManager? get _contacts => _chat?.contacts;

  /// Starts feeding [chat]. Call once per session; call [dispose] when the session ends.
  void bind(ChatService chat) {
    _chat = chat;
    session.chatActive = true;
    session.setInboundPersister((m) async {
      final id = radioId;
      if (id == null) throw StateError('radio identity unknown'); // not persisted: the session must not drop it from the radio
      chat.handleInbound(mapInbound(id, m));
    });
    _sub = session.events.listen(_onEvent);
    chat.contacts.attach(SessionContactPort(session));
    unawaited(chat.contacts.syncNow(auto: true));
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _chat?.contacts.detach();
    session.setInboundPersister(null);
    session.chatActive = false;
  }

  // ---------------------------------------------------------------- inbound

  static InboundEvent mapInbound(String radioId, r.InboundMessage m) {
    if (m.kind == r.InboundKind.channel) {
      return InboundChannelText(
          radioId: radioId, channelSlot: m.channelIndex ?? 0, timestamp: m.senderTimestamp, text: m.fullText, snr: m.snrDb, pathLen: m.hops, txtType: m.txtType);
    }
    return InboundDirectText(
        radioId: radioId,
        senderPrefix: m.senderPrefixHex ?? '',
        timestamp: m.senderTimestamp,
        text: m.fullText,
        snr: m.snrDb,
        pathLen: m.hops,
        txtType: m.txtType,
        signerPrefix: m.signerPrefixHex);
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

  /// Chat's contact as the radio wants it in ADD_UPDATE_CONTACT.
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
        chat.handleInbound(InboundAck(radioId: id, ackCode: e.ack));
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
      case r.SendFailure.noSuchChannel:
      case r.SendFailure.noSuchContact:
        throw RadioTargetMissing(res.detail ?? 'not on the radio');
      case r.SendFailure.tooLong:
      case r.SendFailure.unsupported:
      case r.SendFailure.radioError:
      case null:
        throw RadioRejected(res.detail ?? 'radio rejected the message');
    }
  }

  @override
  Future<SendReceipt> sendDirect(
      {required String radioId, required String contactPublicKey, required String text, required int timestamp, required int attempt, required bool forceFlood}) async {
    final cm = _contacts;
    // The radio can only send to a contact it holds (it keeps the shared secret and the route). The phone is the master, so
    // put the contact back first when the radio let it go.
    if (cm != null) await _ensureOnRadio(cm, contactPublicKey);
    if (forceFlood) {
      // The radio floods when its saved route is unknown: drop it (RESET_PATH) instead of rewriting the whole contact.
      try {
        await session.resetContactPath(contactPublicKey);
      } catch (_) {
        // sending still works, just by the old route
      }
    }
    var res = await session.sendContactMessage(contactPublicKey, text, attempt: attempt, timestamp: timestamp);
    if (res.failure == r.SendFailure.noSuchContact && cm != null) {
      // The radio lost the contact between our check and the send: once more, with a forced re-add.
      await _ensureOnRadio(cm, contactPublicKey, force: true);
      res = await session.sendContactMessage(contactPublicKey, text, attempt: attempt, timestamp: timestamp);
    }
    if (res.status == r.SendStatus.failed) _throw(res);
    // `queued` = the radio did not answer in time and may still send. Retrying with the same timestamp is safe (receivers dedupe).
    if (res.status == r.SendStatus.queued) throw RadioBusy(res.detail ?? 'no answer from the radio');
    return SendReceipt(flood: res.flood ?? true, expectedAck: res.expectedAck ?? 0, estTimeoutMs: res.estTimeoutMs ?? 5000);
  }

  Future<void> _ensureOnRadio(ContactManager cm, String key, {bool force = false}) async {
    try {
      await cm.ensureOnRadio(key, force: force);
    } on RadioUnavailable {
      throw const RadioNotConnected();
    } on ContactTableFull {
      throw const RadioContactsFull();
    } on ArgumentError {
      throw const RadioTargetMissing('this contact is no longer known');
    } on TimeoutException {
      throw const RadioBusy('the radio is slow to answer');
    } on StateError {
      throw const RadioNotConnected();
    }
  }

  @override
  Future<int> sendChannel({required String radioId, required int slot, required String text, required int timestamp}) async {
    final region = regionScopeForSlot?.call(slot);
    final scope = (region == null || region.trim().isEmpty) ? null : r.FloodScope.key(hashtagSecret16(region));
    final res = await session.sendChannelMessage(slot, text, scope: scope);
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
  Future<Uint8List?> exportAdvert(String publicKey) async {
    try {
      return await session.exportContactAdvert(publicKey);
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
  Future<ContactPolicy> getPolicy() => session.getContactPolicy();
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
