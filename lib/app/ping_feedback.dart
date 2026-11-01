// Ping feedback for the Drive screen: what the repeaters and the network's observers made of the pings of THIS drive.
//
//   * "heard by N repeaters" comes from the phone itself (the engine's echoes), available the moment the window closes;
//   * "M observers confirmed" comes from the server (`GET drive-status?session=`, PLATFORM_CONTRACT): fixed receivers that
//     heard the ping's packet on the air and reported it. It exists only for pings already uploaded, so it lags the drive by
//     the in-drive upload period and by the observers' own reporting delay. Until it answers, the screen says so and shows
//     only what the phone heard; nothing is guessed.
//
// Pure Dart (no Flutter imports) so it is testable without a widget.
import '../core/api.dart';
import '../core/model.dart';

/// Why there is no observer answer, for the screen to say in words.
enum ObserverFeedbackState {
  /// Not asked yet (no ping uploaded yet, or the first answer is on its way).
  waiting,

  /// The server answered; counts below are real.
  live,

  /// This server has no `drive-status`, or this key may not ask: local numbers only.
  unavailable,

  /// No driver key on this phone, so nothing is uploaded and no observer can be matched to a ping.
  noKey,
}

/// What the screen shows for one ping.
class PingFeedbackLine {
  final int repeaters;
  final int? observers;
  const PingFeedbackLine(this.repeaters, this.observers);
}

class PingFeedback {
  ObserverFeedbackState state = ObserverFeedbackState.waiting;
  final Map<String, PingObservation> _observed = {};
  DateTime? lastAnswerAt;
  String? lastProblem;

  /// Pings of this drive the server has seen at least one observer for.
  int get confirmedPings => _observed.values.where((o) => o.observers > 0).length;

  /// Pings of this drive the server has an answer for (observed or not).
  int get answeredPings => _observed.length;

  /// Distinct observers named so far (the server names at most three per ping, so this is a floor).
  Set<String> get observerNames => {for (final o in _observed.values) ...o.via};

  PingObservation? observation(String pingId) => _observed[pingId];

  void reset() {
    state = ObserverFeedbackState.waiting;
    _observed.clear();
    lastAnswerAt = null;
    lastProblem = null;
  }

  void markNoKey() {
    if (state != ObserverFeedbackState.noKey) {
      _observed.clear();
      state = ObserverFeedbackState.noKey;
    }
  }

  /// One poll. Returns true when something changed.
  Future<bool> poll(CmatClient client, String driverKey, String sessionId, DateTime now) async {
    if (state == ObserverFeedbackState.unavailable) return false;
    try {
      final list = await client.driveStatus(driverKey, sessionId);
      var changed = state != ObserverFeedbackState.live;
      for (final o in list) {
        final prev = _observed[o.id];
        if (prev == null || prev.observers != o.observers || prev.settled != o.settled || prev.via.length != o.via.length) changed = true;
        _observed[o.id] = o;
      }
      state = ObserverFeedbackState.live;
      lastAnswerAt = now;
      lastProblem = null;
      return changed;
    } on CmatException catch (e) {
      if (e.status == 404 && e.message != 'not supported by this client') {
        // Unknown session = nothing uploaded yet (or an older server without the route; the next poll tells them apart
        // only if the server ever answers). Stay waiting.
        lastProblem = null;
        return false;
      }
      if (e.status == 401 || e.status == 403 || e.status == 405 || e.status == 501 || e.status == null && e.message.contains('not supported')) {
        state = ObserverFeedbackState.unavailable;
        lastProblem = e.message;
        return true;
      }
      lastProblem = e.message; // network trouble or a rate limit: try again next tick
      return false;
    } catch (e) {
      lastProblem = e.toString();
      return false;
    }
  }
}

/// "Last ping: heard by 3 repeaters, 2 observers confirmed" for the Drive screen; null before the first transmitted ping.
/// What the phone heard is shown at once; the observer part says honestly when it is not known yet.
String? lastPingSummary(DrivePing? last, PingFeedback f) {
  if (last == null || last.kind != PingKind.tx) return null;
  final n = last.echoes.length;
  final heard = n == 0 ? 'no repeater heard it' : 'heard by $n repeater${n == 1 ? '' : 's'}';
  final o = f.observation(last.id);
  final String obs;
  if (o != null && o.observers > 0) {
    obs = '${o.observers} observer${o.observers == 1 ? '' : 's'} confirmed';
  } else if (o != null && o.settled) {
    obs = 'no observer reported it';
  } else if (o != null) {
    obs = 'observers still reporting';
  } else {
    obs = switch (f.state) {
      ObserverFeedbackState.unavailable || ObserverFeedbackState.noKey => '',
      _ => 'observers confirm after the next upload',
    };
  }
  return 'Last ping: $heard${obs.isEmpty ? '' : ', $obs'}';
}
