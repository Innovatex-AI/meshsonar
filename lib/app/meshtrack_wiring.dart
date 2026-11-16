// MeshTrack app wiring (meshsonar-infra docs/planning/meshtrack-plan-2026-11-16.md MT-5 and MT-14). The one place that
// connects the pure MeshTrack core (lib/core/meshtrack, API.md there) to chat, the radio, the drive and storage:
//
//   * builds the one MeshTrackService: silent channel sends through ChatService (TxArbiter TxPriority.track), the budget
//     check (maxTextBytes + the arbiter), the privacy zones, the radio's name and LoRa preset, `meshtrack_last.json`;
//   * registers the chat inbound tap (consumed MeshTrack text never becomes chat) and the arbiter's track door;
//   * routes fixes: the drive's GPS stream while driving, else the phone's location while the app is in front and a group
//     shares for "1 hour" / "Until I stop" (section 5.6: foreground only, no new background location);
//   * feeds the ping listen window, the radio state and drive start/stop;
//   * groups (section 5): every group's name and key live in the Keychain (a registry next to the channel secrets), the
//     per-radio settings in `meshtrack.groups`. On connect a group missing from the radio is written back to a free
//     channel without asking (U7); a full radio leaves it "Not on this radio" (See/Share off) until room is made;
//   * MeshTrackGroupOps: what the Group sheet, setup and settings call (New group, Join, Use existing, Leave/Undo, Start
//     fresh/Undo, invite link, settings values).
//
// Privacy: no position, code or name is ever logged here (the core's log lines carry none either); positions live only in
// the core (memory) and in `meshtrack_last.json` (24 h, cleared by Leave and by Delete my data).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../chat/channel_admin.dart';
import '../chat/channel_secret.dart' show channelHashByte, classifyChannel;
import '../chat/channel_text_tap.dart' show ChannelTextTap, TapVerdict;
import '../chat/chat_service.dart';
import '../chat/mesh_links.dart';
import '../chat/models.dart';
import '../chat/secret_store.dart';
import '../chat/store.dart';
import '../core/api.dart' show MeshTrackSettings;
import '../core/meshtrack/meshtrack_service.dart';
import '../core/model.dart' show Radio;
import '../core/privacy_zones.dart' show PrivacyZones;
import '../radio/radio_api.dart' show EngineState, EngineStatus, GeoFix, LocationSource;
import '../radio/tx_arbiter.dart' show TrackTxGate;
import 'chat_controller.dart';

export '../core/meshtrack/meshtrack_service.dart';

/// Outcome kinds of a group operation (the UI words them; [MtGroupOpResult.message] is ready-made plain copy).
enum MtGroupOpStatus { ok, radioFull, notConnected, invalidLink, notEligible, nameInvalid, failed }

class MtGroupOpResult {
  final MtGroupOpStatus status;

  /// The group's channel (ok only).
  final int? channelId;

  /// Plain user copy for anything that is not ok.
  final String? message;
  const MtGroupOpResult(this.status, {this.channelId, this.message});
  const MtGroupOpResult.ok(int this.channelId)
      : status = MtGroupOpStatus.ok,
        message = null;
  bool get ok => status == MtGroupOpStatus.ok;
  @override
  String toString() => 'MtGroupOpResult(${status.name}${channelId == null ? '' : ' $channelId'})';
}

/// The user copy of the group operations (one place, plain words; never "slot").
abstract final class MtCopy {
  static const String radioFull = 'Your radio has no room for another channel. Remove one you do not need, then try again.';
  static const String notOnRadio = 'Not on this radio: it has no room for another channel.';
  static const String notConnected = 'Connect your radio first.';
  static const String notEligible =
      'Public and # channels cannot be used for MeshTrack: anyone can read them. Use a private channel.';
  static const String invalidLink = 'That is not a channel invite. Ask your friend for the group link or QR code again.';
  static const String failed = 'The radio did not accept the change. Nothing was changed. Try again.';
  static const String unsupported = 'This radio cannot add channels from the app.';
  static const String duplicateName = 'You already have a channel with that name. Pick another name.';
}

/// What the wiring needs from chat: the store, the service, channel admin and the radio the lists are about.
class MtChatBinding {
  final ChatStore store;
  final ChatService service;
  final ChannelAdmin admin;
  final String? Function() radioId;
  final bool Function() radioConnected;

  /// Fires when channels may have changed (it may fire for other chat changes too; the wiring filters).
  final Listenable changes;
  const MtChatBinding({required this.store, required this.service, required this.admin, required this.radioId, required this.radioConnected, required this.changes});

  factory MtChatBinding.of(ChatController c) => MtChatBinding(
      store: c.store, service: c.service, admin: c.admin, radioId: () => c.radioId, radioConnected: () => c.radioConnected, changes: c);
}

/// `meshtrack_last.json` in the app support folder (24 h TTL is the core's).
class FileMtLastKnownStore implements MtLastKnownStore {
  final File file;
  FileMtLastKnownStore(this.file);
  @override
  Future<String?> read() async => await file.exists() ? await file.readAsString() : null;
  @override
  Future<void> write(String json) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}

/// One group as the Keychain registry keeps it (name + key; survives a radio switch and a reinstall).
class _Reg {
  final String uid;
  String name;
  Uint8List secret;
  _Reg(this.uid, this.name, this.secret);
  Map<String, Object?> toJson() => {'uid': uid, 'name': name, 'secret': toHex(secret)};
  static _Reg? fromJson(Object? j) {
    if (j is! Map) return null;
    final uid = j['uid'], name = j['name'], s = j['secret'];
    if (uid is! String || name is! String || s is! String || !isHex(s, 32)) return null;
    return _Reg(uid, name, fromHex(s));
  }
}

/// One group's settings as stored in `meshtrack.groups` (per radio row ids + the switches).
class _Stored {
  /// Phone channel row of this group per radio (public key hex -> Channel.id).
  final Map<String, int> rows;
  bool see;
  bool shareEveryDrive;
  MtGroupConfig? last;
  _Stored({Map<String, int>? rows, this.see = true, this.shareEveryDrive = false, this.last}) : rows = rows ?? {};
}

/// The MeshTrack wiring. One per AppState (null when the flag is off).
class MeshTrackWiring {
  /// Keychain ref of the group registry (next to the channel secrets; never in SQLite or settings.json).
  static const String registryRef = 'meshtrack.groups.v1';

  final DateTime Function() _now;
  final SecretStore _keychain;
  final MeshTrackSettings Function() _readSettings;
  final Future<void> Function(MeshTrackSettings) _writeSettings;
  final String Function() _wardriveChannelName;
  final LocationSource? Function() _phoneLocation;
  final void Function(String line) _log;

  late final MeshTrackService service;
  late final MeshTrackGroupOps groups = MeshTrackGroupOps._(this);

  MtChatBinding? _chat;
  TrackTxGate? _gate;
  final List<_Reg> _reg = [];
  final Map<String, _Stored> _stored = {};
  final Map<int, String> _uidByChannel = {};
  final Map<int, _Reg> _recentlyRemoved = {};
  bool _started = false;
  bool _disposed = false;
  bool _connected = false;
  bool _driving = false;
  bool _foreground = true;
  MtPingWindow _window = MtPingWindow.idle;
  StreamSubscription<GeoFix>? _phoneSub;
  String? _channelSig;
  bool _reconciling = false;
  bool _reconcileAgain = false;
  bool _reconcileWrite = false;
  Future<void> _persistChain = Future.value();
  Future<void>? _reconcileDone;

  MeshTrackWiring({
    required PrivacyZones Function() zones,
    required MeshTrackSettings Function() readSettings,
    required Future<void> Function(MeshTrackSettings) writeSettings,
    SecretStore? keychain,
    MtLastKnownStore? lastKnown,
    Radio? Function()? radioParams,
    String Function()? wardriveChannelName,
    LocationSource? Function()? phoneLocation,
    void Function(String line)? log,
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now,
        _keychain = keychain ?? InMemorySecretStore(),
        // ignore: prefer_initializing_formals
        _readSettings = readSettings,
        // ignore: prefer_initializing_formals
        _writeSettings = writeSettings,
        _wardriveChannelName = wardriveChannelName ?? (() => '#wardriving'),
        _phoneLocation = phoneLocation ?? (() => null),
        _log = log ?? ((_) {}) {
    service = MeshTrackService(
      sendChannelText: _send,
      budget: _budget,
      zones: zones,
      selfName: () => _chat?.service.selfName(),
      lastKnown: lastKnown,
      positionAirtime: () {
        final r = radioParams?.call();
        final name = _chat?.service.selfName() ?? '';
        return meshTrackPositionAirtime(sf: r?.sf, bwKhz: r?.bwKhz, cr: r?.cr, nameBytes: name.isEmpty ? 6 : utf8.encode(name).length);
      },
      log: _log,
      now: _now,
      onGroupsChanged: _onCoreGroups,
    );
    service.addListener(_onServiceChanged);
  }

  bool get started => _started;

  /// The chat inbound tap: the core decides; a group whose "Show position messages" is on keeps them as chat too.
  late final ChannelTextTap _tap = ChannelTextTap.of((e) {
    final consumed = service.onChannelText(MtInboundText.fromTapEvent(e));
    if (!consumed) return TapVerdict.pass;
    return _readSettings().showPositions.contains(e.channelId) ? TapVerdict.pass : TapVerdict.consume;
  });

  /// The tap registered with chat (tests).
  @visibleForTesting
  ChannelTextTap get debugTap => _tap;

  // ------------------------------------------------------------------ lifecycle

  /// Reads the Keychain registry and `meshtrack.groups` (Share forced off: sharing never resumes by itself), the settings
  /// values, and `meshtrack_last.json`. Call once.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final s = _readSettings();
    service.setPositionMode(s.approximate ? MtPositionMode.approximate : MtPositionMode.exact);
    service.setRate(s.lowTraffic ? MtRate.lowTraffic : MtRate.smart);
    service.setAnswerRequests(s.answerRequests);
    await _loadRegistry();
    final initial = <MtGroupConfig>[];
    final known = {for (final r in _reg) r.uid};
    for (final g in s.groups) {
      final uid = g['uid'];
      if (uid is! String) continue;
      final cfg = MtGroupConfig.fromJson(g);
      final rows = <String, int>{
        if (g['rows'] case final Map m)
          for (final e in m.entries)
            if (e.value is int) '${e.key}': e.value as int,
      };
      _stored[uid] = _Stored(rows: rows, see: cfg?.see ?? true, shareEveryDrive: cfg?.shareEveryDrive ?? false, last: cfg);
      if (cfg != null && known.contains(uid) && !_uidByChannel.containsKey(cfg.channelId)) {
        _uidByChannel[cfg.channelId] = uid;
        initial.add(cfg);
      }
    }
    // Registry entries without settings (a reinstall: settings.json is gone, the Keychain is not) appear once chat is bound.
    // The engine's timers (staleness tick) and the last-known file start with the first group: a phone without MeshTrack
    // groups runs nothing.
    if (_reg.isNotEmpty) await _ensureServiceStarted();
    service.loadGroups(initial);
    if (_chat != null) _scheduleReconcile(write: _connected);
  }

  bool _serviceStarted = false;
  Future<void>? _serviceStarting;

  Future<void> _ensureServiceStarted() {
    if (_serviceStarted || _disposed) return _serviceStarting ?? Future.value();
    _serviceStarted = true;
    return _serviceStarting = service.start();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    service.removeListener(_onServiceChanged);
    _unbindChat();
    await _phoneSub?.cancel();
    _phoneSub = null;
    // Never started (no group ever): nothing to stop and no last-known file to write.
    if (_serviceStarted) {
      await _serviceStarting;
      await service.dispose();
    }
    groups._dispose();
  }

  // ------------------------------------------------------------------ inputs from AppState / chat

  /// Chat opened (or closed: null). Registers the inbound tap and the arbiter door.
  void bindChat(MtChatBinding? b) {
    if (identical(b, _chat) || _disposed) return;
    _unbindChat();
    _chat = b;
    if (b == null) return;
    b.service.addChannelTextTap(_tap);
    b.service.trackGate = _gate;
    b.changes.addListener(_onChatChanged);
    _channelSig = null;
    if (_started) _scheduleReconcile(write: _connected);
  }

  void _unbindChat() {
    final b = _chat;
    if (b == null) return;
    b.service.removeChannelTextTap(_tap);
    if (identical(b.service.trackGate, _gate)) b.service.trackGate = null;
    b.changes.removeListener(_onChatChanged);
    _chat = null;
  }

  /// The session's transmit arbiter (one per app): MeshTrack sends go through its `track` class.
  void setTrackGate(TrackTxGate? g) {
    _gate = g;
    _chat?.service.trackGate = g;
  }

  /// Radio connected / gone. On connect, groups missing from this radio are written back without asking.
  void setRadioConnected(bool connected) {
    if (_disposed) return;
    final was = _connected;
    _connected = connected;
    service.setRadioConnected(connected);
    if (connected && !was) {
      _channelSig = null;
      _scheduleReconcile(write: true);
    }
  }

  void driveStarted() {
    if (_disposed || _driving) return;
    _driving = true;
    service.driveStarted();
    _updatePhoneFixes();
  }

  void driveStopped() {
    if (_disposed) return;
    // The ping engine is gone with the drive (also after a drive that failed to start): its listen window is closed.
    engineStopped();
    if (!_driving) return;
    _driving = false;
    service.driveStopped();
    _updatePhoneFixes();
  }

  /// The ping engine was torn down: no listen window and no next ping any more (a window left open would hold every
  /// MeshTrack send).
  void engineStopped() {
    if (_disposed) return;
    if (!_window.listening && _window.nextPingAt == null) return;
    _window = MtPingWindow.idle;
    service.setPingWindow(MtPingWindow.idle);
  }

  /// Every fix of the drive's GPS stream.
  void onDriveFix(GeoFix f) {
    if (_disposed || !_driving) return;
    service.onFix(mtFixOf(f));
  }

  /// Every EngineStatus: the ping's listen window and the next ping.
  void onEngineStatus(EngineStatus st) {
    if (_disposed) return;
    final w = pingWindowOf(st);
    if (w.listening == _window.listening && w.nextPingAt == _window.nextPingAt) return;
    _window = w;
    service.setPingWindow(w);
  }

  /// The app came to the front / went behind (the phone-location share runs only in front).
  void setForeground(bool fg) {
    if (_disposed || fg == _foreground) return;
    _foreground = fg;
    _updatePhoneFixes();
  }

  static MtFix mtFixOf(GeoFix f) =>
      MtFix(lat: f.lat, lon: f.lon, at: f.at, accuracyM: f.accuracyM, speedMps: f.speedMps, courseDeg: f.courseDeg);

  /// `listening = state == pinging || heardSoFar != null`, `nextPingAt = EngineStatus.nextPingAt` (API.md).
  static MtPingWindow pingWindowOf(EngineStatus st) =>
      MtPingWindow(listening: st.state == EngineState.pinging || st.heardSoFar != null, nextPingAt: st.nextPingAt);

  /// Delete my data: every friend position, every meet pin, `meshtrack_last.json` and the group list (the channels stay as
  /// ordinary chat channels). Returns how many groups were removed.
  Future<int> clearLocal() async {
    final ids = [for (final g in service.state.groups) g.channelId];
    for (final id in ids) {
      service.leaveGroup(id);
    }
    await service.clearLastKnown();
    for (final g in _readSettings().groups) {
      if (g['uid'] case final String uid) _removedUids.add(uid);
    }
    _removedUids.addAll([for (final r in _reg) r.uid]);
    _reg.clear();
    _stored.clear();
    _uidByChannel.clear();
    _recentlyRemoved.clear();
    _persist(force: true);
    await _persistChain;
    return ids.length;
  }

  // ------------------------------------------------------------------ phone location outside a drive (5.6)

  bool get phoneFixesActive => _phoneSub != null;

  bool get _wantPhoneFixes =>
      !_driving &&
      _foreground &&
      service.state.groups.any((g) => g.config.share && g.config.onRadio && g.config.duration != MtShareDuration.thisDrive);

  void _onServiceChanged() {
    _updatePhoneFixes();
    groups._notify();
  }

  void _updatePhoneFixes() {
    if (_disposed) return;
    if (_wantPhoneFixes) {
      if (_phoneSub != null) return;
      final src = _phoneLocation();
      if (src == null) return;
      _phoneSub = src.fixes.listen((f) {
        if (!_driving) service.onFix(mtFixOf(f));
      }, onError: (Object _) {});
      _log('meshtrack: phone location on (sharing without a drive)');
    } else if (_phoneSub != null) {
      unawaited(_phoneSub!.cancel());
      _phoneSub = null;
      _log('meshtrack: phone location off');
    }
  }

  // ------------------------------------------------------------------ sending

  Future<bool> _send(int channelId, String text) async {
    final b = _chat;
    final radio = b?.radioId();
    if (b == null || radio == null) return false;
    final r = await b.service.sendChannelTextSilently(radioId: radio, channelId: channelId, text: text);
    if (!r.sent) _log('meshtrack: send ${r.status.name}${r.skipReason == null ? '' : ' (${r.skipReason})'}');
    return r.sent;
  }

  /// The pre-send check: too long for the channel, or the arbiter's airtime budget / region cap. A short gap after another
  /// send is not an airtime limit: it passes here and the send itself is refused (the next fix tries again). The arbiter
  /// counts exactly one refusal per attempt: the check peeks (no side effect); only an airtime refusal that stops the send
  /// here is counted (the silent send that follows a pass asks, and counts, itself).
  MtBudget _budget(int channelId, String text) {
    final b = _chat;
    if (b == null) return MtBudget.ok;
    final row = b.store.channels.getById(channelId);
    final bytes = utf8.encode(text.trim()).length;
    if (row != null && bytes > b.service.maxTextBytes(row.convKey)) return MtBudget.tooLong;
    final g = _gate;
    if (g != null) {
      final d = g.peekTrack(bytes);
      if (!d.go && d.airtimeLimited) {
        g.requestTrack(bytes); // the one counted refusal of this attempt
        return MtBudget.airtimeLimit;
      }
    }
    return MtBudget.ok;
  }

  // ------------------------------------------------------------------ the Keychain registry and settings

  /// The Keychain registry could not be read: a read error, data that is not a list, or nothing while `meshtrack.groups`
  /// still lists groups (a locked Keychain can answer "nothing"). While set the registry is never written or deleted and
  /// `meshtrack.groups` is never rewritten, so a bad read can never wipe the stored groups. Every write first reads again.
  bool _registryUnreadable = false;

  /// Groups the person removed (Leave, the channel deleted, Delete my data): their stored settings may go. Settings of any
  /// other group not in the registry are kept as they are.
  final Set<String> _removedUids = {};

  @visibleForTesting
  bool get debugRegistryUnreadable => _registryUnreadable;

  /// One read of the registry. Null = unreadable (see [_registryUnreadable]); an empty list = really no registry yet (a
  /// fresh install: the settings list no group either, or [acceptEmpty]).
  Future<List<_Reg>?> _readRegistry({bool acceptEmpty = false}) async {
    try {
      final raw = await _keychain.read(registryRef);
      if (raw == null) return acceptEmpty || _readSettings().groups.isEmpty ? <_Reg>[] : null;
      final j = jsonDecode(utf8.decode(raw));
      if (j is! List) return null;
      final out = <_Reg>[];
      for (final e in j) {
        final r = _Reg.fromJson(e);
        if (r != null && !out.any((x) => x.uid == r.uid)) out.add(r);
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadRegistry() async {
    _reg.clear();
    final list = await _readRegistry();
    if (list == null) {
      _registryUnreadable = true;
      _log('meshtrack: group list in the Keychain could not be read');
      return;
    }
    _registryUnreadable = false;
    _reg.addAll(list);
    _savedRegistry = jsonEncode([for (final r in _reg) r.toJson()]);
  }

  /// Reads the registry again while it is unreadable; on success merges it with the groups added since (the read list
  /// first) and puts its groups back on this radio. True when it is readable now. "Nothing" is believed only when the app
  /// is in front (the Keychain is unlocked) and two reads in a row say so.
  Future<bool> _retryRegistry() async {
    if (!_registryUnreadable) return true;
    var list = await _readRegistry();
    if (list == null && _foreground) {
      final again = await _readRegistry(acceptEmpty: true);
      if (again != null && again.isNotEmpty) {
        list = again;
      } else if (again != null) {
        list = await _readRegistry(acceptEmpty: true); // "nothing" twice in a row, in front: really no registry
      }
    }
    if (list == null || _disposed) return false;
    _registryUnreadable = false;
    _savedRegistry = jsonEncode([for (final r in list) r.toJson()]);
    var added = false;
    for (final r in list.reversed) {
      if (_removedUids.contains(r.uid) || _reg.any((x) => x.uid == r.uid)) continue;
      _reg.insert(0, r);
      _stored.putIfAbsent(r.uid, _Stored.new);
      added = true;
    }
    _log('meshtrack: group list in the Keychain read again');
    if (added) _scheduleReconcile(write: _connected);
    return true;
  }

  void _addReg(_Reg r) {
    _removedUids.remove(r.uid);
    if (!_reg.any((x) => x.uid == r.uid)) _reg.add(r);
  }

  /// The registry JSON last written to (or read from) the Keychain.
  String? _savedRegistry;

  _Reg? _regOf(String uid) => _reg.where((r) => r.uid == uid).firstOrNull;

  int _uidN = 0;
  String _newUid() => 'g${_now().microsecondsSinceEpoch.toRadixString(36)}${(_uidN++).toRadixString(36)}';

  /// Writes the registry (Keychain) and `meshtrack.groups` (settings), in order, best effort. While the registry is
  /// unreadable it is read again first; if it still cannot be read nothing is written ([force]: Delete my data, which
  /// removes everything anyway).
  void _persist({bool force = false}) {
    _persistChain = _persistChain.then((_) async {
      if (!force && _registryUnreadable && !await _retryRegistry()) {
        _log('meshtrack: group list not saved (the Keychain list could not be read)');
        return;
      }
      if (force) _registryUnreadable = false;
      final reg = jsonEncode([for (final r in _reg) r.toJson()]);
      final list = <Map<String, Object?>>[];
      final byUid = {for (final e in _uidByChannel.entries) e.value: e.key};
      for (final r in _reg) {
        final st = _stored[r.uid];
        if (st == null) continue;
        final id = byUid[r.uid];
        final cfg = id == null ? null : service.state.group(id)?.config;
        final base = cfg ?? st.last;
        if (base == null) continue;
        list.add({
          ...base.copyWith(see: st.see, shareEveryDrive: st.shareEveryDrive).toJson(),
          'uid': r.uid,
          'rows': st.rows,
        });
      }
      if (reg != _savedRegistry) {
        try {
          if (_reg.isEmpty) {
            await _keychain.delete(registryRef);
          } else {
            await _keychain.write(registryRef, Uint8List.fromList(utf8.encode(reg)));
          }
          _savedRegistry = reg;
        } catch (_) {
          _log('meshtrack: group list could not be saved to the Keychain');
        }
      }
      final cur = _readSettings();
      // A stored group that is not in the registry (and was not removed by the person) keeps its settings as they are.
      final known = {for (final r in _reg) r.uid};
      for (final g in cur.groups) {
        final uid = g['uid'];
        if (uid is String && !known.contains(uid) && !_removedUids.contains(uid)) list.add(g);
      }
      if (jsonEncode(cur.groups) == jsonEncode(list)) return; // nothing new: settings.json is not rewritten
      try {
        await _writeSettings(cur.copyWith(groups: list));
      } catch (_) {
        _log('meshtrack: group settings could not be saved');
      }
    });
  }

  /// Settings values (Settings > MeshTrack, intro, chat toggle) saved without touching the groups.
  Future<void> _saveValues(MeshTrackSettings Function(MeshTrackSettings s) f) {
    _persistChain = _persistChain.then((_) async {
      try {
        await _writeSettings(f(_readSettings()));
      } catch (_) {
        _log('meshtrack: settings could not be saved');
      }
    });
    return _persistChain;
  }

  /// The core's group list changed (Share / See / every drive switches, Leave, Undo, addGroup from the UI).
  void _onCoreGroups(List<MtGroupConfig> list) {
    if (_disposed) return;
    if (list.isNotEmpty) unawaited(_ensureServiceStarted());
    final ids = {for (final c in list) c.channelId};
    // Removed (Leave, or a group cleared): forget it in the Keychain and the settings. Kept for an Undo.
    for (final e in _uidByChannel.entries.toList()) {
      if (ids.contains(e.key)) continue;
      final r = _regOf(e.value);
      if (r != null) {
        _recentlyRemoved[e.key] = r;
        _reg.remove(r);
      }
      _stored.remove(e.value);
      _removedUids.add(e.value);
      _uidByChannel.remove(e.key);
    }
    for (final c in list) {
      var uid = _uidByChannel[c.channelId];
      if (uid == null) {
        // New to the wiring (addGroup / restoreGroup called on the service directly): adopt it with its channel's key.
        final back = _recentlyRemoved.remove(c.channelId);
        if (back != null) {
          _addReg(back);
          uid = back.uid;
        } else {
          uid = _newUid();
          unawaited(_adoptFromRow(uid, c.channelId, c.name));
        }
        _uidByChannel[c.channelId] = uid;
      }
      final st = _stored[uid] ??= _Stored();
      st.last = c;
      // A group that is not on this radio reports See off: the person's choice is kept for when it is back.
      if (c.onRadio) st.see = c.see;
      st.shareEveryDrive = c.shareEveryDrive;
      final radio = _chat?.radioId();
      if (radio != null) st.rows[radio] = c.channelId;
    }
    _persist();
  }

  Future<void> _adoptFromRow(String uid, int channelId, String name) async {
    final b = _chat;
    final row = b?.store.channels.getById(channelId);
    final secret = row == null ? null : await b!.store.channels.secretOf(row);
    if (secret == null || row == null || !_eligible(row, secret)) {
      // No key on this phone (or not a private channel): it cannot be a group.
      _uidByChannel.remove(channelId);
      _stored.remove(uid);
      service.syncGroups([for (final g in service.state.groups) if (g.channelId != channelId) g.config]);
      _persist();
      return;
    }
    if (_regOf(uid) == null) _addReg(_Reg(uid, row.name, Uint8List.fromList(secret)));
    _persist();
  }

  bool _eligible(Channel c, List<int>? secret) => MeshTrackGroup.eligible(c, wardriveChannelName: _wardriveChannelName(), secret: secret);

  // ------------------------------------------------------------------ reconcile groups with the channels of this radio

  void _onChatChanged() {
    final sig = _signature();
    if (sig == _channelSig) return;
    _scheduleReconcile(write: _connected);
  }

  String? _signature() {
    final b = _chat;
    final radio = b?.radioId();
    if (b == null || radio == null) return null;
    final sb = StringBuffer(radio);
    for (final c in b.store.channels.list(radio)) {
      sb.write('|${c.id},${c.slot},${c.name},${c.hashByte}');
    }
    return sb.toString();
  }

  void _scheduleReconcile({required bool write}) {
    if (_disposed || !_started) return;
    _reconcileWrite = _reconcileWrite || write;
    if (_reconciling) {
      _reconcileAgain = true;
      return;
    }
    _reconcileDone = _reconcileLoop();
  }

  /// Completes when the reconcile in flight (if any) is done. Tests.
  @visibleForTesting
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      final d = _reconcileDone;
      if (d != null) await d;
      await _persistChain;
      await Future<void>.delayed(Duration.zero);
      if (!_reconciling) return;
    }
  }

  Future<void> _reconcileLoop() async {
    _reconciling = true;
    try {
      do {
        _reconcileAgain = false;
        final write = _reconcileWrite;
        _reconcileWrite = false;
        await _reconcile(write: write);
      } while (_reconcileAgain && !_disposed);
    } catch (e) {
      _log('meshtrack: group check failed (${e.runtimeType})');
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _reconcile({required bool write}) async {
    final b = _chat;
    final radio = b?.radioId();
    if (b == null || radio == null || _disposed) return;
    // A registry that could not be read at start is tried again (it may have been a locked Keychain).
    if (_registryUnreadable) await _retryRegistry();
    final connected = _connected && b.radioConnected();
    final store = b.store;
    final resolved = <({String uid, int id, String name, bool onRadio})>[];
    final dropped = <String>{};
    final processed = <String>{};
    var changed = false;
    for (final r in List.of(_reg)) {
      processed.add(r.uid);
      final st = _stored[r.uid] ??= _Stored();
      final mapped = st.rows[radio];
      Channel? row = mapped == null ? null : store.channels.getById(mapped);
      if (mapped != null && row == null) {
        // The person deleted the channel on this radio (the channel delete flow): the group goes with it.
        _reg.remove(r);
        _stored.remove(r.uid);
        _removedUids.add(r.uid);
        dropped.add(r.uid);
        changed = true;
        continue;
      }
      if (row != null) {
        final s = await store.channels.secretOf(row);
        if (s == null || !_same(s, r.secret)) row = null; // a different key under that row: look for ours
      }
      row ??= await _findBySecret(store, radio, r.secret);
      var onRadio = row?.slot != null;
      if (!onRadio && connected && write) {
        try {
          final j = await b.admin.joinPrivate(radio, row?.name ?? r.name, toHex(r.secret), regionScope: row?.regionScope);
          row = j.channel;
          onRadio = row.slot != null;
          if (onRadio) _log('meshtrack: group put back on this radio');
        } on ChannelAdminException catch (e) {
          _log('meshtrack: group not on this radio (${e.error.name})');
        } catch (e) {
          _log('meshtrack: group not on this radio (${e.runtimeType})');
        }
      }
      if (row == null) {
        if (!connected) continue; // unknown on this radio and no radio to ask: wait for the connect
        // A phone-only row (history and "Not on this radio") until there is room on the radio. Never on top of another
        // phone-only channel with the same name (the store would take that row as this one).
        final clash = store.channels
            .list(radio)
            .any((c) => c.slot == null && c.kind == ChannelKind.private && c.name.toLowerCase() == r.name.toLowerCase());
        if (clash) {
          _log('meshtrack: group not on this radio (name in use)');
          continue;
        }
        row = await store.channels.save(Channel(radioId: radio, name: r.name, kind: ChannelKind.private), secret: r.secret);
        changed = true;
      }
      final id = row.id!;
      if (st.rows[radio] != id) {
        st.rows[radio] = id;
        changed = true;
      }
      if (r.name != row.name) {
        r.name = row.name;
        changed = true;
      }
      resolved.add((uid: r.uid, id: id, name: row.name, onRadio: onRadio));
    }
    if (_disposed) return;
    // Built from the state as it is now (the person may have switched Share while the radio was asked).
    final current = {for (final g in service.state.groups) g.channelId: g.config};
    final out = <MtGroupConfig>[];
    final uidByChannel = <int, String>{};
    for (final x in resolved) {
      final st = _stored[x.uid];
      if (st == null || _regOf(x.uid) == null) continue; // left while this ran
      final prev = current[x.id];
      final base = prev ?? st.last;
      out.add(MtGroupConfig(
        channelId: x.id,
        name: x.name,
        see: x.onRadio && st.see,
        share: x.onRadio && (prev?.share ?? false),
        duration: prev?.duration ?? base?.duration ?? MtShareDuration.thisDrive,
        shareUntil: prev?.shareUntil,
        shareEveryDrive: st.shareEveryDrive,
        onRadio: x.onRadio,
      ));
      uidByChannel[x.id] = x.uid;
    }
    // Groups added while this ran (New group, Undo, an adopt still reading its key) stay as they are.
    for (final e in _uidByChannel.entries) {
      if (uidByChannel.containsKey(e.key) || dropped.contains(e.value) || processed.contains(e.value)) continue;
      final cfg = current[e.key];
      if (cfg == null) continue;
      uidByChannel[e.key] = e.value;
      out.add(cfg);
    }
    _uidByChannel
      ..clear()
      ..addAll(uidByChannel);
    if (out.isNotEmpty) unawaited(_ensureServiceStarted());
    service.syncGroups(out);
    _channelSig = _signature();
    if (changed) _log('meshtrack: groups matched to this radio');
    if (changed || dropped.isNotEmpty) _persist();
    groups._notify();
  }

  static Future<Channel?> _findBySecret(ChatStore store, String radio, List<int> secret) async {
    final hash = channelHashByte(secret);
    Channel? best;
    for (final c in store.channels.list(radio, includeSystem: false)) {
      if (c.hashByte != hash) continue;
      final s = await store.channels.secretOf(c);
      if (s != null && _same(s, secret)) {
        if (c.slot != null) return c;
        best ??= c;
      }
    }
    return best;
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// What the MeshTrack UI (Group sheet, setup, settings, channel detail) calls. Notifies on every change of the groups.
class MeshTrackGroupOps extends ChangeNotifier {
  final MeshTrackWiring _w;
  MeshTrackGroupOps._(this._w);
  bool _gone = false;

  MeshTrackService get _svc => _w.service;

  void _notify() {
    if (!_gone) notifyListeners();
  }

  void _dispose() {
    _gone = true;
    dispose();
  }

  /// Opens the existing channel list where the user removes one ("Make room"): the Chat tab, Channels segment
  /// (`ShellScope.select(AppTab.chat)` + `ChatShellSegment.channels`; the app has no named routes).
  static const String makeRoomRoute = 'chat/channels';

  MtChatBinding? get _chat => _w._chat;

  ({MtChatBinding b, String radio})? _need() {
    final b = _chat;
    final radio = b?.radioId();
    if (b == null || radio == null || !_w._connected || !b.radioConnected()) return null;
    return (b: b, radio: radio);
  }

  static MtGroupOpResult _fromAdmin(ChannelAdminException e) => switch (e.error) {
        ChannelAdminError.noFreeSlot => const MtGroupOpResult(MtGroupOpStatus.radioFull, message: MtCopy.radioFull),
        ChannelAdminError.notConnected => const MtGroupOpResult(MtGroupOpStatus.notConnected, message: MtCopy.notConnected),
        ChannelAdminError.invalidName => MtGroupOpResult(MtGroupOpStatus.nameInvalid, message: e.message),
        ChannelAdminError.duplicateName => const MtGroupOpResult(MtGroupOpStatus.nameInvalid, message: MtCopy.duplicateName),
        ChannelAdminError.badLink || ChannelAdminError.invalidSecret => const MtGroupOpResult(MtGroupOpStatus.invalidLink, message: MtCopy.invalidLink),
        ChannelAdminError.unsupported => const MtGroupOpResult(MtGroupOpStatus.failed, message: MtCopy.unsupported),
        _ => const MtGroupOpResult(MtGroupOpStatus.failed, message: MtCopy.failed),
      };

  /// Marks [c] (saved, with its key on this phone) as a group: Keychain registry, See on, Share off.
  Future<MtGroupOpResult> _adopt(MtChatBinding b, String radio, Channel c, {bool see = true}) async {
    final secret = await b.store.channels.secretOf(c);
    if (secret == null || !_w._eligible(c, secret)) return const MtGroupOpResult(MtGroupOpStatus.notEligible, message: MtCopy.notEligible);
    final id = c.id!;
    if (isGroup(id)) return MtGroupOpResult.ok(id);
    final uid = _w._newUid();
    _w._addReg(_Reg(uid, c.name, Uint8List.fromList(secret)));
    _w._stored[uid] = _Stored(rows: {radio: id}, see: see);
    _w._uidByChannel[id] = uid;
    _svc.addGroup(id, c.name);
    if (!see) _svc.setSee(id, false);
    _notify();
    return MtGroupOpResult.ok(id);
  }

  /// New group: a private channel named [name] (<= 31 bytes, the channel-name rules), marked a group.
  Future<MtGroupOpResult> createGroup(String name) async {
    final n = _need();
    if (n == null) return const MtGroupOpResult(MtGroupOpStatus.notConnected, message: MtCopy.notConnected);
    try {
      ChannelAdmin.checkPrivateName(name);
      final j = await n.b.admin.createPrivate(n.radio, name);
      return await _adopt(n.b, n.radio, j.channel);
    } on ChannelAdminException catch (e) {
      return _fromAdmin(e);
    } catch (e) {
      return const MtGroupOpResult(MtGroupOpStatus.failed, message: MtCopy.failed);
    }
  }

  /// Join from a `meshcore://channel/add` link (QR text or pasted). Public, # and the wardrive channel are refused.
  Future<MtGroupOpResult> joinFromLink(String link) async {
    final p = MeshLinks.parse(link);
    if (p is! ChannelLink) return const MtGroupOpResult(MtGroupOpStatus.invalidLink, message: MtCopy.invalidLink);
    final probe = Channel(radioId: '', slot: 1, name: p.name, kind: classifyChannel(p.name, p.secret));
    if (!_w._eligible(probe, p.secret)) return const MtGroupOpResult(MtGroupOpStatus.notEligible, message: MtCopy.notEligible);
    final n = _need();
    if (n == null) return const MtGroupOpResult(MtGroupOpStatus.notConnected, message: MtCopy.notConnected);
    try {
      final j = await n.b.admin.joinFromLink(n.radio, link);
      return await _adopt(n.b, n.radio, j.channel);
    } on ChannelAdminException catch (e) {
      return _fromAdmin(e);
    } catch (e) {
      return const MtGroupOpResult(MtGroupOpStatus.failed, message: MtCopy.failed);
    }
  }

  /// "Use with MeshTrack" on an existing private channel.
  Future<MtGroupOpResult> useExistingChannel(int channelId) async {
    final b = _chat;
    final radio = b?.radioId();
    final c = b?.store.channels.getById(channelId);
    if (b == null || radio == null || c == null) return const MtGroupOpResult(MtGroupOpStatus.failed, message: MtCopy.failed);
    if (c.slot == null) return const MtGroupOpResult(MtGroupOpStatus.radioFull, message: MtCopy.notOnRadio);
    return _adopt(b, radio, c);
  }

  /// Unmark (Leave): See and Share off, friends forgotten, channel and chat kept. Returns what Undo needs.
  Future<MtGroupConfig?> stopUsingChannel(int channelId) async {
    final c = _svc.leaveGroup(channelId);
    _notify();
    return c;
  }

  Future<void> undoStopUsing(MtGroupConfig config) async {
    _svc.restoreGroup(config);
    _notify();
  }

  final Map<int, ({Channel old, MtGroupConfig oldConfig, _Reg oldReg})> _fresh = {};

  /// Start fresh: a new key under the same name in the same place on the radio; the old group is retired (its channel
  /// stays on the phone with its history, off the radio). Returns the new channel id. Undo: [undoStartFresh].
  Future<MtGroupOpResult> startFresh(int channelId) async {
    final n = _need();
    if (n == null) return const MtGroupOpResult(MtGroupOpStatus.notConnected, message: MtCopy.notConnected);
    final old = n.b.store.channels.getById(channelId);
    final cfg = _svc.state.group(channelId)?.config;
    if (old == null || cfg == null) return const MtGroupOpResult(MtGroupOpStatus.failed, message: MtCopy.failed);
    if (old.slot == null) return const MtGroupOpResult(MtGroupOpStatus.radioFull, message: MtCopy.notOnRadio);
    final uid = _w._uidByChannel[channelId];
    final reg = uid == null ? null : _w._regOf(uid);
    if (reg == null) return const MtGroupOpResult(MtGroupOpStatus.failed, message: MtCopy.failed);
    // The old group is retired first, so nothing puts the old key back on the radio while the new one is written.
    _svc.leaveGroup(channelId); // stops sharing (MT1 x when a position went out) and forgets the old group's friends
    final ChannelJoin j;
    try {
      j = await n.b.admin.rekeyPrivate(old);
    } catch (e) {
      // Nothing changed on the radio: the old group comes back as it was (Share off).
      _w._recentlyRemoved.remove(channelId);
      _w._addReg(reg);
      _w._stored[reg.uid] = _Stored(rows: {n.radio: channelId}, see: cfg.see, shareEveryDrive: cfg.shareEveryDrive);
      _w._uidByChannel[channelId] = reg.uid;
      _svc.restoreGroup(cfg);
      _notify();
      return e is ChannelAdminException ? _fromAdmin(e) : const MtGroupOpResult(MtGroupOpStatus.failed, message: MtCopy.failed);
    }
    _w._recentlyRemoved.remove(channelId);
    final r = await _adopt(n.b, n.radio, j.channel, see: cfg.see);
    if (r.ok) _fresh[j.channel.id!] = (old: n.b.store.channels.getById(channelId) ?? old, oldConfig: cfg, oldReg: reg);
    _w._log('meshtrack: group started fresh');
    return r;
  }

  /// Undo of [startFresh]: the old key goes back on the radio, the new channel is removed, the old group comes back.
  Future<void> undoStartFresh(int newChannelId) async {
    final rec = _fresh.remove(newChannelId);
    final b = _chat;
    if (rec == null || b == null) return;
    final fresh = b.store.channels.getById(newChannelId);
    if (fresh == null) return;
    try {
      _svc.leaveGroup(newChannelId);
      _w._recentlyRemoved.remove(newChannelId);
      final back = await b.admin.undoRekey(rec.old, fresh);
      final radio = b.radioId();
      _w._addReg(rec.oldReg);
      _w._stored[rec.oldReg.uid] = _Stored(rows: {?radio: back.id!}, see: rec.oldConfig.see, shareEveryDrive: rec.oldConfig.shareEveryDrive);
      _w._uidByChannel[back.id!] = rec.oldReg.uid;
      _svc.restoreGroup(rec.oldConfig);
    } catch (e) {
      _w._log('meshtrack: start fresh could not be undone (${e.runtimeType})');
    }
    _notify();
  }

  /// The `meshcore://channel/add` invite (same format as ChannelAdmin.shareLink) for the QR and Share link. Empty when
  /// the group is unknown.
  String inviteLink(int channelId) {
    final uid = _w._uidByChannel[channelId];
    final r = uid == null ? null : _w._regOf(uid);
    if (r == null) return '';
    final row = _chat?.store.channels.getById(channelId);
    return MeshLinks.encodeChannel(name: row?.name ?? r.name, secret: r.secret, regionScope: row?.regionScope);
  }

  /// Private channels on this radio that could become a group (not yet one).
  List<Channel> eligibleChannels() {
    final b = _chat;
    final radio = b?.radioId();
    if (b == null || radio == null) return const [];
    return [
      for (final c in b.store.channels.list(radio, includeSystem: false))
        if (c.slot != null && !isGroup(c.id!) && _w._eligible(c, null)) c,
    ];
  }

  /// The group's key is on this phone but its channel is not on the connected radio (no room).
  bool notOnRadio(int channelId) => _svc.state.group(channelId)?.config.onRadio == false;

  bool isGroup(int channelId) => _svc.state.group(channelId) != null;

  // ------------------------------------------------------------------ settings values

  MeshTrackSettings get _s => _w._readSettings();

  bool get introSeen => _s.introSeen;
  Future<void> setIntroSeen() async {
    await _w._saveValues((s) => s.copyWith(introSeen: true));
    _notify();
  }

  MtPositionMode get positionMode => _s.approximate ? MtPositionMode.approximate : MtPositionMode.exact;
  Future<void> setPositionMode(MtPositionMode m) async {
    _svc.setPositionMode(m);
    await _w._saveValues((s) => s.copyWith(approximate: m == MtPositionMode.approximate));
    _notify();
  }

  MtRate get rate => _s.lowTraffic ? MtRate.lowTraffic : MtRate.smart;
  Future<void> setRate(MtRate r) async {
    _svc.setRate(r);
    await _w._saveValues((s) => s.copyWith(lowTraffic: r == MtRate.lowTraffic));
    _notify();
  }

  bool get answerRequests => _s.answerRequests;
  Future<void> setAnswerRequests(bool on) async {
    _svc.setAnswerRequests(on);
    await _w._saveValues((s) => s.copyWith(answerRequests: on));
    _notify();
  }

  /// Show position messages in this channel's chat (channel detail, default off).
  bool showPositionMessages(int channelId) => _s.showPositions.contains(channelId);
  Future<void> setShowPositionMessages(int channelId, bool on) async {
    await _w._saveValues((s) => s.copyWith(showPositions: on ? {...s.showPositions, channelId} : ({...s.showPositions}..remove(channelId))));
    _notify();
  }
}
