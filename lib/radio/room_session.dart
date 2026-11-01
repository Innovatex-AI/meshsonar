// Room servers: log in (guest or admin password), read the room's posts, post a message, count what is unread.
// Verified against MeshCore main examples/simple_room_server/MyMesh.cpp (Nov 1 2026):
//  - login is the same SEND_LOGIN; the companion adds the 4-byte `sync_since` itself for a contact of type room (3).
//  - the room PUSHES each post to every logged-in client as a normal text message with txt_type 2 (TXT_TYPE_SIGNED_PLAIN):
//    [timestamp][flags = 2 << 2][author key prefix, 4 bytes][text]. The companion queues it like any contact message
//    (CONTACT_MSG_RECV_V3 with the 4-byte signer prefix), so it arrives on [RadioSession.inbound].
//  - a POST is a plain direct message (txt_type 0) to the room. The room acknowledges it. A login with only the guest role
//    (allow.read.only) gets neither an ack nor a post: posting needs read-and-write or admin.
//  - CLI for a room admin is the same CLI_DATA (txt_type 1) as for a repeater.
// Pure Dart.
import 'dart:async';

import 'claim_radio.dart';
import 'crypto.dart' show toHex;
import 'inbound.dart';
import 'protocol.dart' show AdvType;
import 'session.dart';

/// One post in a room.
class RoomPost {
  /// First 4 bytes of the author's key, 8 hex characters.
  final String authorPrefixHex;
  final String text;

  /// The room's timestamp for the post (epoch seconds).
  final int timestamp;
  final DateTime receivedAt;

  /// Posted from this phone's radio.
  final bool mine;
  const RoomPost({required this.authorPrefixHex, required this.text, required this.timestamp, required this.receivedAt, this.mine = false});

  String get dedupeKey => '$authorPrefixHex|$timestamp|$text';
}

enum RoomPostOutcome { sent, notAllowed, tooLong, notLoggedIn, radioBusy, failed }

class RoomSession {
  final RadioSession radio;

  /// The room's public key, 64 hex.
  final String keyHex;
  final String name;

  RoomSession({required this.radio, required String keyHex, this.name = ''}) : keyHex = keyHex.toLowerCase();

  RemoteLogin? _login;
  StreamSubscription<InboundMessage>? _sub;
  final List<RoomPost> _posts = [];
  final Set<String> _seen = {};
  final _changes = StreamController<void>.broadcast();
  int _unread = 0;

  /// The login result; null before [login].
  RemoteLogin? get loginInfo => _login;
  bool get loggedIn => _login != null;
  bool get isAdmin => _login?.isAdmin ?? false;

  /// The login may post (read and write, or admin).
  bool get canPost => _login?.canPost ?? false;

  /// Oldest first.
  List<RoomPost> get posts => List.unmodifiable(_posts);

  /// Posts that arrived since [markRead].
  int get unread => _unread;
  Stream<void> get changes => _changes.stream;

  String get _prefix => keyHex.substring(0, 12);

  /// Logs in. Posts the room pushes afterwards arrive in [posts]. Throws [ClaimRadioException] (silent = wrong password or
  /// out of reach; both look the same).
  Future<RemoteLogin> login(String password) async {
    if (password.isEmpty) throw const ClaimRadioException(ClaimRadioError.radio, 'Enter the room password.');
    await radio.ensureContact(keyHex, nodeType: AdvType.room, name: name);
    _sub ??= radio.inbound.listen(_onMessage);
    final r = await radio.login(keyHex, password);
    _login = r;
    return r;
  }

  void _onMessage(InboundMessage m) {
    if (m.kind != InboundKind.contact || m.senderPrefixHex != _prefix || m.txtType != 2) return;
    final author = m.signerPrefixHex ?? '';
    final p = RoomPost(authorPrefixHex: author, text: m.text, timestamp: m.senderTimestamp, receivedAt: m.receivedAt, mine: _isMine(author));
    if (!_seen.add(p.dedupeKey)) return;
    _posts.add(p);
    if (_posts.length > 300) _posts.removeAt(0);
    _unread++;
    if (!_changes.isClosed) _changes.add(null);
  }

  bool _isMine(String authorPrefix) {
    final me = radio.selfPublicKey;
    return me != null && authorPrefix.isNotEmpty && me.toLowerCase().startsWith(authorPrefix);
  }

  void markRead() {
    _unread = 0;
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Posts [text] as a plain direct message to the room. The room's own echo (a txt_type 2 push with your key prefix) is the
  /// real confirmation that it was posted; until then the post shows as pending.
  Future<RoomPostOutcome> post(String text) async {
    if (_login == null) return RoomPostOutcome.notLoggedIn;
    if (!canPost) return RoomPostOutcome.notAllowed;
    final t = text.trim();
    if (t.isEmpty) return RoomPostOutcome.failed;
    final res = await radio.sendContactMessage(keyHex, t);
    switch (res.status) {
      case SendStatus.accepted:
        return RoomPostOutcome.sent;
      case SendStatus.queued:
        return RoomPostOutcome.sent;
      case SendStatus.failed:
        return switch (res.failure) {
          SendFailure.tooLong => RoomPostOutcome.tooLong,
          SendFailure.radioBusy => RoomPostOutcome.radioBusy,
          _ => RoomPostOutcome.failed,
        };
    }
  }

  Future<void> logout() async {
    _login = null;
    await radio.logout(keyHex);
  }

  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_changes.close());
  }

  /// Display for an author prefix: the name of a known contact, else the first 4 hex characters.
  static String authorLabel(String prefixHex, String? knownName) => knownName != null && knownName.isNotEmpty ? knownName : prefixHex.substring(0, prefixHex.length < 4 ? prefixHex.length : 4);

  @override
  String toString() => 'RoomSession(${keyHex.substring(0, 12)}, loggedIn: $loggedIn, posts: ${_posts.length})';
}

/// Hex of a key prefix.
String roomKeyPrefix(List<int> key, [int n = 4]) => toHex(key.take(n).toList());
