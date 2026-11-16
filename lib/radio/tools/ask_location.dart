// Ask for location (MeshTrack MT-13): asks one contact for its position with MeshCore's telemetry request and sorts the
// answer into what the contact screen shows. One hub per radio session (RadioTools), so leaving the contact screen while
// it asks and coming back finds the same request, and the once-per-30-s limit holds across screens.
//
// The request is the existing TelemetryTool one (CMD 39 with the contact's key, through the shared remote-request queue),
// sent at user priority with its airtime recorded by the TxArbiter as a user send. Firmware reading (source only, not
// verified on hardware): docs/protocol/telemetry-location-request.md.
//
// Privacy: positions stay in memory (this hub and the Drive map's "asked" pin); log lines never carry a name or a
// coordinate. Our own radio's answers to other people's requests are not touched here (its telemetry permissions are the
// radio's own setting).
// Pure Dart.
import 'dart:async';

import '../../core/meshtrack/ask_location.dart';
import '../inbound.dart' show RadioContact;
import 'lpp.dart' show LppKind;
import 'telemetry_tool.dart';
import 'tool_state.dart';

export '../../core/meshtrack/ask_location.dart';

enum AskPhase {
  /// Not asked in this session.
  idle,

  /// Waiting for the answer (spinner, Cancel).
  asking,

  /// Answered with a position.
  located,

  /// Answered, without a position (location not allowed, or no GPS).
  noLocation,

  /// No answer within the wait.
  noAnswer,

  /// The radio does not have this contact, so it cannot address the request.
  notOnRadio,

  /// The radio is busy with another request (Stats, a login); nothing was sent.
  busy,

  /// The radio refused or failed to send.
  failed,

  /// No radio connected.
  notConnected,
}

class AskState {
  final AskPhase phase;
  final String keyHex;
  final String name;

  /// When the current or last ask started.
  final DateTime? startedAt;

  /// The answer ([AskPhase.located]).
  final MtAskedPosition? position;

  /// When the answer (with or without a position) came.
  final DateTime? answeredAt;
  const AskState(this.phase, this.keyHex, this.name, {this.startedAt, this.position, this.answeredAt});

  bool get asking => phase == AskPhase.asking;

  @override
  String toString() => 'AskState(${phase.name})'; // never the position
}

class AskLocationHub with ToolChanges {
  final TelemetryTool tool;
  final AskLimiter limiter;
  final DateTime Function() _clock;

  /// Diagnostics sink; lines never carry a name or a coordinate.
  void Function(String line)? log;

  final Map<String, AskState> _states = {};
  final Map<String, TelemetryCancel> _running = {};

  AskLocationHub(this.tool, {AskLimiter? limiter, DateTime Function()? clock, this.log})
      : _clock = clock ?? DateTime.now,
        limiter = limiter ?? AskLimiter(clock: clock);

  static String _k(String keyHex) => keyHex.toLowerCase();

  /// The current or last ask of [keyHex] in this session ([AskPhase.idle] when none). An answer older than
  /// [kAskedOnMapFor] has expired (its map pin is gone too): it reads as idle and is forgotten.
  AskState stateOf(String keyHex, {String name = ''}) {
    final k = _k(keyHex);
    final s = _states[k];
    if (s == null) return AskState(AskPhase.idle, k, name);
    final at = s.answeredAt;
    if (s.phase != AskPhase.asking && at != null && _clock().difference(at) >= kAskedOnMapFor) {
      _states.remove(k);
      return AskState(AskPhase.idle, k, s.name);
    }
    return s;
  }

  /// How long [keyHex]'s answer stays shown (null when there is no answer to expire).
  Duration? answerExpiresIn(String keyHex) {
    final at = _states[_k(keyHex)]?.answeredAt;
    if (at == null) return null;
    final left = kAskedOnMapFor - _clock().difference(at);
    return left > Duration.zero ? left : Duration.zero;
  }

  /// Delete my data: forgets every answer (and stops any ask in flight).
  void clear() {
    for (final c in _running.values.toList()) {
      c.cancel();
    }
    _states.clear();
    notifyChanged();
  }

  /// How long until [keyHex] may be asked again; null = now.
  Duration? retryIn(String keyHex) => limiter.waitFor(keyHex);

  bool isAsking(String keyHex) => _running.containsKey(_k(keyHex));

  void _set(AskState s) {
    _states[s.keyHex] = s;
    notifyChanged();
  }

  /// Asks [c] for its position. [onLocated] gets an answered position (the app puts the "asked" pin on the map). Returns
  /// the final state. Refused at once (state unchanged) while the same contact is already being asked or inside the 30 s
  /// limit.
  Future<AskState> ask(RadioContact c, {String? name, void Function(MtAskedPosition p)? onLocated}) async {
    final key = _k(c.publicKeyHex);
    final who = name ?? (c.name.isEmpty ? key.substring(0, 8) : c.name);
    if (_running.containsKey(key) || limiter.waitFor(key) != null) return stateOf(key, name: who);
    final started = _clock();
    if (!tool.radio.isConnected) {
      final s = AskState(AskPhase.notConnected, key, who, startedAt: started);
      _set(s);
      return s;
    }
    final before = _states[key];
    final cancel = TelemetryCancel();
    _running[key] = cancel;
    limiter.mark(key);
    _set(AskState(AskPhase.asking, key, who, startedAt: started));
    log?.call('ask for location: request sent');
    TelemetryResult r;
    try {
      r = await tool.requestContactQueued(
        c,
        user: true,
        waitFor: (sent) => askLocationWait(flood: sent.flood, estTimeoutMs: sent.estTimeoutMs),
        cancel: cancel,
      );
    } catch (_) {
      r = TelemetryResult(TelemetryStatus.refused, who, _clock(), keyHex: key);
    } finally {
      _running.remove(key);
    }
    if (cancel.isCancelled && !_states.containsKey(key)) {
      return AskState(AskPhase.idle, key, who); // cleared (Delete my data) while asking: keep nothing
    }
    final at = _clock();
    AskState done(AskPhase p, {MtAskedPosition? pos, bool answered = false, bool sent = true}) {
      if (!sent) limiter.clear(key); // nothing went on air: asking again right away costs nothing
      return AskState(p, key, who, startedAt: started, position: pos, answeredAt: answered ? at : null);
    }

    final AskState s;
    switch (r.status) {
      case TelemetryStatus.ok || TelemetryStatus.empty:
        final g = r.readings.where((x) => x.kind == LppKind.gps && x.lat != null && x.lon != null && askedPositionUsable(x.lat!, x.lon!)).firstOrNull;
        if (g == null) {
          s = done(AskPhase.noLocation, answered: true);
          log?.call('ask for location: answered without a position');
        } else {
          final pos = MtAskedPosition(keyHex: key, name: who, lat: g.lat!, lon: g.lon!, altitudeM: g.altitudeM, at: at);
          s = done(AskPhase.located, pos: pos, answered: true);
          log?.call('ask for location: answered with a position');
          onLocated?.call(pos);
        }
      case TelemetryStatus.silent:
        s = done(AskPhase.noAnswer);
        log?.call('ask for location: no answer');
      case TelemetryStatus.cancelled:
        // Cancel keeps the last answer on screen (if any); the request may already be on air, so the limit stays.
        s = before != null && before.answeredAt != null ? before : AskState(AskPhase.idle, key, who);
        log?.call('ask for location: cancelled');
      case TelemetryStatus.noContact:
        s = done(AskPhase.notOnRadio, sent: false);
      case TelemetryStatus.tooSoon:
        s = done(AskPhase.busy, sent: false);
      case TelemetryStatus.notConnected:
        s = done(AskPhase.notConnected, sent: false);
      case TelemetryStatus.refused:
        s = done(AskPhase.failed, sent: false);
    }
    _set(s);
    return s;
  }

  /// Stops waiting for [keyHex]'s answer.
  void cancel(String keyHex) => _running[_k(keyHex)]?.cancel();

  void dispose() {
    for (final c in _running.values.toList()) {
      c.cancel();
    }
    disposeChanges();
  }
}
