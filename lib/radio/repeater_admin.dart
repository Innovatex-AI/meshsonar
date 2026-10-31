// RepeaterAdminSession: remote administration of ONE repeater (or room server) through the phone's own radio, over the
// RadioSession login. Free, for the owner; the admin password is typed by the person, goes only into the radio's login frame
// and is never stored, logged or returned by anything in this file.
//
// Rules this layer enforces (research: meshsonar-infra/docs/planning/repeater-observer-live-research-2026-11-01.md):
//  - Silence is the only failure signal, so every call has a timeout and a clear "no answer" error.
//  - Reads are idempotent: retried (twice) on silence. Writes are NEVER retried: after a write the setting is read back and
//    the outcome is verified / rejected / not applied / mismatch / unverified. "Unknown" is never left on screen: the
//    person can re-check.
//  - Every write is built from a typed [SettingDef] (never from free text), needs a [Confirmation] that matches the danger
//    level, remembers the previous value for an undo, and is rate limited.
//  - Binary requests (status, telemetry, neighbours, access list, anonymous clock/regions) are used wherever they exist:
//    they have no 160-character cap and do not touch the CLI replay rule.
//  - Only one request is outstanding at a time (the companion keeps a single pending slot per kind).
// Pure Dart.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'claim_radio.dart';
import 'crypto.dart' show toHex;
import 'protocol.dart' show AdvType, maxLoginPasswordBytes;
import 'repeater_cli.dart';
import 'repeater_radio.dart';
import 'repeater_settings.dart';
import 'repeater_wire.dart';

// ------------------------------------------------------------------ errors

enum AdminErrorKind {
  /// Not logged in (or the login was a guest login and this needs an admin).
  notAdmin,
  notLoggedIn,

  /// No answer in time. For a login this is also what a wrong password looks like.
  silent,

  /// The radio link is gone.
  radioLost,

  /// The radio said no (contact table full, firmware too old).
  radio,

  /// The command or value was refused before anything was sent (invalid, blocked, wrong confirmation).
  refused,

  /// Sent too much too fast; try again after [AdminException.retryAfter].
  rateLimited,
}

class AdminException implements Exception {
  final AdminErrorKind kind;
  final String message;
  final Duration? retryAfter;
  const AdminException(this.kind, this.message, {this.retryAfter});
  @override
  String toString() => 'AdminException(${kind.name}): $message';
}

AdminException _fromRadio(ClaimRadioException e) => switch (e.kind) {
      ClaimRadioError.silent => AdminException(AdminErrorKind.silent, e.message),
      ClaimRadioError.notConnected => AdminException(AdminErrorKind.radioLost, 'Your radio is not connected.'),
      ClaimRadioError.noContact => AdminException(AdminErrorKind.radio, 'Your radio could not add this repeater to its contacts (${e.message}).'),
      ClaimRadioError.unsupported => AdminException(AdminErrorKind.radio, 'This radio firmware cannot do that (${e.message}).'),
      ClaimRadioError.radio => AdminException(AdminErrorKind.radio, e.message),
    };

// ------------------------------------------------------------------ limits and log

class AdminLimits {
  /// CLI commands allowed in [cliWindow].
  final int cliMax;
  final Duration cliWindow;

  /// Anonymous requests allowed in [anonWindow]. The repeater itself answers 4 per 180 s to EVERYONE; we keep one in hand.
  final int anonMax;
  final Duration anonWindow;

  /// Least time between two writes.
  final Duration writeGap;
  final Duration advertCooldown;
  final Duration discoverCooldown;

  /// A read that hits the limit waits up to this long instead of failing.
  final Duration maxAutoWait;
  const AdminLimits({
    this.cliMax = 45,
    this.cliWindow = const Duration(seconds: 60),
    this.anonMax = 3,
    this.anonWindow = const Duration(seconds: 180),
    this.writeGap = const Duration(seconds: 2),
    this.advertCooldown = const Duration(seconds: 30),
    this.discoverCooldown = const Duration(seconds: 120),
    this.maxAutoWait = const Duration(seconds: 20),
  });
}

enum AdminLogKind { sent, reply, note, error }

class AdminLogEntry {
  final DateTime at;
  final AdminLogKind kind;

  /// Already redacted: secrets are replaced before an entry exists.
  final String text;
  const AdminLogEntry(this.at, this.kind, this.text);
  @override
  String toString() => '${at.toIso8601String()} ${kind.name} $text';
}

// ------------------------------------------------------------------ results

class RepeaterIdentity {
  final String? name;
  final String? role;
  final String? firmware;
  final String? board;
  const RepeaterIdentity({this.name, this.role, this.firmware, this.board});
  bool get isObserverBuild => (firmware ?? '').contains('-observer-');
}

class ClockCheck {
  final int repeaterEpoch;
  final int phoneEpoch;
  const ClockCheck(this.repeaterEpoch, this.phoneEpoch);

  /// Repeater minus phone, seconds (positive = the repeater is ahead). About +-1 s of this is the trip time.
  int get skewSecs => repeaterEpoch - phoneEpoch;
}

class RepeaterSnapshot {
  final RepeaterStats? stats;
  final RepeaterTelemetry? telemetry;
  final RepeaterIdentity identity;
  final ClockCheck? clock;
  final List<String> problems;
  const RepeaterSnapshot({this.stats, this.telemetry, this.identity = const RepeaterIdentity(), this.clock, this.problems = const []});
}

enum ReadState { ok, unsupported, silent, error }

class SettingValue {
  final SettingDef def;
  final ReadState state;

  /// The value without the `> ` marker; null unless [state] is ok. For a secret setting this is never filled.
  final String? value;
  const SettingValue(this.def, this.state, [this.value]);
  bool get ok => state == ReadState.ok;
}

class ChangePlan {
  final SettingDef def;
  final String? current;
  final String next;
  final bool noChange;
  final String consequence;
  final List<String> warnings;
  final String? typedPhrase;

  /// The settings from the repeater's own region, if the plan came from one (kept for undo).
  const ChangePlan(this.def, this.current, this.next, this.noChange, this.consequence, this.warnings, this.typedPhrase);

  Danger get danger => def.danger;
  TakesEffect get effect => def.effect;

  /// What the confirm step must collect.
  bool get needsTyped => typedPhrase != null;

  @override
  String toString() => 'ChangePlan(${def.key}${def.secret ? '' : ': $current -> $next'})';
}

enum ApplyOutcome {
  /// Written and read back equal.
  verified,

  /// The repeater said no (an Error reply). Nothing changed.
  rejected,

  /// The repeater still has the old value: the write probably never arrived. Safe to try again by hand.
  notApplied,

  /// Read back something that is neither the old nor the new value.
  mismatch,

  /// Could not read it back (no answer). Tap re-check.
  unverified,
}

class AppliedChange {
  final ChangePlan plan;
  final ApplyOutcome outcome;

  /// What the read-back returned (never for a secret).
  final String? readBack;

  /// What the repeater answered to the write, redacted.
  final String? replyText;
  final bool replyLost;
  final DateTime at;
  const AppliedChange(this.plan, this.outcome, this.readBack, this.replyText, this.replyLost, this.at);

  bool get needsReboot => plan.effect == TakesEffect.afterReboot && outcome != ApplyOutcome.rejected && outcome != ApplyOutcome.notApplied;

  /// The previous value can be written back.
  bool get canUndo => !plan.def.secret && plan.current != null && !plan.noChange && outcome != ApplyOutcome.rejected && outcome != ApplyOutcome.notApplied;
}

class RepeaterRegionNode {
  final String name;
  final int depth;
  final bool floodAllowed;
  const RepeaterRegionNode(this.name, this.depth, this.floodAllowed);
}

class RepeaterRegions {
  final List<RepeaterRegionNode> nodes;
  final String? home;
  final String? defaultScope;

  /// The tree answer was cut at 160 characters; [nodes] came from the allowed / denied lists instead (no hierarchy).
  final bool truncated;
  const RepeaterRegions(this.nodes, this.home, this.defaultScope, {this.truncated = false});
  bool has(String name) => nodes.any((n) => n.name == name);
}

class ActionResult {
  final bool ok;
  final String message;
  const ActionResult(this.ok, this.message);
}

/// What typing into the console produced.
sealed class ConsoleResult {
  const ConsoleResult();
}

class ConsoleReply extends ConsoleResult {
  final String text;
  const ConsoleReply(this.text);
}

class ConsoleRefused extends ConsoleResult {
  final String reason;
  const ConsoleRefused(this.reason);
}

class ConsolePlan extends ConsoleResult {
  final ChangePlan plan;
  const ConsolePlan(this.plan);
}

class ConsoleAction extends ConsoleResult {
  final String command;
  final String consequence;
  const ConsoleAction(this.command, this.consequence);
}

// ------------------------------------------------------------------ the session

class RepeaterAdminSession {
  final RepeaterAdminRadio radio;

  /// The repeater's public key, 64 hex.
  final String keyHex;
  final int nodeType;
  final String contactName;
  final AdminLimits limits;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final int readRetries;

  RepeaterAdminSession({
    required this.radio,
    required String keyHex,
    this.nodeType = AdvType.repeater,
    this.contactName = '',
    this.limits = const AdminLimits(),
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    this.readRetries = 2,
  })  : keyHex = keyHex.toLowerCase(),
        _clock = clock ?? DateTime.now,
        _delay = delay ?? ((d) => Future<void>.delayed(d));

  // ---- state
  bool _loggedIn = false;
  bool _isAdmin = false;
  int? _firmwareLevel;
  BoardLimits _board = const BoardLimits(22);
  String? _boardName;
  int _tag = 0;
  final List<AdminLogEntry> _log = [];
  final List<DateTime> _cliTimes = [];
  final List<DateTime> _anonTimes = [];
  DateTime? _lastWrite;
  final Map<String, DateTime> _lastAction = {};
  final Set<String> _pendingReboot = {};
  Future<void> _chain = Future<void>.value();
  int _outstanding = 0;
  final _activity = StreamController<bool>.broadcast();
  int _commandsSent = 0;

  bool get loggedIn => _loggedIn;

  /// The login was an admin login; CLI, ACL and every write need this.
  bool get isAdmin => _loggedIn && _isAdmin;
  int? get firmwareLevel => _firmwareLevel;
  int get commandsSent => _commandsSent;
  List<AdminLogEntry> get log => List.unmodifiable(_log);
  BoardLimits get boardLimits => _board;

  /// Settings saved that only take effect after a reboot.
  Set<String> get pendingReboot => Set.unmodifiable(_pendingReboot);

  /// True while a request is on the air or waiting for its answer ("Using airtime").
  bool get usingAirtime => _outstanding > 0;
  Stream<bool> get activity => _activity.stream;

  /// The person's own radio key (64 hex), if known; the Access screen never lets you remove it.
  String? get selfKey => radio.selfPublicKey;

  /// Safe summary for state dumps: no passwords, no replies.
  Map<String, Object?> debugState() => {
        'key': keyHex.substring(0, 12),
        'loggedIn': _loggedIn,
        'isAdmin': _isAdmin,
        'commands': _commandsSent,
        'pendingReboot': _pendingReboot.toList(),
      };

  @override
  String toString() => 'RepeaterAdminSession(${keyHex.substring(0, 12)}, loggedIn: $_loggedIn, admin: $_isAdmin)';

  void _note(AdminLogKind k, String text) {
    _log.add(AdminLogEntry(_clock(), k, text));
    if (_log.length > 400) _log.removeRange(0, _log.length - 400);
  }

  // ---- serialisation: one outstanding request at a time
  Future<T> _exclusive<T>(Future<T> Function() job) {
    final c = Completer<T>();
    final prev = _chain;
    _chain = (() async {
      try {
        await prev;
      } catch (_) {}
      _outstanding++;
      if (_outstanding == 1 && !_activity.isClosed) _activity.add(true);
      try {
        c.complete(await job());
      } catch (e, st) {
        c.completeError(e, st);
      } finally {
        _outstanding--;
        if (_outstanding == 0 && !_activity.isClosed) _activity.add(false);
      }
    })();
    return c.future;
  }

  // ---- budgets
  Duration? _budget(List<DateTime> times, int max, Duration window) {
    final now = _clock();
    times.removeWhere((t) => now.difference(t) >= window);
    if (times.length < max) return null;
    return window - now.difference(times.first);
  }

  Future<void> _takeCli() async {
    var wait = _budget(_cliTimes, limits.cliMax, limits.cliWindow);
    if (wait != null) {
      if (wait > limits.maxAutoWait) {
        throw AdminException(AdminErrorKind.rateLimited, 'Too many commands for this repeater. Try again in ${wait.inSeconds + 1} s.', retryAfter: wait);
      }
      await _delay(wait);
      wait = _budget(_cliTimes, limits.cliMax, limits.cliWindow);
    }
    _cliTimes.add(_clock());
  }

  void _takeAnon() {
    final wait = _budget(_anonTimes, limits.anonMax, limits.anonWindow);
    if (wait != null) {
      throw AdminException(AdminErrorKind.rateLimited,
          'A repeater answers only 4 no-login requests per 3 minutes to everybody together. Try again in ${wait.inSeconds + 1} s.',
          retryAfter: wait);
    }
    _anonTimes.add(_clock());
  }

  void _requireAdmin() {
    if (!_loggedIn) throw const AdminException(AdminErrorKind.notLoggedIn, 'Log in first.');
    if (!_isAdmin) throw const AdminException(AdminErrorKind.notAdmin, 'This needs the admin password. You are logged in as a guest.');
  }

  // ---- login

  /// Logs in. Never accepts a blank password: a blank one only re-admits keys already in the repeater's list and proves
  /// nothing (research section 6). Passwords over 15 bytes are refused because the radio would cut them and they could
  /// never match.
  Future<RemoteLogin> login(String password, {Duration? timeout}) async {
    if (password.isEmpty) throw const AdminException(AdminErrorKind.refused, 'Enter the password.');
    if (utf8Length(password) > maxLoginPasswordBytes) {
      throw const AdminException(AdminErrorKind.refused, 'Repeater passwords from a radio are at most 15 characters.');
    }
    return _exclusive(() async {
      _note(AdminLogKind.sent, 'login');
      try {
        await _ensureContact();
        final r = await radio.login(keyHex, password, timeout: timeout);
        _loggedIn = true;
        _isAdmin = r.isAdmin;
        _firmwareLevel = r.firmwareLevel;
        _note(AdminLogKind.reply, r.isAdmin ? 'login ok (admin)' : 'login ok (guest)');
        return r;
      } on ClaimRadioException catch (e) {
        _loggedIn = false;
        _isAdmin = false;
        _note(AdminLogKind.error, 'login failed: ${e.kind.name}');
        if (e.kind == ClaimRadioError.silent) {
          throw const AdminException(AdminErrorKind.silent,
              'No answer. A wrong password, a repeater out of reach and a busy repeater all look the same from here.');
        }
        throw _fromRadio(e);
      }
    });
  }

  Future<void> logout() async {
    _loggedIn = false;
    _isAdmin = false;
    await radio.logout(keyHex);
    _note(AdminLogKind.note, 'logged out');
  }

  void dispose() {
    unawaited(_activity.close());
  }

  bool _contactReady = false;

  /// The radio must hold the repeater as a contact before any request (anonymous requests need no login, but do need this).
  Future<void> _ensureContact() async {
    if (_contactReady) return;
    try {
      await radio.ensureContact(keyHex, nodeType: nodeType, name: contactName);
      _contactReady = true;
    } on ClaimRadioException catch (e) {
      throw _fromRadio(e);
    }
  }

  // ---- CLI primitive

  String _nextTag() {
    _tag = (_tag + 1) % 100;
    return _tag.toString().padLeft(2, '0');
  }

  /// One CLI call: rate limited, tagged, redacted in the log. [idempotent] calls are retried on silence; writes never.
  /// Returns the reply text (raw; the caller decides what may be shown).
  Future<String> _cli(String command, {bool idempotent = false, Duration? timeout}) {
    _requireAdmin();
    return _exclusive(() async {
      final tries = idempotent ? readRetries + 1 : 1;
      AdminException? last;
      for (var i = 0; i < tries; i++) {
        await _takeCli();
        _commandsSent++;
        _note(AdminLogKind.sent, redactCommand(command));
        try {
          final reply = await radio.runTaggedCli(keyHex, _nextTag(), command, timeout: timeout);
          _note(AdminLogKind.reply, redactReply(command, reply));
          return reply;
        } on ClaimRadioException catch (e) {
          final ex = _fromRadio(e);
          _note(AdminLogKind.error, '${ex.kind.name}: ${redactCommand(command)}');
          last = ex;
          if (ex.kind != AdminErrorKind.silent) throw ex;
        }
      }
      throw last!;
    });
  }

  // ------------------------------------------------------------------ reads

  Future<Uint8List> _binary(Future<Uint8List> Function() send, String what) {
    return _exclusive(() async {
      AdminException? last;
      for (var i = 0; i <= readRetries; i++) {
        _commandsSent++;
        _note(AdminLogKind.sent, what);
        try {
          final d = await send();
          _note(AdminLogKind.reply, '$what: ${d.length} bytes');
          return d;
        } on ClaimRadioException catch (e) {
          last = _fromRadio(e);
          _note(AdminLogKind.error, '$what: ${last.kind.name}');
          if (last.kind != AdminErrorKind.silent) throw last;
        }
      }
      throw last!;
    });
  }

  /// STATUS_REQ: works for guests too.
  Future<RepeaterStats> readStatus({Duration? timeout}) async {
    if (!_loggedIn) throw const AdminException(AdminErrorKind.notLoggedIn, 'Log in first.');
    final b = await _binary(() => radio.statusBytes(keyHex, timeout: timeout), 'status');
    final s = RepeaterStats.parse(b);
    if (s == null) throw const AdminException(AdminErrorKind.radio, 'The repeater sent a status block this version does not understand.');
    return s;
  }

  Future<RepeaterTelemetry> readTelemetry({Duration? timeout}) async {
    if (!_loggedIn) throw const AdminException(AdminErrorKind.notLoggedIn, 'Log in first.');
    final b = await _binary(() => radio.telemetryRequest(keyHex, timeout: timeout), 'telemetry');
    return RepeaterTelemetry.parse(b);
  }

  /// The repeater's clock WITHOUT a login (anonymous request; 4 per 180 s shared by every client, direct route only).
  Future<AnonClock> readClockAnon({Duration? timeout}) async {
    await _ensureContact();
    _takeAnon();
    final b = await _binary(() => radio.anonRequest(keyHex, anonBasicRequest, timeout: timeout), 'anonymous clock');
    final c = AnonClock.parse(b);
    if (c == null) throw const AdminException(AdminErrorKind.radio, 'The repeater sent a clock this version does not understand.');
    return c;
  }

  Future<List<String>> readRegionsAnon({Duration? timeout}) async {
    await _ensureContact();
    _takeAnon();
    final b = await _binary(() => radio.anonRequest(keyHex, anonRegionsRequest, timeout: timeout), 'anonymous regions');
    return parseAnonRegions(b);
  }

  Future<OwnerInfo> readOwner() async {
    if (!_loggedIn) throw const AdminException(AdminErrorKind.notLoggedIn, 'Log in first.');
    final b = await _binary(() => radio.binaryRequest(keyHex, ownerRequest), 'owner info');
    return OwnerInfo.parse(b);
  }

  /// The repeater's clock against the phone's. Uses the anonymous request when its budget allows (no airtime for CLI), else
  /// the `clock` command.
  Future<ClockCheck> readClock() async {
    final before = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    try {
      final c = await readClockAnon();
      final after = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
      return ClockCheck(c.epochSecs, (before + after) ~/ 2);
    } on AdminException catch (e) {
      if (e.kind != AdminErrorKind.rateLimited && e.kind != AdminErrorKind.silent) rethrow;
      if (!isAdmin) rethrow;
    }
    final reply = await _cli('clock', idempotent: true);
    final epoch = parseClockReply(reply);
    if (epoch == null) throw const AdminException(AdminErrorKind.radio, 'The repeater\'s clock answer could not be read.');
    return ClockCheck(epoch, _clock().toUtc().millisecondsSinceEpoch ~/ 1000);
  }

  Future<RepeaterIdentity> readIdentity() async {
    _requireAdmin();
    Future<String?> one(String c) async {
      try {
        final r = parseReply(await _cli(c, idempotent: true));
        if (r.kind == ReplyKind.unsupported || r.kind == ReplyKind.error) return null;
        return r.text;
      } on AdminException catch (e) {
        if (e.kind == AdminErrorKind.silent) return null;
        rethrow;
      }
    }

    final ver = await one('ver');
    final board = await one('board');
    final name = await one('get name');
    final role = await one('get role');
    if (board != null) {
      _boardName = board;
      _board = BoardLimits.forBoard(board);
    }
    return RepeaterIdentity(name: name, role: role, firmware: ver, board: board);
  }

  /// Everything the dashboard shows, one request at a time; a part that fails is left out and named in `problems`.
  Future<RepeaterSnapshot> readSnapshot({void Function(String step)? onStep}) async {
    final problems = <String>[];
    RepeaterStats? stats;
    RepeaterTelemetry? tel;
    var id = const RepeaterIdentity();
    ClockCheck? clock;

    Future<void> part(String label, Future<void> Function() f) async {
      onStep?.call(label);
      try {
        await f();
      } on AdminException catch (e) {
        if (e.kind == AdminErrorKind.radioLost || e.kind == AdminErrorKind.notLoggedIn) rethrow;
        problems.add('$label: ${e.message}');
      }
    }

    await part('Status', () async => stats = await readStatus());
    await part('Telemetry', () async => tel = await readTelemetry());
    await part('Clock', () async => clock = await readClock());
    if (isAdmin) {
      await part('Name and firmware', () async => id = await readIdentity());
    }
    return RepeaterSnapshot(stats: stats, telemetry: tel, identity: id, clock: clock, problems: problems);
  }

  /// Neighbours, newest heard first, paged until the repeater's total or 4 pages.
  Future<List<RepeaterNeighbour>> readNeighbours({int order = 0}) async {
    if (!_loggedIn) throw const AdminException(AdminErrorKind.notLoggedIn, 'Log in first.');
    final out = <RepeaterNeighbour>[];
    var total = 0;
    for (var page = 0; page < 4; page++) {
      final req = neighboursRequest(count: 8, offset: out.length, order: order, random: [page + 1, 7, 7, 7]);
      final b = await _binary(() => radio.binaryRequest(keyHex, req), 'neighbours');
      final p = NeighbourPage.parse(b);
      if (p == null) throw const AdminException(AdminErrorKind.radio, 'The neighbour list could not be read.');
      total = p.total;
      out.addAll(p.entries);
      if (p.entries.isEmpty || out.length >= total) break;
    }
    return out;
  }

  /// The access list (admin only; a guest gets silence from the repeater, so this refuses first).
  Future<List<AclEntry>> readAcl() async {
    _requireAdmin();
    final b = await _binary(() => radio.binaryRequest(keyHex, accessListRequest), 'access list');
    return parseAclList(b);
  }

  /// One setting's current value. Secrets are not read here.
  Future<SettingValue> readSetting(SettingDef def) async {
    final cmd = def.getCommand;
    if (def.secret || cmd == null) return SettingValue(def, ReadState.unsupported);
    try {
      final r = parseReply(await _cli(cmd, idempotent: true));
      return switch (r.kind) {
        ReplyKind.value => SettingValue(def, ReadState.ok, r.text),
        ReplyKind.unsupported => SettingValue(def, ReadState.unsupported),
        _ => SettingValue(def, ReadState.error),
      };
    } on AdminException catch (e) {
      if (e.kind == AdminErrorKind.silent) return SettingValue(def, ReadState.silent);
      rethrow;
    }
  }

  /// Reads the settings of [groups] (all non-secret ones). [onProgress] gets (done, total).
  Future<Map<String, SettingValue>> readSettings({Iterable<SettingDef>? only, void Function(int done, int total)? onProgress}) async {
    final defs = [for (final d in (only ?? repeaterSettings)) if (!d.secret && d.getCommand != null) d];
    final out = <String, SettingValue>{};
    for (var i = 0; i < defs.length; i++) {
      onProgress?.call(i, defs.length);
      out[defs[i].key] = await readSetting(defs[i]);
    }
    onProgress?.call(defs.length, defs.length);
    return out;
  }

  /// The region tree. The tree answer is cut at 160 characters; when it is, the allowed and denied lists are used.
  Future<RepeaterRegions> readRegions() async {
    _requireAdmin();
    final tree = await _cli('region', idempotent: true);
    final home = _regionValue(await _cli('region home', idempotent: true), 'home is ');
    final def = _regionValue(await _cli('region default', idempotent: true), 'default scope is ');
    final cut = tree.length >= 150; // replies are cut near 160 characters, tag included
    if (!cut) return RepeaterRegions(parseRegionTree(tree), home, def);
    final allowed = parseReply(await _cli('region list allowed', idempotent: true)).text;
    final denied = parseReply(await _cli('region list denied', idempotent: true)).text;
    final nodes = <RepeaterRegionNode>[
      for (final n in _names(allowed)) RepeaterRegionNode(n, 0, true),
      for (final n in _names(denied)) RepeaterRegionNode(n, 0, false),
    ];
    return RepeaterRegions(nodes, home, def, truncated: true);
  }

  static List<String> _names(String list) => list == '-none-' ? const [] : [for (final n in list.split(',')) if (n.trim().isNotEmpty) n.trim()];

  static String? _regionValue(String reply, String marker) {
    final i = reply.indexOf(marker);
    if (i < 0) return null;
    final v = reply.substring(i + marker.length).trim();
    return v == '<null>' ? null : v;
  }

  // ------------------------------------------------------------------ settings: plan, apply, verify, undo

  /// Checks [rawValue] against the setting's rules, reads the current value, and says what applying would do. Sends nothing
  /// that changes anything.
  Future<ChangePlan> plan(SettingDef def, String rawValue) async {
    _requireAdmin();
    if (_boardName == null && def.key == 'tx') {
      try {
        await readIdentity();
      } on AdminException catch (_) {}
    }
    final bad = def.validate(rawValue, _board);
    if (bad != null) throw AdminException(AdminErrorKind.refused, bad);
    final next = def.normalize(rawValue);
    String? current;
    if (!def.secret && def.getCommand != null) {
      final v = await readSetting(def);
      current = v.value;
    }
    final same = current != null && def.matches(current, next);
    return ChangePlan(def, current, next, same, def.consequence(current, next), def.warnings(current, next, _board), def.typedPhrase(current, next));
  }

  static String? _confirmProblem(ChangePlan p, Confirmation c) {
    if (!c.acknowledged) return 'Confirm first.';
    final phrase = p.typedPhrase;
    if (phrase != null && c.typed.trim() != phrase) return 'Type $phrase exactly to go on.';
    return null;
  }

  /// Sends the change, reads it back and reports. Never retried: a lost reply is answered by a read-back, not a resend.
  Future<AppliedChange> apply(ChangePlan plan, Confirmation confirmation) async {
    _requireAdmin();
    final def = plan.def;
    assert(def.danger != Danger.bricking || plan.typedPhrase != null, 'a bricking setting must have a typed phrase');
    final problem = _confirmProblem(plan, confirmation);
    if (problem != null) throw AdminException(AdminErrorKind.refused, problem);
    final cmd = def.command(plan.next);
    final verdict = classifyCommand(cmd);
    if (!(verdict.kind == CliKind.write || (def.key == 'password' && cmd.startsWith('password ')))) {
      throw AdminException(AdminErrorKind.refused, verdict.reason);
    }
    if (def.key != 'password' && settingFor(verdict.settingKey ?? '') == null) {
      throw const AdminException(AdminErrorKind.refused, 'That setting is not one MeshSonar can change.');
    }
    // write gap
    final last = _lastWrite;
    if (last != null) {
      final since = _clock().difference(last);
      if (since < limits.writeGap) await _delay(limits.writeGap - since);
    }
    _lastWrite = _clock();

    String? reply;
    var lost = false;
    try {
      reply = await _cli(cmd, idempotent: false);
    } on AdminException catch (e) {
      if (e.kind != AdminErrorKind.silent) rethrow;
      lost = true;
    }
    final shown = reply == null ? null : redactReply(cmd, reply);
    final parsed = reply == null ? null : parseReply(reply);
    if (parsed != null && (parsed.kind == ReplyKind.error || parsed.kind == ReplyKind.unsupported)) {
      return AppliedChange(plan, ApplyOutcome.rejected, null, shown, false, _clock());
    }
    final result = await _verify(plan, replyText: reply, replyLost: lost, shown: shown);
    if (def.effect == TakesEffect.afterReboot && result.outcome != ApplyOutcome.rejected && result.outcome != ApplyOutcome.notApplied) {
      _pendingReboot.add(def.key);
    }
    return result;
  }

  Future<AppliedChange> _verify(ChangePlan plan, {String? replyText, required bool replyLost, String? shown}) async {
    final def = plan.def;
    final now = _clock();
    // admin password: the repeater echoes it back in its reply; compare there, and tell the person to test it with a login
    if (def.key == 'password') {
      if (replyText != null && replyText.contains('password now: ')) {
        final echoed = replyText.substring(replyText.indexOf('password now: ') + 'password now: '.length).trim();
        return AppliedChange(plan, echoed == plan.next ? ApplyOutcome.verified : ApplyOutcome.mismatch, null, shown, replyLost, now);
      }
      return AppliedChange(plan, ApplyOutcome.unverified, null, shown, replyLost, now);
    }
    final got = await _readBackValue(def, secret: def.secret);
    if (got == null) return AppliedChange(plan, ApplyOutcome.unverified, null, shown, replyLost, now);
    if (def.matches(got, plan.next)) {
      return AppliedChange(plan, ApplyOutcome.verified, def.secret ? null : got, shown, replyLost, now);
    }
    final prev = plan.current;
    if (prev != null && def.matches(got, prev)) {
      return AppliedChange(plan, replyLost ? ApplyOutcome.notApplied : ApplyOutcome.mismatch, got, shown, replyLost, now);
    }
    return AppliedChange(plan, ApplyOutcome.mismatch, def.secret ? null : got, shown, replyLost, now);
  }

  /// Reads a value back (idempotent, retried). For a secret the value is only compared by the caller, never kept or logged
  /// (the log redacts `get guest.password`).
  Future<String?> _readBackValue(SettingDef def, {bool secret = false}) async {
    final cmd = def.getCommand;
    if (cmd == null) return null;
    try {
      final r = parseReply(await _cli(cmd, idempotent: true));
      return r.kind == ReplyKind.value ? r.text : null;
    } on AdminException catch (e) {
      if (e.kind == AdminErrorKind.silent) return null;
      rethrow;
    }
  }

  /// "Could not verify: tap to re-check": reads the setting again and reports.
  Future<AppliedChange> recheck(AppliedChange c) async {
    _requireAdmin();
    if (c.plan.def.key == 'password') {
      return AppliedChange(c.plan, c.outcome, null, c.replyText, c.replyLost, _clock());
    }
    final v = await _verify(c.plan, replyText: null, replyLost: c.replyLost, shown: c.replyText);
    return v;
  }

  /// Checks a new admin password the only honest way: a fresh login with it (non-blank, so it proves the password).
  Future<bool> testPassword(String password) async {
    try {
      final r = await login(password);
      return r.isAdmin;
    } on AdminException {
      return false;
    }
  }

  /// Puts the previous value back. Goes through [plan] and [apply] again, so it is confirmed, read back and verified like
  /// any change. Throws when there is nothing to put back.
  Future<ChangePlan> planUndo(AppliedChange c) {
    if (!c.canUndo) throw const AdminException(AdminErrorKind.refused, 'There is no earlier value to put back.');
    return plan(c.plan.def, c.plan.current!);
  }

  // ------------------------------------------------------------------ actions

  Duration? _cooldown(String name, Duration d) {
    final last = _lastAction[name];
    if (last == null) return null;
    final left = d - _clock().difference(last);
    return left > Duration.zero ? left : null;
  }

  Future<ActionResult> _action(String cmd, String cooldownName, Duration cooldown, Confirmation c) async {
    _requireAdmin();
    if (!c.acknowledged) throw const AdminException(AdminErrorKind.refused, 'Confirm first.');
    final wait = _cooldown(cooldownName, cooldown);
    if (wait != null) {
      throw AdminException(AdminErrorKind.rateLimited, 'Wait ${wait.inSeconds + 1} s before sending that again.', retryAfter: wait);
    }
    _lastAction[cooldownName] = _clock();
    try {
      final r = parseReply(await _cli(cmd));
      return ActionResult(r.kind != ReplyKind.error && r.kind != ReplyKind.unsupported, r.text);
    } on AdminException catch (e) {
      if (e.kind == AdminErrorKind.silent) {
        return const ActionResult(false, 'No answer. It may still have been sent: check before sending again.');
      }
      rethrow;
    }
  }

  /// A flood advert (about 0.35 s of airtime on every repeater that passes it on) or a zero-hop one (direct neighbours only).
  Future<ActionResult> sendAdvert({required bool flood, required Confirmation confirmation}) =>
      _action(flood ? 'advert' : 'advert.zerohop', flood ? 'advert' : 'advert.zerohop', limits.advertCooldown, confirmation);

  /// Asks the repeater to look for neighbours; it fills its table for about 60 s. Limit: 4 per 2 minutes.
  Future<ActionResult> discoverNeighbours(Confirmation confirmation) =>
      _action('discover.neighbors', 'discover', limits.discoverCooldown, confirmation);

  /// `clock sync`: the repeater sets its clock to this radio's clock plus 1 s, only if that is forward. A repeater that is
  /// AHEAD stays ahead (the firmware never goes backwards).
  Future<ActionResult> syncClock(Confirmation confirmation) async {
    final r = await _action('clock sync', 'clock', const Duration(seconds: 10), confirmation);
    if (r.message.contains('cannot go backwards')) {
      return const ActionResult(false, 'The repeater\'s clock is ahead of your radio\'s, and a repeater never sets its clock backwards.');
    }
    return r;
  }

  /// Reboots the repeater. It is silent about it. Typed confirmation. Afterwards [waitForReturn] says when it came back.
  Future<ActionResult> reboot(Confirmation confirmation) async {
    _requireAdmin();
    if (!confirmation.acknowledged || confirmation.typed.trim() != 'REBOOT') {
      throw const AdminException(AdminErrorKind.refused, 'Type REBOOT exactly to go on.');
    }
    await _exclusive(() async {
      await _takeCli();
      _commandsSent++;
      _note(AdminLogKind.sent, 'reboot');
      try {
        await radio.runTaggedCli(keyHex, _nextTag(), 'reboot', timeout: const Duration(seconds: 3));
      } on ClaimRadioException {
        // the repeater does not answer a reboot
      }
    });
    _pendingReboot.clear();
    return const ActionResult(true, 'Reboot sent. The repeater is off the air for a few seconds.');
  }

  /// Polls the status until the repeater answers with an uptime shorter than [uptimeBefore] (it restarted). Null if it did
  /// not come back in [attempts] x [every].
  Future<Duration?> waitForReturn({required int uptimeBeforeSecs, int attempts = 8, Duration every = const Duration(seconds: 10)}) async {
    final start = _clock();
    for (var i = 0; i < attempts; i++) {
      await _delay(every);
      try {
        final s = await readStatus(timeout: const Duration(seconds: 6));
        if (s.upTimeSecs < uptimeBeforeSecs) return _clock().difference(start);
      } on AdminException {
        // still down
      }
    }
    return null;
  }

  // ------------------------------------------------------------------ regions (typed, read back)

  /// Sets the default flood scope to an EXISTING region. `region default <name>` creates a region when the name is not
  /// found, so a typo would add one: the name must be in [known] (from [readRegions]).
  Future<AppliedChange> setDefaultRegion(String name, {required RepeaterRegions known, required Confirmation confirmation}) async {
    _requireAdmin();
    if (!known.has(name) && name != '<null>') throw AdminException(AdminErrorKind.refused, '"$name" is not a region on this repeater.');
    _checkRegionName(name);
    if (!confirmation.acknowledged) throw const AdminException(AdminErrorKind.refused, 'Confirm first.');
    final before = known.defaultScope ?? '<null>';
    String? reply;
    var lost = false;
    try {
      reply = await _cli('region default $name');
    } on AdminException catch (e) {
      if (e.kind != AdminErrorKind.silent) rethrow;
      lost = true;
    }
    final parsed = reply == null ? null : parseReply(reply);
    final def = _regionDef;
    final plan = ChangePlan(def, before, name, before == name, 'Sets the default flood scope to $name.', const [], null);
    if (parsed != null && parsed.kind == ReplyKind.error) return AppliedChange(plan, ApplyOutcome.rejected, null, reply, false, _clock());
    String? now;
    try {
      now = _regionValue(await _cli('region default', idempotent: true), 'default scope is ') ?? '<null>';
    } on AdminException catch (e) {
      if (e.kind != AdminErrorKind.silent) rethrow;
    }
    final outcome = now == null
        ? ApplyOutcome.unverified
        : now == name
            ? ApplyOutcome.verified
            : now == before
                ? (lost ? ApplyOutcome.notApplied : ApplyOutcome.mismatch)
                : ApplyOutcome.mismatch;
    return AppliedChange(plan, outcome, now, reply, lost, _clock());
  }

  /// Allows or denies flooding for one existing region, then saves. `denyf *` (everything) needs the typed phrase DENY ALL.
  Future<AppliedChange> setRegionFlood(String name, {required bool allow, required RepeaterRegions known, required Confirmation confirmation}) async {
    _requireAdmin();
    if (!known.has(name)) throw AdminException(AdminErrorKind.refused, '"$name" is not a region on this repeater.');
    _checkRegionName(name);
    final deny = !allow;
    final phrase = (deny && name == '*') ? 'DENY ALL' : null;
    if (!confirmation.acknowledged || (phrase != null && confirmation.typed.trim() != phrase)) {
      throw AdminException(AdminErrorKind.refused, phrase == null ? 'Confirm first.' : 'Type $phrase exactly to go on.');
    }
    final was = known.nodes.firstWhere((n) => n.name == name).floodAllowed;
    final cmd = 'region ${allow ? 'allowf' : 'denyf'} $name';
    String? reply;
    var lost = false;
    try {
      reply = await _cli(cmd);
    } on AdminException catch (e) {
      if (e.kind != AdminErrorKind.silent) rethrow;
      lost = true;
    }
    final plan = ChangePlan(_regionDef, was ? 'allowed' : 'denied', allow ? 'allowed' : 'denied', was == allow,
        '${allow ? 'Allows' : 'Stops'} flood packets for region $name.', const [], phrase);
    if (reply != null && parseReply(reply).kind == ReplyKind.error) return AppliedChange(plan, ApplyOutcome.rejected, null, reply, false, _clock());
    // save, then read back
    try {
      await _cli('region save');
    } on AdminException catch (e) {
      if (e.kind != AdminErrorKind.silent) rethrow;
    }
    bool? now;
    try {
      final r = await _cli('region get $name', idempotent: true);
      now = r.trimRight().endsWith(' F');
    } on AdminException catch (e) {
      if (e.kind != AdminErrorKind.silent) rethrow;
    }
    final outcome = now == null
        ? ApplyOutcome.unverified
        : now == allow
            ? ApplyOutcome.verified
            : (lost ? ApplyOutcome.notApplied : ApplyOutcome.mismatch);
    return AppliedChange(plan, outcome, now == null ? null : (now ? 'allowed' : 'denied'), reply, lost, _clock());
  }

  void _checkRegionName(String n) {
    if (n.isEmpty || n.contains(' ') || RegExp(r'[\x00-\x1f|]').hasMatch(n) || n.length > 30) {
      throw const AdminException(AdminErrorKind.refused, 'That is not a region name.');
    }
  }

  static final SettingDef _regionDef = SettingDef.regionPlaceholder();

  // ------------------------------------------------------------------ access list edits

  /// Removes an entry (`setperm <key> 0`). A prefix is enough to remove. Never the key this radio logged in with.
  Future<AppliedChange> removeAclEntry(String keyOrPrefixHex, {required Confirmation confirmation}) =>
      _setPerm(keyOrPrefixHex, AclRole.guest, confirmation);

  /// Sets a role. Anything but removal needs the FULL 64-hex key (a partial key works only for removal).
  Future<AppliedChange> setAclRole(String fullKeyHex, AclRole role, {required Confirmation confirmation}) =>
      _setPerm(fullKeyHex, role, confirmation);

  Future<AppliedChange> _setPerm(String hex, AclRole role, Confirmation c) async {
    _requireAdmin();
    final k = hex.toLowerCase();
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(k) || k.length < 12 || k.length > 64 || k.length.isOdd) {
      throw const AdminException(AdminErrorKind.refused, 'That is not a key.');
    }
    if (role != AclRole.guest && k.length != 64) {
      throw const AdminException(AdminErrorKind.refused, 'Changing a role needs the full key. Only removal works with a partial key.');
    }
    final self = selfKey?.toLowerCase();
    if (self != null && (self.startsWith(k) || k.startsWith(self.substring(0, math.min(12, self.length))))) {
      throw const AdminException(AdminErrorKind.refused, 'This is your own radio. Removing or changing it would lock you out.');
    }
    final phrase = role == AclRole.admin ? 'GRANT ADMIN' : null;
    if (!c.acknowledged || (phrase != null && c.typed.trim() != phrase)) {
      throw AdminException(AdminErrorKind.refused, phrase == null ? 'Confirm first.' : 'Type $phrase exactly to go on.');
    }
    final before = await readAcl();
    final prefix = k.substring(0, 12);
    final had = before.where((e) => e.prefixHex == prefix).map((e) => e.role).cast<AclRole?>().firstWhere((_) => true, orElse: () => null);
    String? reply;
    var lost = false;
    try {
      reply = await _cli('setperm $k ${role.value}');
    } on AdminException catch (e) {
      if (e.kind != AdminErrorKind.silent) rethrow;
      lost = true;
    }
    final plan = ChangePlan(_aclDef, had?.label ?? 'none', role == AclRole.guest ? 'removed' : role.label, false,
        role == AclRole.guest ? 'Removes ${prefix.substring(0, 8)}... from the access list.' : 'Gives ${prefix.substring(0, 8)}... the role ${role.label}.', const [], phrase);
    if (reply != null && parseReply(reply).kind == ReplyKind.error) return AppliedChange(plan, ApplyOutcome.rejected, null, reply, false, _clock());
    List<AclEntry>? after;
    try {
      after = await readAcl();
    } on AdminException catch (e) {
      if (e.kind != AdminErrorKind.silent) rethrow;
    }
    if (after == null) return AppliedChange(plan, ApplyOutcome.unverified, null, reply, lost, _clock());
    final now = after.where((e) => e.prefixHex == prefix).map((e) => e.role).cast<AclRole?>().firstWhere((_) => true, orElse: () => null);
    final ok = role == AclRole.guest ? now == null : now == role;
    return AppliedChange(plan, ok ? ApplyOutcome.verified : (lost && now == had ? ApplyOutcome.notApplied : ApplyOutcome.mismatch),
        now?.label ?? 'none', reply, lost, _clock());
  }

  static final SettingDef _aclDef = SettingDef.accessPlaceholder();

  // ------------------------------------------------------------------ console

  /// A line typed in the console. Reads and replies come back as text; writes come back as a [ConsolePlan] to confirm;
  /// actions as a [ConsoleAction] to confirm; everything else as a refusal with the reason. Never sends a command that
  /// [classifyCommand] does not allow.
  Future<ConsoleResult> console(String line) async {
    final v = classifyCommand(line);
    switch (v.kind) {
      case CliKind.blocked:
      case CliKind.unknown:
        return ConsoleRefused(v.reason);
      case CliKind.read:
        try {
          final reply = await _cli(line.trim(), idempotent: true);
          return ConsoleReply(redactReply(line, reply));
        } on AdminException catch (e) {
          return ConsoleRefused(e.message);
        }
      case CliKind.action:
        if (v.reason == 'reboot') {
          return const ConsoleRefused('Reboot is in Advanced on the Settings screen, behind a typed confirmation.');
        }
        return ConsoleAction(line.trim(), _actionText(line.trim()));
      case CliKind.write:
        final def = settingFor(v.settingKey!);
        if (def == null) return ConsoleRefused('MeshSonar does not know the setting "${v.settingKey}", so it is not changed from here.');
        if (def.secret) return const ConsoleRefused('Passwords are set on the Access screen, which hides them.');
        try {
          return ConsolePlan(await plan(def, v.value!));
        } on AdminException catch (e) {
          return ConsoleRefused(e.message);
        }
    }
  }

  static String _actionText(String c) => switch (c) {
        'advert' => 'Sends a flood advert: the whole mesh hears it, using airtime on every repeater that passes it on.',
        'advert.zerohop' => 'Sends a zero-hop advert: only direct neighbours hear it.',
        'discover.neighbors' => 'Asks the repeater to look for neighbours. It fills its table for about a minute.',
        'clock sync' => 'Sets the repeater\'s clock to your radio\'s clock, if that is later than its own.',
        _ => c,
      };

  /// Runs a confirmed console action.
  Future<ActionResult> runConsoleAction(ConsoleAction a, Confirmation c) => switch (a.command) {
        'advert' => sendAdvert(flood: true, confirmation: c),
        'advert.zerohop' => sendAdvert(flood: false, confirmation: c),
        'discover.neighbors' => discoverNeighbours(c),
        'clock sync' => syncClock(c),
        _ => Future.error(const AdminException(AdminErrorKind.refused, 'Not an action.')),
      };

  // ------------------------------------------------------------------ observer (read only)

  /// Read-only uplink status of an observer build: `get mqtt.status`, `mqtt.stats`, per-slot diagnostics, memory. Only
  /// status commands are sent (never a password, token or username). Server URLs are shown with any credentials removed.
  Future<Map<String, String>> readObserverRaw({void Function(int done, int total)? onProgress}) async {
    _requireAdmin();
    final cmds = [
      'get mqtt.status', 'get mqtt.stats', 'get mqtt.iata', 'get mqtt.origin', 'memory', 'get mqtt.ntp.diag',
      for (var i = 1; i <= 6; i++) ...['get mqtt$i.diag', 'get mqtt$i.preset', 'get mqtt$i.server'],
    ];
    final out = <String, String>{};
    for (var i = 0; i < cmds.length; i++) {
      onProgress?.call(i, cmds.length);
      final c = cmds[i];
      try {
        final r = parseReply(await _cli(c, idempotent: true));
        out[c] = c.endsWith('.server') ? redactUrl(r.text) : r.text;
      } on AdminException catch (e) {
        if (e.kind != AdminErrorKind.silent) rethrow;
      }
    }
    onProgress?.call(cmds.length, cmds.length);
    return out;
  }
}

/// A server URL without `user:password@`.
String redactUrl(String url) => url.replaceFirstMapped(RegExp(r'^([a-z][a-z0-9+.-]*://)[^/@\s]*@'), (m) => '${m[1]}');

/// Parses the `region` dump: one region per line, indented one space per level, ` F` at the end when flooding is allowed.
List<RepeaterRegionNode> parseRegionTree(String dump) {
  final out = <RepeaterRegionNode>[];
  for (final raw in dump.split('\n')) {
    if (raw.trim().isEmpty) continue;
    var depth = 0;
    while (depth < raw.length && raw[depth] == ' ') {
      depth++;
    }
    final body = raw.trim();
    final allowed = body.endsWith(' F');
    final name = (allowed ? body.substring(0, body.length - 2) : body).trim();
    if (name.isEmpty) continue;
    out.add(RepeaterRegionNode(name, depth, allowed));
  }
  return out;
}

/// Hex of a key for display of the first [n] bytes.
String keyPrefixHex(Uint8List key, [int n = 6]) => toHex(key.take(n).toList());
