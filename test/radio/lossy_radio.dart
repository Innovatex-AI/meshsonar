// A scripted, lossy test radio (build 77, redesign round 3): a companion radio AND a mesh that can fail the way real ones
// do. The tests of builds up to 76 ran against a radio that always confirmed in about a second, never lost a frame and had
// no mesh, so they could not see why messages failed.
//
// What it models, from the firmware (companion v1.18.0):
//   * the commands delivery uses: DEVICE_QUERY, APP_START, SET/GET_DEVICE_TIME, SEND_TXT_MSG, RESET_PATH,
//     ADD_UPDATE_CONTACT, GET_CONTACT_BY_KEY, REMOVE_CONTACT, GET_CONTACTS, SYNC_NEXT_MESSAGE, GET_AUTOADD_CONFIG;
//   * the radio decides direct or flood from ITS route to the contact (out_path_len 0xFF = flood);
//   * the confirmation code is SHA-256(timestamp, try & 3, text, own key)[0..4];
//   * a packet's identity is what goes on the air: timestamp, try & 3, text and, above try 3, the whole try number at the
//     tail. A packet the mesh has already carried is DROPPED: it reaches nobody and is never confirmed. (That is the
//     defect M1 of build 76: its try 5 and every manual retry were packets the mesh had seen.)
//
// What a test can script: lose or delay the reply to any command, confirm late, confirm only some tries (so a confirmation
// is for an earlier try), never confirm, answer "busy" (TABLE_FULL), "not a contact" (NOT_FOUND), a full contact table,
// duplicate incoming messages, a contact list that stalls, a clock ahead of the phone.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_api.dart';

class LossyContact {
  final Uint8List key;
  int type;
  int flags;
  String name;

  /// 0xFF = the radio has no route (it floods).
  int outPathLen;
  Uint8List outPath;
  int lastAdvert;
  double lat;
  double lon;
  int lastMod;
  LossyContact(this.key, {this.type = 1, this.flags = 0, this.name = 'Bob', this.outPathLen = 0xFF, Uint8List? outPath, this.lastAdvert = 0, this.lat = 0, this.lon = 0, this.lastMod = 1})
      : outPath = outPath ?? Uint8List(0);
  String get hex => toHex(key);
  bool get hasRoute => outPathLen != 0xFF;
}

/// One CMD_SEND_TXT_MSG the radio was given.
class LossySend {
  /// Position among the plain direct messages given to the radio, from 0.
  final int ordinal;

  /// The whole command frame, byte for byte.
  final Uint8List frame;
  final String contactHex;

  /// The try number byte exactly as the app sent it.
  final int attempt;
  final int timestamp;
  final String text;

  /// How the radio sent it: by flood (no route) or direct.
  final bool flood;

  /// The confirmation code the radio expects.
  final int ack;

  /// The mesh had already carried this exact packet, so it went nowhere.
  final bool droppedAsDuplicate;
  const LossySend(this.ordinal, this.frame, this.contactHex, this.attempt, this.timestamp, this.text, this.flood, this.ack, this.droppedAsDuplicate);
}

class LossyRadio implements ByteTransport {
  final Uint8List publicKey;
  final String name;
  final _in = StreamController<Uint8List>.broadcast();
  bool _connected = true;
  final List<Timer> _timers = [];

  /// The radio's contact table, by key hex.
  final Map<String, LossyContact> contacts = {};
  int maxContacts;

  /// Every command frame the app wrote, in order.
  final List<Uint8List> commands = [];

  /// Every plain direct message the radio was given.
  final List<LossySend> sends = [];

  /// Keys RESET_PATH was sent for, in order, with the position in [commands].
  final List<({String key, int at})> resets = [];

  /// Contacts written with ADD_UPDATE_CONTACT: key, path byte and path as written.
  final List<({String key, int outPathLen, Uint8List outPath, int flags})> contactWrites = [];

  /// Packets the mesh has carried (the identity is described at the top of this file).
  final Set<String> _air = {};

  /// The radio's estimates (RESP_CODE_SENT est_timeout), small so tests are fast.
  int estDirectMs = 40;
  int estFloodMs = 60;

  /// How long after a send its confirmation arrives; null = never. Default: every packet that reached the mesh is
  /// confirmed after 15 ms.
  Duration? Function(LossySend s) confirmAfter = (_) => const Duration(milliseconds: 15);

  /// After a confirmed FLOOD the radio learns a route and pushes PATH_UPDATED (the reciprocal path exchange).
  bool learnRouteOnFloodConfirm = false;

  /// The reply to the next [count] commands with this code is lost (the command is still carried out).
  final Map<int, int> _loseReply = {};

  /// The reply to the next command with this code is held back this long.
  final Map<int, List<Duration>> _delayReply = {};

  /// The next N sends are answered "busy" (ERR TABLE_FULL: no free packet); nothing goes on the air.
  int busySends = 0;

  /// The radio's clock is this many seconds ahead of whatever the phone sets (it then refuses SET_DEVICE_TIME).
  int clockAheadSecs = 0;
  int _clock = 0;

  /// GET_CONTACTS stops sending after this many contacts (the link's idle timeout then ends the read); null = never.
  int? stallContactsAfter;

  /// How long after the stall the next contact frame still arrives (a stray by then).
  Duration stalledContactDelay = const Duration(milliseconds: 250);

  /// Messages waiting in the radio's offline queue (whole reply frames).
  final List<Uint8List> offlineQueue = [];

  /// The app's declared protocol version (DEVICE_QUERY byte 1).
  int appTargetVer = 0;

  LossyRadio({Uint8List? publicKey, this.name = 'Me', this.maxContacts = 100})
      : publicKey = publicKey ?? Uint8List.fromList(List<int>.generate(32, (i) => 0xA0 + (i % 16)));

  String get publicKeyHex => toHex(publicKey);

  // ---------------------------------------------------------------- scripting

  LossyContact addContact(String keyHex, {String name = 'Bob', int type = 1, List<int>? route, int flags = 0, int lastAdvert = 1760000000, double lat = 0, double lon = 0}) {
    final c = LossyContact(fromHex(keyHex),
        name: name, type: type, flags: flags, outPathLen: route == null ? 0xFF : route.length, outPath: route == null ? null : Uint8List.fromList(route), lastAdvert: lastAdvert, lat: lat, lon: lon, lastMod: ++_mod);
    contacts[keyHex.toLowerCase()] = c;
    return c;
  }

  int _mod = 1000;

  void loseReply(int commandCode, {int count = 1}) => _loseReply[commandCode] = (_loseReply[commandCode] ?? 0) + count;
  void delayReply(int commandCode, Duration by) => (_delayReply[commandCode] ??= []).add(by);

  /// Queues an incoming direct message in the radio's offline queue and pushes MSG_WAITING.
  void incomingDm(String fromKeyHex, String text, {required int timestamp, bool push = true}) {
    offlineQueue.add(encodeContactText(fromHex(fromKeyHex), text, txtType: txtTypePlain, timestamp: timestamp, pathLen: 0xFF, v3: appTargetVer >= 3));
    if (push) _emit(encodeMsgWaiting());
  }

  /// A push straight to the app (a confirmation with any code, a path update).
  void push(Uint8List frame, [Duration after = Duration.zero]) => _emit(frame, after);

  /// The bytes of each plain direct message given to the radio, as hex, in order.
  List<String> get sendHex => [for (final s in sends) toHex(s.frame)];

  // ---------------------------------------------------------------- ByteTransport

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> disconnect() async {
    if (!_connected) return;
    _connected = false;
    for (final t in _timers) {
      t.cancel();
    }
    await _in.close();
  }

  void _emit(Uint8List frame, [Duration after = Duration.zero]) {
    if (!_connected) return;
    if (after == Duration.zero) {
      scheduleMicrotask(() {
        if (_connected && !_in.isClosed) _in.add(frame);
      });
    } else {
      _timers.add(Timer(after, () {
        if (_connected && !_in.isClosed) _in.add(frame);
      }));
    }
  }

  /// The reply to command [code]: lost, delayed or sent at once, as scripted.
  void _reply(int code, Uint8List frame) {
    final lose = _loseReply[code] ?? 0;
    if (lose > 0) {
      _loseReply[code] = lose - 1;
      return;
    }
    final d = _delayReply[code];
    if (d != null && d.isNotEmpty) {
      _emit(frame, d.removeAt(0));
      return;
    }
    _emit(frame);
  }

  @override
  Future<void> send(Uint8List frame) async {
    if (!_connected) throw StateError('lossy radio disconnected');
    final f = Uint8List.fromList(frame);
    commands.add(f);
    if (f.isEmpty) return;
    final code = f[0];
    final bd = ByteData.sublistView(f);
    switch (code) {
      case Cmd.deviceQuery:
        if (f.length >= 2) appTargetVer = f[1];
        _reply(code, encodeDeviceInfo(firmwareVerCode: 14, maxContactsHalf: (maxContacts ~/ 2).clamp(1, 255), maxChannels: 8, buildDate: '1 Oct 2026', manufacturer: 'Lossy test radio', firmwareVersion: 'v1.18.0'));
      case Cmd.appStart:
        _reply(code, encodeSelfInfo(txPowerDbm: 20, maxTxPowerDbm: 22, publicKey: publicKey, freqKhz: 910525, bwHz: 62500, sf: 7, cr: 5, name: name));
      case Cmd.setDeviceTime:
        final secs = bd.getUint32(1, Endian.little);
        if (clockAheadSecs > 0) {
          _clock = secs + clockAheadSecs;
          _reply(code, encodeErr(ErrCode.illegalArg)); // refuses to go backwards
        } else {
          _clock = secs;
          _reply(code, encodeOk());
        }
      case Cmd.getDeviceTime:
        _reply(code, encodeCurrTime(_clock));
      case Cmd.syncNextMessage:
        _reply(code, offlineQueue.isEmpty ? encodeNoMoreMessages() : offlineQueue.removeAt(0));
      case Cmd.getContacts:
        final since = f.length >= 5 ? bd.getUint32(1, Endian.little) : 0;
        _emit(encodeContactsStart(contacts.length));
        var n = 0, most = 0;
        for (final c in contacts.values.toList()) {
          if (c.lastMod <= since) continue;
          if (stallContactsAfter != null && n >= stallContactsAfter!) {
            stallContactsAfter = null;
            // the rest arrive late, after the app gave up: strays
            _emit(_contactFrame(c), stalledContactDelay);
            return;
          }
          _emit(_contactFrame(c));
          n++;
          if (c.lastMod > most) most = c.lastMod;
        }
        _emit(encodeEndOfContacts(most));
      case Cmd.getContactByKey:
        final c = contacts[toHex(f.sublist(1, 33))];
        _reply(code, c == null ? encodeErr(ErrCode.notFound) : _contactFrame(c));
      case Cmd.addUpdateContact:
        final key = toHex(f.sublist(1, 33));
        final pathLen = f[35];
        final hops = pathLen == 0xFF ? 0 : (pathLen & 63) * ((pathLen >> 6) + 1);
        final path = Uint8List.fromList(f.sublist(36, 36 + hops));
        contactWrites.add((key: key, outPathLen: pathLen, outPath: path, flags: f[34]));
        final ex = contacts[key];
        if (ex == null && contacts.length >= maxContacts) {
          _reply(code, encodeErr(ErrCode.tableFull));
          return;
        }
        final nameBytes = f.sublist(100, 132);
        final end = nameBytes.indexOf(0);
        final c = ex ?? LossyContact(fromHex(key));
        // The firmware copies the path from the frame without question (updateContactFromFrame, MyMesh.cpp 194-217).
        c
          ..type = f[33]
          ..flags = f[34]
          ..outPathLen = pathLen
          ..outPath = path
          ..name = utf8.decode(end < 0 ? nameBytes : nameBytes.sublist(0, end), allowMalformed: true)
          ..lastAdvert = bd.getUint32(132, Endian.little)
          ..lat = bd.getInt32(136, Endian.little) / 1e6
          ..lon = bd.getInt32(140, Endian.little) / 1e6
          ..lastMod = ++_mod;
        contacts[key] = c;
        _reply(code, encodeOk());
      case Cmd.removeContact:
        _reply(code, contacts.remove(toHex(f.sublist(1, 33))) == null ? encodeErr(ErrCode.notFound) : encodeOk());
      case Cmd.resetPath:
        final key = toHex(f.sublist(1, 33));
        resets.add((key: key, at: commands.length - 1));
        final c = contacts[key];
        if (c == null) {
          _reply(code, encodeErr(ErrCode.notFound));
        } else {
          c
            ..outPathLen = 0xFF
            ..outPath = Uint8List(0);
          _reply(code, encodeOk());
        }
      case Cmd.sendTxtMsg:
        _onSendTxt(f);
      case Cmd.sendChannelTxtMsg:
        _reply(code, encodeOk());
      case Cmd.getAutoAddConfig:
        _reply(code, encodeAutoAddConfig(0, 0));
      case Cmd.setFloodScopeKey:
        _reply(code, encodeOk());
      case Cmd.getChannel:
        _reply(code, encodeErr(ErrCode.notFound));
      default:
        _reply(code, encodeErr(ErrCode.unsupportedCmd));
    }
  }

  Uint8List _contactFrame(LossyContact c) => encodeContactFrame(c.key,
      type: c.type, name: c.name, outPathLen: c.outPathLen, outPath: c.outPath, flags: c.flags, lastAdvert: c.lastAdvert, lat: c.lat, lon: c.lon, lastMod: c.lastMod);

  // CMD_SEND_TXT_MSG as MyMesh.cpp 1132-1177 and BaseChatMesh.cpp 451-490 do it.
  void _onSendTxt(Uint8List f) {
    const code = Cmd.sendTxtMsg;
    if (f.length < 14) return _reply(code, encodeErr(ErrCode.illegalArg));
    final txt = f[1], attempt = f[2];
    final ts = ByteData.sublistView(f).getUint32(3, Endian.little);
    final prefix = toHex(f.sublist(7, 13));
    LossyContact? c;
    for (final x in contacts.values) {
      if (x.hex.startsWith(prefix)) c = x;
    }
    if (c == null) return _reply(code, encodeErr(ErrCode.notFound)); // not a contact
    if (txt != txtTypePlain) return _reply(code, encodeSent(flood: !c.hasRoute, tag: 0, estTimeoutMs: estFloodMs));
    final textBytes = f.sublist(13);
    // composeMsgPacket: too long for this try = MSG_SEND_FAILED = ERR TABLE_FULL.
    if (textBytes.length > 160 || (attempt > 3 && textBytes.length > 158)) return _reply(code, encodeErr(ErrCode.tableFull));
    if (busySends > 0) {
      busySends--;
      return _reply(code, encodeErr(ErrCode.tableFull)); // no free packet
    }
    final text = utf8.decode(textBytes, allowMalformed: true);
    final flood = !c.hasRoute;
    final ack = expectedDmAck(sha256, timestamp: ts, attempt: attempt, text: text, senderPublicKey: publicKey);
    // What is on the air: [ts][attempt & 3][text] and, above try 3, [0][attempt] at the tail.
    final onAir = '$prefix|$ts|${attempt & 3}|${toHex(textBytes)}|${attempt > 3 ? attempt : ''}';
    final dup = !_air.add(onAir);
    final s = LossySend(sends.length, f, c.hex, attempt, ts, text, flood, ack, dup);
    sends.add(s);
    _reply(code, encodeSent(flood: flood, tag: ack, estTimeoutMs: flood ? estFloodMs : estDirectMs));
    if (dup) return; // every node that saw it before drops it: no delivery, no confirmation
    final after = confirmAfter(s);
    if (after == null) return;
    _emit(encodeSendConfirmed(ack, after.inMilliseconds), after);
    if (flood && learnRouteOnFloodConfirm) {
      final contact = c;
      _timers.add(Timer(after + const Duration(milliseconds: 5), () {
        contact
          ..outPathLen = 1
          ..outPath = Uint8List.fromList([0x11])
          ..lastMod = ++_mod;
        _emit(encodePathUpdated(contact.key));
      }));
    }
  }
}
