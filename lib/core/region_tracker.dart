// Which region the phone is in, with hysteresis so a border crossing (or GPS jitter on the border) never flaps.
// Pure Dart. Spec: app-website-parity-and-region-spec WP-R1 / E.5.
//
// Rules, in order, for each fix:
//  1. First fix commits immediately (nothing to flap from).
//  2. Same region as committed: all good, reset any pending switch.
//  3. The committed region still contains the fix (overlap zone, shared border): stay. Overlap never switches.
//  4. Outside every region: keep the committed region for [outsideGrace]; after that the committed region becomes
//     null ("outside coverage"). Brief gaps (tunnels, boundary simplification) never drop it.
//  5. Inside another region B but outside the committed one: hold while the fix is within [edgeMarginM] of the
//     committed region's boundary (near-edge: GPS error can put you on the wrong side), otherwise B must win
//     [confirmFixes] consecutive fixes before it is committed.
import 'region_geometry.dart';
import 'region_lookup.dart';
import 'region_pick.dart';

export 'region_geometry.dart' show distanceToBoundaryM;

/// What one fix did to the tracker.
class RegionTrackUpdate {
  final RegionIndexEntry? current;
  final RegionIndexEntry? previous;

  /// True when [current] differs from the region committed before this fix.
  final bool changed;

  /// The fix is within [RegionTracker.nearEdgeM] of the committed region's boundary.
  final bool nearEdge;

  /// Every OTHER region that also holds the fix (a shared border, a nested zone): the server lists a node in each of
  /// them and gives a ping to one, so the phone says "also in ..." instead of pretending the border is a line.
  final List<RegionIndexEntry> alsoIn;
  const RegionTrackUpdate(
      {required this.current, required this.previous, required this.changed, required this.nearEdge, this.alsoIn = const []});
}

class RegionTracker {
  final int confirmFixes;
  final double edgeMarginM;
  final double nearEdgeM;
  final Duration outsideGrace;

  /// The hub index is thinned to about 300 m, so two neighbours no longer share an exact edge and a fix on the seam can
  /// fall in neither outline: within this many metres of an outline counts as inside it (the exact rule is 0).
  final double seamM;
  RegionTracker({
    this.confirmFixes = 3,
    this.edgeMarginM = 100,
    this.nearEdgeM = 300,
    this.outsideGrace = const Duration(seconds: 60),
    this.seamM = 300,
  });

  RegionIndexEntry? _current;
  String? _pendingCode;
  int _pendingCount = 0;
  DateTime? _outsideSince;

  RegionIndexEntry? get current => _current;

  /// Forget everything (index replaced, server changed).
  void reset() {
    _current = null;
    _pendingCode = null;
    _pendingCount = 0;
    _outsideSince = null;
  }

  RegionTrackUpdate update(List<RegionIndexEntry> index, double lat, double lon, DateTime at) {
    final prev = _current;
    // Re-resolve the committed region against the latest index (boundaries may have been refreshed).
    RegionIndexEntry? cur;
    if (prev != null) {
      for (final r in index) {
        if (r.code == prev.code) cur = r;
      }
      _current = cur; // dropped from the index -> treated as outside
    }
    final here = regionsContaining(index, lat, lon);
    final raw = here.isNotEmpty ? here.first : regionContaining(index, lat, lon, seamM: seamM);

    void commit(RegionIndexEntry? to) {
      _current = to;
      _pendingCode = null;
      _pendingCount = 0;
      _outsideSince = null;
    }

    if (raw == null) {
      if (_current != null) {
        _outsideSince ??= at;
        if (at.difference(_outsideSince!) >= outsideGrace) commit(null);
      }
    } else {
      _outsideSince = null;
      if (_current == null) {
        commit(raw);
      } else if (raw.code == _current!.code) {
        _pendingCode = null;
        _pendingCount = 0;
      } else if (_stillInside(_current!, lat, lon)) {
        _pendingCode = null; // overlap zone: never switch
        _pendingCount = 0;
      } else {
        final edge = _current!.boundary == null ? double.infinity : distanceToBoundaryM(_current!.boundary!, lat, lon);
        if (edge >= edgeMarginM) {
          if (_pendingCode == raw.code) {
            _pendingCount++;
          } else {
            _pendingCode = raw.code;
            _pendingCount = 1;
          }
          if (_pendingCount >= confirmFixes) commit(raw);
        }
        // else: near-edge hold; keep any pending count as is (do not advance it).
      }
    }

    final now = _current;
    var near = false;
    if (now?.boundary != null) near = distanceToBoundaryM(now!.boundary!, lat, lon) <= nearEdgeM;
    return RegionTrackUpdate(
        current: now,
        previous: prev,
        changed: now?.code != prev?.code,
        nearEdge: near,
        alsoIn: [for (final r in here) if (r.code != now?.code) r]);
  }

  bool _stillInside(RegionIndexEntry r, double lat, double lon) => regionHolds(r, lat, lon);
}
