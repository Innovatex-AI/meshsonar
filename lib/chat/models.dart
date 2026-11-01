// Chat data models (pure Dart, no Flutter imports). Design: docs/planning/meshsonar-one-app-one-radio-design section 2.
// Nothing in here is ever uploaded: chat is app-only (HANDOFF section 71, D5).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

/// MeshCore advert / contact types (docs/qr_codes.md: 1 companion, 2 repeater, 3 room server, 4 sensor).
enum ContactType {
  companion(1),
  repeater(2),
  room(3),
  sensor(4);

  final int code;
  const ContactType(this.code);

  static ContactType? fromCode(int? code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// Where a contact row came from. The phone is the master copy; the radio's table is a cache.
enum ContactSource { radio, discovered, imported, manual }

/// A person, repeater, room server or sensor.
class Contact {
  final String radioId;

  /// 64 lowercase hex characters.
  final String publicKey;
  final ContactType type;
  final String name;
  final String? customName;
  final bool favourite;
  final bool blocked;
  final double? lat;
  final double? lon;

  /// Unix seconds of the last advert heard (sender clock).
  final int? lastAdvertTs;
  final int? lastMod;

  /// Learned route to the contact; null or [outPathLen] < 0 means unknown (flood).
  final Uint8List? outPath;
  final int outPathLen;
  final String notes;
  final ContactSource source;

  /// True while the radio's contact table holds this contact (the radio is a cache; see ContactSync). Only meaningful for
  /// the radio that is connected now.
  final bool onRadio;

  /// The radio's own flag byte for this contact (bit 0 = favourite; the other bits are the radio's telemetry permissions and
  /// are carried through untouched).
  final int radioFlags;

  /// Local time (ms) this phone last heard the contact: an advert, a message or an acknowledgement.
  final int? lastHeardMs;

  /// Send every DM to this contact by flood, never along a saved path.
  final bool forceFlood;

  const Contact({
    required this.radioId,
    required this.publicKey,
    required this.type,
    required this.name,
    this.customName,
    this.favourite = false,
    this.blocked = false,
    this.lat,
    this.lon,
    this.lastAdvertTs,
    this.lastMod,
    this.outPath,
    this.outPathLen = -1,
    this.notes = '',
    this.source = ContactSource.radio,
    this.onRadio = false,
    this.radioFlags = 0,
    this.lastHeardMs,
    this.forceFlood = false,
  });

  /// First 6 bytes of the key as 12 hex characters: what DM frames carry.
  String get prefix => publicKey.substring(0, 12);
  String get displayName => (customName != null && customName!.trim().isNotEmpty) ? customName! : name;
  bool get hasPath => outPathLen >= 0;
  bool get hasPosition => lat != null && lon != null;

  Contact copyWith({
    ContactType? type,
    String? name,
    Object? customName = _keep,
    bool? favourite,
    bool? blocked,
    Object? lat = _keep,
    Object? lon = _keep,
    Object? lastAdvertTs = _keep,
    Object? lastMod = _keep,
    Object? outPath = _keep,
    int? outPathLen,
    String? notes,
    ContactSource? source,
    bool? onRadio,
    int? radioFlags,
    Object? lastHeardMs = _keep,
    bool? forceFlood,
  }) =>
      Contact(
        radioId: radioId,
        publicKey: publicKey,
        type: type ?? this.type,
        name: name ?? this.name,
        customName: identical(customName, _keep) ? this.customName : customName as String?,
        favourite: favourite ?? this.favourite,
        blocked: blocked ?? this.blocked,
        lat: identical(lat, _keep) ? this.lat : lat as double?,
        lon: identical(lon, _keep) ? this.lon : lon as double?,
        lastAdvertTs: identical(lastAdvertTs, _keep) ? this.lastAdvertTs : lastAdvertTs as int?,
        lastMod: identical(lastMod, _keep) ? this.lastMod : lastMod as int?,
        outPath: identical(outPath, _keep) ? this.outPath : outPath as Uint8List?,
        outPathLen: outPathLen ?? this.outPathLen,
        notes: notes ?? this.notes,
        source: source ?? this.source,
        onRadio: onRadio ?? this.onRadio,
        radioFlags: radioFlags ?? this.radioFlags,
        lastHeardMs: identical(lastHeardMs, _keep) ? this.lastHeardMs : lastHeardMs as int?,
        forceFlood: forceFlood ?? this.forceFlood,
      );

  /// Hops of the saved route (low 6 bits of the path byte), or null when none is saved.
  int? get pathHops => hasPath ? outPathLen & 63 : null;

  /// Bytes per hop id in the saved route (1-3; the top two bits of the path byte hold size - 1).
  int get pathHashBytes => hasPath ? (outPathLen >> 6) + 1 : 1;

  /// The saved route as one hex id per hop, first repeater first; empty when none is saved or the contact is a neighbour.
  List<String> get routeIds {
    final p = outPath;
    if (!hasPath || p == null || p.isEmpty) return const [];
    final size = pathHashBytes;
    return [for (var i = 0; i + size <= p.length; i += size) toHex(p.sublist(i, i + size))];
  }
}

const Object _keep = Object();

/// public: the well-known Public channel. hashtag: key derived from the name (public by construction).
/// private: random secret shared by link/QR. system: the wardrive channel, hidden from conversations.
enum ChannelKind { public, hashtag, private, system }

enum NotifyMode { all, mentionsOnly, muted }

class Channel {
  /// Local stable id (rowid); null before the first save.
  final int? id;
  final String radioId;

  /// Radio slot, or null when the channel only lives on the phone (evicted from the radio).
  final int? slot;
  final String name;
  final ChannelKind kind;

  /// Key in the SecretStore. The secret itself is never in SQLite.
  final String? secretRef;

  /// One-byte on-air hash, SHA-256(secret)[0]. Not secret (it is visible in every packet).
  final int? hashByte;
  final String? regionScope;
  final int sortOrder;

  const Channel({
    this.id,
    required this.radioId,
    this.slot,
    required this.name,
    required this.kind,
    this.secretRef,
    this.hashByte,
    this.regionScope,
    this.sortOrder = 0,
  });

  bool get isSystem => kind == ChannelKind.system;

  /// Conversation key. Stable across slot changes.
  String get convKey {
    if (id == null) throw StateError('channel not saved yet');
    return ConvKey.channel(id!);
  }

  Channel copyWith({int? id, int? slot, bool clearSlot = false, String? name, ChannelKind? kind, String? secretRef, int? hashByte, Object? regionScope = _keep, int? sortOrder}) => Channel(
        id: id ?? this.id,
        radioId: radioId,
        slot: clearSlot ? null : (slot ?? this.slot),
        name: name ?? this.name,
        kind: kind ?? this.kind,
        secretRef: secretRef ?? this.secretRef,
        hashByte: hashByte ?? this.hashByte,
        regionScope: identical(regionScope, _keep) ? this.regionScope : regionScope as String?,
        sortOrder: sortOrder ?? this.sortOrder,
      );
}

enum ConvKind { dm, channel, room }

/// Conversation keys: `d:<12 hex>` direct message, `r:<12 hex>` room server, `c:<channel id>` channel.
abstract final class ConvKey {
  static String dm(String prefix12) => 'd:${prefix12.toLowerCase().substring(0, 12)}';
  static String room(String prefix12) => 'r:${prefix12.toLowerCase().substring(0, 12)}';
  static String channel(int channelId) => 'c:$channelId';

  static ConvKind? kindOf(String key) {
    if (key.length < 3 || key[1] != ':') return null;
    switch (key[0]) {
      case 'd':
        return ConvKind.dm;
      case 'r':
        return ConvKind.room;
      case 'c':
        return ConvKind.channel;
    }
    return null;
  }

  static String body(String key) => key.substring(2);
}

enum Direction { incoming, outgoing }

/// queued -> sending -> sent (radio accepted, expected ack known) -> acked (DM) | heard (channel: >= 1 repeat) | failed.
/// retrying: an ack did not arrive in time and another attempt is scheduled.
enum MessageState { queued, sending, sent, retrying, heard, acked, failed, received }

enum Route { flood, direct }

/// Why an outgoing message was given up on. Shown to the user verbatim via [describe].
enum FailReason {
  noAck,
  radioRejected,
  radioBusy,
  notConnected,
  expired,
  textTooLong,
  unknownContact,
  unknownChannel,
  contactListFull,
  cancelled;

  String describe() => switch (this) {
        FailReason.noAck => 'No acknowledgement after every try. They may be out of range or switched off, or the repeater path to them may have changed.',
        FailReason.radioRejected => 'The radio refused the message.',
        FailReason.radioBusy => 'The radio stayed busy and the message could not be sent.',
        FailReason.notConnected => 'The radio was not connected for too long.',
        FailReason.expired => 'The message waited too long and was dropped.',
        FailReason.textTooLong => 'The message is too long for one packet.',
        FailReason.unknownContact => 'This contact is no longer known.',
        FailReason.unknownChannel => 'This channel is no longer on the radio.',
        FailReason.contactListFull => 'The radio\'s contact list is full, so it could not take this contact. Free a slot in Contacts and try again.',
        FailReason.cancelled => 'Cancelled.',
      };
}

class ChatMessage {
  /// Local id (uuid-ish string).
  final String id;

  /// Monotonic local sequence (rowid); tiebreak for paging. 0 before first save.
  final int seq;
  final String radioId;
  final ConvKind convKind;
  final String convKey;
  final Direction direction;
  final String? senderName;

  /// 12 hex chars of the sender key for DMs / room posts; null for channels.
  final String? senderPrefix;

  /// Sender clock, unix seconds. Kept identical across retries so receivers can dedupe.
  final int tsSender;

  /// Local arrival (incoming) or creation (outgoing) time, unix milliseconds. This orders the conversation.
  final int tsLocalMs;
  final String text;
  final double? snr;
  final int? pathLen;
  final Route? route;
  final MessageState state;
  final int attempt;
  final int? expectedAck;
  final int? ackMs;
  final int repeatsHeard;
  final FailReason? failReason;
  final String dedupeKey;
  final bool read;
  final int txtType;

  const ChatMessage({
    required this.id,
    this.seq = 0,
    required this.radioId,
    required this.convKind,
    required this.convKey,
    required this.direction,
    this.senderName,
    this.senderPrefix,
    required this.tsSender,
    required this.tsLocalMs,
    required this.text,
    this.snr,
    this.pathLen,
    this.route,
    required this.state,
    this.attempt = 0,
    this.expectedAck,
    this.ackMs,
    this.repeatsHeard = 0,
    this.failReason,
    required this.dedupeKey,
    this.read = false,
    this.txtType = 0,
  });

  bool get isOutgoing => direction == Direction.outgoing;
  bool get isPending => state == MessageState.queued || state == MessageState.sending || state == MessageState.retrying;
}

/// Row of the conversation list.
class ConversationSummary {
  final String key;
  final ConvKind kind;
  final String radioId;
  final String title;
  final String? lastPreview;
  final int? lastTsMs;
  final int unread;
  final NotifyMode notifyMode;
  final int? mutedUntilMs;
  final bool pinned;
  final int? retentionDays;
  final bool isSystem;

  const ConversationSummary({
    required this.key,
    required this.kind,
    required this.radioId,
    required this.title,
    this.lastPreview,
    this.lastTsMs,
    this.unread = 0,
    this.notifyMode = NotifyMode.all,
    this.mutedUntilMs,
    this.pinned = false,
    this.retentionDays,
    this.isSystem = false,
  });

  bool isMutedAt(int nowMs) => notifyMode == NotifyMode.muted && (mutedUntilMs == null || mutedUntilMs! > nowMs);
}

/// Stats for the 'System' section (the wardrive channel).
class SystemChannelStats {
  final Channel channel;
  final int pingsSent;
  final int? lastPingTsMs;
  final int heardFromOthers;
  final int? lastHeardTsMs;
  const SystemChannelStats({required this.channel, this.pingsSent = 0, this.lastPingTsMs, this.heardFromOthers = 0, this.lastHeardTsMs});
}

/// A node heard advertising (Discover list).
class AdvertSeen {
  final String radioId;
  final String publicKey;
  final ContactType? type;
  final String name;
  final double? lat;
  final double? lon;
  final int firstTsMs;
  final int lastTsMs;
  final int count;
  final int? pathLen;
  final double? snr;

  /// The advert's own timestamp (sender clock, epoch seconds). Adding the node to the radio must carry exactly this, or the
  /// radio's replay check (BaseChatMesh.cpp 133) would refuse the node's next real advert.
  final int? advertTs;

  /// The user said "not interested": hidden from New nodes nearby until restored.
  final bool ignored;
  const AdvertSeen({
    required this.radioId,
    required this.publicKey,
    this.type,
    required this.name,
    this.lat,
    this.lon,
    required this.firstTsMs,
    required this.lastTsMs,
    this.count = 1,
    this.pathLen,
    this.snr,
    this.advertTs,
    this.ignored = false,
  });
}

/// Dedupe key: first 16 bytes (32 hex) of SHA-256 over `convKey \0 tsSender \0 text`.
/// MeshCore has no message id (doc B section 3 item 9): channel frames carry the sender only as a text prefix and DM
/// frames a 6-byte key prefix, so (conversation, sender timestamp, text) is the identity. Retries of a DM carry the same
/// timestamp and text, so they collapse onto one row (changelog of the official app v1.4.1 does the same).
String dedupeKeyFor(String convKey, int tsSender, String text) {
  final d = c.sha256.convert(utf8.encode('$convKey\u0000$tsSender\u0000$text'));
  return d.toString().substring(0, 32);
}

/// Hex helpers (strict, lowercase).
final RegExp _hexRe = RegExp(r'^[0-9a-fA-F]*$');
bool isHex(String s, [int? length]) => _hexRe.hasMatch(s) && (length == null || s.length == length) && s.length.isEven;

String toHex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List fromHex(String hex) {
  if (!isHex(hex)) throw FormatException('not hex: ${hex.length > 16 ? '${hex.substring(0, 16)}...' : hex}');
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
