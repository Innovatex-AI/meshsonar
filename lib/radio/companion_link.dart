// MeshCoreCompanionLink: a CompanionLink over any ByteTransport (BLE, or the simulator).
//
// Command flow follows MeshCore firmware docs/companion_protocol.md ("Command Sequencing": one command at a time,
// wait for the reply, ~5 s timeout) and examples/companion_radio/MyMesh.cpp (MIT, © 2025 Scott Powell /
// rippleradios.com). ensureChannel() is adapted from the MeshMapper web client (MIT, © 2025 MrAlders0n),
// content/wardrive.js ensureChannel()/createWardriveChannel(): find the channel by name, otherwise write it into the
// first empty slot with the hashtag-derived secret. Noise floor comes from CMD_GET_STATS/STATS_TYPE_RADIO as
// MeshMapper's getRadioStats() does.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/drive_context.dart';
import '../core/model.dart';
import 'claim_radio.dart';
import 'command_queue.dart';
import 'crypto.dart';
import 'inbound.dart';
import 'message_sync.dart';
import 'protocol.dart';
import 'radio_api.dart';
import 'radio_health.dart';
import 'scope_guard.dart';

class CompanionException implements Exception {
  final String message;
  final int? errCode;
  CompanionException(this.message, [this.errCode]);
  @override
  String toString() => 'CompanionException: $message${errCode == null ? '' : ' (err $errCode)'}';
}

/// A zero-hop control packet the radio heard (PUSH_CODE_CONTROL_DATA), e.g. a NODE_DISCOVER_RESP.
class ControlPacket {
  final DateTime at;
  final double snrDb;
  final int rssiDbm;
  final int pathLen;
  final Uint8List payload;
  const ControlPacket(this.at, this.snrDb, this.rssiDbm, this.pathLen, this.payload);
}

class MeshCoreCompanionLink implements CompanionLink, RadioStatsSource, ClaimRadio, MessageSource {
  final ByteTransport _transport;
  final Duration timeout;
  final DateTime Function() _clock;
  final String appName;

  /// How long login / CLI / status wait for the repeater's answer after the radio took the command. Null = what the
  /// radio estimates for the trip, doubled, between 15 s and 60 s. Tests set a short one.
  final Duration? claimReplyTimeout;

  final _rx = StreamController<RxPacket>.broadcast();
  final _control = StreamController<ControlPacket>.broadcast();

  /// Pushes that are not replies and not rx log / control / claim traffic: DM confirmations, path updates, adverts,
  /// contact table notices. The session turns them into [RadioEvent]s.
  final _unsolicited = StreamController<Frame>.broadcast();

  /// Login/status pushes and contact texts (a repeater's CLI replies), for the claim calls below.
  final _claimEvents = StreamController<Frame>.broadcast();
  StreamSubscription<Uint8List>? _sub;

  final CommandQueue _commands = CommandQueue();
  Completer<Frame>? _pending;

  /// While a multi-frame command (GET_CONTACTS) runs, every non-push frame goes here instead of to [_pending].
  void Function(Frame f)? _multi;
  bool _closed = false;
  bool _statsUnsupported = false;

  /// Drains the radio's offline message queue (see message_sync.dart). The link feeds it PUSH_MSG_WAITING and starts it
  /// after [start]; the session sets its persister and listens to its messages.
  late final MessageSync sync;

  /// Sets the flood scope right before a flood send (scope_guard.dart).
  final ScopeGuard scopeGuard = ScopeGuard();

  /// GET_STATS sub-types (and -1 = GET_BATT_AND_STORAGE) this radio said it does not support; never asked again.
  final Set<int> _unsupported = {};

  int? _maxChannels;
  int? _firmwareVerCode;
  DeviceInfoFrame? _deviceInfo;
  int? _maxTxDbm;
  SelfInfo? _self;
  SelfInfoFrame? _selfFrame;
  final Map<int, Uint8List> _secrets = {};
  int _lastSentTs = 0;
  int _lastAttemptTs = 0;

  MeshCoreCompanionLink(this._transport,
      {this.timeout = const Duration(seconds: 5),
      DateTime Function()? clock,
      this.appName = 'MeshSonar',
      this.claimReplyTimeout,
      Duration messagePollInterval = const Duration(seconds: 5)})
      : _clock = clock ?? DateTime.now {
    sync = MessageSync(this, clock: _clock, pollInterval: messagePollInterval)..onContactText = _onContactText;
    _sub = _transport.incoming.listen(_onFrame, onDone: _onTransportDone, onError: (Object _) {});
  }

  void _onContactText(ContactTextFrame f) {
    if (!_claimEvents.isClosed) _claimEvents.add(f);
  }

  /// Unsolicited pushes for the session (see [_unsolicited]).
  Stream<Frame> get unsolicited => _unsolicited.stream;

  /// Text messages drained from the radio, after the persister (if any) saved them.
  Stream<InboundMessage> get inboundMessages => sync.messages;

  /// DEVICE_INFO as read by [start]; null before, or on firmware too old to answer.
  DeviceInfoFrame? get deviceInfo => _deviceInfo;

  /// Commands waiting behind the one in flight.
  int get commandsPending => _commands.pending;

  /// Frames from the companion that aren't a reply to a command.
  Stream<ControlPacket> get controlPackets => _control.stream;

  SelfInfo? get selfInfo => _self;

  /// FIRMWARE_VER_CODE from DEVICE_INFO (MyMesh.h line 7), or null before start().
  int? get firmwareVerCode => _firmwareVerCode;

  /// The radio's identity beyond Drive Format v1 (stream 7 category `radio_config`): board model string (DEVICE_INFO
  /// manufacturer), firmware ver code + build date, max TX power (SELF_INFO), path hash mode. Null before start().
  CompanionDetails? get companionDetails {
    final di = _deviceInfo;
    if (di == null && _maxTxDbm == null) return null;
    final d = CompanionDetails(
      model: di?.manufacturer,
      fwCode: di?.firmwareVerCode,
      fwBuild: di?.buildDate,
      maxTxDbm: _maxTxDbm,
      pathHashMode: di?.pathHashMode,
    );
    return d.isEmpty ? null : d;
  }

  /// The secret of a channel this link has read or written, for decrypting echoes.
  Uint8List? channelSecret(int index) => _secrets[index];

  /// Timestamp (epoch seconds) put in the most recent CMD_SEND_CHANNEL_TXT_MSG; it is inside the encrypted
  /// payload, so echoes of that exact send can be told apart from earlier ones.
  int get lastSentTimestamp => _lastSentTs;

  /// Timestamp of the most recent channel or contact send ATTEMPT, accepted or not (a timeout leaves the outcome unknown).
  int get lastAttemptTimestamp => _lastAttemptTs;

  @override
  bool get isConnected => !_closed && _transport.isConnected;

  // ---------------------------------------------------------------- frame handling

  void _onFrame(Uint8List data) {
    if (data.isEmpty) return;
    if (data[0] == Push.telemetryResponse) {
      final w = _telemetryWaiter;
      final self = _self?.publicKey;
      final t = decodeSelfTelemetryPush(data, selfPrefix: self == null || self.length < 12 ? null : fromHex(self.substring(0, 12)));
      if (t != null && w != null && !w.isCompleted) {
        _telemetryWaiter = null;
        w.complete(t);
      }
      return;
    }
    Frame f;
    try {
      f = decodeFrame(data);
    } catch (_) {
      return; // malformed frame: ignore rather than kill the link
    }
    if (isPushCode(data[0])) {
      _onPush(f);
      return;
    }
    final multi = _multi;
    if (multi != null) {
      multi(f);
      return;
    }
    final p = _pending;
    if (p != null && !p.isCompleted) {
      _pending = null;
      p.complete(f);
    }
    // A reply with no command waiting (e.g. a late reply after a timeout) is dropped.
  }

  void _onPush(Frame f) {
    final now = _clock();
    switch (f) {
      case LogRxDataPush():
        if (!_rx.isClosed) _rx.add(RxPacket(at: now, raw: f.raw, snrDb: f.snrDb, rssiDbm: f.rssiDbm.toDouble()));
      case ControlDataPush():
        if (!_control.isClosed) _control.add(ControlPacket(now, f.snrDb, f.rssiDbm, f.pathLen, f.payload));
      case LoginSuccessPush() || LoginFailPush() || StatusResponsePush():
        if (!_claimEvents.isClosed) _claimEvents.add(f);
      case MsgWaitingPush():
        // Drain the radio's offline queue so it never fills (MyMesh.cpp addToOfflineQueue ~224).
        sync.requestDrain();
      case SendConfirmedPush() ||
            PathUpdatedPush() ||
            AdvertPush() ||
            NewAdvertPush() ||
            ContactDeletedPush() ||
            ContactsFullPush():
        if (!_unsolicited.isClosed) _unsolicited.add(f);
      default:
        break;
    }
  }

  void _onTransportDone() {
    _shutdown(StateError('radio disconnected'));
  }

  void _shutdown(Object reason) {
    if (_closed) return;
    _closed = true;
    final p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) p.completeError(reason);
    final m = _multi;
    _multi = null;
    if (m != null) m(const ErrFrame(null)); // fails a running GET_CONTACTS at once
    sync.dispose();
    _rx.close();
    _control.close();
    _unsolicited.close();
    _claimEvents.close();
  }

  /// Sends one command and waits for its reply. Commands are strictly serialised; a waiting command with a lower
  /// [priority] number goes first ([CommandPriority]).
  Future<Frame> _command(Uint8List frame, {int priority = CommandPriority.normal}) =>
      _commands.run(() => _send(frame), priority: priority);

  Future<Frame> _send(Uint8List frame) async {
    if (!isConnected) throw StateError('radio not connected');
    final c = Completer<Frame>();
    _pending = c;
    try {
      await _transport.send(frame);
    } catch (e) {
      if (identical(_pending, c)) _pending = null;
      rethrow;
    }
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      if (identical(_pending, c)) _pending = null;
      throw TimeoutException('radio did not answer command ${frame[0]}', timeout);
    }
  }

  static Never _fail(String what, Frame f) {
    if (f is ErrFrame) throw CompanionException('$what failed', f.code);
    throw CompanionException('$what: unexpected reply ${f.runtimeType}');
  }

  // ---------------------------------------------------------------- CompanionLink

  @override
  Future<SelfInfo> start() async {
    final si = await _command(encodeAppStart(appName));
    if (si is! SelfInfoFrame) _fail('app start', si);
    _selfFrame = si;
    _maxTxDbm = si.maxTxPowerDbm > 0 ? si.maxTxPowerDbm : null;

    String? firmware;
    try {
      final di = await _command(encodeDeviceQuery());
      if (di is DeviceInfoFrame) {
        _deviceInfo = di;
        _firmwareVerCode = di.firmwareVerCode;
        _maxChannels = di.maxChannels;
        final v = di.firmwareVersion;
        firmware = (v != null && v.isNotEmpty) ? v : 'ver ${di.firmwareVerCode}';
      }
    } on CompanionException {
      // very old firmware: carry on without device info
    }

    // Set the clock. The firmware refuses to move it backwards (ERR ILLEGAL_ARG) — harmless, ignore.
    final setTime = await _command(encodeSetDeviceTime(_clock().toUtc().millisecondsSinceEpoch ~/ 1000));
    if (setTime is! OkFrame && setTime is! ErrFrame) _fail('set time', setTime);

    final self = SelfInfo(
      publicKey: toHex(si.publicKey),
      name: si.name,
      radio: Radio(
        freqMhz: si.freqKhz > 0 ? si.freqMhz : null,
        bwKhz: si.bwHz > 0 ? si.bwKhz : null,
        sf: si.sf > 0 ? si.sf : null,
        cr: si.cr > 0 ? si.cr : null,
        txDbm: si.txPowerDbm.toDouble(),
      ),
      firmware: firmware,
    );
    _self = self;
    scopeGuard
      ..reset()
      ..firmwareVerCode = _firmwareVerCode;
    sync.requestDrain();
    return self;
  }

  /// Reads one channel slot; null if the index doesn't exist.
  Future<ChannelInfoFrame?> getChannel(int index) async {
    final f = await _command(encodeGetChannel(index));
    if (f is ChannelInfoFrame) return f;
    if (f is ErrFrame && f.code == ErrCode.notFound) return null;
    _fail('get channel $index', f);
  }

  Future<void> setChannel(int index, String name, Uint8List secret16) async {
    final f = await _command(encodeSetChannel(index, name, secret16));
    if (f is! OkFrame) _fail('set channel $index', f);
    _secrets[index] = Uint8List.fromList(secret16);
  }

  @override
  Future<int> ensureChannel(String name) async {
    final wanted = name.trim();
    final derived = wellKnownChannelSecret(wanted);
    final limit = _maxChannels ?? 64;
    int? byName;
    int? bySecret;
    int? firstEmpty;
    for (var i = 0; i < limit; i++) {
      final ch = await getChannel(i);
      if (ch == null) break;
      _secrets[i] = ch.secret;
      if (derived != null && _bytesEqual(ch.secret, derived)) {
        bySecret ??= i;
        break; // the community channel itself: best possible match
      }
      if (byName == null && ch.name.toLowerCase() == wanted.toLowerCase() && !ch.isEmpty) byName = i;
      if (firstEmpty == null && ch.name.isEmpty) firstEmpty = i;
    }
    final found = bySecret ?? byName;
    if (found != null) return found;
    if (derived == null) {
      throw CompanionException('channel "$wanted" is not on the radio and its key is unknown');
    }
    if (firstEmpty == null) {
      throw CompanionException('no free channel slot on the radio for "$wanted"; free one in your companion app');
    }
    await setChannel(firstEmpty, wanted, derived);
    return firstEmpty;
  }

  @override
  Future<void> sendChannelText(int channelIndex, String text, {int priority = CommandPriority.normal, FloodScope? scope}) async {
    final f = await sendChannelFrame(channelIndex, text, priority: priority, scope: scope);
    // Firmware replies RESP_CODE_OK (MyMesh.cpp ~1196); accept RESP_CODE_SENT too, as the docs describe.
    if (f is OkFrame || f is SentFrame || (f is UnknownFrame && f.code == Resp.sent)) return;
    _fail('send channel text', f);
  }

  /// CMD_SEND_CHANNEL_TXT_MSG with the radio's answer returned as it came (OK, or ERR with the code). [scope] is put on the
  /// radio first, in the same command-queue slot, when the scope guard says the radio holds another one; null = leave it
  /// (and clear a scope an earlier send left behind). Timestamps are strictly increasing so every send has its own
  /// (encrypted) fingerprint.
  Future<Frame> sendChannelFrame(int channelIndex, String text, {int priority = CommandPriority.normal, FloodScope? scope}) {
    return _commands.run(() async {
      await _applyScope(scope);
      var ts = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
      if (ts <= _lastSentTs) ts = _lastSentTs + 1;
      _lastAttemptTs = ts;
      final f = await _send(encodeSendChannelText(channelIndex, ts, text));
      if (f is OkFrame || f is SentFrame || (f is UnknownFrame && f.code == Resp.sent)) _lastSentTs = ts;
      return f;
    }, priority: priority);
  }

  /// CMD_SEND_TXT_MSG to a contact. Returns the radio's answer: SENT (flood flag, expected ack, estimated timeout) or ERR.
  /// [timestamp] null = now (strictly increasing); a retry passes the first try's timestamp. Returns the timestamp used.
  Future<(Frame, int)> sendContactFrame(String pubkeyHex, String text,
      {int attempt = 0, int? timestamp, int priority = CommandPriority.user, FloodScope? scope}) {
    return _commands.run(() async {
      await _applyScope(scope);
      var ts = timestamp ?? _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
      if (timestamp == null) {
        if (ts <= _lastSentTs) ts = _lastSentTs + 1;
        _lastSentTs = ts;
      }
      _lastAttemptTs = ts;
      final f = await _send(encodeSendTxt(txtTypePlain, attempt, ts, fromHex(pubkeyHex), text));
      return (f, ts);
    }, priority: priority);
  }

  /// Puts the flood scope a send wants on the radio, inside the send's queue slot (see scope_guard.dart).
  Future<void> _applyScope(FloodScope? wanted) async {
    final step = scopeGuard.commandFor(wanted);
    if (step == null) return;
    final f = await _send(step.cmd);
    if (f is OkFrame) {
      scopeGuard.applied(step.target);
    } else if (f is ErrFrame && (f.code == ErrCode.unsupportedCmd || f.code == ErrCode.illegalArg)) {
      scopeGuard.disable(); // this firmware does not know the command: stop asking
    }
  }

  @override
  Stream<RxPacket> get rxPackets => _rx.stream;

  @override
  Future<double?> noiseFloor() async {
    if (_statsUnsupported || !isConnected) return null;
    try {
      final f = await _command(encodeGetStats(StatsType.radio));
      if (f is RadioStatsFrame) {
        // 0 = not calibrated yet (RadioLibWrappers.cpp starts _noise_floor at 0); that's "unknown", not 0 dBm.
        return f.noiseFloorDbm == 0 ? null : f.noiseFloorDbm.toDouble();
      }
      if (f is ErrFrame && f.code == ErrCode.unsupportedCmd) _statsUnsupported = true;
      return null;
    } on TimeoutException {
      return null;
    } on CompanionException {
      return null;
    }
  }

  // ---------------------------------------------------------------- radio health (RadioStatsSource)
  // Each goes through the same single command queue as everything else. Callers must not ask while a ping is in
  // flight (RadioHealthPoller checks the engine first). ERR unsupported (no GET_STATS at all, firmware < v8) or ERR
  // illegal arg (sub-type unknown to this firmware) is remembered per link so the radio is asked once, not every
  // minute. Timeouts and other errors give null for that call only.

  static const _battKey = -1;
  static const _telemetryKey = -2;
  Completer<SelfTelemetry>? _telemetryWaiter;

  Future<T?> _readStats<T extends Frame>(int key, Uint8List cmd) async {
    if (!isConnected || _unsupported.contains(key)) return null;
    if (key != _battKey && _statsUnsupported) return null;
    try {
      final f = await _command(cmd);
      if (f is T) return f;
      if (f is ErrFrame) {
        if (f.code == ErrCode.unsupportedCmd) {
          if (key == _battKey) {
            _unsupported.add(key);
          } else {
            _statsUnsupported = true;
          }
        } else if (f.code == ErrCode.illegalArg) {
          _unsupported.add(key);
        }
      }
      return null;
    } on TimeoutException {
      return null;
    } on CompanionException {
      return null;
    } on StateError {
      return null;
    }
  }

  @override
  Future<BattAndStorageFrame?> batteryAndStorage() =>
      _readStats<BattAndStorageFrame>(_battKey, encodeGetBattAndStorage());

  @override
  Future<CoreStatsFrame?> coreStats() => _readStats<CoreStatsFrame>(StatsType.core, encodeGetStats(StatsType.core));

  @override
  Future<RadioStatsFrame?> radioStats() => _readStats<RadioStatsFrame>(StatsType.radio, encodeGetStats(StatsType.radio));

  @override
  Future<PacketStatsFrame?> packetStats() =>
      _readStats<PacketStatsFrame>(StatsType.packets, encodeGetStats(StatsType.packets));

  /// The radio's own telemetry (MCU temperature, battery voltage): CMD_SEND_TELEMETRY_REQ "self" form, answered by a
  /// PUSH_CODE_TELEMETRY_RESPONSE instead of a reply (protocol.dart decodeSelfTelemetryPush). Goes through the command
  /// queue like every other read; ERR unsupported = asked once per link; timeout = null for this call.
  @override
  Future<SelfTelemetry?> selfTelemetry() async {
    if (!isConnected || _unsupported.contains(_telemetryKey)) return null;
    return _commands.run(() async {
      if (!isConnected) return null;
      final reply = Completer<Frame>();
      final push = Completer<SelfTelemetry>();
      _pending = reply;
      _telemetryWaiter = push;
      try {
        await _transport.send(encodeSelfTelemetryReq());
        final r = await Future.any<Object>([reply.future, push.future]).timeout(timeout);
        if (r is SelfTelemetry) return r;
        if (r is ErrFrame && (r.code == ErrCode.unsupportedCmd || r.code == ErrCode.illegalArg)) {
          _unsupported.add(_telemetryKey);
        }
        return null;
      } catch (_) {
        return null;
      } finally {
        if (identical(_pending, reply)) _pending = null;
        if (identical(_telemetryWaiter, push)) _telemetryWaiter = null;
      }
    });
  }

  /// Sends a zero-hop NODE_DISCOVER_REQ for repeaters (firmware v8+). Answers arrive on [controlPackets].
  Future<void> sendDiscoverRequest(int tag) async {
    final f = await _command(encodeSendControlData(encodeDiscoverRequestPayload(tag)), priority: CommandPriority.discovery);
    if (f is! OkFrame) _fail('discover request', f);
  }

  // ---------------------------------------------------------------- messages, contacts, channels (for the session)

  /// MessageSource: one SYNC_NEXT_MESSAGE, at admin priority so waiting pings never delay a message off the radio.
  @override
  Future<Frame> syncNextMessage() => _command(encodeSyncNextMessage(), priority: CommandPriority.admin);

  /// GET_CONTACTS (MyMesh.cpp 1238-1258, 2385-2410): CONTACTS_START, N x CONTACT, END_OF_CONTACTS. Each frame must arrive
  /// within [timeout] of the last (the radio sends them at the BLE pace, about 16 a second).
  ///
  /// [onContact] is called for every contact as its frame arrives (with the count so far and the total the radio announced),
  /// so a caller can save progress while a long list is still coming and keep it if the link drops half way.
  Future<ContactListing> getContacts({int since = 0, void Function(RadioContact contact, int received, int total)? onContact}) {
    return _commands.run(() async {
      if (!isConnected) throw StateError('radio not connected');
      final done = Completer<void>();
      final found = <RadioContact>[];
      var total = 0;
      var cursor = 0;
      Timer? idle;
      void arm() {
        idle?.cancel();
        idle = Timer(timeout, () {
          if (!done.isCompleted) done.completeError(TimeoutException('radio stopped sending contacts', timeout));
        });
      }

      _multi = (Frame f) {
        arm();
        switch (f) {
          case ContactsStartFrame():
            total = f.count;
          case ContactFrame():
            final rc = radioContactOf(f);
            found.add(rc);
            if (onContact != null) onContact(rc, found.length, total);
          case EndOfContactsFrame():
            cursor = f.mostRecentLastMod;
            if (!done.isCompleted) done.complete();
          case ErrFrame():
            if (!done.isCompleted) done.completeError(CompanionException('get contacts failed', f.code));
          default:
            break;
        }
      };
      arm();
      try {
        await _transport.send(encodeGetContacts(since: since));
        await done.future;
      } finally {
        idle?.cancel();
        _multi = null;
      }
      return ContactListing(totalOnRadio: total, contacts: found, mostRecentLastMod: cursor);
    }, priority: CommandPriority.admin);
  }

  /// ADD_UPDATE_CONTACT with every field.
  Future<void> addOrUpdateContact(RadioContact c) async {
    final f = await _command(
        encodeAddUpdateContact(fromHex(c.publicKeyHex),
            type: c.type,
            name: c.name,
            flags: c.flags,
            outPathLen: c.outPathLen,
            outPath: c.outPath,
            lastAdvert: c.lastAdvert,
            lat: c.lat ?? 0,
            lon: c.lon ?? 0),
        priority: CommandPriority.admin);
    if (f is ErrFrame && f.code == ErrCode.tableFull) throw const RadioTableFull();
    if (f is! OkFrame) _fail('add contact', f);
  }

  /// The radio's own copy of one contact; null when it does not have it (ERR NOT_FOUND).
  Future<RadioContact?> getContactByKey(String publicKeyHex) async {
    final f = await _command(encodeGetContactByKey(fromHex(publicKeyHex)), priority: CommandPriority.admin);
    if (f is ContactFrame) return radioContactOf(f);
    if (f is ErrFrame && f.code == ErrCode.notFound) return null;
    _fail('get contact', f);
  }

  /// REMOVE_CONTACT. False when the radio did not have it (already gone), true when it removed it.
  Future<bool> removeContact(String publicKeyHex) async {
    final f = await _command(encodeRemoveContact(fromHex(publicKeyHex)), priority: CommandPriority.admin);
    if (f is OkFrame) return true;
    if (f is ErrFrame && f.code == ErrCode.notFound) return false;
    _fail('remove contact', f);
  }

  /// RESET_PATH: the next message to this contact floods. False when the radio does not have the contact.
  Future<bool> resetContactPath(String publicKeyHex) async {
    final f = await _command(encodeResetPath(fromHex(publicKeyHex)), priority: CommandPriority.admin);
    if (f is OkFrame) return true;
    if (f is ErrFrame && f.code == ErrCode.notFound) return false;
    _fail('reset path', f);
  }

  /// The last advert packet the radio heard from this contact (null when it holds none: see [encodeExportContact]).
  Future<Uint8List?> exportContactAdvert(String publicKeyHex) async {
    final f = await _command(encodeExportContact(fromHex(publicKeyHex)), priority: CommandPriority.admin);
    if (f is ExportContactFrame) return f.packet;
    if (f is ErrFrame && f.code == ErrCode.notFound) return null;
    _fail('export contact', f);
  }

  /// IMPORT_CONTACT: hands the radio an advert packet to treat as heard. Throws [CompanionException] (ILLEGAL_ARG) when it
  /// is not a valid advert packet.
  Future<void> importContactAdvert(Uint8List packet) async {
    final f = await _command(encodeImportContact(packet), priority: CommandPriority.admin);
    if (f is! OkFrame) _fail('import contact', f);
  }

  /// SHARE_CONTACT (zero-hop). False when the radio has no stored advert packet for it or no free packet.
  Future<bool> shareContactZeroHop(String publicKeyHex) async {
    final f = await _command(encodeShareContact(fromHex(publicKeyHex)), priority: CommandPriority.admin);
    if (f is OkFrame) return true;
    if (f is ErrFrame && (f.code == ErrCode.tableFull || f.code == ErrCode.notFound)) return false;
    _fail('share contact', f);
  }

  /// SELF_INFO as the radio holds it NOW (APP_START again; harmless mid-session). Another screen may have changed the radio's
  /// "other params" since [start], and SET_OTHER_PARAMS overwrites them all, so never write from a stale copy.
  Future<SelfInfoFrame> _freshSelfFrame() async {
    final cached = _selfFrame;
    if (cached == null) throw StateError('radio not started');
    try {
      final f = await _command(encodeAppStart(appName), priority: CommandPriority.admin);
      if (f is SelfInfoFrame) return _selfFrame = f;
    } on TimeoutException {
      // fall back to what we last knew
    }
    return cached;
  }

  /// What the radio does with a node it hears: from SELF_INFO (manual_add) and AUTOADD_CONFIG. [autoAddSupported] is false
  /// on a firmware without CMD_GET_AUTOADD_CONFIG (the per-type switches then do nothing).
  Future<ContactPolicy> getContactPolicy() async {
    final si = await _freshSelfFrame();
    var cfg = 0; // NodePrefs.h:38 default; also what a firmware without the command does in "ask" mode
    var hops = 0;
    var supported = false;
    final f = await _command(encodeGetAutoAddConfig(), priority: CommandPriority.admin);
    if (f is AutoAddConfigFrame) {
      cfg = f.config;
      hops = f.maxHops;
      supported = true;
    } else if (!(f is ErrFrame && f.code == ErrCode.unsupportedCmd)) {
      _fail('get auto-add config', f);
    }
    return ContactPolicy(
      askBeforeAdding: si.asksBeforeAdding,
      autoAddSupported: supported,
      autoAddChat: (cfg & AutoAddFlags.chat) != 0,
      autoAddRepeaters: (cfg & AutoAddFlags.repeater) != 0,
      autoAddRooms: (cfg & AutoAddFlags.room) != 0,
      autoAddSensors: (cfg & AutoAddFlags.sensor) != 0,
      overwriteOldest: (cfg & AutoAddFlags.overwriteOldest) != 0,
      maxHops: hops,
    );
  }

  /// Writes [policy]. SET_OTHER_PARAMS carries the radio's other settings too, so they are sent back as SELF_INFO gave them.
  Future<void> setContactPolicy(ContactPolicy policy) async {
    final si = await _freshSelfFrame();
    final manual = policy.askBeforeAdding ? (si.manualAdd | 1) : (si.manualAdd & ~1);
    final f = await _command(
        encodeSetOtherParams(manualAdd: manual, telemetryModes: si.telemetryModes, advertLocPolicy: si.advertLocPolicy, multiAcks: si.multiAcks),
        priority: CommandPriority.admin);
    if (f is! OkFrame) _fail('set contact policy', f);
    _selfFrame = SelfInfoFrame(
        advType: si.advType, txPowerDbm: si.txPowerDbm, maxTxPowerDbm: si.maxTxPowerDbm, publicKey: si.publicKey, advLat: si.advLat, advLon: si.advLon,
        freqKhz: si.freqKhz, bwHz: si.bwHz, sf: si.sf, cr: si.cr, name: si.name, multiAcks: si.multiAcks, advertLocPolicy: si.advertLocPolicy,
        telemetryModes: si.telemetryModes, manualAdd: manual);
    if (policy.autoAddSupported) {
      final cfg = (policy.overwriteOldest ? AutoAddFlags.overwriteOldest : 0) |
          (policy.autoAddChat ? AutoAddFlags.chat : 0) |
          (policy.autoAddRepeaters ? AutoAddFlags.repeater : 0) |
          (policy.autoAddRooms ? AutoAddFlags.room : 0) |
          (policy.autoAddSensors ? AutoAddFlags.sensor : 0);
      final g = await _command(encodeSetAutoAddConfig(cfg, maxHops: policy.maxHops), priority: CommandPriority.admin);
      if (g is! OkFrame) _fail('set auto-add config', g);
    }
  }

  /// A radio-side contact frame as the plain type the chat layer uses.
  static RadioContact radioContactOf(ContactFrame f) => RadioContact(
        publicKeyHex: toHex(f.publicKey),
        type: f.type,
        flags: f.flags,
        outPathLen: f.outPathLen,
        outPath: f.outPath,
        name: f.name,
        lastAdvert: f.lastAdvert,
        lat: f.lat == 0 && f.lon == 0 ? null : f.lat,
        lon: f.lat == 0 && f.lon == 0 ? null : f.lon,
        lastMod: f.lastMod,
      );

  /// All channel slots that exist, empty ones included.
  Future<List<RadioChannel>> listChannels() async {
    final out = <RadioChannel>[];
    final limit = _maxChannels ?? 64;
    for (var i = 0; i < limit; i++) {
      final ch = await _channelSlot(i);
      if (ch == null) break;
      _secrets[i] = ch.secret;
      out.add(RadioChannel(i, ch.name, ch.secret));
    }
    return out;
  }

  Future<ChannelInfoFrame?> _channelSlot(int i) async {
    final f = await _command(encodeGetChannel(i), priority: CommandPriority.admin);
    if (f is ChannelInfoFrame) return f;
    if (f is ErrFrame && f.code == ErrCode.notFound) return null;
    _fail('get channel $i', f);
  }


  // ---------------------------------------------------------------- ClaimRadio (login, CLI, status, sign)
  // Frame layouts verified against MeshCore companion_radio/MyMesh.cpp at main (Oct 31 2026); see protocol.dart.

  @override
  String? get selfPublicKey => _self?.publicKey.toLowerCase();

  /// Waits for the first claim event that [test] accepts. Subscribe BEFORE sending the command that causes it.
  _EventWaiter<T> _waitFor<T extends Frame>(bool Function(T f) test) =>
      _EventWaiter<T>(_claimEvents.stream, test, () => const ClaimRadioException(ClaimRadioError.notConnected, 'radio disconnected'));

  void _requireLink() {
    if (!isConnected) throw const ClaimRadioException(ClaimRadioError.notConnected, 'radio not connected');
  }

  /// One command, with radio-side failures mapped to [ClaimRadioException].
  Future<Frame> _claimCommand(Uint8List frame, String what) async {
    _requireLink();
    try {
      return await _command(frame, priority: CommandPriority.admin);
    } on TimeoutException {
      throw ClaimRadioException(ClaimRadioError.silent, 'the radio did not answer ($what)');
    } on StateError {
      throw const ClaimRadioException(ClaimRadioError.notConnected, 'radio disconnected');
    } on CompanionException catch (e) {
      throw ClaimRadioException(ClaimRadioError.radio, e.message, e.errCode);
    }
  }

  static ClaimRadioException _sendFailure(Frame f, String what) {
    if (f is ErrFrame) {
      return switch (f.code) {
        ErrCode.notFound => ClaimRadioException(ClaimRadioError.noContact, '$what: the radio does not know this repeater', f.code),
        ErrCode.tableFull => ClaimRadioException(ClaimRadioError.noContact, '$what: the radio\'s contact list is full', f.code),
        ErrCode.unsupportedCmd => ClaimRadioException(ClaimRadioError.unsupported, '$what: this firmware does not support it', f.code),
        _ => ClaimRadioException(ClaimRadioError.radio, '$what failed', f.code),
      };
    }
    return ClaimRadioException(ClaimRadioError.radio, '$what: unexpected reply ${f.runtimeType}');
  }

  @override
  Future<Uint8List> sign(Uint8List data) async {
    final start = await _claimCommand(encodeSignStart(), 'sign start');
    if (start is! SignStartFrame) throw _sendFailure(start, 'sign start');
    if (data.length > start.maxLen) {
      throw ClaimRadioException(ClaimRadioError.radio, 'the message is longer than the radio signs (${start.maxLen} bytes)');
    }
    for (var at = 0; at < data.length; at += _signChunk) {
      final end = at + _signChunk < data.length ? at + _signChunk : data.length;
      final f = await _claimCommand(encodeSignData(data.sublist(at, end)), 'sign data');
      if (f is! OkFrame) throw _sendFailure(f, 'sign data');
    }
    final fin = await _claimCommand(encodeSignFinish(), 'sign finish');
    if (fin is! SignatureFrame) throw _sendFailure(fin, 'sign finish');
    return fin.signature;
  }

  static const _signChunk = 120;

  /// The radio's own advert packet (CMD_EXPORT_CONTACT with no key).
  Future<Uint8List> exportSelfAdvert() async {
    final f = await _claimCommand(encodeExportSelfContact(), 'export contact');
    if (f is! ExportContactFrame) throw _sendFailure(f, 'export contact');
    return f.packet;
  }

  @override
  Future<void> ensureContact(String pubkeyHex, {required int nodeType, String name = ''}) async {
    final key = fromHex(pubkeyHex);
    final have = await _claimCommand(encodeGetContactByKey(key), 'get contact');
    if (have is ContactFrame) return;
    if (have is! ErrFrame || have.code != ErrCode.notFound) throw _sendFailure(have, 'get contact');
    final add = await _claimCommand(encodeAddUpdateContact(key, type: nodeType, name: name), 'add contact');
    if (add is! OkFrame) throw _sendFailure(add, 'add contact');
  }

  Duration _waitFromSent(SentFrame sent, Duration? override) {
    if (override != null) return override;
    if (claimReplyTimeout != null) return claimReplyTimeout!;
    final ms = sent.estTimeoutMs * 2;
    return Duration(milliseconds: ms.clamp(15000, 60000));
  }

  @override
  Future<RemoteLogin> login(String pubkeyHex, String password, {Duration? timeout}) async {
    final prefix = pubkeyHex.substring(0, 12).toLowerCase();
    final waiter = _waitFor<Frame>((f) => (f is LoginSuccessPush && f.prefixHex == prefix) || (f is LoginFailPush && f.prefixHex == prefix));
    try {
      final sent = await _claimCommand(encodeSendLogin(fromHex(pubkeyHex), password), 'login');
      if (sent is! SentFrame) throw _sendFailure(sent, 'login');
      final f = await waiter.wait(_waitFromSent(sent, timeout), 'the repeater did not answer the login');
      if (f is LoginSuccessPush) {
        // The repeater now holds the radio's login timestamp and ignores any command that is not strictly newer. Re-read the
        // radio's clock (it is at least that late) and start this repeater's command counter from it.
        _radioClockOffsetSecs = null;
        _lastCliTs.remove(pubkeyHex.toLowerCase());
        final seed = await _cliTimestamp(pubkeyHex.toLowerCase());
        _lastCliTs[pubkeyHex.toLowerCase()] = seed;
        return RemoteLogin(isAdmin: f.isAdmin, firmwareLevel: f.firmwareLevel);
      }
      throw const ClaimRadioException(ClaimRadioError.radio, 'the repeater refused the login');
    } finally {
      waiter.cancel();
    }
  }

  @override
  Future<void> logout(String pubkeyHex) async {
    try {
      await _claimCommand(encodeLogout(fromHex(pubkeyHex)), 'logout');
    } catch (_) {}
  }

  // Defence in depth: a repeater keeps the timestamp of the last thing a client sent (its login, stamped by the RADIO's clock)
  // and ignores any command that is not strictly newer. The radio refuses to set its clock backwards, so it can be ahead of
  // the phone. Commands are therefore stamped from the radio's own clock and always increase. (The real bug behind "could not
  // read the repeater's name" was the text type: see txtTypeCliData.)
  int? _radioClockOffsetSecs;
  final Map<String, int> _lastCliTs = {};

  Future<int> _cliTimestamp(String pubkeyHex) async {
    final phoneNow = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    if (_radioClockOffsetSecs == null) {
      try {
        final f = await _claimCommand(encodeGetDeviceTime(), 'radio clock');
        _radioClockOffsetSecs = f is CurrTimeFrame ? f.epochSecs - phoneNow : 0;
      } on ClaimRadioException catch (e) {
        if (e.kind == ClaimRadioError.notConnected) rethrow;
        _radioClockOffsetSecs = 0; // an old firmware without GET_DEVICE_TIME: the phone's clock is the best guess
      }
    }
    final last = _lastCliTs[pubkeyHex] ?? 0;
    final ts = math.max(phoneNow + _radioClockOffsetSecs!, last + 1);
    _lastCliTs[pubkeyHex] = ts;
    return ts;
  }

  @override
  Future<String> runCli(String pubkeyHex, String command, {Duration? timeout}) async {
    final prefix = pubkeyHex.substring(0, 12).toLowerCase();
    final waiter = _waitFor<ContactTextFrame>((f) => f.prefixHex == prefix && (f.txtType == txtTypeCliData || f.txtType == txtTypeCliCommand));
    try {
      final ts = await _cliTimestamp(pubkeyHex.toLowerCase());
      final sent = await _claimCommand(encodeSendTxt(txtTypeCliData, 0, ts, fromHex(pubkeyHex), command), 'cli');
      if (sent is! SentFrame) throw _sendFailure(sent, 'cli');
      final reply = await waiter.wait(_waitFromSent(sent, timeout), 'the repeater did not reply to "${command.split(' ').first}"');
      return reply.text.trim();
    } finally {
      waiter.cancel();
    }
  }

  @override
  Future<RepeaterStatus?> status(String pubkeyHex, {Duration? timeout}) async {
    final prefix = pubkeyHex.substring(0, 12).toLowerCase();
    final waiter = _waitFor<StatusResponsePush>((f) => f.prefixHex == prefix);
    try {
      final sent = await _claimCommand(encodeSendStatusReq(fromHex(pubkeyHex)), 'status');
      if (sent is! SentFrame) return null;
      return (await waiter.wait(_waitFromSent(sent, timeout), 'no status')).status;
    } on ClaimRadioException {
      return null;
    } finally {
      waiter.cancel();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _shutdown(StateError('link closed'));
    await _sub?.cancel();
    try {
      await _transport.disconnect();
    } catch (_) {}
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}


/// One-shot wait for a claim event; the timer only starts in [wait], so the subscription can be made before the
/// command goes out.
class _EventWaiter<T extends Frame> {
  final Completer<T> _done = Completer<T>();
  late final StreamSubscription<Frame> _sub;
  Timer? _timer;

  _EventWaiter(Stream<Frame> events, bool Function(T f) test, ClaimRadioException Function() onClosed) {
    _sub = events.listen((f) {
      if (f is T && !_done.isCompleted && test(f)) _done.complete(f);
    }, onDone: () {
      if (!_done.isCompleted) _done.completeError(onClosed());
    });
    // a waiter nobody awaited (command failed first) must not report an unhandled error
    _done.future.then<void>((_) {}, onError: (_) {});
  }

  Future<T> wait(Duration timeout, String silentMessage) {
    _timer = Timer(timeout, () {
      if (!_done.isCompleted) _done.completeError(ClaimRadioException(ClaimRadioError.silent, silentMessage));
    });
    return _done.future;
  }

  void cancel() {
    _timer?.cancel();
    _sub.cancel();
  }
}
