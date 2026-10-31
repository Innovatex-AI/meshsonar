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
import 'models.dart';
import 'radio_bridge.dart';

class RadioSessionChatAdapter implements OutboundMessageSink {
  final r.RadioSession session;

  /// Chat's own copy of a contact, to rebuild the radio record when a path has to be cleared (phone is master).
  final Contact? Function(String publicKeyHex) lookupContact;

  /// The region (flood scope) the channel in [slot] is limited to, or null for none. The key is derived from the name
  /// like a hashtag key; the session sets it on the radio right before the flood and clears it afterwards (ScopeGuard).
  final String? Function(int slot)? regionScopeForSlot;
  StreamSubscription<r.RadioEvent>? _sub;
  ChatService? _chat;
  int _contactCursor = 0;
  bool _syncing = false;

  RadioSessionChatAdapter(this.session, {required this.lookupContact, this.regionScopeForSlot});

  String? get radioId => session.selfPublicKey;

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
    unawaited(syncContacts());
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
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
      );

  void _onEvent(r.RadioEvent e) {
    final chat = _chat;
    final id = radioId;
    if (chat == null || id == null) return;
    switch (e) {
      case r.SendConfirmedEvent():
        chat.handleInbound(InboundAck(radioId: id, ackCode: e.ack));
      case r.PathUpdatedEvent():
        unawaited(syncContacts());
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
      case r.ContactTableEvent():
        break; // M2 (contacts UI) decides what a full radio table means for the user
    }
  }

  /// Reads contacts changed since the last call and hands them to chat. Safe to call often.
  Future<void> syncContacts({bool full = false}) async {
    final chat = _chat;
    final id = radioId;
    if (chat == null || id == null || _syncing || !session.isConnected) return;
    _syncing = true;
    try {
      final l = await session.getContacts(since: full ? 0 : _contactCursor);
      chat.handleInbound(InboundContactSnapshot(radioId: id, contacts: [for (final c in l.contacts) mapContact(id, c)]));
      if (l.mostRecentLastMod > _contactCursor) _contactCursor = l.mostRecentLastMod;
    } catch (_) {
      // best effort; the next advert, path update or reconnect syncs again
    } finally {
      _syncing = false;
    }
  }

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
    if (forceFlood) await _clearPath(contactPublicKey);
    final res = await session.sendContactMessage(contactPublicKey, text, attempt: attempt, timestamp: timestamp);
    if (res.status == r.SendStatus.failed) _throw(res);
    // `queued` = the radio did not answer in time and may still send. Retrying with the same timestamp is safe (receivers dedupe).
    if (res.status == r.SendStatus.queued) throw RadioBusy(res.detail ?? 'no answer from the radio');
    return SendReceipt(flood: res.flood ?? true, expectedAck: res.expectedAck ?? 0, estTimeoutMs: res.estTimeoutMs ?? 5000);
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

  /// Makes the next DM flood by writing the contact back with an unknown path (the firmware floods when it has none).
  Future<void> _clearPath(String key) async {
    final c = lookupContact(key);
    if (c == null) return;
    try {
      await session.addOrUpdateContact(r.RadioContact(
        publicKeyHex: c.publicKey,
        type: c.type.code,
        outPathLen: 0xFF,
        outPath: Uint8List(0),
        name: c.name,
        lastAdvert: c.lastAdvertTs ?? 0,
        lat: c.lat,
        lon: c.lon,
        lastMod: c.lastMod ?? 0,
      ));
    } catch (_) {
      // sending still works, just by the old route
    }
  }
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
