// LaunchReconnect: after the system closed the app (jetsam) and it started again, or when it comes back to the front with
// the link gone, connect to the radio that was in use, without the person doing anything.
//
//  * Starts within about a second of launch; tries with growing waits (1, 3, 6, 10, 15, 20, 30, 30 s: about two minutes)
//    then stops and says so. The person can always press Reconnect.
//  * Does nothing when no radio is remembered, when the person disconnected or handed the radio over on purpose (the store
//    is cleared then), when a radio is already connected, or when [blocked] says so.
//  * [state] and [statusText] are what the Chat tab shows: "Reconnecting to <radio>…".
//  * It uses the app's normal connect path ([connect] = AppState.connect), so every other state (antenna prompt, claims,
//    chat session binding) behaves as after a manual connect.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../radio/radio_api.dart';
import 'ble_lifecycle_log.dart';
import 'last_radio_store.dart';

enum LaunchReconnectState { idle, waiting, connecting, connected, gaveUp }

class LaunchReconnect extends ChangeNotifier {
  final LastRadioStore store;
  final Future<bool> Function(RadioDevice device) connect;
  final bool Function() isConnected;
  final bool Function() blocked;
  final BleLifecycleLog? log;

  /// Wait before try n (1-based). Tests replace it.
  final Duration Function(int attempt) delay;

  /// Waits [d]. Tests replace it with an instant one.
  final Future<void> Function(Duration d) wait;
  final int maxAttempts;

  LaunchReconnect({
    required this.store,
    required this.connect,
    required this.isConnected,
    this.blocked = _never,
    this.log,
    this.delay = defaultDelay,
    Future<void> Function(Duration d)? wait,
    this.maxAttempts = 8,
  }) : wait = wait ?? ((d) => Future<void>.delayed(d));

  static bool _never() => false;
  static Duration defaultDelay(int n) => Duration(seconds: const [1, 3, 6, 10, 15, 20, 30, 30][(n - 1).clamp(0, 7)]);

  LaunchReconnectState _state = LaunchReconnectState.idle;
  LastRadio? _radio;
  int _attempt = 0;
  bool _cancel = false;
  Future<void>? _running;

  LaunchReconnectState get state => _state;
  int get attempt => _attempt;
  String? get radioName => _radio?.name;
  bool get active => _state == LaunchReconnectState.waiting || _state == LaunchReconnectState.connecting;

  /// "Reconnecting to Radio X…" while it works, a plain sentence when it gave up, null otherwise.
  String? get statusText => switch (_state) {
        LaunchReconnectState.waiting || LaunchReconnectState.connecting => 'Reconnecting to ${_radio?.name ?? 'your radio'}…',
        LaunchReconnectState.gaveUp =>
          'Could not reach ${_radio?.name ?? 'your radio'}. Is it on, nearby, and not connected to another app?',
        _ => null,
      };

  void _set(LaunchReconnectState s) {
    if (_state == s) return;
    _state = s;
    notifyListeners();
  }

  /// Starts (or joins) the retry loop. Returns when it connected, gave up or was cancelled.
  Future<void> run({String reason = 'launch'}) => _running ??= _run(reason).whenComplete(() => _running = null);

  Future<void> _run(String reason) async {
    _cancel = false;
    final radio = await store.load();
    if (radio == null) {
      log?.add('reconnect', 'skip ($reason): no remembered radio');
      return;
    }
    if (isConnected()) {
      _set(LaunchReconnectState.connected);
      return;
    }
    if (blocked()) {
      log?.add('reconnect', 'skip ($reason): blocked');
      return;
    }
    _radio = radio;
    _attempt = 0;
    log?.add('reconnect', 'start ($reason) radio="${radio.name}"');
    while (_attempt < maxAttempts && !_cancel) {
      _attempt++;
      _set(LaunchReconnectState.waiting);
      await wait(delay(_attempt));
      if (_cancel) break;
      if (isConnected()) {
        _set(LaunchReconnectState.connected);
        log?.add('reconnect', 'connected by someone else');
        return;
      }
      if (blocked()) break;
      _set(LaunchReconnectState.connecting);
      log?.add('reconnect', 'try $_attempt');
      bool ok;
      try {
        ok = await connect(radio.device);
      } catch (e) {
        ok = false;
        log?.add('reconnect', 'try $_attempt error ${e.runtimeType}');
      }
      if (ok) {
        _set(LaunchReconnectState.connected);
        log?.add('reconnect', 'connected after $_attempt ${_attempt == 1 ? 'try' : 'tries'}');
        return;
      }
    }
    if (_cancel || blocked()) {
      _set(LaunchReconnectState.idle);
      log?.add('reconnect', 'stopped');
      return;
    }
    _set(LaunchReconnectState.gaveUp);
    log?.add('reconnect', 'gave up after $_attempt tries');
  }

  /// The person did something that decides it (disconnected, picked another radio): stop.
  void cancel() {
    _cancel = true;
    if (!active) _set(LaunchReconnectState.idle);
  }

  /// The app came to the front. If the link is gone and we are not already trying, try again.
  Future<void> onForeground() async {
    if (_running != null || isConnected()) return;
    if (_state == LaunchReconnectState.connected) _set(LaunchReconnectState.idle);
    await run(reason: 'foreground');
  }
}
