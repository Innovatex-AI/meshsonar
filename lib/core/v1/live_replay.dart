// The live map's replay clock (AZ-3.3, behaviour modelled on the CoreScope teardown E §1.3, never its code): packets
// are played in time order; the wait between two packets is their real gap clamped to 100 ms .. 2 s, divided by the
// speed, so a quiet hour does not play as an hour of nothing and a burst does not play as one frame. Speeds 0.25x to
// 8x. The clock is driven by the caller's frame ticker ([tick] with the real time since the last frame), so it pauses
// with the ticker (off screen, background, Saver) and tests can step it exactly.
//
// Pure Dart: no Flutter imports.
import 'live_api.dart';

/// The replay speeds, slowest first.
const List<double> replaySpeeds = [0.25, 0.5, 1, 2, 4, 8];

String replaySpeedLabel(double s) => switch (s) {
      0.25 => '¼×',
      0.5 => '½×',
      _ => '${s == s.truncateToDouble() ? s.toInt() : s}×',
    };

class ReplayClock {
  static const Duration minGap = Duration(milliseconds: 100);
  static const Duration maxGap = Duration(seconds: 2);

  final List<LiveV2Packet> _queue = [];
  final Set<String> _seen = {};
  double _speed;

  /// Real time left before the next packet plays.
  Duration _wait = Duration.zero;
  int _next = 0;
  DateTime _playhead;

  ReplayClock({required DateTime start, double speed = 1})
      : _playhead = start,
        _speed = _valid(speed);

  static double _valid(double s) => replaySpeeds.contains(s) ? s : 1;

  double get speed => _speed;

  /// The time of the packet played last (the clock's "now" in the replayed window).
  DateTime get playhead => _playhead;

  /// Packets still to play.
  int get pending => _queue.length - _next;
  bool get exhausted => _next >= _queue.length;

  /// The time of the last queued packet; null when none.
  DateTime? get queuedUntil => _queue.isEmpty ? null : _queue.last.firstSeen;

  static Duration gapFor(DateTime a, DateTime b, double speed) {
    var g = b.difference(a);
    if (g < minGap) g = minGap;
    if (g > maxGap) g = maxGap;
    return Duration(microseconds: (g.inMicroseconds / speed).round());
  }

  /// Queues [ps] (a replay page); packets before the playhead or already queued are skipped.
  void add(Iterable<LiveV2Packet> ps) {
    final fresh = [
      for (final p in ps)
        if (!_seen.contains(p.hash) && !p.firstSeen.isBefore(_playhead)) p
    ]..sort((a, b) => a.firstSeen.compareTo(b.firstSeen));
    if (fresh.isEmpty) return;
    final wasEmpty = exhausted;
    for (final p in fresh) {
      _seen.add(p.hash);
    }
    _queue.addAll(fresh);
    final rest = _queue.sublist(_next)..sort((a, b) => a.firstSeen.compareTo(b.firstSeen));
    _queue.replaceRange(_next, _queue.length, rest);
    if (wasEmpty) _wait = gapFor(_playhead, _queue[_next].firstSeen, _speed);
  }

  /// Changes the speed; the wait already running is rescaled so the next packet keeps its place.
  void setSpeed(double s) {
    final v = _valid(s);
    if (v == _speed) return;
    _wait = Duration(microseconds: (_wait.inMicroseconds * _speed / v).round());
    _speed = v;
  }

  /// Advances by [realDt] of wall time; returns the packets that play in it, oldest first.
  List<LiveV2Packet> tick(Duration realDt) {
    final out = <LiveV2Packet>[];
    var left = realDt;
    while (!exhausted) {
      if (left < _wait) {
        _wait -= left;
        break;
      }
      left -= _wait;
      final p = _queue[_next++];
      out.add(p);
      _playhead = p.firstSeen;
      _wait = exhausted ? Duration.zero : gapFor(p.firstSeen, _queue[_next].firstSeen, _speed);
    }
    // Drop played packets now and then so a long replay does not grow without end.
    if (_next > 2000) {
      _queue.removeRange(0, _next);
      _next = 0;
    }
    return out;
  }
}
