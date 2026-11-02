// MapHitResolver: one tap, one decision (Drive plan 7.6). Every source that could claim a tap (a ping dot, a repeater marker
// or cluster, an observer, the coverage cell under the finger) submits a candidate during the tap; the resolver picks the winner
// by fixed priority ping > repeater > observer > cell, nearest first, smallest polygon first for cells, and runs only that
// candidate's action. It replaces the old 90 ms timer arbitration: the decision is taken as soon as the tap has been delivered
// to every source (a microtask after the same pointer dispatch), not after a fixed delay.
import 'dart:async' show scheduleMicrotask;

enum MapHitKind { ping, repeater, observer, cell }

class MapHitCandidate {
  final MapHitKind kind;

  /// Distance from the tap to the thing, in logical pixels (0 when the tap is inside it). Smaller wins within a kind.
  final double distance;

  /// For cells: the polygon's area (smaller wins on a tie), any unit.
  final double area;

  /// Runs if this candidate wins.
  final void Function() onWin;
  const MapHitCandidate(this.kind, this.onWin, {this.distance = 0, this.area = 0});
}

/// Picks the winner among [candidates] (pure; used by [MapHitResolver] and by tests). Null for an empty list.
MapHitCandidate? pickWinner(Iterable<MapHitCandidate> candidates) {
  MapHitCandidate? best;
  for (final c in candidates) {
    if (best == null || _better(c, best)) best = c;
  }
  return best;
}

bool _better(MapHitCandidate a, MapHitCandidate b) {
  if (a.kind != b.kind) return a.kind.index < b.kind.index; // enum order = priority
  if (a.distance != b.distance) return a.distance < b.distance;
  return a.area < b.area;
}

class MapHitResolver {
  final List<MapHitCandidate> _pending = [];
  bool _scheduled = false;
  bool _disposed = false;

  /// Called when nothing at all claimed the tap (the tap landed on bare map): clears selections.
  void Function()? onNothing;

  /// A tap reached the map itself (the base layer): it only matters if nobody else claims it.
  void tapReachedMap() => _schedule();

  /// A source claims the tap.
  void submit(MapHitCandidate c) {
    _pending.add(c);
    _schedule();
  }

  /// Decided after the whole synchronous pointer dispatch has run (every source that reacts to this tap has submitted by then).
  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      if (_scheduled && !_disposed) resolveNow();
    });
  }

  /// Decides now (tests call this directly).
  void resolveNow() {
    _scheduled = false;
    final winner = pickWinner(_pending);
    _pending.clear();
    if (winner != null) {
      winner.onWin();
    } else {
      onNothing?.call();
    }
  }

  void dispose() {
    _disposed = true;
    _scheduled = false;
    _pending.clear();
  }
}
