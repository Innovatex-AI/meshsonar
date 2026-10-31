// ChatService: the one object the UI talks to for everything chat. Pure Dart.
//
// Rules it keeps:
//  * Persist first, then notify. An event is emitted only after the row is committed.
//  * Idempotent: the same inbound frame twice (a reconnect re-syncs) changes nothing the second time.
//  * Chat never leaves the phone: nothing in here touches the network.
//  * The wardrive channel (ChannelKind.system) is never chat: its traffic is stored read, counted, capped, and announced only as
//    ChatEventKind.systemChanged.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'channel_secret.dart';
import 'db/message_repository.dart';
import 'events.dart';
import 'mesh_links.dart';
import 'models.dart';
import 'outbox.dart';
import 'radio_bridge.dart';
import 'store.dart';

class MessageTooLong implements Exception {
  final int maxBytes;
  final int actualBytes;
  const MessageTooLong(this.maxBytes, this.actualBytes);
  @override
  String toString() => 'message is $actualBytes bytes, the limit is $maxBytes';
}

/// What importing a link produced.
sealed class LinkImportResult {
  const LinkImportResult();
}

class ChannelImported extends LinkImportResult {
  final Channel channel;
  final bool created;
  const ChannelImported(this.channel, this.created);
}

class ContactImported extends LinkImportResult {
  final Contact contact;
  final bool created;
  const ContactImported(this.contact, this.created);
}

/// A legacy advert-packet link: the radio layer must send it with CMD_IMPORT_CONTACT.
class AdvertToImport extends LinkImportResult {
  final AdvertLink advert;
  const AdvertToImport(this.advert);
}

class LinkRejected extends LinkImportResult {
  final LinkError error;
  const LinkRejected(this.error);
}

class ChatService {
  final ChatStore store;
  final int Function() nowMs;
  final String? Function() selfName;
  final String Function() newId;
  final OutboundMessageSink? sink;
  final InboundMessageSource? source;
  final RetryPolicy policy;
  final Random? _random;
  late final Outbox? _ob = sink == null ? null : Outbox(store: store, sink: sink!, nowMs: nowMs, policy: policy, random: _random, notify: _emit);

  /// Longest text the radio carries (MAX_TEXT_LEN = 10 * 16, firmware).
  static const int maxPacketTextBytes = 160;
  static const int maxInboundChars = 2000;

  /// System (wardrive) channel traffic kept per channel.
  final int systemTrafficCap;

  final StreamController<ChatEvent> _events = StreamController<ChatEvent>.broadcast();
  StreamSubscription<InboundEvent>? _sub;
  Timer? _timer;
  /// Run the retry timer and start sends as soon as a message is queued. Tests turn this off and call [pump].
  final bool autoTimer;
  bool _started = false;
  bool _disposed = false;
  int _systemInserts = 0;

  ChatService({
    required this.store,
    this.source,
    this.sink,
    int Function()? nowMs,
    String? Function()? selfName,
    String Function()? newId,
    this.policy = const RetryPolicy(),
    Random? random,
    this.systemTrafficCap = 500,
    this.autoTimer = true,
  })  : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        selfName = selfName ?? (() => null),
        newId = newId ?? _randomId,
        // ignore: prefer_initializing_formals
        _random = random;

  static final Random _rng = Random.secure();
  static String _randomId() {
    final b = List<int>.generate(12, (_) => _rng.nextInt(256));
    return toHex(b);
  }

  Stream<ChatEvent> get events => _events.stream;

  void _emit(ChatEvent e) {
    if (_disposed || _events.isClosed) return;
    _events.add(e);
    if (e.kind == ChatEventKind.messageUpdated || e.kind == ChatEventKind.messageAdded) _rearm();
  }

  // ------------------------------------------------------------------ lifecycle

  /// Subscribes to the radio, recovers the outbox after a restart and starts the retry timer.
  void start() {
    if (_started) return;
    _started = true;
    _ob?.recover();
    _sub = source?.events.listen(_onInbound, onError: (_) {});
    _rearm();
    _kick();
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    await _sub?.cancel();
    await _events.close();
  }

  /// The radio linked up (or came back): try everything that was waiting.
  void notifyRadioReady() => _kick();

  /// Starts a pump without waiting for it. Off when [autoTimer] is false (tests drive [pump] by hand).
  void _kick() {
    if (autoTimer) unawaited(pump());
  }

  /// Runs every send that is due. The timer calls this; tests call it with a fake clock.
  Future<void> pump() async {
    final ob = _ob;
    if (ob == null || _disposed) return;
    try {
      await ob.tick();
    } catch (_) {
      if (!_disposed && !store.db.isClosed) rethrow;
    }
    _rearm();
  }

  void _rearm() {
    if (!autoTimer || _disposed) return;
    _timer?.cancel();
    final due = _ob?.nextDueMs;
    if (due == null) return;
    final wait = max(0, due - nowMs());
    _timer = Timer(Duration(milliseconds: wait), () => unawaited(pump()));
  }

  // ------------------------------------------------------------------ inbound

  void _onInbound(InboundEvent e) {
    if (_disposed) return;
    try {
      handleInbound(e);
    } catch (_) {
      // One bad frame must never kill the stream subscription.
    }
  }

  /// Applies one inbound event. Synchronous and idempotent; exposed for tests and for adapters that push directly.
  void handleInbound(InboundEvent e) {
    switch (e) {
      case InboundChannelText():
        _onChannelText(e);
      case InboundDirectText():
        _onDirectText(e);
      case InboundAck():
        _ob?.onAck(e.radioId, e.ackCode);
      case InboundRepeatHeard():
        _onRepeatHeard(e);
      case InboundAdvert():
        _onAdvert(e);
      case InboundPathUpdate():
        store.contacts.setPath(e.radioId, e.publicKey, e.path, e.pathLen);
      case InboundContactSnapshot():
        applyRadioContacts(e.radioId, e.contacts);
    }
  }

  static String _clamp(String s) => s.length > maxInboundChars ? s.substring(0, maxInboundChars) : s;

  /// "name: body" -> (name, body). Channel frames carry the sender only as this prefix.
  static (String?, String) splitSender(String raw) {
    final i = raw.indexOf(': ');
    if (i > 0 && i <= 40 && !raw.substring(0, i).contains('\n')) return (raw.substring(0, i), raw.substring(i + 2));
    return (null, raw);
  }

  Channel _channelForSlot(String radioId, int slot) {
    final existing = store.channels.bySlot(radioId, slot);
    if (existing != null) return existing;
    // A channel we have never been told about (set up outside the app). Keep its traffic; the user can rename it.
    final c = store.channels.db.transaction(() {
      store.db.raw.execute('INSERT OR IGNORE INTO channels(radio_id, slot, name, kind, sort_order) VALUES (?,?,?,?,?)',
          [radioId, slot, 'Channel $slot', ChannelKind.private.name, slot]);
      return store.channels.bySlot(radioId, slot)!;
    });
    _emit(const ChatEvent.channels());
    return c;
  }

  void _onChannelText(InboundChannelText e) {
    final now = nowMs();
    final raw = _clamp(e.text);
    final ch = _channelForSlot(e.radioId, e.channelSlot);
    final convKey = ch.convKey;
    final (name, body) = splitSender(raw);
    final system = ch.isSystem;
    final m = ChatMessage(
      id: newId(),
      radioId: e.radioId,
      convKind: ConvKind.channel,
      convKey: convKey,
      direction: Direction.incoming,
      senderName: name,
      tsSender: e.timestamp,
      tsLocalMs: now,
      text: body,
      snr: e.snr,
      pathLen: e.pathLen,
      state: MessageState.received,
      dedupeKey: dedupeKeyFor(convKey, e.timestamp, raw),
      read: system,
      txtType: e.txtType,
    );
    if (!store.messages.insert(m)) return; // replay
    if (system) {
      store.systemStats.heard(ch.id!, now);
      if (++_systemInserts % 32 == 0) store.messages.pruneToNewest(convKey, systemTrafficCap);
      _emit(ChatEvent.system(convKey));
      return;
    }
    _emit(ChatEvent.added(m, notify: _shouldNotify(convKey, m, blocked: false)));
  }

  void _onDirectText(InboundDirectText e) {
    if (e.txtType == 1) return; // CLI data: a repeater/room admin reply, owned by the claim/admin flows
    final now = nowMs();
    final raw = _clamp(e.text);
    final prefix = e.senderPrefix.toLowerCase();
    if (prefix.length != 12 || !isHex(prefix)) return;
    final contact = store.contacts.byPrefix(e.radioId, prefix);
    final isRoom = contact?.type == ContactType.room;
    final convKey = isRoom ? ConvKey.room(prefix) : ConvKey.dm(prefix);
    String? author = contact?.displayName;
    if (isRoom && e.signerPrefix != null) {
      final a = store.contacts.byPrefix(e.radioId, e.signerPrefix!);
      author = a?.displayName ?? e.signerPrefix;
    }
    final blocked = contact?.blocked ?? false;
    final m = ChatMessage(
      id: newId(),
      radioId: e.radioId,
      convKind: isRoom ? ConvKind.room : ConvKind.dm,
      convKey: convKey,
      direction: Direction.incoming,
      senderName: author,
      senderPrefix: prefix,
      tsSender: e.timestamp,
      tsLocalMs: now,
      text: raw,
      snr: e.snr,
      pathLen: e.pathLen,
      state: MessageState.received,
      dedupeKey: dedupeKeyFor(convKey, e.timestamp, raw),
      read: blocked,
      txtType: e.txtType,
    );
    if (!store.messages.insert(m)) return; // replay, or a sender retry of a DM we already have
    _emit(ChatEvent.added(m, notify: _shouldNotify(convKey, m, blocked: blocked)));
  }

  bool _shouldNotify(String convKey, ChatMessage m, {required bool blocked}) {
    if (blocked) return false;
    final cv = store.messages.conversation(convKey);
    if (cv == null) return true;
    if (cv.isMutedAt(nowMs())) return false;
    if (cv.notifyMode == NotifyMode.mentionsOnly && m.convKind == ConvKind.channel) {
      final me = selfName();
      return me != null && me.isNotEmpty && m.text.toLowerCase().contains('@[${me.toLowerCase()}]');
    }
    return true;
  }

  void _onRepeatHeard(InboundRepeatHeard e) {
    final ch = store.channels.bySlot(e.radioId, e.channelSlot);
    if (ch == null) return;
    final candidates = store.db.raw.select(
        "SELECT id, text, repeats_heard, state FROM messages WHERE conv_key = ? AND direction = 'out' AND ts_sender = ? ORDER BY seq DESC LIMIT 5", [ch.convKey, e.timestamp]);
    for (final r in candidates) {
      final t = r['text'] as String;
      if (e.text == t || e.text.endsWith(': $t')) {
        final n = (r['repeats_heard'] as int) + 1;
        final st = r['state'] as String;
        store.messages.update(r['id'] as String,
            repeatsHeard: n, state: (st == 'sent' || st == 'heard') ? MessageState.heard : null);
        _emit(ChatEvent.updated(ch.convKey, r['id'] as String));
        return;
      }
    }
  }

  /// Merges contacts read from the radio. The radio's fields (name, type, position, path, last advert) win; the phone's own
  /// (favourite, blocked, custom name, notes) are kept. Contacts missing from the batch are left alone (a batch can be partial).
  void applyRadioContacts(String radioId, Iterable<Contact> batch) {
    store.db.transaction(() {
      for (final c in batch) {
        final ex = store.contacts.get(radioId, c.publicKey);
        store.contacts.upsert(ex == null
            ? c
            : c.copyWith(favourite: ex.favourite, blocked: ex.blocked, customName: ex.customName, notes: ex.notes, source: ex.source));
      }
    });
    _emit(const ChatEvent.contacts());
  }

  void _onAdvert(InboundAdvert e) {
    final now = nowMs();
    final key = e.publicKey.toLowerCase();
    if (!isHex(key, 64)) return;
    store.adverts.record(AdvertSeen(
        radioId: e.radioId, publicKey: key, type: e.type, name: e.name, lat: e.lat, lon: e.lon, firstTsMs: now, lastTsMs: now, pathLen: e.pathLen, snr: e.snr));
    final existing = store.contacts.get(e.radioId, key);
    if (existing != null || e.isContact) {
      final base = existing ??
          Contact(radioId: e.radioId, publicKey: key, type: e.type ?? ContactType.companion, name: e.name, source: ContactSource.radio);
      store.contacts.upsert(base.copyWith(
        name: e.name.isEmpty ? base.name : e.name,
        type: e.type ?? base.type,
        lat: e.lat ?? base.lat,
        lon: e.lon ?? base.lon,
        lastAdvertTs: e.advertTimestamp ?? base.lastAdvertTs,
      ));
      _emit(const ChatEvent.contacts());
    }
  }

  // ------------------------------------------------------------------ sending

  /// Longest body that fits for [convKey]. Channel messages lose room to the "name: " prefix the firmware adds.
  int maxTextBytes(String convKey) {
    if (ConvKey.kindOf(convKey) != ConvKind.channel) return maxPacketTextBytes;
    final n = utf8.encode(selfName() ?? '').length;
    return maxPacketTextBytes - (n == 0 ? 32 : n) - 2;
  }

  /// Stores an outgoing message and queues it. Returns at once; delivery state arrives as events.
  /// Throws [MessageTooLong] or [ArgumentError] (empty text, unknown conversation).
  ChatMessage send({required String radioId, required String convKey, required String text}) {
    final body = text.trim();
    if (body.isEmpty) throw ArgumentError('empty message');
    final bytes = utf8.encode(body).length;
    final max = maxTextBytes(convKey);
    if (bytes > max) throw MessageTooLong(max, bytes);
    final kind = ConvKey.kindOf(convKey);
    if (kind == null) throw ArgumentError('bad conversation $convKey');
    final ob = _ob;
    if (ob == null) throw StateError('no radio sink configured');
    var hasPath = false;
    if (kind != ConvKind.channel) {
      final c = store.contacts.byPrefix(radioId, ConvKey.body(convKey));
      if (c == null) throw ArgumentError('unknown contact');
      hasPath = c.hasPath;
    } else {
      final ch = store.channels.getById(int.parse(ConvKey.body(convKey)));
      if (ch == null) throw ArgumentError('unknown channel');
      if (ch.isSystem) throw ArgumentError('the system channel is not a chat');
    }
    final now = nowMs();
    var ts = now ~/ 1000;
    var key = dedupeKeyFor(convKey, ts, body);
    // Receivers dedupe on (conversation, timestamp, text): two identical sends in one second need different timestamps.
    while (store.messages.existsDedupe(radioId, key)) {
      ts++;
      key = dedupeKeyFor(convKey, ts, body);
    }
    final m = ChatMessage(
      id: newId(),
      radioId: radioId,
      convKind: kind,
      convKey: convKey,
      direction: Direction.outgoing,
      senderName: selfName(),
      tsSender: ts,
      tsLocalMs: now,
      text: body,
      state: MessageState.queued,
      dedupeKey: key,
      read: true,
    );
    store.db.transaction(() {
      store.messages.insert(m);
      ob.enqueue(m, hasPath: hasPath);
      store.drafts.clear(convKey);
    });
    _emit(ChatEvent.added(m, notify: false));
    _kick();
    return m;
  }

  bool retryFailed(String messageId) {
    final m = store.messages.get(messageId);
    final ob = _ob;
    if (m == null || ob == null) return false;
    final hasPath = m.convKind == ConvKind.channel ? false : (store.contacts.byPrefix(m.radioId, ConvKey.body(m.convKey))?.hasPath ?? false);
    final ok = ob.retryFailed(messageId, hasPath: hasPath);
    if (ok) _kick();
    return ok;
  }

  bool cancel(String messageId) => _ob?.cancel(messageId) ?? false;

  // ------------------------------------------------------------------ reading

  List<ConversationSummary> conversations({String? radioId, bool includeEmpty = false}) => store.messages.conversations(radioId: radioId, includeEmpty: includeEmpty);
  ConversationSummary? conversation(String convKey) => store.messages.conversation(convKey);
  MessagePage page(String convKey, {MessageCursor? before, int limit = 50}) => store.messages.page(convKey, before: before, limit: limit);
  List<ChatMessage> search(String query, {String? convKey, int limit = 50, int offset = 0}) => store.messages.search(query, convKey: convKey, limit: limit, offset: offset);
  int unreadBadge() => store.messages.unreadConversationCount(nowMs: nowMs());

  void markRead(String convKey) {
    if (store.messages.markConversationRead(convKey) > 0) _emit(ChatEvent.conversation(convKey));
  }

  // ------------------------------------------------------------------ per-conversation settings

  void setNotifyMode(String radioId, String convKey, NotifyMode mode, {Duration? muteFor}) {
    store.messages.setNotify(convKey, radioId, mode, mutedUntilMs: muteFor == null ? null : nowMs() + muteFor.inMilliseconds);
    _emit(ChatEvent.conversation(convKey));
  }

  void setPinned(String radioId, String convKey, bool pinned) {
    store.messages.setPinned(convKey, radioId, pinned);
    _emit(ChatEvent.conversation(convKey));
  }

  void saveDraft(String convKey, String text) {
    store.drafts.save(convKey, text, nowMs());
    _emit(ChatEvent.conversation(convKey));
  }

  String? loadDraft(String convKey) => store.drafts.load(convKey);

  // ------------------------------------------------------------------ retention and deletion

  static const _defaultRetentionKey = 'retention_default_days';

  int? get defaultRetentionDays {
    final v = store.db.setting(_defaultRetentionKey);
    return v == null ? null : int.tryParse(v);
  }

  /// null = keep everything (the default).
  void setDefaultRetentionDays(int? days) => store.db.putSetting(_defaultRetentionKey, days == null || days <= 0 ? null : '$days');

  void setConversationRetentionDays(String radioId, String convKey, int? days) => store.messages.setRetentionDays(convKey, radioId, days);

  /// Deletes messages older than each conversation's retention (its own, else the default). Returns the number deleted.
  /// System channels are bounded by count instead ([systemTrafficCap]).
  int applyRetention() {
    final now = nowMs();
    final def = defaultRetentionDays;
    var total = 0;
    store.db.transaction(() {
      for (final c in store.messages.conversations(includeSystem: true, includeEmpty: true)) {
        if (c.isSystem) {
          total += store.messages.pruneToNewest(c.key, systemTrafficCap);
          continue;
        }
        final days = c.retentionDays ?? def;
        if (days == null || days <= 0) continue;
        total += store.messages.deleteOlderThan(c.key, now - days * 86400000);
      }
    });
    if (total > 0) _emit(ChatEvent.deleted(null));
    return total;
  }

  /// Removes one message from this phone (it is not recalled from anyone else). A message still waiting to be sent is dropped.
  bool deleteMessage(String messageId) {
    final m = store.messages.get(messageId);
    if (m == null) return false;
    final ok = store.messages.deleteMessage(messageId);
    if (ok) _emit(ChatEvent.deleted(m.convKey));
    return ok;
  }

  int deleteHistory(String convKey) {
    final n = store.messages.deleteHistory(convKey);
    _emit(ChatEvent.deleted(convKey));
    return n;
  }

  /// Wipes everything chat holds on the phone: messages, contacts, channels and their secrets, drafts, settings.
  Future<void> wipeAll() async {
    final secretRefs = store.db.raw.select('SELECT secret_ref FROM channels WHERE secret_ref IS NOT NULL').map((r) => r['secret_ref'] as String).toList();
    store.db.transaction(() {
      for (final t in ['outbox', 'delivery_attempts', 'messages', 'conversations', 'drafts', 'adverts_seen', 'system_stats', 'contacts', 'channels', 'settings']) {
        store.db.raw.execute('DELETE FROM $t');
      }
    });
    for (final r in secretRefs) {
      await store.secrets.delete(r);
    }
    _emit(ChatEvent.deleted(null));
  }

  // ------------------------------------------------------------------ system (wardrive) channel

  List<SystemChannelStats> systemChannels(String radioId) => [
        for (final c in store.channels.systemChannels(radioId))
          () {
            final s = store.systemStats.get(c.id!);
            return SystemChannelStats(channel: c, pingsSent: s.pingsSent, lastPingTsMs: s.lastPingMs, heardFromOthers: s.heardOthers, lastHeardTsMs: s.lastHeardMs);
          }()
      ];

  /// The wardrive engine calls this when it sends a ping (we do not store our own pings as messages; the drive file has them).
  void recordOwnPing(String radioId, int channelSlot) {
    final ch = store.channels.bySlot(radioId, channelSlot);
    if (ch == null || !ch.isSystem) return;
    store.systemStats.ping(ch.id!, nowMs());
    _emit(ChatEvent.system(ch.convKey));
  }

  /// Read-only 'View traffic' for the System section: what others posted on the wardrive channel. Newest first.
  MessagePage systemTraffic(int channelId, {MessageCursor? before, int limit = 50}) => store.messages.page(ConvKey.channel(channelId), before: before, limit: limit);

  // ------------------------------------------------------------------ links

  String channelLink(Channel c, List<int> secret) => MeshLinks.encodeChannel(name: c.name, secret: secret, regionScope: c.regionScope);
  String contactLink(Contact c) => MeshLinks.encodeContact(name: c.displayName, publicKey: c.publicKey, type: c.type);

  /// Parses a pasted/scanned link and stores what it describes. Channels get no radio slot here (the radio layer assigns one
  /// and saves the channel again); the secret goes to the SecretStore. Never throws on hostile input.
  Future<LinkImportResult> importLink(String radioId, String link) async {
    final p = MeshLinks.parse(link);
    switch (p) {
      case LinkParseError():
        return LinkRejected(p.error);
      case AdvertLink():
        return AdvertToImport(p);
      case ContactLink():
        final existing = store.contacts.get(radioId, p.publicKey);
        final c = (existing ?? Contact(radioId: radioId, publicKey: p.publicKey, type: p.type ?? ContactType.companion, name: p.name.isEmpty ? p.publicKey.substring(0, 8) : p.name, source: ContactSource.imported))
            .copyWith(type: p.type, name: p.name.isEmpty ? null : p.name);
        store.contacts.upsert(c);
        _emit(const ChatEvent.contacts());
        return ContactImported(c, existing == null);
      case ChannelLink():
        final kind = _kindFor(p.name, p.secret);
        final existing = store.db.raw.select(
            'SELECT id FROM channels WHERE radio_id = ? AND hash_byte = ? AND lower(name) = lower(?)', [radioId, channelHashByte(p.secret), p.name]);
        final already = existing.isEmpty ? null : store.channels.getById(existing.first['id'] as int);
        final saved = await store.channels.save(
            already?.copyWith(regionScope: p.regionScope) ?? Channel(radioId: radioId, name: p.name, kind: kind, regionScope: p.regionScope),
            secret: p.secret);
        _emit(const ChatEvent.channels());
        return ChannelImported(saved, already == null);
    }
  }

  static ChannelKind _kindFor(String name, List<int> secret) {
    bool same(List<int> a, List<int> b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    if (same(secret, publicChannelSecret16)) return ChannelKind.public;
    if (name.startsWith('#') && same(secret, hashtagSecret16(name))) return ChannelKind.hashtag;
    return ChannelKind.private;
  }
}
