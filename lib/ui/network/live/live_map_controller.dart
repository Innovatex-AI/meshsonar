// The state of Network > Map, the live packet map with replay (AZ-3.3). One controller per region view:
//   - LIVE: packets from the stream (NetworkLiveStream: `/v1/stream`, else today's region feed) are drawn as they
//     propagate, and listed in the feed.
//   - PAUSED: nothing is drawn; new packets still arrive and are counted ("+N while paused").
//   - REPLAY: packets from `/v1/replay` (else `region-replay`) are played by the ReplayClock at 0.25x to 8x, paged an
//     hour at a time as the clock moves; "Jump to live" goes back.
// The scrubber shows packet density over the chosen window (`/v1/packets/density`, else counted from replay pages)
// and starts a replay where it is dropped. Filters (type, observer, My nodes) apply to the feed and the drawing. A
// packet opened elsewhere ("Show on map" in the packet detail) is drawn as the focus until it is closed.
//
// Battery rules: [setActive] false (section off screen, app in background, Saver mode) drops the stream and stops
// the animation; true resumes the stream with Last-Event-ID. Frames are driven by the view's ticker, capped by
// PowerProfile.current.mapFps.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../core/v1/live_api.dart';
import '../../../core/v1/live_geometry.dart';
import '../../../core/v1/live_replay.dart';
import '../../../core/v1/network_api.dart' show NetworkReadSource;
import '../../../core/v1/favourites_store.dart' show MyNodes;

enum LiveMode { live, paused, replay }

/// One packet being drawn.
class LiveAnimation {
  final LiveV2Packet packet;
  final LiveDrawing drawing;

  /// Controller time (ms) when it started.
  final int startMs;

  /// Speed it plays at (replay speed; 1 live).
  final double speed;
  const LiveAnimation(this.packet, this.drawing, this.startMs, this.speed);
}

/// The filters of the map and feed.
class LiveFilter {
  /// Packet type numbers; empty = every type.
  final Set<int> types;

  /// One observer id; null = all.
  final String? observerId;
  final bool myNodesOnly;
  const LiveFilter({this.types = const {}, this.observerId, this.myNodesOnly = false});

  static const LiveFilter none = LiveFilter();
  bool get isEmpty => types.isEmpty && observerId == null && !myNodesOnly;

  LiveFilter copyWith({Set<int>? types, String? observerId, bool clearObserver = false, bool? myNodesOnly}) => LiveFilter(
      types: types ?? this.types, observerId: clearObserver ? null : (observerId ?? this.observerId), myNodesOnly: myNodesOnly ?? this.myNodesOnly);

  /// True when [p] passes. My nodes: the origin, a resolved hop, a hop prefix of one of my keys, or a starred observer.
  bool matches(LiveV2Packet p, MyNodes mine) {
    if (types.isNotEmpty && !types.contains(p.type)) return false;
    if (observerId != null && !p.observations.any((o) => o.observer.id == observerId)) return false;
    if (myNodesOnly) {
      if (mine.isEmpty) return false;
      final hit = mine.hasKey(p.origin?.key) ||
          p.observations.any((o) => mine.observerIds.contains(o.observer.id) || mine.hasKey(o.observer.id)) ||
          p.paths.any((path) => path.hops.any((h) => mine.hasKey(h.node?.key) || mine.matchesPrefix(h.prefix)));
      if (!hit) return false;
    }
    return true;
  }
}

class LiveMapController extends ChangeNotifier {
  final String baseUrl, regionSlug;
  final NetworkLiveStream stream;
  final LiveReplayApi api;

  /// Animation timing (CS-162 behaviour): about 660 ms per hop at 1x, then a fade.
  static const int hopMs = 660;
  static const int fadeMs = 2000;
  static const int maxConcurrent = 20;
  static const int maxFeed = 200;

  LiveMapController({required this.baseUrl, required this.regionSlug, NetworkLiveStream? stream, LiveReplayApi? api, DateTime Function()? clock})
      : stream = stream ?? networkLiveStreamFactory(baseUrl, LiveSubscription(region: regionSlug)),
        api = api ?? liveReplayApiFactory(baseUrl),
        clock = clock ?? DateTime.now;

  final DateTime Function() clock;
  StreamSubscription<NetLiveEvent>? _evSub;
  StreamSubscription<NetLiveState>? _stSub;
  bool _started = false, _active = false, _disposed = false;

  LiveMode _mode = LiveMode.live;
  LiveMode get mode => _mode;
  NetLiveState get streamState => stream.state;
  NetworkReadSource get source => stream.mode;

  int? observersOnline;
  bool? nodeListTrusted;
  String? nodeListReason;

  /// A plain note for the status line ("Caught up 37 packets the stream skipped").
  String? note;

  // ---- positions
  LivePositions positions = LivePositions.none;
  void setPositions(LivePositions p) {
    positions = p;
    _notify();
  }

  // ---- filters
  LiveFilter _filter = LiveFilter.none;
  LiveFilter get filter => _filter;
  MyNodes _mine = MyNodes.empty;
  MyNodes get myNodes => _mine;
  void setFilter(LiveFilter f) {
    _filter = f;
    _notify();
  }

  void setMyNodes(MyNodes m) {
    _mine = m;
    _notify();
  }

  bool passes(LiveV2Packet p) => _filter.matches(p, _mine);

  // ---- feed (newest first)
  final List<LiveV2Packet> _feed = [];
  final Map<String, LiveV2Packet> _byHash = {};
  List<LiveV2Packet> get feed => [for (final p in _feed) if (passes(p)) p];
  List<LiveV2Packet> get allPackets => List.unmodifiable(_feed);

  int missedWhilePaused = 0;

  // ---- animation
  int _nowMs = 0;
  int get nowMs => _nowMs;
  final List<LiveAnimation> _anims = [];
  List<LiveAnimation> get animations => List.unmodifiable(_anims);
  int droppedAnimations = 0;

  // ---- focus ("Show on map")
  LiveV2Packet? focus;
  LiveDrawing? get focusDrawing => focus == null ? null : drawLivePacket(focus!, positions);

  // ---- replay
  ReplayClock? _clock;
  ReplayClock? get replayClock => _clock;
  double speed = 1;
  String? _replayCursor;
  NetworkReadSource? _replaySource;
  DateTime? _replayPageTo;
  bool _fetchingReplay = false;
  String? replayError;
  int _replayGen = 0;

  // ---- density
  String window = '1h';
  DensityRead? density;
  bool densityLoading = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Opens the stream (once) and loads the density.
  void start() {
    if (_started) return;
    _started = true;
    _evSub = stream.events.listen(_onEvent);
    _stSub = stream.states.listen((_) => _notify());
    unawaited(loadDensity());
  }

  /// False while the section is off screen, the app is in the background or the mode is Saver: the stream is
  /// dropped and nothing animates. True resumes (with Last-Event-ID).
  void setActive(bool on) {
    if (on == _active && _started) return;
    _active = on;
    if (!_started) start();
    if (on) {
      // The stream keeps running while PAUSED too (it counts what arrives); only the drawing stops.
      stream.start();
      stream.resume();
    } else {
      stream.pause();
    }
    _notify();
  }

  bool get active => _active;

  void _remember(LiveV2Packet p) {
    final old = _byHash[p.hash];
    if (old != null) {
      final m = old.mergedWith(p);
      _byHash[p.hash] = m;
      final i = _feed.indexWhere((x) => x.hash == p.hash);
      if (i >= 0) _feed[i] = m;
      return;
    }
    _byHash[p.hash] = p;
    // Newest first by first sighting.
    var i = 0;
    while (i < _feed.length && _feed[i].firstSeen.isAfter(p.firstSeen)) {
      i++;
    }
    _feed.insert(i, p);
    while (_feed.length > maxFeed) {
      _byHash.remove(_feed.removeLast().hash);
    }
  }

  void _animate(LiveV2Packet p, double sp) {
    if (!passes(p)) return;
    final d = drawLivePacket(p, positions);
    if (d.isEmpty) return;
    _anims.removeWhere((a) => a.packet.hash == p.hash);
    if (_anims.length >= maxConcurrent) {
      droppedAnimations++;
      return;
    }
    _anims.add(LiveAnimation(p, d, _nowMs, sp));
  }

  void _onEvent(NetLiveEvent e) {
    switch (e) {
      case NetHello():
        break;
      case NetStatus(:final observersOnline, :final nodeListTrusted, :final nodeListReason):
        if (observersOnline != null) this.observersOnline = observersOnline;
        if (nodeListTrusted != null) this.nodeListTrusted = nodeListTrusted;
        if (nodeListReason != null) this.nodeListReason = nodeListReason;
      case NetPacket(:final packet):
        _remember(packet);
        if (_mode == LiveMode.live && _active) {
          _animate(_byHash[packet.hash]!, 1);
        } else if (_mode != LiveMode.live && passes(packet)) {
          missedWhilePaused++;
        }
      case NetPacketUpdate(:final hash, :final observations, :final paths, :final settled):
        final old = _byHash[hash];
        if (old == null) break;
        final m = old.merged(obs: observations, newPaths: paths, settled: settled);
        _byHash[hash] = m;
        final i = _feed.indexWhere((x) => x.hash == hash);
        if (i >= 0) _feed[i] = m;
        if (_mode == LiveMode.live && _active && paths.isNotEmpty) _animate(m, 1);
      case NetMessage(:final message):
        final old = _byHash[message.id];
        if (old != null) {
          final m = old.withMessage(message);
          _byHash[message.id] = m;
          final i = _feed.indexWhere((x) => x.hash == message.id);
          if (i >= 0) _feed[i] = m;
        }
      case NetMessageHidden(:final id):
        final old = _byHash[id];
        if (old?.message != null) {
          final m = old!.withMessage(old.message!.hide());
          _byHash[id] = m;
          final i = _feed.indexWhere((x) => x.hash == id);
          if (i >= 0) _feed[i] = m;
        }
      case NetPulse():
      case NetHeartbeat():
        break;
      case NetMissed(:final count, :final refetch):
        note = 'The stream skipped $count packets; catching up.';
        if (refetch != null) unawaited(_catchUp(refetch, count));
      case NetReset(:final refetch):
        note = 'The live feed restarted; catching up on the gap.';
        if (refetch != null) unawaited(_catchUp(refetch, null));
    }
    _notify();
  }

  Future<void> _catchUp(String refetch, int? count) async {
    try {
      final ps = await api.refetch(refetch);
      for (final p in ps) {
        _remember(p);
      }
      note = ps.isEmpty ? null : 'Caught up ${ps.length} packets the stream skipped (listed, not animated).';
    } catch (_) {
      note = count == null ? 'The live feed restarted; the gap could not be loaded.' : 'The stream skipped $count packets; they could not be loaded.';
    }
    _notify();
  }

  /// Advances the animation and the replay by [dt] of wall time.
  void tick(Duration dt) {
    if (!_active || _mode == LiveMode.paused) return;
    _nowMs += dt.inMilliseconds;
    final c = _clock;
    if (_mode == LiveMode.replay && c != null) {
      for (final p in c.tick(dt)) {
        _remember(p);
        _animate(p, c.speed);
      }
      if (c.pending < 20) unawaited(_fetchMoreReplay());
      if (c.exhausted && !_fetchingReplay && _replayCursor == null && _replayPageTo != null && !_replayPageTo!.isBefore(clock().toUtc())) {
        jumpToLive();
        return;
      }
    }
    _anims.removeWhere((a) => _nowMs - a.startMs > durationMs(a));
    _notify();
  }

  /// How long [a] is on screen (ms of controller time).
  static int durationMs(LiveAnimation a) => ((math.max(1, a.drawing.steps) * hopMs) / a.speed).round() + fadeMs;

  /// 0..steps progress of [a] (fractional), and its opacity (1 until the path is drawn, then fading to 0).
  (double, double) progressOf(LiveAnimation a) {
    final t = (_nowMs - a.startMs) * a.speed;
    final drawMs = math.max(1, a.drawing.steps) * hopMs;
    final prog = (t / hopMs).clamp(0, math.max(1, a.drawing.steps)).toDouble();
    final fadeT = (_nowMs - a.startMs) - drawMs / a.speed;
    final alpha = fadeT <= 0 ? 1.0 : (1 - fadeT / fadeMs).clamp(0.0, 1.0);
    return (prog, alpha);
  }

  bool get animating => _anims.isNotEmpty || (_mode == LiveMode.replay && !(_clock?.exhausted ?? true));

  // ---- VCR
  void pause() {
    if (_mode == LiveMode.paused) return;
    _mode = LiveMode.paused;
    missedWhilePaused = 0;
    _notify();
  }

  /// Play: resume the replay when one is loaded, else back to live.
  void play() {
    if (_mode != LiveMode.paused) return;
    _mode = _clock != null && !_clock!.exhausted ? LiveMode.replay : LiveMode.live;
    if (_mode == LiveMode.live) _clock = null;
    missedWhilePaused = 0;
    _notify();
  }

  void jumpToLive() {
    _replayGen++;
    _clock = null;
    _replayCursor = null;
    _replaySource = null;
    _replayPageTo = null;
    _anims.clear();
    _mode = LiveMode.live;
    missedWhilePaused = 0;
    speed = 1;
    replayError = null;
    _notify();
  }

  void setSpeed(double s) {
    speed = replaySpeeds.contains(s) ? s : 1;
    _clock?.setSpeed(speed);
    _notify();
  }

  /// Starts a replay at [from] (clamped to the server's horizon and to now).
  Future<void> replayFrom(DateTime from) async {
    final now = clock().toUtc();
    final horizon = now.subtract(replayHorizon(source));
    var at = from.toUtc();
    if (at.isBefore(horizon)) at = horizon;
    if (at.isAfter(now)) {
      jumpToLive();
      return;
    }
    final gen = ++_replayGen;
    _clock = ReplayClock(start: at, speed: speed);
    _anims.clear();
    _replayCursor = null;
    _replaySource = null;
    _replayPageTo = null;
    replayError = null;
    _mode = LiveMode.replay;
    _notify();
    await _fetchReplay(at, gen);
  }

  Future<void> _fetchReplay(DateTime from, int gen, {String? cursor, NetworkReadSource? src}) async {
    if (_fetchingReplay) return;
    _fetchingReplay = true;
    try {
      final page = await api.replay(from, types: _filter.types, observer: _filter.observerId, cursor: cursor, cursorSource: src);
      if (gen != _replayGen) return;
      _clock?.add(page.packets);
      _replaySource = page.source;
      if (page.next != null) {
        _replayCursor = page.next;
        _replayPageTo = from;
      } else {
        _replayCursor = null;
        _replayPageTo = page.to ?? from.add(const Duration(hours: 1));
      }
      replayError = null;
    } on V1Error catch (e) {
      if (gen == _replayGen) replayError = e.offline ? 'Replay needs a connection.' : e.message;
    } finally {
      _fetchingReplay = false;
      _notify();
    }
  }

  Future<void> _fetchMoreReplay() async {
    if (_fetchingReplay || _mode != LiveMode.replay) return;
    final gen = _replayGen;
    if (_replayCursor != null) {
      // Same hour, next page (a /v1 cursor) or, on the old server, its nextFrom time.
      final from = _replaySource == NetworkReadSource.legacy ? (DateTime.tryParse(_replayCursor!)?.toUtc() ?? _replayPageTo!) : _replayPageTo!;
      await _fetchReplay(from, gen, cursor: _replaySource == NetworkReadSource.legacy ? null : _replayCursor, src: _replaySource == NetworkReadSource.legacy ? null : _replaySource);
      return;
    }
    final to = _replayPageTo;
    if (to == null || !to.isBefore(clock().toUtc())) return;
    await _fetchReplay(to, gen);
  }

  // ---- density
  Future<void> setWindow(String w) async {
    if (!liveWindows.containsKey(w) || w == window) return;
    window = w;
    _notify();
    await loadDensity();
  }

  /// The window's start and end now.
  (DateTime, DateTime) windowRange() {
    final to = clock().toUtc();
    return (to.subtract(liveWindows[window]!.$1), to);
  }

  Future<void> loadDensity() async {
    densityLoading = true;
    _notify();
    try {
      final d = await api.density(window, types: _filter.types);
      if (d != null) {
        density = d;
      } else {
        // Old server: count what replay pages the phone can get cheaply (the last hour), plus what it has seen live.
        final (from, to) = windowRange();
        final b = bucketDuration(liveWindows[window]!.$2);
        final times = <DateTime>[for (final p in _feed) p.firstSeen];
        if (window == '1h') {
          try {
            final page = await api.replay(from, to: to);
            times.addAll([for (final p in page.packets) p.firstSeen]);
            for (final p in page.packets) {
              _remember(p);
            }
          } catch (_) {}
        }
        density = DensityRead.count(times.toSet(), from, to, b);
      }
    } on V1Error {
      density = null;
    } finally {
      densityLoading = false;
      _notify();
    }
  }

  // ---- focus
  void showPacket(LiveV2Packet p) {
    focus = p;
    _remember(p);
    _notify();
  }

  void clearFocus() {
    focus = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _evSub?.cancel();
    _stSub?.cancel();
    unawaited(stream.dispose());
    api.close();
    super.dispose();
  }
}
