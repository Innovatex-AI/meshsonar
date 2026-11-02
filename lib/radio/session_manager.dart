// RadioSessionManager: owns the current radio session and the link under it: connect, hand over to another app,
// reconnect after a drop, the link state stream. AppState used to do all of this itself (app_state.dart `_link`,
// `_reconnectRadio`); it now keeps only the drive UX around it.
//
// One manager per app today (one radio). Sessions are instances, not singletons, so a second radio later is a second
// session in this manager (design doc C section 3.2 item 8).
import 'dart:async';

import 'companion_link.dart' show MeshCoreCompanionLink;
import 'radio_api.dart';
import 'remote_request_queue.dart';
import 'radio_health.dart';
import 'radio_session_impl.dart';
import 'session.dart';
import 'tx_arbiter.dart';

/// Wraps a connected transport in the companion protocol (MeshCoreCompanionLink in the real app).
typedef LinkFactory = CompanionLink Function(ByteTransport transport);

class RadioSessionManager {
  final LinkFactory linkFactory;
  final DateTime Function() _clock;
  final Duration connectTimeout;
  final Duration startTimeout;

  LinkRadioSession? _session;
  LinkState _state = LinkState.disconnected;
  StreamSubscription<LinkState>? _watch;
  final _states = StreamController<LinkState>.broadcast();
  final _sessions = StreamController<LinkRadioSession?>.broadcast();

  RadioSessionManager({
    required this.linkFactory,
    DateTime Function()? clock,
    TxPolicy policy = const TxPolicy(),
    this.connectTimeout = const Duration(seconds: 25),
    this.startTimeout = const Duration(seconds: 20),
  }) : _clock = clock ?? DateTime.now {
    arbiter = TxArbiter(clock: _clock, policy: policy);
  }

  /// The transmit arbiter and airtime ledger of this app's radio. One instance for all sessions this manager creates, so
  /// the rolling 10-minute and one-hour ledgers survive a reconnect.
  late final TxArbiter arbiter;

  /// The one remote request queue of this app's radio (login, status, telemetry, neighbours, CLI ... to other nodes). One
  /// instance for all sessions, so a reconnect does not lose the list; it pauses the Rx log of whatever link is current
  /// while a request is in flight.
  late final RemoteRequestQueue remoteQueue = RemoteRequestQueue(clock: _clock, onRxPause: _pauseRx);

  void _pauseRx(bool paused) {
    final l = _session?.link;
    if (l is MeshCoreCompanionLink) l.rxLogPaused = paused;
  }

  /// The live session, or null when no radio is connected.
  LinkRadioSession? get session => _session;

  /// The link under the session.
  CompanionLink? get link => _session?.link;

  LinkState get state => _state;
  Stream<LinkState> get linkStates => _states.stream;

  /// Emits the session each time it is replaced (connect, reconnect) and null when it ends.
  Stream<LinkRadioSession?> get sessions => _sessions.stream;

  bool get connected => _session?.isConnected ?? false;
  SelfInfo? get selfInfo => _session?.selfInfo;

  /// Health sampling (battery, noise floor, packet counters, MCU temperature) reads through the session, so it follows
  /// a reconnect without being rebuilt.
  RadioStatsSource? get healthSource => _session;

  void _setState(LinkState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  void _adopt(LinkRadioSession? s) {
    _watch?.cancel();
    _watch = null;
    _session = s;
    final l = s?.link;
    if (l is MeshCoreCompanionLink) {
      l.rxLogPaused = remoteQueue.rxPaused;
      l.onRemoteSent = remoteQueue.reportSentForCurrent;
    }
    if (s != null) {
      _watch = s.linkStates.listen((st) {
        // The link dropped under a session that is still current: say so (the owner decides whether to reconnect).
        if (identical(_session, s) && st == LinkState.disconnected && _state == LinkState.connected) {
          _setState(LinkState.disconnected);
        }
      });
    }
    if (!_sessions.isClosed) _sessions.add(s);
  }

  Future<LinkRadioSession> _open(RadioScanner scanner, RadioDevice device) async {
    ByteTransport? transport;
    try {
      transport = await scanner.connect(device).timeout(connectTimeout);
      final link = linkFactory(transport);
      final info = await link.start().timeout(startTimeout);
      final s = LinkRadioSession(link, info: info, clock: _clock, arbiter: arbiter);
      return s;
    } catch (e) {
      try {
        await transport?.disconnect();
      } catch (_) {}
      rethrow;
    }
  }

  /// Connects to [device]. Closes any current session first. Throws what the scanner or the radio threw (a
  /// TimeoutException when the radio does not answer); the state is then disconnected.
  Future<LinkRadioSession> connect(RadioScanner scanner, RadioDevice device) async {
    await disconnect();
    _setState(LinkState.connecting);
    try {
      final s = await _open(scanner, device);
      _adopt(s);
      _setState(LinkState.connected);
      return s;
    } catch (e) {
      _setState(LinkState.disconnected);
      rethrow;
    }
  }

  /// Closes the session and its link.
  Future<void> disconnect() async {
    final s = _session;
    _adopt(null);
    _setState(LinkState.disconnected);
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
  }

  /// The user gives the radio to another app on purpose (the radio takes one BLE connection at a time). The link closes
  /// and nothing reconnects by itself until [connect] is called again.
  Future<void> handOver() async {
    final s = _session;
    _adopt(null);
    _setState(LinkState.handedOver);
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
  }

  /// Gets a dropped radio back: tries again with growing waits until it works or [keepGoing] says stop (the drive ended).
  /// On success the new session replaces the old one (which is closed) and is returned; the caller resumes whatever was
  /// running on [LinkRadioSession.link]. Returns null when stopped, or when the radio was handed over meanwhile.
  ///
  /// [onConnected] runs once a link is up and is current, before the state turns connected; if it throws the try counts as
  /// failed and the loop goes on.
  ///
  /// [expectedKeyHex]: a different radio answering at the address is a failed try. [delay] is the wait before try n.
  Future<LinkRadioSession?> reconnect(
    RadioScanner scanner,
    RadioDevice device, {
    required bool Function() keepGoing,
    required Duration Function(int attempt) delay,
    String? expectedKeyHex,
    void Function(int attempt)? onAttempt,
    void Function(Object error)? onFailure,
    Future<void> Function(LinkRadioSession session)? onConnected,
  }) async {
    if (_state == LinkState.handedOver) return null;
    _setState(LinkState.reconnecting);
    var attempt = 0;
    try {
      while (keepGoing() && _state == LinkState.reconnecting) {
        attempt++;
        onAttempt?.call(attempt);
        await Future<void>.delayed(delay(attempt));
        if (!keepGoing() || _state != LinkState.reconnecting) break;
        try {
          final s = await _open(scanner, device);
          final key = s.selfInfo?.publicKey.toLowerCase();
          if (expectedKeyHex != null && key != expectedKeyHex) {
            await s.close();
            throw StateError('A different radio answered at this address');
          }
          if (!keepGoing() || _state != LinkState.reconnecting) {
            await s.close();
            break;
          }
          final old = _session;
          _adopt(s);
          if (old != null) unawaited(old.close().catchError((Object _) {}));
          if (onConnected != null) {
            try {
              // The caller resumes what was running on the new link. If that fails the try failed: drop this link and go on.
              await onConnected(s);
            } catch (e) {
              try {
                await s.close();
              } catch (_) {}
              rethrow;
            }
          }
          _setState(LinkState.connected);
          return s;
        } catch (e) {
          onFailure?.call(e);
        }
      }
      return null;
    } finally {
      if (_state == LinkState.reconnecting) _setState(_session?.isConnected == true ? LinkState.connected : LinkState.disconnected);
    }
  }

  /// Sets the region's cap on own transmit time per hour (fraction of wall time) on this and later sessions. Unknown
  /// region: leave the 1% default.
  void setRegionCap(double fraction) {
    arbiter.policy = arbiter.policy.copyWith(capFraction: fraction);
  }

  Future<void> dispose() async {
    await disconnect();
    remoteQueue.close();
    unawaited(_states.close());
    unawaited(_sessions.close());
  }
}
