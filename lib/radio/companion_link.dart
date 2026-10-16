// MeshCoreCompanionLink: a CompanionLink over any ByteTransport (BLE, or the simulator).
//
// Command flow follows MeshCore firmware docs/companion_protocol.md ("Command Sequencing": one command at a time,
// wait for the reply, ~5 s timeout) and examples/companion_radio/MyMesh.cpp (MIT, © 2025 Scott Powell /
// rippleradios.com). ensureChannel() is adapted from the MeshMapper web client (MIT, © 2025 MrAlders0n),
// content/wardrive.js ensureChannel()/createWardriveChannel(): find the channel by name, otherwise write it into the
// first empty slot with the hashtag-derived secret. Noise floor comes from CMD_GET_STATS/STATS_TYPE_RADIO as
// MeshMapper's getRadioStats() does.
import 'dart:async';
import 'dart:typed_data';

import '../core/model.dart';
import 'crypto.dart';
import 'protocol.dart';
import 'radio_api.dart';

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

class MeshCoreCompanionLink implements CompanionLink {
  final ByteTransport _transport;
  final Duration timeout;
  final DateTime Function() _clock;
  final String appName;

  final _rx = StreamController<RxPacket>.broadcast();
  final _control = StreamController<ControlPacket>.broadcast();
  final _channelMessages = StreamController<ChannelMsgFrame>.broadcast();
  StreamSubscription<Uint8List>? _sub;

  Future<void> _queue = Future.value();
  Completer<Frame>? _pending;
  bool _closed = false;
  bool _syncing = false;
  bool _statsUnsupported = false;

  int? _maxChannels;
  int? _firmwareVerCode;
  SelfInfo? _self;
  final Map<int, Uint8List> _secrets = {};
  int _lastSentTs = 0;

  MeshCoreCompanionLink(this._transport,
      {this.timeout = const Duration(seconds: 5), DateTime Function()? clock, this.appName = 'MeshSonar'})
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

    String? firmware;
    try {
      final di = await _command(encodeDeviceQuery());
      if (di is DeviceInfoFrame) {
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
    if (f is OkFrame || (f is UnknownFrame && f.code == Resp.sent)) {
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

  /// Sends a zero-hop NODE_DISCOVER_REQ for repeaters (firmware v8+). Answers arrive on [controlPackets].
  Future<void> sendDiscoverRequest(int tag) async {
    final f = await _command(encodeSendControlData(encodeDiscoverRequestPayload(tag)));
    if (f is! OkFrame) _fail('discover request', f);
  }

  Future<void> _drainMessages() async {
    if (_syncing) return;
    _syncing = true;
    try {
      for (var n = 0; n < 256 && isConnected; n++) {
        final f = await _command(encodeSyncNextMessage());
        if (f is ChannelMsgFrame) {
          if (!_channelMessages.isClosed) _channelMessages.add(f);
          continue;
        }
        if (f is ContactMsgFrame) continue;
        break; // NO_MORE_MESSAGES, error, or anything else
      }
    } catch (_) {
      // best effort
    } finally {
      _syncing = false;
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
