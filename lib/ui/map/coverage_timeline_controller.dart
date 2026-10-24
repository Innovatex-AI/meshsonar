// State behind the coverage-growth slider: which day is scrubbed to, play/pause, the debounced re-query and the
// request budget. The region's first-data date and the day->`until` maths live in lib/core/coverage_timeline.dart.
//
// Requests: scrubbing is debounced (the last position wins), playback issues one request per tick, and every
// request goes through a [RateBudget] (server limit 120/min). Stale answers are dropped by AppState's request
// sequence number (a newer request supersedes an older one; the in-flight HTTP call itself is not aborted).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/coverage_query.dart';
import '../../core/coverage_timeline.dart';
import '../../core/region_timeline_api.dart';

enum TimelineLoad { idle, loading, ready, unavailable }

class CoverageTimelineController extends ChangeNotifier {
  CoverageTimelineController({
    required this.getQuery,
    required this.setQuery,
    required this.baseUrl,
    this.fetchTimeline = fetchRegionTimeline,
    DateTime Function()? clock,
    RateBudget? budget,
    this.debounce = const Duration(milliseconds: 350),
    this.playTick = const Duration(milliseconds: 1200),
  })  : _clock = clock ?? DateTime.now,
        _budget = budget ?? RateBudget(now: clock);

  final CoverageQuery Function() getQuery;
  final void Function(CoverageQuery) setQuery;

  /// The viewed region's base URL (null = unknown, timeline unavailable).
  final String? Function() baseUrl;
  final Future<RegionTimeline?> Function(String baseUrl) fetchTimeline;
  final DateTime Function() _clock;
  final RateBudget _budget;
  final Duration debounce;
  final Duration playTick;

  TimelineLoad _load = TimelineLoad.idle;
  TimelineLoad get load => _load;
  TimelineScale? _scale;
  TimelineScale? get scale => _scale;
  int _index = 0;

  /// The scrubbed step (the live step when not scrubbed).
  int get index => _scale == null ? 0 : _index;
  bool get isLive => _scale == null || _scale!.isLive(_index);
  bool _playing = false;
  bool get playing => _playing;
  String? _loadedFor;
  Timer? _debounceTimer;
  Timer? _playTimer;
  bool _disposed = false;

  /// "Coverage as of Oct 18, 2026" while scrubbed back, else null.
  String? get asOfLabel => _scale?.asOfLabel(_index);

  /// Loads the first-data date for the current region (once per base URL; call again after a region change).
  Future<void> ensureLoaded() async {
    final url = baseUrl();
    if (url == null) {
      _set(TimelineLoad.unavailable);
      return;
    }
    if (_loadedFor == url && _load != TimelineLoad.unavailable) return;
    if (_load == TimelineLoad.loading) return;
    _loadedFor = url;
    pause();
    reset(apply: false);
    _scale = null;
    _set(TimelineLoad.loading);
    final tl = await fetchTimeline(url);
    if (_disposed || _loadedFor != url) return;
    final first = tl?.firstDay;
    final sc = first == null ? null : TimelineScale.forRange(first, _clock());
    _scale = sc;
    _index = sc?.liveIndex ?? 0;
    final q = getQuery();
    if (sc != null && q.until != null) _index = sc.indexOf(q.until);
    _set(sc == null ? TimelineLoad.unavailable : TimelineLoad.ready);
  }

  /// Forget the loaded region (the viewed region changed): back to live, reload on next [ensureLoaded].
  void regionChanged() {
    _loadedFor = null;
    pause();
    _debounceTimer?.cancel();
    _scale = null;
    _index = 0;
    _load = TimelineLoad.idle;
    if (getQuery().until != null) setQuery(getQuery().copyWith(clearUntil: true));
    notifyListeners();
  }

  /// Slider moved to step [i]: the label updates now, the request after the debounce.
  void scrubTo(int i) {
    final sc = _scale;
    if (sc == null) return;
    final next = sc.clamp(i);
    if (next == _index) return;
    _index = next;
    notifyListeners();
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _apply);
  }

  /// Back to live (no `until`).
  void reset({bool apply = true}) {
    pause();
    _debounceTimer?.cancel();
    final sc = _scale;
    _index = sc?.liveIndex ?? 0;
    notifyListeners();
    if (apply) _apply();
  }

  void play() {
    final sc = _scale;
    if (sc == null || _playing) return;
    if (sc.isLive(_index)) {
      _index = 0; // play from the start when sitting at live
      _debounceTimer?.cancel();
      _apply();
    }
    _playing = true;
    notifyListeners();
    _schedulePlay();
  }

  void pause() {
    _playTimer?.cancel();
    if (_playing) {
      _playing = false;
      notifyListeners();
    }
  }

  void _schedulePlay() {
    _playTimer?.cancel();
    _playTimer = Timer(playTick, () {
      final sc = _scale;
      if (!_playing || sc == null || _disposed) return;
      final next = sc.nextForPlay(_index);
      if (next == null) {
        pause();
        return;
      }
      _index = next;
      notifyListeners();
      _apply();
      if (sc.isLive(_index)) {
        pause();
      } else {
        _schedulePlay();
      }
    });
  }

  Timer? _budgetTimer;
  void _apply() {
    final sc = _scale;
    if (sc == null || _disposed) return;
    final wait = _budget.wait();
    if (wait > Duration.zero) {
      // Over the request budget: hold this position and send it when a slot frees (the newest position wins).
      _budgetTimer?.cancel();
      _budgetTimer = Timer(wait, _apply);
      return;
    }
    _budget.tryAcquire();
    final until = sc.untilFor(_index);
    final q = getQuery();
    setQuery(until == null ? q.copyWith(clearUntil: true) : q.copyWith(until: until));
  }

  void _set(TimelineLoad l) {
    _load = l;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _playTimer?.cancel();
    _budgetTimer?.cancel();
    super.dispose();
  }
}
