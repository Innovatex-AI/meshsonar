// LinkRadioSession: a RadioSession over one CompanionLink. Owns the link's TxArbiter and wires the pieces together
// (command queue and message sync live in the link; arbiter, scope and result mapping live here).
//
// Works over any CompanionLink: with a MeshCoreCompanionLink everything is available; over another link (a test fake)
// the chat calls report notConnected / unsupported instead of throwing at random.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/drive_context.dart';
import 'claim_radio.dart';
import 'command_queue.dart';
import 'companion_link.dart';
import 'crypto.dart' show toHex;
import 'inbound.dart';
import 'ping_gate.dart';
import 'protocol.dart';
import 'radio_api.dart';
import 'radio_health.dart';
import 'repeater_radio.dart';
import 'session.dart';
import 'tools/link_tools_radio.dart';
import 'tools/radio_tools.dart';
import 'tools/trace_tool.dart' show TraceStore;
import 'tx_arbiter.dart';

class LinkRadioSession implements RadioSession, RepeaterAdminRadio, RadioStatsSource {
  /// The link this session owns.
  final CompanionLink link;
  final DateTime Function() _clock;
  final TxArbiter arbiter;

  /// Starts out as what [start] returned; refreshed by [adoptSelfInfo].
  SelfInfo? _self;

  final _states = StreamController<LinkState>.broadcast();
  final _events = StreamController<RadioEvent>.broadcast();
  LinkState _state;
  StreamSubscription<Frame>? _unsolicitedSub;
  StreamSubscription<RxPacket>? _rxDoneSub;

  /// ack tag -> contact key hex of recent DMs (the radio's table holds 8).
  final Map<int, String> _acks = {};
  static const int _ackTable = 8;

  /// [info] is what [CompanionLink.start] returned for [link].
  LinkRadioSession(this.link, {SelfInfo? info, DateTime Function()? clock, TxArbiter? arbiter})
      : _clock = clock ?? DateTime.now,
        arbiter = arbiter ?? TxArbiter(clock: clock),
        _self = info,
        _state = link.isConnected ? LinkState.connected : LinkState.disconnected {
    this.arbiter
      ..queueProbe = _probeQueue
      ..airParams = _airParams
      ..senderNameBytes = _nameBytes;
    final mc = _mc;
    if (mc != null) {
      _unsolicitedSub = mc.unsolicited.listen(_onPush, onError: (Object _) {});
    }
    // A closed rx stream means the link is gone (MeshCoreCompanionLink closes it on shutdown).
    _rxDoneSub = link.rxPackets.listen((_) {}, onDone: _linkGone, onError: (Object _) {});
  }

  MeshCoreCompanionLink? get _mc => link is MeshCoreCompanionLink ? link as MeshCoreCompanionLink : null;
  ClaimRadio? get _claim => link is ClaimRadio ? link as ClaimRadio : null;

  /// This session's link can run claims (login, CLI, status, signing).
  bool get supportsClaims => _claim != null;

  void adoptSelfInfo(SelfInfo info) => _self = info;

  void _linkGone() {
    if (_state == LinkState.disconnected) return;
    _state = LinkState.disconnected;
    if (!_states.isClosed) _states.add(_state);
  }

  // ---------------------------------------------------------------- state

  @override
  LinkState get linkState => link.isConnected ? _state : LinkState.disconnected;

  @override
  Stream<LinkState> get linkStates => _states.stream;

  @override
  bool get isConnected => link.isConnected;

  @override
  SelfInfo? get selfInfo => _self ?? _mc?.selfInfo;

  @override
  DeviceLimits? get limits {
    final di = _mc?.deviceInfo;
    if (di == null) return null;
    return DeviceLimits(maxContacts: di.maxContacts, maxChannels: di.maxChannels, firmwareVerCode: di.firmwareVerCode);
  }

  /// The radio's identity beyond Drive Format v1 (see MeshCoreCompanionLink.companionDetails).
  CompanionDetails? get companionDetails => _mc?.companionDetails;

  // ---------------------------------------------------------------- arbiter inputs

  Future<int?> _probeQueue() async => (await _mc?.coreStats())?.queueLen;

  RadioAirParams? _airParams() {
    final r = selfInfo?.radio;
    if (r == null || r.sf == null || r.bwKhz == null) return null;
    return RadioAirParams(r.sf!, r.bwKhz!, r.cr ?? 5);
  }

  int _nameBytes() => utf8.encode(selfInfo?.name ?? '').length;

  @override
  PingGate get pingGate => arbiter;

  @override
  bool get chatActive => arbiter.chatActive;
  @override
  set chatActive(bool value) => arbiter.chatActive = value;

  // ---------------------------------------------------------------- inbound

  @override
  Stream<InboundMessage> get inbound => _mc?.inboundMessages ?? const Stream.empty();

  @override
  Stream<RadioEvent> get events => _events.stream;

  @override
  void setInboundPersister(Future<void> Function(InboundMessage message)? persist) {
    _mc?.sync.persist = persist;
  }

  @override
  Future<void> syncMessagesNow() async => _mc?.sync.drain();

  void _onPush(Frame f) {
    final now = _clock();
    RadioEvent? e;
    switch (f) {
      case SendConfirmedPush():
        e = SendConfirmedEvent(now, ack: f.ack, tripMs: f.tripMs, contactKeyHex: _acks.remove(f.ack));
      case PathUpdatedPush():
        e = PathUpdatedEvent(now, toHex(f.publicKey));
      case AdvertPush():
        e = AdvertHeardEvent(now, toHex(f.publicKey), isNew: false);
      case NewAdvertPush():
        e = AdvertHeardEvent(now, toHex(f.contact.publicKey), isNew: true, contact: MeshCoreCompanionLink.radioContactOf(f.contact));
      case ContactDeletedPush():
        e = ContactTableEvent(now, full: false, deletedKeyHex: toHex(f.publicKey));
      case ContactsFullPush():
        e = ContactTableEvent(now, full: true);
      default:
        break;
    }
    if (e != null && !_events.isClosed) _events.add(e);
  }

  // ---------------------------------------------------------------- outbound

  @override
  int get maxChannelTextBytes {
    final n = _nameBytes();
    return (maxDirectTextBytes - (n + 2)).clamp(0, maxDirectTextBytes);
  }

  static SendResult _failureOf(Frame f, {int ts = 0, int attempt = 0, bool channel = false}) {
    if (f is ErrFrame) {
      return switch (f.code) {
        ErrCode.notFound => SendResult.failed(channel ? SendFailure.noSuchChannel : SendFailure.noSuchContact,
            detail: channel ? 'no such channel, or the radio was busy' : 'the radio does not have this contact', timestamp: ts, attempt: attempt),
        ErrCode.tableFull => SendResult.failed(SendFailure.radioBusy, detail: 'the radio\'s send queue is full', timestamp: ts, attempt: attempt),
        ErrCode.unsupportedCmd => SendResult.failed(SendFailure.unsupported, detail: 'this firmware does not take that', timestamp: ts, attempt: attempt),
        _ => SendResult.failed(SendFailure.radioError, detail: 'radio error ${f.code}', timestamp: ts, attempt: attempt),
      };
    }
    return SendResult.failed(SendFailure.radioError, detail: 'unexpected reply ${f.runtimeType}', timestamp: ts, attempt: attempt);
  }

  @override
  Future<SendResult> sendChannelMessage(int channelIndex, String text, {FloodScope? scope}) async {
    final mc = _mc;
    if (mc == null || !mc.isConnected) return const SendResult.failed(SendFailure.notConnected, detail: 'the radio is not connected');
    final bytes = utf8.encode(text).length;
    if (bytes == 0) return const SendResult.failed(SendFailure.tooLong, detail: 'empty message');
    if (bytes > maxChannelTextBytes) {
      return SendResult.failed(SendFailure.tooLong, detail: '$bytes bytes; this radio\'s name leaves $maxChannelTextBytes');
    }
    chatActive = true;
    arbiter.admitUserSend(arbiter.estimateChannelMs(bytes));
    final max = limits?.maxChannels;
    var retried = false;
    while (true) {
      try {
        final f = await mc.sendChannelFrame(channelIndex, text, priority: CommandPriority.user, scope: scope);
        final ts = mc.lastAttemptTimestamp;
        if (f is OkFrame || f is SentFrame) return SendResult.accepted(ts);
        // The firmware answers NOT_FOUND for a bad slot AND for a full packet pool (MyMesh.cpp 1190-1195): for a slot that
        // exists, treat it as busy once.
        if (f is ErrFrame && f.code == ErrCode.notFound && !retried && (max == null || channelIndex < max)) {
          retried = true;
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        return _failureOf(f, ts: ts, channel: true);
      } on TimeoutException {
        return SendResult.queued(mc.lastAttemptTimestamp, detail: 'the radio did not confirm; it may still send');
      } on StateError {
        return const SendResult.failed(SendFailure.notConnected, detail: 'the radio disconnected');
      }
    }
  }

  @override
  Future<SendResult> sendContactMessage(String publicKeyHex, String text, {int attempt = 0, int? timestamp, FloodScope? scope}) async {
    final mc = _mc;
    if (mc == null || !mc.isConnected) return const SendResult.failed(SendFailure.notConnected, detail: 'the radio is not connected');
    final key = publicKeyHex.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) {
      return const SendResult.failed(SendFailure.noSuchContact, detail: 'not a 64-character public key');
    }
    final bytes = utf8.encode(text).length;
    if (bytes == 0) return const SendResult.failed(SendFailure.tooLong, detail: 'empty message');
    if (bytes > maxDirectTextBytes) return SendResult.failed(SendFailure.tooLong, detail: '$bytes bytes; one message holds $maxDirectTextBytes');
    chatActive = true;
    arbiter.admitUserSend(arbiter.estimateDirectMs(bytes));
    try {
      final (f, ts) = await mc.sendContactFrame(key, text, attempt: attempt, timestamp: timestamp, priority: CommandPriority.user, scope: scope);
      if (f is SentFrame) {
        if (f.tag != 0) {
          _acks[f.tag] = key;
          while (_acks.length > _ackTable) {
            _acks.remove(_acks.keys.first);
          }
        }
        return SendResult.accepted(ts, expectedAck: f.tag, estTimeoutMs: f.estTimeoutMs, flood: f.flood, attempt: attempt & 3);
      }
      return _failureOf(f, ts: ts, attempt: attempt & 3);
    } on TimeoutException {
      return SendResult.queued(timestamp ?? mc.lastAttemptTimestamp, detail: 'the radio did not confirm; it may still send', attempt: attempt & 3);
    } on StateError {
      return const SendResult.failed(SendFailure.notConnected, detail: 'the radio disconnected');
    }
  }

  // ---------------------------------------------------------------- contacts and channels

  MeshCoreCompanionLink _need() {
    final mc = _mc;
    if (mc == null || !mc.isConnected) throw StateError('radio not connected');
    return mc;
  }

  @override
  Future<ContactListing> getContacts({int since = 0}) => downloadContacts(since: since);

  @override
  Future<ContactListing> downloadContacts({int since = 0, void Function(RadioContact contact, int received, int total)? onContact}) async {
    final mc = _need();
    // An iteration that a timed-out call left running makes the firmware answer BAD_STATE until it ends.
    for (var attempt = 0;; attempt++) {
      try {
        return await mc.getContacts(since: since, onContact: onContact);
      } on CompanionException catch (e) {
        if (e.errCode != ErrCode.badState || attempt >= 3) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
    }
  }

  @override
  Future<void> addOrUpdateContact(RadioContact contact) => _need().addOrUpdateContact(contact);

  @override
  Future<RadioContact?> getContact(String publicKeyHex) => _need().getContactByKey(publicKeyHex);

  @override
  Future<bool> removeContact(String publicKeyHex) => _need().removeContact(publicKeyHex);

  @override
  Future<bool> resetContactPath(String publicKeyHex) => _need().resetContactPath(publicKeyHex);

  @override
  Future<Uint8List?> exportContactAdvert(String publicKeyHex) => _need().exportContactAdvert(publicKeyHex);

  @override
  Future<void> importContactAdvert(Uint8List packet) => _need().importContactAdvert(packet);

  @override
  Future<bool> shareContactZeroHop(String publicKeyHex) => _need().shareContactZeroHop(publicKeyHex);

  @override
  Future<ContactPolicy> getContactPolicy() => _need().getContactPolicy();

  @override
  Future<void> setContactPolicy(ContactPolicy policy) => _need().setContactPolicy(policy);

  @override
  Future<List<RadioChannel>> listChannels() => _need().listChannels();

  @override
  Future<void> setChannel(int index, String name, Uint8List secret16) => _need().setChannel(index, name, secret16);

  @override
  Future<void> deleteChannel(int index) => _need().setChannel(index, '', Uint8List(16));

  @override
  Future<int> ensureChannel(String name) => link.ensureChannel(name);

  // ---------------------------------------------------------------- wardrive

  @override
  Stream<RxPacket> get rxPackets => link.rxPackets;

  // ---------------------------------------------------------------- RadioStatsSource (health sampling)

  /// The link reports radio health (battery, noise floor, counters).
  bool get hasStats => link is RadioStatsSource;

  RadioStatsSource? get _stats => link is RadioStatsSource ? link as RadioStatsSource : null;

  @override
  Future<BattAndStorageFrame?> batteryAndStorage() async => _stats?.batteryAndStorage();
  @override
  Future<CoreStatsFrame?> coreStats() async => _stats?.coreStats();
  @override
  Future<RadioStatsFrame?> radioStats() async => _stats?.radioStats();
  @override
  Future<PacketStatsFrame?> packetStats() async => _stats?.packetStats();
  @override
  Future<SelfTelemetry?> selfTelemetry() async => _stats?.selfTelemetry();

  // ---------------------------------------------------------------- ClaimRadio (priority P1, counted in the ledger)

  ClaimRadio get _claimOrThrow =>
      _claim ?? (throw const ClaimRadioException(ClaimRadioError.unsupported, 'this radio link cannot run claims'));

  /// A claim command is a small flood or direct packet; budget it as a 40-byte message.
  void _countAdmin() => arbiter.recordTx(TxPriority.admin, arbiter.estimateDirectMs(40));

  @override
  String? get selfPublicKey => _claim?.selfPublicKey ?? selfInfo?.publicKey.toLowerCase();

  @override
  Future<Uint8List> sign(Uint8List data) => _claimOrThrow.sign(data);

  @override
  Future<void> ensureContact(String pubkeyHex, {required int nodeType, String name = ''}) =>
      _claimOrThrow.ensureContact(pubkeyHex, nodeType: nodeType, name: name);

  @override
  Future<RemoteLogin> login(String pubkeyHex, String password, {Duration? timeout}) {
    _countAdmin();
    return _claimOrThrow.login(pubkeyHex, password, timeout: timeout);
  }

  @override
  Future<void> logout(String pubkeyHex) => _claimOrThrow.logout(pubkeyHex);

  @override
  Future<String> runCli(String pubkeyHex, String command, {Duration? timeout}) {
    _countAdmin();
    return _claimOrThrow.runCli(pubkeyHex, command, timeout: timeout);
  }

  @override
  Future<RepeaterStatus?> status(String pubkeyHex, {Duration? timeout}) {
    _countAdmin();
    return _claimOrThrow.status(pubkeyHex, timeout: timeout);
  }

  // ---------------------------------------------------------------- RepeaterAdminRadio (priority P1, counted in the ledger)

  RepeaterAdminRadio get _adminOrThrow {
    final l = link;
    if (l is RepeaterAdminRadio) return l as RepeaterAdminRadio;
    throw const ClaimRadioException(ClaimRadioError.unsupported, 'this radio link cannot administer repeaters');
  }

  /// This session's link can administer repeaters (binary requests, remote telemetry, tagged CLI).
  bool get supportsRepeaterAdmin => link is RepeaterAdminRadio;

  @override
  Future<Uint8List> binaryRequest(String keyHex, List<int> request, {Duration? timeout}) {
    _countAdmin();
    return _adminOrThrow.binaryRequest(keyHex, request, timeout: timeout);
  }

  @override
  Future<Uint8List> anonRequest(String keyHex, List<int> request, {Duration? timeout}) {
    _countAdmin();
    return _adminOrThrow.anonRequest(keyHex, request, timeout: timeout);
  }

  @override
  Future<Uint8List> telemetryRequest(String keyHex, {Duration? timeout}) {
    _countAdmin();
    return _adminOrThrow.telemetryRequest(keyHex, timeout: timeout);
  }

  @override
  Future<Uint8List> statusBytes(String keyHex, {Duration? timeout}) {
    _countAdmin();
    return _adminOrThrow.statusBytes(keyHex, timeout: timeout);
  }

  @override
  Future<String> runTaggedCli(String keyHex, String tag, String command, {Duration? timeout}) {
    _countAdmin();
    return _adminOrThrow.runTaggedCli(keyHex, tag, command, timeout: timeout);
  }

  // ---------------------------------------------------------------- Tools (lib/radio/tools)

  RadioTools? _tools;

  /// True while a wardrive ping is in flight; the Tools' noise monitor then skips its read. Set by the app.
  bool Function()? pingBusy;

  /// Where saved traces live (null = memory). Set by the app before the first use of [tools].
  TraceStore? traceStore;

  /// This session's Tools (trace, discovery, adverts, RX log, noise floor, telemetry, radio setup), sharing this session's
  /// airtime ledger. Null when the link is not a MeshCore companion link (a test fake).
  RadioTools? get tools {
    final mc = _mc;
    if (mc == null) return null;
    return _tools ??= RadioTools(LinkToolsRadio(mc, this), arbiter, clock: _clock, pingBusy: () => pingBusy?.call() ?? false, traceStore: traceStore);
  }

  // ---------------------------------------------------------------- end

  @override
  Future<void> close() async {
    final t = _tools;
    _tools = null;
    if (t != null) unawaited(t.dispose());
    unawaited(_unsolicitedSub?.cancel());
    unawaited(_rxDoneSub?.cancel());
    _state = LinkState.disconnected;
    if (!_states.isClosed) {
      _states.add(_state);
      unawaited(_states.close()); // never awaited: a controller nobody listens to completes close() only when listened
    }
    if (!_events.isClosed) unawaited(_events.close());
    try {
      await link.close();
    } catch (_) {}
  }
}
