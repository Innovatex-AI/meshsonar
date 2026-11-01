// The state behind the repeater admin screens. One controller per repeater screen: it owns the [RepeaterAdminSession], the
// last thing read for each tab, the health findings, and the changes made in this visit. Screens read it and call it; they
// never talk to the radio. Passwords arrive here as the person types them, go to the session's login and (only when the
// person chose "Remember passwords on this phone") the vault - nowhere else.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/api.dart' show RadioPreset;
import '../../../radio/admin_password_vault.dart';
import '../../../radio/repeater_admin.dart';
import '../../../radio/repeater_health.dart';
import '../../../radio/repeater_settings.dart';
import '../../../radio/repeater_wire.dart';

enum AdminStage { login, connecting, ready }

/// A line of the "what happened" list on a tab.
class AdminNotice {
  final String text;
  final bool error;
  const AdminNotice(this.text, {this.error = false});
}

class RepeaterAdminController extends ChangeNotifier {
  final RepeaterAdminSession session;

  /// What the screen calls the repeater until the repeater says its own name.
  final String title;
  final bool isRoom;

  /// This region's radio preset (to compare); null when the region has none.
  final RadioPreset? regionPreset;

  /// Contact lookups on the phone's radio: name for a key prefix (hex), and the full key for a prefix (null if unknown or
  /// ambiguous).
  final String? Function(String prefixHex)? nameForPrefix;
  final String? Function(String prefixHex)? fullKeyForPrefix;

  /// Epoch seconds of the last advert the phone's radio heard from this repeater (contact `lastAdvert`), or 0 / null.
  final int? lastAdvertEpoch;
  final AdminPasswordVault? vault;
  final DateTime Function() now;

  /// Uptime seen at the previous health check in this app run (to spot a restart in between).
  static final Map<String, int> _lastUptime = {};

  RepeaterAdminController({
    required this.session,
    required this.title,
    this.isRoom = false,
    this.regionPreset,
    this.nameForPrefix,
    this.fullKeyForPrefix,
    this.lastAdvertEpoch,
    this.vault,
    DateTime Function()? clock,
  }) : now = clock ?? DateTime.now {
    _act = session.activity.listen((v) {
      _airtime = v;
      notifyListeners();
    });
  }

  StreamSubscription<bool>? _act;
  bool _airtime = false;
  bool _disposed = false;

  /// "Using airtime": a request is on the air or waiting for its answer.
  bool get usingAirtime => _airtime;

  // ---- login
  AdminStage stage = AdminStage.login;
  String? loginError;
  bool rememberOffered = false;
  bool rememberOn = false;

  bool get isAdmin => session.isAdmin;

  // ---- data
  RepeaterSnapshot? snapshot;
  bool loadingOverview = false;
  String? overviewStep;
  Map<String, SettingValue> settings = {};
  bool loadingSettings = false;
  ({int done, int total})? settingsProgress;
  List<RepeaterNeighbour>? neighbours;
  bool loadingNeighbours = false;
  bool neighboursByStrength = false;
  List<AclEntry>? acl;
  bool loadingAcl = false;
  RepeaterRegions? regions;
  bool loadingRegions = false;
  ObserverStatus? observer;
  bool loadingObserver = false;
  List<HealthFinding> findings = const [];
  bool checkingHealth = false;
  String? healthStep;

  /// Messages per tab ('overview', 'settings', 'neighbours', 'regions', 'access').
  final Map<String, AdminNotice> notices = {};

  /// The last change made to each setting key in this visit (for "current -> new", undo and re-check).
  final Map<String, AppliedChange> lastApplied = {};

  void _notice(String tab, String? text, {bool error = true}) {
    if (text == null) {
      notices.remove(tab);
    } else {
      notices[tab] = AdminNotice(text, error: error);
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_act?.cancel());
    session.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ login

  Future<void> checkVault() async {
    final v = vault;
    if (v == null) return;
    rememberOffered = v.canRemember;
    rememberOn = await v.remembering();
    _changed();
  }

  /// The saved password for this repeater, if any (memory, or the secure store when remembering is on).
  Future<String?> savedPassword() async => vault?.recall(session.keyHex);

  Future<void> setRemember(bool on) async {
    await vault?.setRemember(on, knownKeys: [session.keyHex]);
    rememberOn = on;
    if (on) {
      final pw = await vault?.recall(session.keyHex);
      if (pw != null) await vault?.keep(session.keyHex, pw);
    }
    _changed();
  }

  /// Logs in. On success the password is kept for this run (and in the secure store only if remembering is on).
  Future<bool> login(String password) async {
    stage = AdminStage.connecting;
    loginError = null;
    _changed();
    try {
      await session.login(password);
      await vault?.keep(session.keyHex, password);
      stage = AdminStage.ready;
      _changed();
      unawaited(refreshOverview());
      return true;
    } on AdminException catch (e) {
      loginError = e.message;
      stage = AdminStage.login;
      _changed();
      return false;
    }
  }

  Future<void> logout() async {
    await session.logout();
    stage = AdminStage.login;
    snapshot = null;
    settings = {};
    neighbours = null;
    acl = null;
    regions = null;
    observer = null;
    findings = const [];
    lastApplied.clear();
    _changed();
  }

  // ------------------------------------------------------------------ reads

  String _msg(Object e) => e is AdminException ? e.message : 'Something went wrong. Try again.';

  /// When the radio drops or the login is lost, go back to the login screen with the reason.
  bool _lostLink(Object e) {
    if (e is AdminException && (e.kind == AdminErrorKind.radioLost || e.kind == AdminErrorKind.notLoggedIn)) {
      stage = AdminStage.login;
      loginError = e.kind == AdminErrorKind.radioLost ? 'Your radio disconnected. Reconnect it, then log in again.' : e.message;
      return true;
    }
    return false;
  }

  Future<void> refreshOverview() async {
    if (loadingOverview) return;
    loadingOverview = true;
    _notice('overview', null);
    _changed();
    try {
      snapshot = await session.readSnapshot(onStep: (s) {
        overviewStep = s;
        _changed();
      });
      if (snapshot!.problems.isNotEmpty) _notice('overview', snapshot!.problems.join('\n'));
      _recomputeFindings();
    } catch (e) {
      if (!_lostLink(e)) _notice('overview', _msg(e));
    } finally {
      loadingOverview = false;
      overviewStep = null;
      _changed();
    }
  }

  Future<void> loadSettings({bool force = false}) async {
    if (loadingSettings || !session.isAdmin) return;
    if (settings.isNotEmpty && !force) return;
    loadingSettings = true;
    _notice('settings', null);
    _changed();
    try {
      final only = [for (final d in repeaterSettings) if (!isRoom || _roomHas(d)) d];
      settings = await session.readSettings(only: only, onProgress: (d, t) {
        settingsProgress = (done: d, total: t);
        _changed();
      });
      _recomputeFindings();
    } catch (e) {
      if (!_lostLink(e)) _notice('settings', _msg(e));
    } finally {
      loadingSettings = false;
      settingsProgress = null;
      _changed();
    }
  }

  /// A room server keeps identity and access settings; the radio and routing ones are the repeater's.
  bool _roomHas(SettingDef d) => d.group == SettingGroup.identity || d.group == SettingGroup.access || d.key == 'radio' || d.key == 'tx';

  /// Settings a screen shows for this node.
  List<SettingDef> get visibleSettings => [for (final d in repeaterSettings) if (!isRoom || _roomHas(d)) d];

  Future<void> loadNeighbours() async {
    if (loadingNeighbours) return;
    loadingNeighbours = true;
    _notice('neighbours', null);
    _changed();
    try {
      neighbours = await session.readNeighbours(order: neighboursByStrength ? 2 : 0);
      _recomputeFindings();
    } catch (e) {
      if (!_lostLink(e)) _notice('neighbours', _msg(e));
    } finally {
      loadingNeighbours = false;
      _changed();
    }
  }

  Future<void> setNeighbourOrder({required bool byStrength}) async {
    neighboursByStrength = byStrength;
    await loadNeighbours();
  }

  Future<void> loadAcl() async {
    if (loadingAcl || !session.isAdmin) return;
    loadingAcl = true;
    _notice('access', null);
    _changed();
    try {
      acl = await session.readAcl();
    } catch (e) {
      if (!_lostLink(e)) _notice('access', _msg(e));
    } finally {
      loadingAcl = false;
      _changed();
    }
  }

  Future<void> loadRegions() async {
    if (loadingRegions) return;
    loadingRegions = true;
    _notice('regions', null);
    _changed();
    try {
      if (session.isAdmin) {
        regions = await session.readRegions();
      } else {
        final names = await session.readRegionsAnon();
        regions = RepeaterRegions([for (final n in names) RepeaterRegionNode(n, 0, true)], null, null, truncated: true);
      }
    } catch (e) {
      if (!_lostLink(e)) _notice('regions', _msg(e));
    } finally {
      loadingRegions = false;
      _changed();
    }
  }

  Future<void> loadObserver() async {
    if (loadingObserver || !session.isAdmin) return;
    loadingObserver = true;
    _changed();
    try {
      observer = ObserverStatus.parse(await session.readObserverRaw());
      _recomputeFindings();
    } catch (e) {
      if (!_lostLink(e)) _notice('settings', _msg(e));
    } finally {
      loadingObserver = false;
      _changed();
    }
  }

  bool get isObserverBuild => snapshot?.identity.isObserverBuild ?? false;

  // ------------------------------------------------------------------ health

  /// The values the check reads from the settings.
  static const List<String> _healthKeys = ['radio', 'tx', 'flood.advert.interval', 'advert.interval', 'repeat', 'flood.max'];

  void _recomputeFindings() {
    final s = snapshot;
    final values = <String, String>{
      for (final e in settings.entries)
        if (e.value.ok && e.value.value != null) e.key: e.value.value!,
    };
    findings = evaluateHealth(HealthInput(
      stats: s?.stats,
      telemetry: s?.telemetry,
      clockSkewSecs: s?.clock?.skewSecs,
      settings: values,
      regionPreset: regionPreset,
      neighbourCount: neighbours?.length,
      observer: observer,
      isObserverBuild: isObserverBuild,
      boardLimits: session.boardLimits,
      previousUptimeSecs: _lastUptime[session.keyHex],
    ));
  }

  /// Reads whatever the check still needs (the few settings it looks at, the neighbour list, the observer uplink), then
  /// evaluates. Sends only reads.
  Future<void> runHealthCheck() async {
    if (checkingHealth) return;
    checkingHealth = true;
    _notice('overview', null);
    _changed();
    try {
      healthStep = 'Status';
      _changed();
      await refreshOverview();
      if (session.isAdmin) {
        healthStep = 'Settings';
        _changed();
        final missing = [for (final k in _healthKeys) if (settings[k] == null) settingFor(k)!];
        if (missing.isNotEmpty) {
          final got = await session.readSettings(only: missing);
          settings = {...settings, ...got};
        }
        healthStep = 'Neighbours';
        _changed();
        neighbours = await session.readNeighbours();
        if (isObserverBuild) {
          healthStep = 'Uplink';
          _changed();
          observer = ObserverStatus.parse(await session.readObserverRaw());
        }
      }
      _recomputeFindings();
      final up = snapshot?.stats?.upTimeSecs;
      if (up != null) _lastUptime[session.keyHex] = up;
    } catch (e) {
      if (!_lostLink(e)) _notice('overview', _msg(e));
    } finally {
      checkingHealth = false;
      healthStep = null;
      _changed();
    }
  }

  // ------------------------------------------------------------------ changes

  /// Checks a typed value and says what applying would do.
  Future<ChangePlan> plan(SettingDef def, String raw) => session.plan(def, raw);

  Future<AppliedChange> apply(ChangePlan plan, Confirmation c) async {
    final r = await session.apply(plan, c);
    _record(r);
    return r;
  }

  Future<AppliedChange> recheck(AppliedChange c) async {
    final r = await session.recheck(c);
    _record(r);
    return r;
  }

  void _record(AppliedChange r) {
    lastApplied[r.plan.def.key] = r;
    final d = r.plan.def;
    if (!d.secret && (r.outcome == ApplyOutcome.verified || r.outcome == ApplyOutcome.mismatch) && r.readBack != null) {
      settings = {...settings, d.key: SettingValue(d, ReadState.ok, r.readBack)};
    }
    if (r.outcome == ApplyOutcome.verified && d.key == 'name') {
      final s = snapshot;
      if (s != null) {
        snapshot = RepeaterSnapshot(
            stats: s.stats,
            telemetry: s.telemetry,
            identity: RepeaterIdentity(name: r.plan.next, role: s.identity.role, firmware: s.identity.firmware, board: s.identity.board),
            clock: s.clock,
            problems: s.problems);
      }
    }
    _recomputeFindings();
    _changed();
  }

  Future<ActionResult> syncClock() async {
    final r = await session.syncClock(Confirmation.yes);
    if (r.ok) unawaited(refreshOverview());
    return r;
  }

  Future<ActionResult> sendAdvert({required bool flood}) => session.sendAdvert(flood: flood, confirmation: Confirmation.yes);

  Future<ActionResult> discoverNeighbours() => session.discoverNeighbours(Confirmation.yes);

  Future<ActionResult> reboot(String typed) async {
    final r = await session.reboot(Confirmation(acknowledged: true, typed: typed));
    _changed();
    return r;
  }

  // ---- regions / access (each returns the outcome for the screen to show)

  Future<AppliedChange> setDefaultRegion(String name) async {
    final r = await session.setDefaultRegion(name, known: regions!, confirmation: Confirmation.yes);
    if (r.outcome == ApplyOutcome.verified) unawaited(loadRegions());
    return r;
  }

  Future<AppliedChange> setRegionFlood(String name, {required bool allow, String typed = ''}) async {
    final r = await session.setRegionFlood(name, allow: allow, known: regions!, confirmation: Confirmation(acknowledged: true, typed: typed));
    unawaited(loadRegions());
    return r;
  }

  /// Proves a password by logging in again with it (a non-blank login proves the password). On success it replaces the saved one.
  Future<bool> testPassword(String password) async {
    final ok = await session.testPassword(password);
    if (ok) await vault?.keep(session.keyHex, password);
    _changed();
    return ok;
  }

  Future<AppliedChange> removeAcl(String prefixOrKey) async {
    final r = await session.removeAclEntry(prefixOrKey, confirmation: Confirmation.yes);
    unawaited(loadAcl());
    return r;
  }

  Future<AppliedChange> setAclRole(String fullKey, AclRole role, {String typed = ''}) async {
    final r = await session.setAclRole(fullKey, role, confirmation: Confirmation(acknowledged: true, typed: typed));
    unawaited(loadAcl());
    return r;
  }

  /// Display name of a key prefix from the radio's contacts.
  String? nameFor(String prefixHex) => nameForPrefix?.call(prefixHex);
}
