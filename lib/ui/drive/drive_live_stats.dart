// A running, mid-drive tally of new-vs-repeat map grid cells, updated as pings arrive. This is the live
// counterpart to the after-drive report's "new grids" number (lib/ui/report/drive_report.dart) -- same cell
// identity, same history rule, just kept incrementally instead of recomputed once at the end.
//
// A cell is "new" the first time a tx ping lands in it, counting both this drive and every earlier drive stored
// on this phone; after that it's "repeat" for the rest of this drive (and every later one). History is the set
// of grid cells any earlier (already-ended) local drive touched -- loaded once, asynchronously, when a new drive
// starts, from the same store reads lib/ui/report/drive_report_screen.dart's loadDriveReport uses.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_state.dart';
import '../../core/model.dart';
import '../report/drive_report.dart' show cellIndexOf;

class DriveLiveStats extends ChangeNotifier {
  final AppState state;
  DriveLiveStats(this.state) {
    state.addListener(_onState);
    _onState();
  }

  String? _sessionId;
  Set<(int, int)>? _oldCells; // null until history has loaded for the current session
  final Set<(int, int)> _seenThisDrive = {};
  int _newCount = 0;
  int _repeatCount = 0;
  int _processed = 0;
  bool _loading = false;

  /// Cells pinged for the first time ever on this phone, so far this drive.
  int get newCells => _newCount;

  /// Cells pinged this drive that an earlier, already-finished drive on this phone also pinged.
  int get repeatCells => _repeatCount;

  /// True once the earlier-drives history has loaded, so [newCells]/[repeatCells] are trustworthy. False briefly
  /// at the start of a drive (or while a very large local history is still being read).
  bool get historyLoaded => _oldCells != null;

  void _onState() {
    final session = state.currentSession;
    if (session != null && session.id != _sessionId) {
      _sessionId = session.id;
      _oldCells = null;
      _seenThisDrive.clear();
      _newCount = 0;
      _repeatCount = 0;
      _processed = 0;
      unawaited(_loadHistory(session));
    }
    _consume();
  }

  Future<void> _loadHistory(DriveSession session) async {
    if (_loading) return;
    _loading = true;
    try {
      final cells = <(int, int)>{};
      for (final x in await state.services.store.sessions()) {
        if (x.session.id == session.id || !x.session.startedAt.isBefore(session.startedAt)) continue;
        for (final p in await state.services.store.pings(x.session.id)) {
          if (p.kind == PingKind.tx) cells.add(cellIndexOf(p.lat, p.lon));
        }
      }
      // A different drive started (or this one was replaced) while the read was in flight: that newer session's
      // own history load already owns _oldCells/_seenThisDrive, so don't clobber it with stale results.
      if (_sessionId != session.id) return;
      _oldCells = cells;
      _consume();
      notifyListeners();
    } finally {
      _loading = false;
    }
  }

  void _consume() {
    final old = _oldCells;
    if (old == null) return;
    final pings = state.drivePings;
    for (var i = _processed; i < pings.length; i++) {
      final p = pings[i];
      if (p.kind != PingKind.tx) continue;
      final key = cellIndexOf(p.lat, p.lon);
      if (_seenThisDrive.add(key)) {
        if (old.contains(key)) {
          _repeatCount++;
        } else {
          _newCount++;
        }
      }
    }
    _processed = pings.length;
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    super.dispose();
  }
}
