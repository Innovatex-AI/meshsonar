// Test-only fake radio and fake server for the claim flows. NOT part of the app or its release builds.
//
// ClaimFakeTransport plays a MeshCore companion radio over the REAL frame layouts (lib/radio/protocol.dart): app start,
// contacts, CMD_SEND_LOGIN -> LOGIN_SUCCESS (admin / guest) or silence or LOGIN_FAIL, CLI over CMD_SEND_TXT_MSG with the
// reply queued as a contact message (MSG_WAITING -> SYNC_NEXT_MESSAGE) for `get name` / `set name` / `advert`, and
// CMD_SIGN_* with a real Ed25519 key (package:cryptography, dev dependency only).
// FakeClaimClient plays the server: it hands out challenges, verifies Ed25519 signatures, and "hears" adverts that
// the fake repeater sends (an observer in range), exactly the check the real server does.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cr;
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_api.dart';

/// A repeater out in the mesh. Its name changes with `set name` and every `advert` is logged with the name it carried.
class FakeRepeater {
  final Uint8List key;
  String name;
  String adminPassword;
  String? guestPassword;

  /// Out of radio range of the companion: nothing it sends arrives and nothing reaches it.
  bool inRange = true;

  /// A bad password gets LOGIN_FAIL instead of silence (real repeaters stay silent; this is the other branch).
  bool failWithPush = false;

  /// The next N CLI replies are lost on the way back (the command still takes effect).
  int dropNextReplies = 0;

  /// The reply to the next command starting with this text is lost (the command still takes effect); then cleared.
  String? dropOncePrefix;

  /// Every CLI reply is lost from now on.
  bool dropAllReplies = false;

  /// `set name` answers "Error".
  bool refuseSetName = false;

  /// Names carried by each advert, in order. An observer in range reports these to the server.
  final List<String> adverts = [];
  final List<String> cliLog = [];
  final Set<String> _admins = {}; // companion keys with an admin session
  final Map<String, int> _lastTs = {}; // per client: the timestamp of its login / last command (real repeaters drop anything not newer)

  FakeRepeater({required this.key, required this.name, this.adminPassword = 'secret', this.guestPassword});

  String get keyHex => toHex(key);
}

class ClaimFakeTransport implements ByteTransport {
  final cr.SimpleKeyPair keyPair;
  final Uint8List publicKey;
  final Map<String, FakeRepeater> repeaters;
  final _incoming = StreamController<Uint8List>.broadcast();
  final List<Uint8List> sentFrames = [];
  final Set<String> contacts = {};
  final List<Uint8List> _queue = [];
  final BytesBuilder _signData = BytesBuilder();
  bool _signing = false;
  bool _connected = true;

  /// The radio's clock runs this many seconds ahead of the phone (the firmware refuses to set its clock backwards, so a
  /// radio that is ahead stays ahead). Its login and the repeater's replay check use THIS clock.
  int radioAheadSecs = 0;
  int get _radioNow => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + radioAheadSecs;

  /// The radio has no more room for contacts.
  bool contactsFull = false;

  /// Firmware without CMD_SIGN_*.
  bool signUnsupported = false;

  ClaimFakeTransport._(this.keyPair, this.publicKey, this.repeaters);

  static Future<ClaimFakeTransport> create({Iterable<FakeRepeater> repeaters = const [], List<int>? seed}) async {
    final s = seed ?? List<int>.generate(32, (i) => i + 1);
    final kp = await cr.Ed25519().newKeyPairFromSeed(s);
    final pub = await kp.extractPublicKey();
    return ClaimFakeTransport._(kp, Uint8List.fromList(pub.bytes), {for (final r in repeaters) r.keyHex: r});
  }

  String get keyHex => toHex(publicKey);

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  bool get isConnected => _connected;

  /// The radio goes away (BLE dropped).
  void drop() {
    if (!_connected) return;
    _connected = false;
    _incoming.close();
  }

  @override
  Future<void> disconnect() async => drop();

  void _emit(Uint8List f) {
    if (_connected) Future<void>.delayed(Duration.zero, () => _connected ? _incoming.add(f) : null);
  }

  FakeRepeater? _byPrefix(List<int> prefix6) {
    for (final r in repeaters.values) {
      if (_startsWith(r.key, prefix6)) return r;
    }
    return null;
  }

  static bool _startsWith(List<int> key, List<int> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (key[i] != prefix[i]) return false;
    }
    return true;
  }

  @override
  Future<void> send(Uint8List f) async {
    if (!_connected) throw StateError('radio disconnected');
    sentFrames.add(f);
    switch (f[0]) {
      case Cmd.appStart:
        _emit(encodeSelfInfo(txPowerDbm: 20, maxTxPowerDbm: 22, publicKey: publicKey, freqKhz: 910525, bwHz: 62500, sf: 7, cr: 5, name: 'My Companion'));
      case Cmd.deviceQuery:
        _emit(encodeDeviceInfo(firmwareVerCode: 14, maxChannels: 8, buildDate: '31 Oct 2026', manufacturer: 'FakeBoard', firmwareVersion: 'v1.99'));
      case Cmd.getDeviceTime:
        _emit(encodeCurrTime(_radioNow));
      case Cmd.setDeviceTime:
        final want = ByteData.sublistView(f).getUint32(1, Endian.little);
        _emit(want >= _radioNow ? encodeOk() : encodeErr(ErrCode.illegalArg));
      case Cmd.syncNextMessage:
        _emit(_queue.isEmpty ? encodeNoMoreMessages() : _queue.removeAt(0));
      case Cmd.getContactByKey:
        final k = toHex(f.sublist(1, 33));
        if (contacts.contains(k)) {
          _emit(encodeContactFrame(f.sublist(1, 33), type: AdvType.repeater, name: repeaters[k]?.name ?? ''));
        } else {
          _emit(encodeErr(ErrCode.notFound));
        }
      case Cmd.addUpdateContact:
        if (contactsFull) {
          _emit(encodeErr(ErrCode.tableFull));
        } else {
          contacts.add(toHex(f.sublist(1, 33)));
          _emit(encodeOk());
        }
      case Cmd.sendLogin:
        _login(f);
      case Cmd.logout:
        final k = toHex(f.sublist(1, 33));
        repeaters[k]?._admins.remove(keyHex);
        _emit(encodeOk());
      case Cmd.sendStatusReq:
        final r = repeaters[toHex(f.sublist(1, 33))];
        if (r == null || !contacts.contains(r.keyHex)) {
          _emit(encodeErr(ErrCode.notFound));
        } else {
          _emit(encodeSent());
          if (r.inRange) {
            _emit(encodeStatusResponse(r.key, const RepeaterStatus(
                battMilliVolts: 4100, txQueueLen: 0, noiseFloorDbm: -112, lastRssiDbm: -90, packetsRecv: 10, packetsSent: 5, airTimeSecs: 7, upTimeSecs: 3600, lastSnrDb: 6.5)));
          }
        }
      case Cmd.sendTxtMsg:
        _txt(f);
      case Cmd.signStart:
        if (signUnsupported) {
          _emit(encodeErr(ErrCode.unsupportedCmd));
        } else {
          _signing = true;
          _signData.clear();
          _emit(encodeSignStartResponse(8192));
        }
      case Cmd.signData:
        if (!_signing) {
          _emit(encodeErr(ErrCode.badState));
        } else {
          _signData.add(f.sublist(1));
          _emit(encodeOk());
        }
      case Cmd.signFinish:
        if (!_signing) {
          _emit(encodeErr(ErrCode.badState));
        } else {
          _signing = false;
          final data = _signData.toBytes();
          final sig = await cr.Ed25519().sign(data, keyPair: keyPair);
          _emit(encodeSignatureResponse(sig.bytes));
        }
      case Cmd.exportContact:
        _emit(Uint8List.fromList([Resp.exportContact, 0x11, 0x22, ...publicKey]));
      default:
        _emit(encodeErr(ErrCode.unsupportedCmd));
    }
  }

  void _login(Uint8List f) {
    final k = toHex(f.sublist(1, 33));
    final r = repeaters[k];
    if (!contacts.contains(k)) {
      _emit(encodeErr(ErrCode.notFound));
      return;
    }
    // password: after the key, NUL terminated
    var end = 33;
    while (end < f.length && f[end] != 0) {
      end++;
    }
    final pw = utf8.decode(f.sublist(33, end));
    _emit(encodeSent(flood: true, tag: 1, estTimeoutMs: 500));
    if (r == null || !r.inRange) return; // nobody answers
    if (pw == r.adminPassword) {
      r._admins.add(keyHex);
      r._lastTs[keyHex] = _radioNow;
      _emit(encodeLoginSuccess(r.key, isAdmin: true));
    } else if (r.guestPassword != null && pw == r.guestPassword) {
      _emit(encodeLoginSuccess(r.key, isAdmin: false));
    } else if (r.failWithPush) {
      _emit(encodeLoginFail(r.key));
    } // else: a real repeater says nothing to a wrong password
  }

  void _txt(Uint8List f) {
    final prefix = f.sublist(7, 13);
    final r = _byPrefix(prefix);
    if (r == null || !contacts.contains(r.keyHex)) {
      _emit(encodeErr(ErrCode.notFound));
      return;
    }
    final txtType = f[1];
    // A real companion radio (measured Oct 31 2026): CLI_COMMAND (3) and every type but CLI_DATA (1) for CLI is refused at once with ERR 1.
    if (txtType != txtTypeCliData) {
      _emit(encodeErr(ErrCode.unsupportedCmd));
      return;
    }
    final cmd = utf8.decode(f.sublist(13));
    _emit(encodeSent(flood: true, tag: 0, estTimeoutMs: 500));
    if (!r.inRange || !r._admins.contains(keyHex)) return; // out of range, or not an admin: no reply at all
    final ts = ByteData.sublistView(f).getUint32(3, Endian.little);
    final last = r._lastTs[keyHex] ?? 0;
    if (ts <= last) return; // replay (older) or retry (equal): the repeater answers nothing and runs nothing
    r._lastTs[keyHex] = ts;
    r.cliLog.add(cmd);
    String reply;
    if (cmd == 'get name') {
      reply = '> ${r.name}';
    } else if (cmd.startsWith('set name ')) {
      final n = cmd.substring(9);
      if (r.refuseSetName || n.split('').any((c) => invalidNodeNameChars.contains(c))) {
        reply = 'Error, bad chars';
      } else {
        r.name = utf8.decode(utf8Truncate(n, maxNodeNameBytes));
        reply = 'OK';
      }
    } else if (cmd == 'advert') {
      r.adverts.add(r.name);
      reply = 'OK - Advert sent';
    } else {
      reply = 'Unknown command';
    }
    if (r.dropOncePrefix != null && cmd.startsWith(r.dropOncePrefix!)) {
      r.dropOncePrefix = null;
      return;
    }
    if (r.dropAllReplies) return;
    if (r.dropNextReplies > 0) {
      r.dropNextReplies--;
      return;
    }
    _queue.add(encodeContactText(r.key, reply, txtType: txtTypeCliData, timestamp: 1700000000));
    _emit(encodeMsgWaiting());
  }
}

/// The server, for flow tests.
class FakeClaimClient implements CmatClient {
  @override
  final Uri baseUrl = Uri.parse('https://example.org');

  final cr.Ed25519 _ed = cr.Ed25519();
  int _n = 0;
  final Map<String, _Ch> _challenges = {};
  final List<NodeClaim> claims = [];

  /// Everything sent to the server as text, to prove no password ever goes there.
  final List<String> wire = [];

  /// An observer that hears these repeaters' adverts and tells the server.
  final List<FakeRepeater> observed;
  DateTime Function() clock;
  Duration signTtl = const Duration(minutes: 2);
  Duration codeTtl = const Duration(minutes: 15);

  Object? startError;
  CmatException? completeError;
  int statusErrorsLeft = 0;
  int statusCalls = 0;
  final List<String> startedKinds = [];

  /// Only report an advert once this many status polls have happened (a slow ingest).
  int hearAfterPolls = 0;
  bool observerWorks = true;

  FakeClaimClient({this.observed = const [], DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  @override
  Future<ClaimChallenge> claimStart(String driverKey, String pubkey, ClaimKind kind) async {
    wire.add('claim-start $driverKey $pubkey ${kind.name}');
    if (startError != null) throw startError!;
    startedKinds.add(kind.name);
    final id = 'ch${++_n}';
    final now = clock();
    if (kind == ClaimKind.sign) {
      final msg = 'meshsonar-claim:v1:$pubkey:driver:${now.add(signTtl).millisecondsSinceEpoch}';
      _challenges[id] = _Ch(id, pubkey, kind, now.add(signTtl), message: Uint8List.fromList(utf8.encode(msg)));
      return ClaimChallenge(id: id, kind: kind, message: _challenges[id]!.message, expiresAt: now.add(signTtl));
    }
    final code = 'MS7K${10 + _n}';
    _challenges[id] = _Ch(id, pubkey, kind, now.add(codeTtl), code: code);
    return ClaimChallenge(id: id, kind: kind, code: code, expiresAt: now.add(codeTtl), instructions: 'x');
  }

  @override
  Future<NodeClaim> claimComplete(String driverKey, String challengeId, String signatureHex) async {
    wire.add('claim-complete $driverKey $challengeId $signatureHex');
    if (completeError != null) throw completeError!;
    final c = _challenges[challengeId];
    if (c == null || c.used || clock().isAfter(c.expiresAt)) throw const CmatException('gone', status: 410);
    c.used = true;
    final ok = await _ed.verify(c.message!, signature: cr.Signature(fromHex(signatureHex), publicKey: cr.SimplePublicKey(fromHex(c.pubkey), type: cr.KeyPairType.ed25519)));
    if (!ok) throw const CmatException('bad signature', status: 422);
    final claim = NodeClaim(pubkey: c.pubkey, nodeType: ClaimNodeType.companion, method: ClaimMethod.signature, verifiedAt: clock());
    claims
      ..removeWhere((x) => x.pubkey == c.pubkey)
      ..add(claim);
    return claim;
  }

  @override
  Future<ClaimStatus> claimStatus(String driverKey, String challengeId) async {
    wire.add('claim-status $driverKey $challengeId');
    statusCalls++;
    if (statusErrorsLeft > 0) {
      statusErrorsLeft--;
      throw const CmatException('network error: down');
    }
    final c = _challenges[challengeId];
    if (c == null) throw const CmatException('no such challenge', status: 404);
    if (c.claim != null) return ClaimStatus(state: ClaimState.verified, claim: c.claim);
    if (observerWorks && statusCalls > hearAfterPolls) {
      for (final r in observed) {
        if (r.keyHex == c.pubkey && r.adverts.any((n) => n.contains(c.code!))) {
          c.claim = NodeClaim(pubkey: c.pubkey, nodeType: ClaimNodeType.repeater, method: ClaimMethod.advert, verifiedAt: clock(), nodeName: r.name);
          claims
            ..removeWhere((x) => x.pubkey == c.pubkey)
            ..add(c.claim!);
          return ClaimStatus(state: ClaimState.verified, claim: c.claim, seenAdvertAt: clock());
        }
      }
    }
    if (clock().isAfter(c.expiresAt)) return const ClaimStatus(state: ClaimState.expired);
    return const ClaimStatus(state: ClaimState.pending);
  }

  @override
  Future<List<NodeClaim>> myRadios(String driverKey) async => List.of(claims);

  @override
  Future<void> releaseClaim(String driverKey, String pubkey) async {
    claims.removeWhere((c) => c.pubkey == pubkey);
  }

  @override
  Future<NodeClaim> updateClaim(String driverKey, String pubkey, Map<String, Object?> changes) async {
    final i = claims.indexWhere((c) => c.pubkey == pubkey);
    if (i < 0) throw const CmatException('not yours', status: 404);
    final c = claims[i];
    return claims[i] = NodeClaim(
      pubkey: c.pubkey,
      nodeType: c.nodeType,
      method: c.method,
      verifiedAt: c.verifiedAt,
      displayName: changes.containsKey('displayName') ? changes['displayName'] as String? : c.displayName,
      positionPublic: changes.containsKey('positionPublic') ? changes['positionPublic'] as bool? : c.positionPublic,
      notes: changes.containsKey('notes') ? changes['notes'] as String? : c.notes,
      nodeName: c.nodeName,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Ch {
  final String id, pubkey;
  final ClaimKind kind;
  final DateTime expiresAt;
  final Uint8List? message;
  final String? code;
  bool used = false;
  NodeClaim? claim;
  _Ch(this.id, this.pubkey, this.kind, this.expiresAt, {this.message, this.code});
}

/// A clock the flow's waits advance, so a 15-minute window runs in microseconds.
class FakeClock {
  DateTime t;

  /// Real time each wait also takes (zero = instant), for tests that need something else to happen meanwhile.
  Duration realDelay = Duration.zero;
  FakeClock([DateTime? start]) : t = start ?? DateTime.utc(2026, 10, 31, 12);
  DateTime now() => t;
  Future<void> wait(Duration d) async {
    t = t.add(d);
    await Future<void>.delayed(realDelay);
  }
}

Uint8List keyBytes(int seed) => Uint8List.fromList(List<int>.generate(32, (i) => (seed * 31 + i * 7) & 0xff));
