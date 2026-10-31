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
import 'crypto.dart';
import 'protocol.dart';
import 'radio_api.dart';
import 'radio_health.dart';

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

class MeshCoreCompanionLink implements CompanionLink, RadioStatsSource, ClaimRadio {
  final ByteTransport _transport;
  final Duration timeout;
  final DateTime Function() _clock;
  final String appName;

  /// How long login / CLI / status wait for the repeater's answer after the radio took the command. Null = what the
  /// radio estimates for the trip, doubled, between 15 s and 60 s. Tests set a short one.
  final Duration? claimReplyTimeout;

  final _rx = StreamController<RxPacket>.broadcast();
  final _control = StreamController<ControlPacket>.broadcast();
  final _channelMessages = StreamController<ChannelMsgFrame>.broadcast();

  /// Login/status pushes and contact texts (a repeater's CLI replies), for the claim calls below.
  final _claimEvents = StreamController<Frame>.broadcast();
  StreamSubscription<Uint8List>? _sub;

  Future<void> _queue = Future.value();
  Completer<Frame>? _pending;
  bool _closed = false;
  bool _syncing = false;
  bool _statsUnsupported = false;

  /// GET_STATS sub-types (and -1 = GET_BATT_AND_STORAGE) this radio said it does not support; never asked again.
  final Set<int> _unsupported = {};

  int? _maxChannels;
  int? _firmwareVerCode;
  DeviceInfoFrame? _deviceInfo;
  int? _maxTxDbm;
  SelfInfo? _self;
  final Map<int, Uint8List> _secrets = {};
  int _lastSentTs = 0;

  MeshCoreCompanionLink(this._transport,
      {this.timeout = const Duration(seconds: 5), DateTime Function()? clock, this.appName = 'MeshSonar', this.claimReplyTimeout})
      : _clock = clock ?? DateTime.now {
    _sub = _transport.incoming.listen(_onFrame, onDone: _onTransportDone, onError: (Object _) {});
  }

  /// Frames from the companion that aren't a reply to a command.
  Stream<ControlPacket> get controlPackets => _control.stream;

  /// Channel messages drained from the radio's offline queue (after PUSH_CODE_MSG_WAITING).
  Stream<ChannelMsgFrame> get channelMessages => _channelMessages.stream;

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
        unawaited(_drainMessages());
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
    _rx.close();
    _control.close();
    _channelMessages.close();
    _claimEvents.close();
  }

  /// Sends one command and waits for its reply. Commands are strictly serialised.
  Future<Frame> _command(Uint8List frame) {
    final result = _queue.then((_) => _send(frame));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

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
    unawaited(_drainMessages());
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
  Future<void> sendChannelText(int channelIndex, String text) async {
    var ts = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    // Keep timestamps strictly increasing so every send has its own (encrypted) fingerprint.
    if (ts <= _lastSentTs) ts = _lastSentTs + 1;
    final f = await _command(encodeSendChannelText(channelIndex, ts, text));
    // Firmware replies RESP_CODE_OK (MyMesh.cpp ~1196); accept RESP_CODE_SENT too, as the docs describe.
    if (f is OkFrame || f is SentFrame || (f is UnknownFrame && f.code == Resp.sent)) {
      _lastSentTs = ts;
      return;
    }
    _fail('send channel text', f);
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
    final result = _queue.then((_) async {
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
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Sends a zero-hop NODE_DISCOVER_REQ for repeaters (firmware v8+). Answers arrive on [controlPackets].
  Future<void> sendDiscoverRequest(int tag) async {
    final f = await _command(encodeSendControlData(encodeDiscoverRequestPayload(tag)));
    if (f is! OkFrame) _fail('discover request', f);
  }

  Future<void> _drainMessages() async {
    if (_syncing) {
      _drainAgain = true; // a message was queued while we were finishing: go round once more
      return;
    }
    _syncing = true;
    try {
      do {
        _drainAgain = false;
        await _drainOnce();
      } while (_drainAgain && isConnected);
    } finally {
      _syncing = false;
    }
  }

  bool _drainAgain = false;

  Future<void> _drainOnce() async {
    try {
      for (var n = 0; n < 256 && isConnected; n++) {
        final f = await _command(encodeSyncNextMessage());
        if (f is ChannelMsgFrame) {
          if (!_channelMessages.isClosed) _channelMessages.add(f);
          continue;
        }
        if (f is ContactTextFrame) {
          if (!_claimEvents.isClosed) _claimEvents.add(f);
          continue;
        }
        if (f is ContactMsgFrame) continue;
        break; // NO_MORE_MESSAGES, error, or anything else
      }
    } catch (_) {
      // best effort
    }
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
      return await _command(frame);
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

  // A repeater keeps the timestamp of the last thing a client sent (its login, stamped by the RADIO's clock) and ignores any
  // command that is not strictly newer (equal = "retry": no reply; older = "replay": dropped, no reply either). The radio
  // refuses to set its clock backwards, so it can be ahead of the phone and a command stamped by the phone's clock is
  // silently ignored. Commands are therefore stamped from the radio's own clock and always increase.
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
      final sent = await _claimCommand(encodeSendTxt(txtTypeCliCommand, 0, ts, fromHex(pubkeyHex), command), 'cli');
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
