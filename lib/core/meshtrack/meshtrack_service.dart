// MeshTrackService: the one object the app wires for MeshTrack (meshtrack plan sections 3-8). It owns the sharing
// state of every group, decides when to send (SmartBeacon + gates), parses what friends send, and exposes one
// listenable state for the Drive chip, the Group sheet and the Friends map layer. API summary: API.md next to this file.
//
// Privacy rules enforced here (section 6): nothing is sent when the zones are not loaded, inside a zone, or within
// 200 m (+ fix accuracy) outside any zone edge; manual sends and meet-up pins obey the zones too; sharing ends with
// its duration (This drive / 1 hour / Until I stop) and after 5 min without the radio, sending `MT1 x` once per group;
// share switches never turn back on by themselves (only "Share on every drive", at drive start). Log lines never
// carry a code, a coordinate or a name. Sends never go inside a ping listen window, nor within 3 s of a due ping.
//
// Pure Dart: no Flutter imports. Clock, randomness, storage, radio send and budget are injected.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../../chat/channel_text_tap.dart' show ChannelTextEvent, ChannelTextTap, TapVerdict;
import '../../radio/airtime.dart' show groupTextPacketBytes;
import '../privacy_zones.dart' show PrivacyZones, distanceM;
import 'ask_location.dart';
import 'interop.dart';
import 'mt_wire.dart';
import 'plus_code.dart';
import 'smart_beacon.dart';
import 'track_group.dart';

export 'ask_location.dart';
export 'interop.dart' show MtSource;
export 'smart_beacon.dart' show MtFix, MtRate, kMtMaxAccuracyM, meshTrackPositionAirtime;
export 'track_group.dart'
    show MeshTrackGroup, MtFriend, MtMeetPin, MtStaleness, MtTrailPoint, mtStaleness, kMtMaxNames;

/// Most groups shared to at once.
const int kMtMaxSharingGroups = 3;

/// No position within this far outside a privacy zone edge (plus the fix's accuracy).
const double kMtZoneBufferM = 200;

/// Back-to-back MeshTrack sends (one per group) go this far apart.
const Duration kMtSendSpacing = Duration(seconds: 3);

/// A send waits while the next ping is due within this long.
const Duration kMtPingGuard = Duration(seconds: 3);

/// A held send goes this long after the ping's listen window closes.
const Duration kMtAfterWindow = Duration(seconds: 1);

/// A queued message older than this is dropped (its position is out of date).
const Duration kMtQueueMaxAge = Duration(seconds: 60);

/// Sharing turns off after the radio has been gone this long.
const Duration kMtDisconnectStopAfter = Duration(minutes: 5);

/// A fix older than this does not count ("Waiting for GPS").
const Duration kMtFixMaxAge = Duration(seconds: 30);

/// Answers to "where are you?": random 2-10 s delay, at most one per 30 s per group.
const Duration kMtAnswerMinDelay = Duration(seconds: 2);
const Duration kMtAnswerMaxDelay = Duration(seconds: 10);
const Duration kMtAnswerGap = Duration(seconds: 30);

/// Asking "where are you?" is allowed once per 60 s per group (the button shows "Asked").
const Duration kMtAskGap = Duration(seconds: 60);

/// One hour of sharing.
const Duration kMtOneHour = Duration(hours: 1);

/// A stop message owed to a group that was left while the radio was gone goes on reconnect, if within this long.
const Duration kMtPendingStopFor = Duration(minutes: 10);

/// Below this speed a moving position carries no `s` (a rounded `s0` would read as parked).
const double kMtMinSpeedKmh = 1;

/// How long "Sharing slower: airtime limit" shows after a refused send.
const Duration kMtAirtimeNoticeFor = Duration(minutes: 2);

/// Sends the text on the group's channel (the app adds the region scope / flood scope). True when handed to the
/// radio.
typedef MtSendText = Future<bool> Function(int channelId, String text);

/// The transmit budget's answer for one send (TxArbiter `track` class + `maxTextBytes`).
enum MtBudget { ok, airtimeLimit, tooLong }

typedef MtBudgetCheck = MtBudget Function(int channelId, String text);

/// Where `meshtrack_last.json` lives (the app gives the file in the app support dir).
abstract class MtLastKnownStore {
  Future<String?> read();
  Future<void> write(String json);
  Future<void> clear();
}

/// The ping engine's listen window: [listening] while a ping's window is open (`EngineStatus.state == pinging` or
/// `heardSoFar != null`); [nextPingAt] the next auto-ping (`EngineStatus.nextPingAt`).
class MtPingWindow {
  final bool listening;
  final DateTime? nextPingAt;
  const MtPingWindow({this.listening = false, this.nextPingAt});
  static const MtPingWindow idle = MtPingWindow();
}

/// How long a Share switch stays on.
enum MtShareDuration { thisDrive, oneHour, untilStopped }

/// "Position friends see": Exact (11-digit code, about 3 m) or Approximate (8 digits, about 275 m).
enum MtPositionMode { exact, approximate }

/// One group's settings, as stored in app Settings `meshtrack.groups`.
class MtGroupConfig {
  final int channelId;

  /// The channel's name (display only).
  final String name;
  final bool see;
  final bool share;
  final MtShareDuration duration;

  /// End of a 1-hour share.
  final DateTime? shareUntil;

  /// "Share on every drive" (default off).
  final bool shareEveryDrive;

  /// False when the channel is not on the connected radio ("Not on this radio"): no sends, sharing off.
  final bool onRadio;
  const MtGroupConfig({
    required this.channelId,
    required this.name,
    this.see = true,
    this.share = false,
    this.duration = MtShareDuration.thisDrive,
    this.shareUntil,
    this.shareEveryDrive = false,
    this.onRadio = true,
  });

  MtGroupConfig copyWith({String? name, bool? see, bool? share, MtShareDuration? duration, Object? shareUntil = _keep, bool? shareEveryDrive, bool? onRadio}) =>
      MtGroupConfig(
        channelId: channelId,
        name: name ?? this.name,
        see: see ?? this.see,
        share: share ?? this.share,
        duration: duration ?? this.duration,
        shareUntil: identical(shareUntil, _keep) ? this.shareUntil : shareUntil as DateTime?,
        shareEveryDrive: shareEveryDrive ?? this.shareEveryDrive,
        onRadio: onRadio ?? this.onRadio,
      );
  static const Object _keep = Object();

  Map<String, Object?> toJson() => {
        'channelId': channelId,
        'name': name,
        'see': see,
        'share': share,
        'duration': duration.name,
        'shareUntil': shareUntil?.toUtc().toIso8601String(),
        'shareEveryDrive': shareEveryDrive,
      };

  static MtGroupConfig? fromJson(Object? j) {
    if (j is! Map || j['channelId'] is! int) return null;
    return MtGroupConfig(
      channelId: j['channelId'] as int,
      name: j['name'] is String ? j['name'] as String : '',
      see: j['see'] != false,
      share: j['share'] == true,
      duration: MtShareDuration.values.where((d) => d.name == j['duration']).firstOrNull ?? MtShareDuration.thisDrive,
      shareUntil: j['shareUntil'] is String ? DateTime.tryParse(j['shareUntil'] as String) : null,
      shareEveryDrive: j['shareEveryDrive'] == true,
    );
  }
}

/// Why my position is (or is not) going out right now. The Drive chip and Group sheet header show it.
enum MtShareReason {
  /// Not sharing with any group.
  off,

  /// Sharing and sending normally.
  sharing,

  /// Share is on for "This drive" but no drive is running.
  waitingForDrive,

  /// No fix, a fix older than 30 s, or accuracy worse than 100 m ("Waiting for GPS").
  waitingForGps,

  /// Inside a privacy zone or its 200 m buffer ("Sharing paused: privacy zone").
  privacyZone,

  /// Privacy zones not read yet: nothing is sent (fail closed).
  zonesNotLoaded,

  /// A send was refused by the airtime budget or region cap ("Sharing slower: airtime limit").
  airtimeLimit,

  /// Radio not connected; sharing ends after 5 min.
  radioDisconnected,
}

/// Why sharing with a group ended.
enum MtStopCause {
  /// The person turned Share off.
  user,

  /// "This drive" and the drive stopped.
  driveStopped,

  /// "1 hour" ran out.
  durationEnded,

  /// No radio for 5 min.
  radioDisconnected,

  /// Leave group.
  left,

  /// The channel is gone from the radio or the group list (no stop message possible).
  removed,
}

/// Results of commands.
enum MtResult {
  /// Done / queued for the radio.
  ok,
  unknownGroup,

  /// A 4th group ("Up to 3 groups").
  tooManyGroups,
  privacyZone,
  zonesNotLoaded,
  waitingForGps,
  radioDisconnected,

  /// The channel is not on the radio.
  notOnRadio,

  /// Asked within the last 60 s ("Asked").
  tooSoon,
}

/// One-off things the UI shows as a toast.
sealed class MtEvent {
  const MtEvent();
}

/// "Sam asked where you are" with "Send my position" (not sharing with that group).
final class MtAskedWhileNotSharing extends MtEvent {
  final int channelId;
  final String name;
  const MtAskedWhileNotSharing(this.channelId, this.name);
}

/// Sharing with [channelId] ended ("Stopped sharing: radio disconnected" + "Share again").
final class MtSharingStopped extends MtEvent {
  final int channelId;
  final MtStopCause cause;
  const MtSharingStopped(this.channelId, this.cause);
}

/// One group as the Group sheet shows it.
class MtGroupView {
  final MtGroupConfig config;

  /// Friends heard (most recent first); empty when See is off.
  final List<MtFriend> friends;
  final MtMeetPin? meet;

  /// "3 heard in the last 30 min".
  final int heardLast30Min;

  /// Share is on and active now (a This-drive share without a drive is not).
  final bool sharingNow;

  /// "Asked" until this time (the Where are you? button is disabled).
  final DateTime? askedUntil;

  /// Who that last "Where are you?" went to; null = everyone in the group. Only that row says "Asked".
  final String? askedName;

  /// When my position last went to this group.
  final DateTime? lastSentAt;
  const MtGroupView({
    required this.config,
    required this.friends,
    required this.heardLast30Min,
    required this.sharingNow,
    this.meet,
    this.askedUntil,
    this.askedName,
    this.lastSentAt,
  });
  int get channelId => config.channelId;
  String get name => config.name;
}

/// Most position messages kept per group for "Show position messages".
const int kMtMessageLogMax = 100;

/// One MeshTrack message heard or sent on a group's channel, for "Show position messages" (channel detail). Memory only:
/// never stored as chat, never notified, never in a backup, export or search; gone after 24 h, on Leave and on Delete my
/// data.
class MtLoggedMessage {
  /// Who sent it; null = me.
  final String? name;

  /// The message body as on the air (`MT1 @87G8Q2X5+7F2 s34 c270`).
  final String body;

  /// The parsed message; null for another app's position format.
  final MtMessage? message;
  final DateTime at;
  const MtLoggedMessage({required this.name, required this.body, required this.at, this.message});
  bool get mine => name == null;
}

/// My last sent position (the hollow ring on the map while sharing). Memory only.
class MtMyPosition {
  final double lat;
  final double lon;
  final DateTime at;
  const MtMyPosition(this.lat, this.lon, this.at);
}

/// Everything the UI shows. Immutable snapshot; a new one after every change and every 15 s (staleness).
class MeshTrackState {
  final List<MtGroupView> groups;
  final MtShareReason reason;

  /// Names of the groups shared to now, in order ("Sharing: Family, Club").
  final List<String> sharingNames;
  final MtMyPosition? myLastSent;
  final bool driving;
  final bool radioConnected;
  final MtPositionMode positionMode;
  final MtRate rate;
  final bool answerRequests;

  /// People asked for their location with "Ask for location" who answered with a position, newest first, within
  /// [kAskedOnMapFor]. Memory only: never saved, never uploaded.
  final List<MtAskedPosition> asked;
  const MeshTrackState({
    this.groups = const [],
    this.reason = MtShareReason.off,
    this.sharingNames = const [],
    this.myLastSent,
    this.driving = false,
    this.radioConnected = false,
    this.positionMode = MtPositionMode.exact,
    this.rate = MtRate.smart,
    this.answerRequests = true,
    this.asked = const [],
  });

  /// At least one Share switch is on (even if not sending right now).
  bool get sharing => groups.any((g) => g.config.share);
  int get sharingCount => groups.where((g) => g.config.share).length;

  /// A 4th Share switch is disabled ("Up to 3 groups").
  bool get canShareMore => sharingCount < kMtMaxSharingGroups;

  MtGroupView? group(int channelId) => groups.where((g) => g.channelId == channelId).firstOrNull;
}

/// At most this many friends are remembered per channel that is not a group (see [MeshTrackService.strayShares]).
const int kMtMaxStraySenders = 40;

/// One friend's position updates heard in a channel that is not a MeshTrack group on this phone. Memory only.
class MtStrayShare {
  final String name;

  /// How many different updates were heard from them.
  final int updates;

  /// When the newest was received.
  final DateTime lastAt;

  /// The newest update as it came (wire text), kept so the friend appears at once if the channel becomes a group.
  final String lastBody;
  final DateTime? lastSenderTs;
  final double? snr;
  final int? pathLen;
  const MtStrayShare({required this.name, required this.updates, required this.lastAt, required this.lastBody, this.lastSenderTs, this.snr, this.pathLen});

  @override
  String toString() => 'MtStrayShare($updates updates)'; // never the name or the position
}

/// One inbound channel message, as the chat layer received it (before it is stored).
class MtInboundText {
  final int channelId;

  /// The raw text as received: `name: body` (MeshCore adds the sender prefix).
  final String text;

  /// The sender's timestamp from the packet, when known.
  final DateTime? senderTs;

  /// When this phone received it.
  final DateTime receivedAt;
  final double? snr;

  /// 0 = direct; null = unknown.
  final int? pathLen;

  /// Already split by the chat layer ([fromTapEvent]); null = split [text] here.
  final ({String? name, String body})? split;
  const MtInboundText({required this.channelId, required this.text, required this.receivedAt, this.senderTs, this.snr, this.pathLen})
      : split = null;

  /// From the chat inbound tap's event (lib/chat/channel_text_tap.dart, MT-4): sender name and body already split,
  /// sender time in unix seconds (0 = unknown), receive time in epoch ms.
  MtInboundText.fromTapEvent(ChannelTextEvent e)
      : channelId = e.channelId,
        text = e.senderName == null ? e.body : '${e.senderName}: ${e.body}',
        receivedAt = DateTime.fromMillisecondsSinceEpoch(e.receivedMs, isUtc: true),
        senderTs = e.senderTs > 0 ? DateTime.fromMillisecondsSinceEpoch(e.senderTs * 1000, isUtc: true) : null,
        snr = e.snr,
        pathLen = e.pathLen,
        split = (name: e.senderName, body: e.body);
}

enum _Kind { position, stop, request, meet }

class _Queued {
  final int channelId;
  final String text;
  final _Kind kind;
  final DateTime at;

  /// Not sent; [airtime] = refused by the airtime budget or region cap (not a failure or a vanished group).
  final void Function(bool airtime)? onRefused;
  final void Function()? onSent;
  _Queued(this.channelId, this.text, this.kind, this.at, {this.onRefused, this.onSent});
}

class _Group {
  MtGroupConfig config;
  final TrackGroup track;
  DateTime? lastSentAt;
  DateTime? askedUntil;
  String? askedName;
  DateTime? lastAnswerAt;
  DateTime? lastAskedToastAt;
  Timer? answerTimer;

  /// A position went out to this group in the current share session (the stop message is worth sending).
  bool sentThisSession = false;

  /// Sharing ended while the radio was gone: `MT1 x` goes on reconnect.
  bool stopPending = false;

  /// Recent MeshTrack messages on this channel, oldest first (memory only).
  final List<MtLoggedMessage> log = [];
  _Group(this.config) : track = TrackGroup(config.channelId);

  void addLog(MtLoggedMessage m) {
    log.add(m);
    if (log.length > kMtMessageLogMax) log.removeRange(0, log.length - kMtMessageLogMax);
  }
}

/// The MeshTrack engine. See API.md for the wiring.
class MeshTrackService {
  final MtSendText _send;
  final MtBudgetCheck _budgetOf;
  final PrivacyZones Function() _zonesOf;
  final String? Function() _selfNameOf;
  final MtLastKnownStore? _store;
  final Duration Function() _airtime;
  final void Function(String line) _log;
  final DateTime Function() _now;
  final math.Random _random;
  final void Function(List<MtGroupConfig> groups)? _groupsSink;

  final Map<int, _Group> _groups = {};
  final Map<int, Object?> _pendingRestore = {};

  /// Stop messages owed to groups that were left while the radio was gone: channel -> send by (once, on reconnect).
  final Map<int, DateTime> _orphanStops = {};
  final SmartBeacon _beacon = SmartBeacon();
  final List<_Queued> _queue = [];
  final List<void Function()> _listeners = [];
  final StreamController<MeshTrackState> _states = StreamController<MeshTrackState>.broadcast();
  final StreamController<MtEvent> _events = StreamController<MtEvent>.broadcast();

  MtFix? _lastFix;
  bool _radio = false;
  bool _driving = false;
  MtPingWindow _window = MtPingWindow.idle;
  DateTime? _windowClosedAt;
  DateTime? _lastMtSendAt;
  DateTime? _airtimeLimitedAt;

  /// The last send was refused by the airtime budget (logged once until a send goes out again).
  bool _airtimeRefusing = false;
  MtShareReason? _lastGateReason;
  MtMyPosition? _myLastSent;
  MtPositionMode _mode = MtPositionMode.exact;
  MtRate _rate = MtRate.smart;
  bool _answer = true;
  Timer? _pumpTimer;
  Timer? _tick;
  Timer? _disconnectTimer;
  Timer? _saveTimer;
  bool _sending = false;
  int? _inFlight;
  final List<({int channelId, Completer<void> done, Timer timer})> _idleWaiters = [];
  bool _disposed = false;
  MeshTrackState? _state;

  MeshTrackService({
    required MtSendText sendChannelText,
    required MtBudgetCheck budget,
    required PrivacyZones Function() zones,
    required String? Function() selfName,
    MtLastKnownStore? lastKnown,
    Duration Function()? positionAirtime,
    void Function(String line)? log,
    DateTime Function()? now,
    math.Random? random,
    void Function(List<MtGroupConfig> groups)? onGroupsChanged,
  })  : _send = sendChannelText,
        _budgetOf = budget,
        _zonesOf = zones,
        _selfNameOf = selfName,
        _store = lastKnown,
        _airtime = positionAirtime ?? meshTrackPositionAirtime,
        _log = log ?? ((_) {}),
        _now = now ?? DateTime.now,
        _random = random ?? math.Random(),
        _groupsSink = onGroupsChanged;

  // ---------------------------------------------------------------- lifecycle and listening

  /// Reads `meshtrack_last.json` (24 h TTL) and arms the 15 s staleness tick (it only runs while a group is active, see
  /// [tickRunning]). Call once after construction.
  Future<void> start() async {
    _started = true;
    _syncTick();
    final s = _store;
    if (s == null) return;
    String? raw;
    try {
      raw = await s.read();
    } catch (_) {
      raw = null;
    }
    if (raw == null || _disposed) return;
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['v'] != 1) return;
      final saved = DateTime.tryParse('${j['savedAt']}');
      final now = _now();
      if (saved == null || now.difference(saved) > kMtOnListFor) return;
      final groups = j['groups'];
      if (groups is! Map) return;
      groups.forEach((k, v) {
        final id = int.tryParse('$k');
        if (id == null) return;
        final g = _groups[id];
        if (g != null) {
          g.track.restore(v, now);
        } else {
          _pendingRestore[id] = v;
        }
      });
      _changed(save: false);
    } catch (_) {
      // A broken file is ignored (it is rewritten on the next change).
    }
  }

  /// Stops timers and writes the last-known file one last time.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _tick?.cancel();
    _pumpTimer?.cancel();
    _disconnectTimer?.cancel();
    _saveTimer?.cancel();
    for (final g in _groups.values) {
      g.answerTimer?.cancel();
    }
    for (final w in List.of(_idleWaiters)) {
      w.timer.cancel();
      if (!w.done.isCompleted) w.done.complete();
    }
    _idleWaiters.clear();
    await _save();
    await _states.close();
    await _events.close();
  }

  /// Current state (cached until the next change).
  MeshTrackState get state => _state ??= _build();

  /// Same shape as a Flutter Listenable (a thin adapter is all a widget needs).
  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  Stream<MeshTrackState> get states => _states.stream;

  /// Toasts: [MtAskedWhileNotSharing], [MtSharingStopped].
  Stream<MtEvent> get events => _events.stream;

  bool _started = false;

  /// True while the 15 s tick exists: a group is sharing, or something on screen ages with time (friends, a meet pin, the
  /// message log, an asked position). With no active group nothing wakes every 15 s (battery plan A8).
  bool get tickRunning => _tick != null;

  bool get _tickWanted =>
      _asked.isNotEmpty ||
      _groups.values.any((g) =>
          g.config.share || g.track.nameCount > 0 || g.track.meet != null || g.log.isNotEmpty || (g.askedUntil != null && _now().isBefore(g.askedUntil!)));

  void _syncTick() {
    if (_disposed || !_started) return;
    if (_tickWanted) {
      _tick ??= Timer.periodic(const Duration(seconds: 15), (_) => _onTick());
    } else if (_tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  void _changed({bool save = true}) {
    if (_disposed) return;
    _syncTick();
    _state = null;
    for (final l in List.of(_listeners)) {
      l();
    }
    if (_states.hasListener) _states.add(state);
    if (save) _scheduleSave();
  }

  void _emit(MtEvent e) {
    if (!_disposed) _events.add(e);
  }

  // ---------------------------------------------------------------- groups

  /// The stored group list at app start. Share switches are forced off (sharing never resumes by itself after the
  /// app was killed); [onGroupsChanged] reports the corrected list.
  void loadGroups(List<MtGroupConfig> groups) {
    var corrected = false;
    final list = <MtGroupConfig>[];
    for (final c in groups) {
      if (c.share) corrected = true;
      list.add(c.share ? c.copyWith(share: false, shareUntil: null) : c);
    }
    syncGroups(list);
    if (corrected) _groupsChanged();
  }

  /// The group list changed outside (channel renamed, removed, not on this radio, settings restored). Groups missing
  /// from [groups] are dropped silently; a group that is not on the radio stops sharing silently.
  void syncGroups(List<MtGroupConfig> groups) {
    final ids = {for (final c in groups) c.channelId};
    for (final id in _groups.keys.toList()) {
      if (!ids.contains(id)) {
        final g = _groups.remove(id)!;
        g.answerTimer?.cancel();
        _queue.removeWhere((q) => q.channelId == id);
        if (g.config.share) _emit(MtSharingStopped(id, MtStopCause.removed));
      }
    }
    var startedSharing = false;
    for (final c in groups) {
      var cfg = c;
      final g = _groups[c.channelId];
      if (!cfg.onRadio && cfg.share) {
        cfg = cfg.copyWith(share: false, shareUntil: null);
        if (g != null && g.config.share) _emit(MtSharingStopped(c.channelId, MtStopCause.removed));
      }
      if (g == null) {
        final ng = _Group(cfg);
        final pending = _pendingRestore.remove(c.channelId);
        if (pending != null) ng.track.restore(pending, _now());
        _groups[c.channelId] = ng;
        if (cfg.share) startedSharing = true;
      } else {
        if (cfg.share && !g.config.share) startedSharing = true;
        g.config = cfg;
      }
    }
    _enforceMax();
    if (startedSharing) _beacon.restart();
    _changed();
  }

  /// Adds a group (New group / Join / Use with MeshTrack). See on, Share off. Check [MeshTrackGroup.eligible] first.
  void addGroup(int channelId, String name) {
    if (_groups.containsKey(channelId)) return;
    _groups[channelId] = _Group(MtGroupConfig(channelId: channelId, name: name));
    _groupsChanged();
    _adoptStray(channelId);
    _changed();
  }

  /// Leave: stops sharing (with `MT1 x`), forgets the group's friends and its last-known entry. Returns the config
  /// it had (for Undo: [restoreGroup]).
  MtGroupConfig? leaveGroup(int channelId) {
    final g = _groups[channelId];
    if (g == null) return null;
    final before = g.config;
    if (g.config.share) _stop(g, MtStopCause.left, notify: false);
    // Left while the radio is gone: the stop message is still owed to the channel (sent on reconnect, within 10 min).
    if (g.stopPending) _orphanStops[channelId] = _now().add(kMtPendingStopFor);
    g.stopPending = false;
    g.answerTimer?.cancel();
    g.track.clear();
    g.log.clear();
    _groups.remove(channelId);
    _groupsChanged();
    _changed(save: false);
    // The left group's friends leave meshtrack_last.json now, not after the 5 s save delay.
    unawaited(_save());
    return before;
  }

  /// Undo of [leaveGroup]: the group comes back with See as it was and Share off.
  void restoreGroup(MtGroupConfig config) {
    _groups[config.channelId] = _Group(config.copyWith(share: false, shareUntil: null));
    _groupsChanged();
    _changed();
  }

  /// Turns Share on (with [duration]) or off for a group. Off sends `MT1 x` once if a position went out.
  MtResult setShare(int channelId, bool on, {MtShareDuration duration = MtShareDuration.thisDrive}) {
    final g = _groups[channelId];
    if (g == null) return MtResult.unknownGroup;
    if (!on) {
      if (g.config.share) _stop(g, MtStopCause.user);
      return MtResult.ok;
    }
    if (!g.config.onRadio) return MtResult.notOnRadio;
    final now = _now();
    final until = duration == MtShareDuration.oneHour ? now.add(kMtOneHour) : null;
    if (g.config.share) {
      // Already sharing (the This drive / 1 hour / Until I stop control): only the duration changes. The share session,
      // its stop message and the beacon's timing carry on.
      g.config = g.config.copyWith(duration: duration, shareUntil: until);
      _groupsChanged();
      _changed();
      _evaluate();
      return MtResult.ok;
    }
    if (_groups.values.where((x) => x.config.share).length >= kMtMaxSharingGroups) return MtResult.tooManyGroups;
    g.config = g.config.copyWith(share: true, duration: duration, shareUntil: until);
    // Off -> on. A stop message that has not gone out yet (Undo of "Stopped sharing", or a stop held for the radio) is
    // dropped: friends never heard it, so this is still the same share session and its stop is owed later.
    final queuedStops = _queue.where((q) => q.channelId == channelId && q.kind == _Kind.stop).length;
    _queue.removeWhere((q) => q.channelId == channelId && q.kind == _Kind.stop);
    final orphan = _orphanStops.remove(channelId) != null;
    g.sentThisSession = queuedStops > 0 || g.stopPending || orphan;
    g.stopPending = false;
    // The beacon keeps its last-sent time: switching Share off and on never beats the airtime floor.
    _beacon.restart();
    if (!_radio && _disconnectTimer == null) _armDisconnectStop();
    _groupsChanged();
    _changed();
    _evaluate();
    return MtResult.ok;
  }

  /// See switch (receiving costs nothing). Off forgets that group's friends.
  MtResult setSee(int channelId, bool on) {
    final g = _groups[channelId];
    if (g == null) return MtResult.unknownGroup;
    g.config = g.config.copyWith(see: on);
    if (!on) {
      g.track.clear();
      g.log.clear();
    }
    _groupsChanged();
    _changed();
    return MtResult.ok;
  }

  /// "Share on every drive" (group menu).
  MtResult setShareEveryDrive(int channelId, bool on) {
    final g = _groups[channelId];
    if (g == null) return MtResult.unknownGroup;
    g.config = g.config.copyWith(shareEveryDrive: on);
    _groupsChanged();
    _changed();
    return MtResult.ok;
  }

  void _enforceMax() {
    final sharing = _groups.values.where((g) => g.config.share).toList();
    for (final g in sharing.skip(kMtMaxSharingGroups)) {
      g.config = g.config.copyWith(share: false, shareUntil: null);
    }
  }

  void _groupsChanged() => _groupsSink?.call([for (final g in _groups.values) g.config]);

  bool _active(_Group g) => g.config.share && g.config.onRadio && (g.config.duration != MtShareDuration.thisDrive || _driving);

  List<_Group> get _sharingNow => _groups.values.where(_active).toList();

  void _stop(_Group g, MtStopCause cause, {bool notify = true}) {
    g.config = g.config.copyWith(share: false, shareUntil: null);
    g.answerTimer?.cancel();
    g.answerTimer = null;
    _queue.removeWhere((q) => q.channelId == g.config.channelId && q.kind == _Kind.position);
    if (g.sentThisSession && cause != MtStopCause.removed) {
      if (_radio) {
        _enqueue(_Queued(g.config.channelId, kMtStopText, _Kind.stop, _now()));
      } else {
        g.stopPending = true;
      }
    }
    g.sentThisSession = false;
    _emit(MtSharingStopped(g.config.channelId, cause));
    _log('meshtrack: sharing stopped (${cause.name})');
    _groupsChanged();
    if (notify) _changed();
  }

  // ---------------------------------------------------------------- settings

  void setPositionMode(MtPositionMode m) {
    _mode = m;
    _changed(save: false);
  }

  void setRate(MtRate r) {
    _rate = r;
    _changed(save: false);
  }

  void setAnswerRequests(bool on) {
    _answer = on;
    _changed(save: false);
  }

  // ---------------------------------------------------------------- inputs

  /// Every GPS fix (drive stream, or the phone's location while sharing without a drive).
  void onFix(MtFix fix) {
    _lastFix = fix;
    _evaluate();
  }

  /// Radio connected / disconnected. Sends pause while disconnected; after 5 min sharing turns off.
  void setRadioConnected(bool connected) {
    if (connected == _radio) return;
    _radio = connected;
    if (connected) {
      _disconnectTimer?.cancel();
      _disconnectTimer = null;
      for (final g in _groups.values) {
        if (g.stopPending) {
          g.stopPending = false;
          _enqueue(_Queued(g.config.channelId, kMtStopText, _Kind.stop, _now()));
        }
      }
      // Left while the radio was gone: the owed stop goes once, if the radio came back within 10 min.
      final now = _now();
      for (final e in _orphanStops.entries) {
        if (now.isBefore(e.value) && !_groups.containsKey(e.key)) _enqueue(_Queued(e.key, kMtStopText, _Kind.stop, now));
      }
      _orphanStops.clear();
      _pump();
    } else {
      _armDisconnectStop();
    }
    _changed(save: false);
  }

  /// Sharing ends after [kMtDisconnectStopAfter] without the radio. Armed only while a group shares, so a phone that shares
  /// nothing runs no timer.
  void _armDisconnectStop() {
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    if (_radio || !_groups.values.any((g) => g.config.share)) return;
    _disconnectTimer = Timer(kMtDisconnectStopAfter, () {
      _disconnectTimer = null;
      if (_radio) return;
      for (final g in _groups.values.where((g) => g.config.share).toList()) {
        _stop(g, MtStopCause.radioDisconnected, notify: false);
      }
      _changed();
    });
  }

  /// The ping engine's state, on every EngineStatus change.
  void setPingWindow(MtPingWindow w) {
    if (_window.listening && !w.listening) _windowClosedAt = _now();
    _window = w;
    _pump();
  }

  /// A drive started: groups with "Share on every drive" turn on (This drive), This-drive shares become active.
  void driveStarted() {
    if (_driving) return;
    _driving = true;
    var any = false;
    for (final g in _groups.values) {
      if (g.config.shareEveryDrive && !g.config.share && g.config.onRadio) {
        if (_groups.values.where((x) => x.config.share).length >= kMtMaxSharingGroups) break;
        g.config = g.config.copyWith(share: true, duration: MtShareDuration.thisDrive, shareUntil: null);
        g.sentThisSession = false;
        any = true;
      }
    }
    if (any) _groupsChanged();
    _beacon.restart();
    _changed(save: false);
    _evaluate();
  }

  /// The drive stopped: This-drive shares end with `MT1 x`.
  void driveStopped() {
    if (!_driving) return;
    _driving = false;
    for (final g in _groups.values.toList()) {
      if (g.config.share && g.config.duration == MtShareDuration.thisDrive) _stop(g, MtStopCause.driveStopped, notify: false);
    }
    _changed();
  }

  // ---------------------------------------------------------------- sending my position

  /// The gate every outgoing position (and meet-up pin) passes. Null = may send.
  MtShareReason? _zoneGate(double lat, double lon, double accuracyM) {
    final z = _zonesOf();
    if (!z.loaded) return MtShareReason.zonesNotLoaded;
    if (z.hides(lat, lon)) return MtShareReason.privacyZone;
    for (final zone in z.zones) {
      if (distanceM(lat, lon, zone.lat, zone.lon) <= zone.radiusM + kMtZoneBufferM + accuracyM) {
        return MtShareReason.privacyZone;
      }
    }
    return null;
  }

  MtShareReason? _fixGate(MtFix? f) {
    if (f == null) return MtShareReason.waitingForGps;
    final acc = f.accuracyM;
    if (acc == null || acc <= 0 || acc > kMtMaxAccuracyM) return MtShareReason.waitingForGps;
    if (_now().difference(f.at) > kMtFixMaxAge) return MtShareReason.waitingForGps;
    return _zoneGate(f.lat, f.lon, acc);
  }

  String _code(MtFix f) =>
      PlusCode.encode(f.lat, f.lon, codeLength: _mode == MtPositionMode.exact ? kPlusCodeExactDigits : kPlusCodeApproxDigits);

  String _positionText(MtFix f, {bool parked = false, double? speedKmh, double? courseDeg}) {
    final code = _code(f);
    if (parked) return formatMtParked(code);
    var v = speedKmh ?? (f.speedMps != null && f.speedMps! >= 0 ? f.speedMps! * 3.6 : null);
    // `s0` means parked on the wire: a slow-moving position below 1 km/h goes without a speed.
    if (v != null && v < kMtMinSpeedKmh) v = null;
    final c = courseDeg ?? (f.courseDeg != null && f.courseDeg! >= 0 ? f.courseDeg : null);
    return formatMtPosition(code, speedKmh: v?.round(), courseDeg: c?.round());
  }

  void _evaluate() {
    if (_disposed) return;
    final groups = _sharingNow;
    if (groups.isEmpty || !_radio) return _setGate(null);
    final fix = _lastFix;
    final gate = _fixGate(fix);
    if (gate != null) {
      if (gate != _lastGateReason) _log('meshtrack: skipped: ${_reasonWord(gate)}');
      return _setGate(gate);
    }
    _setGate(null);
    final now = _now();
    final d = _beacon.decide(fix!, now: now, groups: groups.length, positionAirtime: _airtime(), rate: _rate);
    if (!d.send) return;
    final text = _positionText(fix, parked: d.parked, speedKmh: d.speedKmh, courseDeg: d.courseDeg);
    final mark = _beacon.markSent(d, fix, now);
    var restored = false;
    for (final g in groups) {
      _enqueue(_Queued(g.config.channelId, text, _Kind.position, now, onRefused: (airtime) {
        if (!restored) {
          restored = true;
          // An airtime refusal backs off for the floor (no retry and no log line on every fix); anything else retries
          // on the next fix.
          _beacon.restore(mark, backoffFrom: airtime ? _now() : null);
        }
      }, onSent: () {
        g.sentThisSession = true;
        g.lastSentAt = _now();
        _myLastSent = MtMyPosition(fix.lat, fix.lon, _now());
      }));
    }
  }

  void _setGate(MtShareReason? r) {
    if (r == _lastGateReason) return;
    _lastGateReason = r;
    _changed(save: false);
  }

  static String _reasonWord(MtShareReason r) => switch (r) {
        MtShareReason.privacyZone => 'zone',
        MtShareReason.zonesNotLoaded => 'zones not loaded',
        MtShareReason.waitingForGps => 'gps',
        MtShareReason.airtimeLimit => 'airtime limit',
        MtShareReason.radioDisconnected => 'radio disconnected',
        _ => r.name,
      };

  /// "Send my position" (one shot) to one group. Obeys the zones and the GPS gate; works without sharing.
  MtResult sendMyPosition(int channelId) {
    final g = _groups[channelId];
    if (g == null) return MtResult.unknownGroup;
    if (!g.config.onRadio) return MtResult.notOnRadio;
    if (!_radio) return MtResult.radioDisconnected;
    final gate = _fixGate(_lastFix);
    if (gate != null) {
      _log('meshtrack: skipped: ${_reasonWord(gate)}');
      return _resultOf(gate);
    }
    final fix = _lastFix!;
    _enqueue(_Queued(channelId, _positionText(fix), _Kind.position, _now(), onSent: () {
      g.lastSentAt = _now();
      if (g.config.share) g.sentThisSession = true;
      _myLastSent = MtMyPosition(fix.lat, fix.lon, _now());
    }));
    return MtResult.ok;
  }

  /// Round 3 decision D4, "Share my position" in a direct message: the text to send, or why not. The same rules as every
  /// position that leaves this phone: nothing without a good, fresh fix, nothing while the privacy zones are not loaded,
  /// nothing inside a zone or its buffer; and the Exact / Approximate setting decides how fine the place is (Approximate
  /// = the middle of the 8-digit Plus Code cell, about 275 m, never the fix itself). [fix] is the phone's newest fix when
  /// the service has none of its own (it only gets fixes while a group shares or a drive runs). The text is plain
  /// "lat, lon", so any MeshCore app can read it and MeshSonar shows "Open on map" under it.
  ({MtResult result, String? text}) positionMessageText({MtFix? fix}) {
    final mine = _lastFix;
    final f = fix == null ? mine : (mine == null || fix.at.isAfter(mine.at) ? fix : mine);
    final gate = _fixGate(f);
    if (gate != null) return (result: _resultOf(gate), text: null);
    if (_mode == MtPositionMode.exact) {
      return (result: MtResult.ok, text: 'My position: ${f!.lat.toStringAsFixed(5)}, ${f.lon.toStringAsFixed(5)}');
    }
    final cell = PlusCode.tryDecode(PlusCode.encode(f!.lat, f.lon, codeLength: kPlusCodeApproxDigits));
    if (cell == null) return (result: MtResult.waitingForGps, text: null);
    // The cell's middle may itself be inside a zone's buffer even when the fix is not: checked again.
    final again = _zoneGate(cell.lat, cell.lon, 0);
    if (again != null) return (result: _resultOf(again), text: null);
    return (result: MtResult.ok, text: 'My position (approximate): ${cell.lat.toStringAsFixed(4)}, ${cell.lon.toStringAsFixed(4)}');
  }

  /// "Exact" or "Approximate": what [positionMessageText] would send (the confirmation says which).
  MtPositionMode get positionMode => _mode;

  static MtResult _resultOf(MtShareReason r) => switch (r) {
        MtShareReason.privacyZone => MtResult.privacyZone,
        MtShareReason.zonesNotLoaded => MtResult.zonesNotLoaded,
        MtShareReason.radioDisconnected => MtResult.radioDisconnected,
        _ => MtResult.waitingForGps,
      };

  /// "Where are you?" to everyone in the group ([name] null) or to one name. Once per 60 s per group.
  MtResult askWhereAreYou(int channelId, {String? name}) {
    final g = _groups[channelId];
    if (g == null) return MtResult.unknownGroup;
    if (!g.config.onRadio) return MtResult.notOnRadio;
    if (!_radio) return MtResult.radioDisconnected;
    final now = _now();
    if (g.askedUntil != null && now.isBefore(g.askedUntil!)) return MtResult.tooSoon;
    g.askedUntil = now.add(kMtAskGap);
    g.askedName = name;
    _enqueue(_Queued(channelId, formatMtRequest(name), _Kind.request, now));
    _changed(save: false);
    return MtResult.ok;
  }

  /// "Meet here": sets the meet-up pin at a chosen point and sends it. A point inside a privacy zone (or its 200 m plus
  /// [accuracyM] buffer) is refused, like any position. [accuracyM] = the phone fix's accuracy when the point is where I
  /// am (0 for a point picked on the map). In Approximate mode the pin goes at 8 digits (about 275 m), like positions, so
  /// "Meet here" never leaks an exact position.
  MtResult meetHere(int channelId, double lat, double lon, {String? label, double accuracyM = 0}) {
    final g = _groups[channelId];
    if (g == null) return MtResult.unknownGroup;
    if (!g.config.onRadio) return MtResult.notOnRadio;
    if (!_radio) return MtResult.radioDisconnected;
    final gate = _zoneGate(lat, lon, accuracyM.isFinite && accuracyM > 0 ? accuracyM : 0);
    if (gate != null) {
      _log('meshtrack: skipped: ${_reasonWord(gate)}');
      return _resultOf(gate);
    }
    final code = PlusCode.encode(lat, lon, codeLength: _mode == MtPositionMode.exact ? kPlusCodeExactDigits : kPlusCodeApproxDigits);
    final a = PlusCode.tryDecode(code)!;
    final clean = cleanMeetLabel(label);
    g.track.meet = MtMeetPin(lat: a.lat, lon: a.lon, label: clean, setBy: _selfNameOf(), at: _now());
    _enqueue(_Queued(channelId, formatMtMeet(code, label: clean), _Kind.meet, _now()));
    _changed();
    return MtResult.ok;
  }

  /// Clears the meet-up pin (here and for friends).
  MtResult clearMeet(int channelId) {
    final g = _groups[channelId];
    if (g == null) return MtResult.unknownGroup;
    g.track.meet = null;
    if (_radio && g.config.onRadio) _enqueue(_Queued(channelId, kMtMeetClearText, _Kind.meet, _now()));
    _changed();
    return MtResult.ok;
  }

  /// Delete my data: forgets every friend and meet pin and removes `meshtrack_last.json`.
  Future<void> clearLastKnown() async {
    for (final g in _groups.values) {
      g.track.clear();
      g.log.clear();
    }
    _pendingRestore.clear();
    _asked.clear();
    _saveTimer?.cancel();
    await _store?.clear();
    _changed(save: false);
  }

  // ---------------------------------------------------------------- send queue

  void _enqueue(_Queued q) {
    _queue.add(q);
    _pump();
  }

  void _schedulePump(Duration d) {
    _pumpTimer?.cancel();
    _pumpTimer = Timer(d < Duration.zero ? Duration.zero : d, _pump);
  }

  /// Completes when nothing for [channelId] is queued or on its way to the radio any more (sent, refused or dropped),
  /// or after [timeout]. Start fresh waits on it so the old group's `MT1 x` goes out under the OLD key before the
  /// channel gets its new key (otherwise the stop would be lost, or go to the new group).
  Future<void> whenIdle(int channelId, {Duration timeout = const Duration(seconds: 20)}) {
    if (_disposed || _idle(channelId)) return Future.value();
    final done = Completer<void>();
    late final ({int channelId, Completer<void> done, Timer timer}) w;
    w = (
      channelId: channelId,
      done: done,
      timer: Timer(timeout, () {
        _idleWaiters.remove(w);
        if (!done.isCompleted) done.complete();
      }),
    );
    _idleWaiters.add(w);
    return done.future;
  }

  bool _idle(int channelId) => _inFlight != channelId && !_queue.any((q) => q.channelId == channelId);

  void _checkIdle() {
    if (_idleWaiters.isEmpty) return;
    for (final w in List.of(_idleWaiters)) {
      if (!_idle(w.channelId)) continue;
      _idleWaiters.remove(w);
      w.timer.cancel();
      if (!w.done.isCompleted) w.done.complete();
    }
  }

  void _pump() {
    _pumpOnce();
    _checkIdle();
  }

  void _pumpOnce() {
    if (_disposed || _sending) return;
    _pumpTimer?.cancel();
    _pumpTimer = null;
    final now = _now();
    _queue.removeWhere((q) => now.difference(q.at) > kMtQueueMaxAge && q.kind != _Kind.stop);
    if (_queue.isEmpty || !_radio) return;
    if (_window.listening) return _schedulePump(const Duration(seconds: 1)); // also re-pumped when the window closes
    final closed = _windowClosedAt;
    if (closed != null && now.isBefore(closed.add(kMtAfterWindow))) return _schedulePump(closed.add(kMtAfterWindow).difference(now));
    final next = _window.nextPingAt;
    if (next != null) {
      final until = next.difference(now);
      if (until >= Duration.zero && until <= kMtPingGuard) return _schedulePump(until + const Duration(seconds: 1));
    }
    final last = _lastMtSendAt;
    if (last != null && now.isBefore(last.add(kMtSendSpacing))) return _schedulePump(last.add(kMtSendSpacing).difference(now));
    final q = _queue.removeAt(0);
    final g = _groups[q.channelId];
    // A stop message still goes after Leave (the group is gone from the list but the channel is still there).
    if (q.kind != _Kind.stop && (g == null || !g.config.onRadio)) {
      q.onRefused?.call(false);
      return _pump();
    }
    final verdict = _budgetOf(q.channelId, q.text);
    if (verdict != MtBudget.ok) {
      final airtime = verdict == MtBudget.airtimeLimit;
      if (!airtime) {
        _log('meshtrack: skipped: too long');
      } else if (!_airtimeRefusing) {
        _airtimeRefusing = true; // logged once until a send goes out again
        _log('meshtrack: skipped: airtime limit');
      }
      if (airtime && q.kind == _Kind.position) _airtimeLimitedAt = now;
      q.onRefused?.call(airtime);
      _changed(save: false);
      return _pump();
    }
    _lastMtSendAt = now;
    _sending = true;
    _inFlight = q.channelId;
    final bytes = groupTextPacketBytes(utf8.encode('${_selfNameOf() ?? ''}: ${q.text}').length);
    _send(q.channelId, q.text).then((ok) {
      _sending = false;
      _inFlight = null;
      if (_disposed) return;
      if (ok) {
        _log('meshtrack: sent ${q.kind.name}, $bytes bytes');
        _airtimeRefusing = false;
        if (q.kind == _Kind.position) _airtimeLimitedAt = null;
        _groups[q.channelId]?.addLog(MtLoggedMessage(name: null, body: q.text, message: parseMeshTrack(q.text), at: _now()));
        q.onSent?.call();
      } else {
        _log('meshtrack: send failed (${q.kind.name})');
        q.onRefused?.call(false);
      }
      _changed(save: false);
      _pump();
    }, onError: (Object _) {
      _sending = false;
      _inFlight = null;
      if (_disposed) return;
      _log('meshtrack: send failed (${q.kind.name})');
      q.onRefused?.call(false);
      _pump();
    });
  }

  // ---------------------------------------------------------------- receiving

  /// An inbound channel message, before chat stores it. Returns true when it is consumed (MeshTrack machine text on a
  /// group: not stored, not notified, not in backup or search). Typed positions return false (they stay chat) but
  /// still become a pin. Never throws.
  /// The chat inbound tap (register with `ChatService.addChannelTextTap(mt.channelTextTap)`).
  late final ChannelTextTap channelTextTap =
      ChannelTextTap.of((e) => onChannelText(MtInboundText.fromTapEvent(e)) ? TapVerdict.consume : TapVerdict.pass);

  // ---------------------------------------------------------------- positions in a channel that is not a group (C-U2)

  final Map<int, Map<String, MtStrayShare>> _stray = {};

  /// Friends whose position updates were heard in channel [channelId] while it is NOT a MeshTrack group on this phone,
  /// newest first. Round 3 C-U2: such an update is never chat (no bubble per update, no unread, no notification, not in
  /// backup or search); the thread shows ONE line for them ("Jo shared their position · 6 updates") and offers "Use for
  /// MeshTrack". Memory only, like every friend position; gone when the app closes or the channel becomes a group.
  List<MtStrayShare> strayShares(int channelId) {
    final m = _stray[channelId];
    if (m == null || m.isEmpty || _groups.containsKey(channelId)) return const [];
    return m.values.toList()..sort((a, b) => b.lastAt.compareTo(a.lastAt));
  }

  /// Forgets [strayShares] of one channel (its thread's line goes away).
  void clearStrayShares(int channelId) {
    if (_stray.remove(channelId) != null) _changed(save: false);
  }

  /// A channel text for a channel that is not a group. Only a POSITION update is taken out of chat; a request, a meet-up
  /// pin or a stop stays a readable chat line (they are rare and say something a person may want to read).
  bool _onStrayText(MtInboundText e) {
    final s = e.split;
    final (name, body) = s != null ? (s.name, s.body) : splitMtSender(e.text);
    if (parseMeshTrack(body) is! MtPosition) return false;
    if (name == null) return false; // no sender: nothing to say about it, leave it to chat as today
    final self = _selfNameOf();
    if (self != null && name == self) return true; // my own update echoed back: never chat
    final m = _stray.putIfAbsent(e.channelId, () => {});
    final old = m[name];
    final sender = e.senderTs;
    // The same update heard again through another repeater is not a new update.
    if (old != null && old.lastBody == body && old.lastSenderTs == sender) return true;
    if (old == null && m.length >= kMtMaxStraySenders) return true;
    m[name] = MtStrayShare(name: name, updates: (old?.updates ?? 0) + 1, lastAt: e.receivedAt, lastBody: body, lastSenderTs: sender, snr: e.snr, pathLen: e.pathLen);
    _changed(save: false);
    return true;
  }

  /// The channel became a group: what was heard there before goes on the map now (each friend's newest update).
  void _adoptStray(int channelId) {
    final m = _stray.remove(channelId);
    if (m == null) return;
    for (final x in m.values) {
      onChannelText(MtInboundText(
          channelId: channelId, text: '${x.name}: ${x.lastBody}', receivedAt: x.lastAt, senderTs: x.lastSenderTs, snr: x.snr, pathLen: x.pathLen));
    }
  }

  bool onChannelText(MtInboundText e) {
    try {
      return _onText(e);
    } catch (_) {
      return false;
    }
  }

  bool _onText(MtInboundText e) {
    final g = _groups[e.channelId];
    if (g == null) return _onStrayText(e);
    final s = e.split;
    final (name, body) = s != null ? (s.name, s.body) : splitMtSender(e.text);
    final msg = parseMeshTrack(body);
    final self = _selfNameOf();
    final isSelf = name != null && self != null && name == self;
    final now = _now();
    final at = mtEffectiveTime(e.senderTs, e.receivedAt);
    if (msg != null) {
      if (name == null || isSelf) return true;
      if (g.track.isDuplicate(name, e.senderTs, body)) return true;
      if (g.config.see) g.addLog(MtLoggedMessage(name: name, body: body, message: msg, at: at));
      switch (msg) {
        case MtPosition():
          if (g.config.see) {
            g.track.addPosition(
              name: name,
              lat: msg.lat,
              lon: msg.lon,
              accuracyM: msg.area.heightM / 2,
              at: at,
              now: now,
              speedKmh: msg.speedKmh,
              courseDeg: msg.courseDeg,
              parked: msg.parked,
              snr: e.snr,
              pathLen: e.pathLen,
            );
          }
        case MtRequest():
          _onRequest(g, name, msg.name, now);
        case MtMeet():
          if (g.config.see) g.track.meet = MtMeetPin(lat: msg.lat, lon: msg.lon, label: msg.label, setBy: name, at: at);
        case MtMeetClear():
          g.track.meet = null;
        case MtStop():
          g.track.markStopped(name, at);
      }
      _changed();
      return true;
    }
    final f = _lastFix;
    final io = parseInterop(body, refLat: f?.lat, refLon: f?.lon);
    if (io == null) return false;
    if (io is MtInteropPosition && name != null && !isSelf && g.config.see && !g.track.isDuplicate(name, e.senderTs, body)) {
      if (io.consume) g.addLog(MtLoggedMessage(name: name, body: body, at: at));
      g.track.addPosition(
          name: name, lat: io.lat, lon: io.lon, accuracyM: io.accuracyM, at: at, now: now, source: io.source, snr: e.snr, pathLen: e.pathLen);
      _changed();
    }
    return io.consume;
  }

  void _onRequest(_Group g, String from, String? target, DateTime now) {
    final self = _selfNameOf();
    if (target != null && (self == null || target.toLowerCase() != self.trim().toLowerCase())) return;
    if (!_active(g)) {
      final last = g.lastAskedToastAt;
      if (last == null || now.difference(last) >= kMtAnswerGap) {
        g.lastAskedToastAt = now;
        _emit(MtAskedWhileNotSharing(g.config.channelId, from));
      }
      return;
    }
    if (!_answer || g.answerTimer != null) return;
    final last = g.lastAnswerAt;
    if (last != null && now.difference(last) < kMtAnswerGap) return;
    g.lastAnswerAt = now;
    final span = kMtAnswerMaxDelay.inMilliseconds - kMtAnswerMinDelay.inMilliseconds;
    final delay = kMtAnswerMinDelay + Duration(milliseconds: _random.nextInt(span + 1));
    g.answerTimer = Timer(delay, () {
      g.answerTimer = null;
      if (_disposed || !_active(g) || !_radio) return;
      final gate = _fixGate(_lastFix);
      if (gate != null) {
        _log('meshtrack: skipped: ${_reasonWord(gate)}');
        return;
      }
      final fix = _lastFix!;
      _enqueue(_Queued(g.config.channelId, _positionText(fix), _Kind.position, _now(), onSent: () {
        g.sentThisSession = true;
        g.lastSentAt = _now();
        _myLastSent = MtMyPosition(fix.lat, fix.lon, _now());
      }));
    });
  }

  // ---------------------------------------------------------------- tick, state, persistence

  /// The group's recent MeshTrack messages, newest first, for "Show position messages" (display only; see
  /// [MtLoggedMessage]). Empty for an unknown group.
  // ------------------------------------------------------------------ Ask for location (MT-13), memory only

  final Map<String, MtAskedPosition> _asked = {};

  /// Shows [p] on the map as an "asked" pin (replaces an older answer from the same person). Never saved: the
  /// last-known file only holds group friends, and nothing here is logged.
  void putAsked(MtAskedPosition p) {
    _asked[p.keyHex.toLowerCase()] = p;
    _changed(save: false);
  }

  /// Takes the "asked" pin of [keyHex] off the map.
  void removeAsked(String keyHex) {
    if (_asked.remove(keyHex.toLowerCase()) != null) _changed(save: false);
  }

  List<MtLoggedMessage> positionMessages(int channelId) {
    final g = _groups[channelId];
    if (g == null) return const [];
    final now = _now();
    return [for (final m in g.log.reversed) if (now.difference(m.at) <= kMtOnListFor) m];
  }

  void _onTick() {
    final now = _now();
    _asked.removeWhere((_, p) => now.difference(p.at) >= kAskedOnMapFor);
    for (final g in _groups.values.toList()) {
      g.track.prune(now);
      g.log.removeWhere((m) => now.difference(m.at) > kMtOnListFor);
      final until = g.config.shareUntil;
      if (g.config.share && g.config.duration == MtShareDuration.oneHour && until != null && !now.isBefore(until)) {
        _stop(g, MtStopCause.durationEnded, notify: false);
      }
    }
    _changed(save: false);
  }

  MeshTrackState _build() {
    final now = _now();
    final views = <MtGroupView>[];
    for (final g in _groups.values) {
      views.add(MtGroupView(
        config: g.config,
        friends: g.config.see ? g.track.friends(now) : const [],
        meet: g.track.meet,
        heardLast30Min: g.config.see ? g.track.heardWithin(const Duration(minutes: 30), now) : 0,
        sharingNow: _active(g),
        askedUntil: g.askedUntil != null && now.isBefore(g.askedUntil!) ? g.askedUntil : null,
        askedName: g.askedUntil != null && now.isBefore(g.askedUntil!) ? g.askedName : null,
        lastSentAt: g.lastSentAt,
      ));
    }
    final sharing = _groups.values.where((g) => g.config.share).toList();
    MtShareReason reason;
    if (sharing.isEmpty) {
      reason = MtShareReason.off;
    } else if (!_radio) {
      reason = MtShareReason.radioDisconnected;
    } else if (_sharingNow.isEmpty) {
      reason = MtShareReason.waitingForDrive;
    } else if (_lastGateReason != null) {
      reason = _lastGateReason!;
    } else if (_airtimeLimitedAt != null && now.difference(_airtimeLimitedAt!) < kMtAirtimeNoticeFor) {
      reason = MtShareReason.airtimeLimit;
    } else {
      reason = MtShareReason.sharing;
    }
    return MeshTrackState(
      groups: List.unmodifiable(views),
      reason: reason,
      sharingNames: [for (final g in sharing) g.config.name],
      myLastSent: sharing.isEmpty ? null : _myLastSent,
      driving: _driving,
      radioConnected: _radio,
      positionMode: _mode,
      rate: _rate,
      answerRequests: _answer,
      asked: List.unmodifiable([
        for (final p in _asked.values.toList()..sort((a, b) => b.at.compareTo(a.at)))
          if (now.difference(p.at) < kAskedOnMapFor) p
      ]),
    );
  }

  void _scheduleSave() {
    if (_store == null || _disposed) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 5), _save);
  }

  Future<void> _save() async {
    final s = _store;
    if (s == null) return;
    _saveTimer?.cancel();
    final groups = <String, Object?>{};
    for (final g in _groups.values) {
      if (!g.config.see) continue;
      final j = g.track.toJson();
      if ((j['friends'] as List).isEmpty && j['meet'] == null) continue;
      groups['${g.config.channelId}'] = j;
    }
    try {
      await s.write(jsonEncode({'v': 1, 'savedAt': _now().toUtc().toIso8601String(), 'groups': groups}));
    } catch (_) {
      // best effort: last-known is a convenience
    }
  }
}

/// `name: body` split exactly like the chat layer (`ChatService.splitSender`): the sender prefix is at most 40
/// characters, before the first `: `.
(String?, String) splitMtSender(String raw) {
  final i = raw.indexOf(': ');
  if (i > 0 && i <= 40 && !raw.substring(0, i).contains('\n')) return (raw.substring(0, i), raw.substring(i + 2));
  return (null, raw);
}
