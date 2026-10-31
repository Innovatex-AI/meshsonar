// The claim flows (pure Dart, no Flutter). A claim only lets a driver MANAGE a radio; it never gates whether the radio's
// data is recorded, uploaded or counted.
//
//   A) [OwnRadioClaimFlow]: "Claim my radio". claim-start(sign) with the connected companion's own public key, the radio
//      signs the server's message with its identity key (CMD_SIGN_*), claim-complete. No radio traffic, no password.
//   B) [RepeaterClaimFlow]: "Claim a repeater". claim-start(advert) gives a code `MSxxxx`; the app logs in to the
//      repeater over the user's own companion (admin password stays in memory only), reads the repeater's name
//      (`get name`), sets `<name> <code>` (`set name`), sends an `advert`, and polls claim-status until an observer
//      has heard the code. The name is ALWAYS put back (`set name <original>`, `advert`, then `get name` to confirm),
//      with retries; if that cannot be confirmed the exact commands to type are shown and the pending restore is kept on
//      disk so it can be finished later. The repeater's name carries the code only for [ClaimTiming.nameHold].
//
// Firmware facts these flows rely on (MeshCore main, Oct 31 2026; see docs/PROTOCOL.md):
//  - a WRONG repeater password gets no reply, so "silent" means out of range OR wrong password;
//  - a guest login succeeds with is_admin 0 and may not run CLI;
//  - node names are at most 31 bytes (`char node_name[32]`) and an advert with a position carries at most 23 bytes of
//    name, so the code goes at the END of a name cut to leave room for it: the code always reaches observers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../radio/claim_radio.dart';
import '../radio/crypto.dart' show toHex;
import '../radio/protocol.dart' show AdvType, invalidNodeNameChars, maxAdvertNameBytesWithPosition, maxNodeNameBytes, utf8Truncate;
import 'api.dart';
import 'node_claim.dart';

// ------------------------------------------------------------------ the name with the code in it

/// The temporary name: [original] cut so that `<original> <code>` fits in what an advert with a position can carry
/// (23 bytes), then the code. Characters `set name` refuses are dropped. Never longer than [maxNodeNameBytes].
String composeClaimName(String original, String code) {
  final room = maxAdvertNameBytesWithPosition - 1 - utf8.encode(code).length;
  final clean = String.fromCharCodes(original.runes.where((r) => !invalidNodeNameChars.contains(String.fromCharCode(r))));
  final cut = utf8.decode(utf8Truncate(clean, room < 0 ? 0 : room), allowMalformed: true).trimRight();
  final name = cut.isEmpty ? code : '$cut $code';
  return utf8.decode(utf8Truncate(name, maxNodeNameBytes));
}

/// The two commands that put a name back, for a person to type in the MeshCore app if the automatic restore failed.
List<String> restoreCommands(String original) => ['set name $original', 'advert'];

// ------------------------------------------------------------------ pending restores (survive an app restart)

class PendingRestore {
  final String pubkey;
  final String originalName;
  final DateTime since;
  const PendingRestore({required this.pubkey, required this.originalName, required this.since});

  Map<String, dynamic> toJson() => {'pubkey': pubkey, 'originalName': originalName, 'since': since.toUtc().toIso8601String()};

  static PendingRestore? fromJson(Object? j) {
    if (j is! Map) return null;
    final k = j['pubkey'], n = j['originalName'], t = j['since'];
    if (k is! String || !isPublicKeyHex(k) || n is! String) return null;
    return PendingRestore(pubkey: k, originalName: n, since: (t is String ? DateTime.tryParse(t) : null) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
  }
}

/// Where "this repeater's name still has to be put back" is remembered (never the password).
abstract class ClaimRestoreStore {
  Future<List<PendingRestore>> load();
  Future<void> put(PendingRestore r);
  Future<void> remove(String pubkey);
}

class MemoryClaimRestoreStore implements ClaimRestoreStore {
  final Map<String, PendingRestore> items = {};
  @override
  Future<List<PendingRestore>> load() async => items.values.toList();
  @override
  Future<void> put(PendingRestore r) async => items[r.pubkey] = r;
  @override
  Future<void> remove(String pubkey) async => items.remove(pubkey);
}

class FileClaimRestoreStore implements ClaimRestoreStore {
  final File file;
  FileClaimRestoreStore(this.file);
  Future<void> _last = Future<void>.value();

  @override
  Future<List<PendingRestore>> load() async {
    try {
      if (!await file.exists()) return const [];
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return const [];
      return [for (final e in raw) ?PendingRestore.fromJson(e)];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _write(List<PendingRestore> all) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final r in all) r.toJson()]), flush: true);
    await tmp.rename(file.path);
  }

  Future<void> _serialized(Future<void> Function() op) {
    final next = _last.then((_) => op());
    _last = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  @override
  Future<void> put(PendingRestore r) => _serialized(() async {
        final all = (await load()).where((e) => e.pubkey != r.pubkey).toList()..add(r);
        await _write(all);
      });

  @override
  Future<void> remove(String pubkey) => _serialized(() async {
        final all = (await load()).where((e) => e.pubkey != pubkey).toList();
        await _write(all);
      });
}

// ------------------------------------------------------------------ state

enum ClaimStep {
  idle,
  starting,
  signing,
  completing,
  loggingIn,
  readingName,
  settingName,
  advertising,
  waitingForObserver,
  restoring,
  checkingLater,
  done,
}

enum ClaimOutcome {
  /// Still running.
  none,
  verified,
  cancelled,

  /// Not connected to a radio (or it dropped before anything was changed).
  noRadio,

  /// The radio dropped while the flow was running; any name change is restored when it is back.
  radioLost,

  /// Logged in, but not as admin: the repeater only let us in as a guest, which cannot run CLI commands.
  notAdmin,

  /// No answer to the login: out of range, or a wrong password (repeaters never answer a wrong password).
  loginSilent,
  loginRefused,

  /// The radio could not add or find the repeater.
  noContact,
  nameUnreadable,
  setNameFailed,

  /// The code ran out before an observer reported it (the name is back to normal).
  expired,

  /// The server said no (409 claimed, 403 not allowed, 429 slow down, 400 bad key ...).
  serverRefused,
  serverUnavailable,
  signFailed,

  /// The server could not verify the signature (422).
  signatureRejected,
}

enum RestoreState {
  /// The name was never changed (or the flow has not got there).
  notNeeded,

  /// The name carries the code; being put back.
  inProgress,

  /// Put back and read back to confirm.
  confirmed,

  /// Could not confirm; [ClaimFlowState.restoreCommands] says what to type.
  failed,
}

class ClaimFlowState {
  final ClaimStep step;
  final ClaimOutcome outcome;
  final String message;
  final NodeClaim? claim;
  final String? code;
  final DateTime? expiresAt;
  final String? originalName;
  final String? temporaryName;
  final RestoreState restore;
  final List<String> restoreCommands;

  /// HTTP status of a server refusal, for the screen to word it.
  final int? serverStatus;
  const ClaimFlowState({
    this.step = ClaimStep.idle,
    this.outcome = ClaimOutcome.none,
    this.message = '',
    this.claim,
    this.code,
    this.expiresAt,
    this.originalName,
    this.temporaryName,
    this.restore = RestoreState.notNeeded,
    this.restoreCommands = const [],
    this.serverStatus,
  });

  bool get finished => step == ClaimStep.done;
  bool get verified => outcome == ClaimOutcome.verified;

  /// The repeater's name still carries (or may carry) the code: the screen must say so and not let the person leave.
  bool get nameAtRisk => restore == RestoreState.inProgress || restore == RestoreState.failed;
}

/// Timings; tests shrink them.
class ClaimTiming {
  /// Between claim-status polls.
  final Duration poll;

  /// The longest the repeater's name carries the code. (The advert goes out within seconds, so a longer hold would only
  /// leave the code on the mesh for nothing.)
  final Duration nameHold;

  /// After the name is back, keep polling for a late observer report until the code expires, at this pace.
  final Duration latePoll;

  /// Waits between restore attempts.
  final List<Duration> restoreBackoff;
  const ClaimTiming({
    this.poll = const Duration(seconds: 5),
    this.nameHold = const Duration(seconds: 90),
    this.latePoll = const Duration(seconds: 10),
    this.restoreBackoff = const [Duration.zero, Duration(seconds: 4), Duration(seconds: 10), Duration(seconds: 20)],
  });
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Shared plumbing: state stream, cancel, waking, clock.
abstract class _FlowBase {
  final CmatClient client;
  final String driverKey;
  final DateTime Function() now;
  final Future<void> Function(Duration d) wait;
  _FlowBase({required this.client, required this.driverKey, DateTime Function()? now, Future<void> Function(Duration d)? wait})
      : now = now ?? DateTime.now,
        wait = wait ?? Future<void>.delayed;

  final _states = StreamController<ClaimFlowState>.broadcast();
  ClaimFlowState _state = const ClaimFlowState();
  final Completer<ClaimFlowState> _done = Completer<ClaimFlowState>();
  final Completer<void> _cancelled = Completer<void>();
  Completer<void> _wake = Completer<void>();

  Stream<ClaimFlowState> get states => _states.stream;
  ClaimFlowState get state => _state;

  /// Completes with the final state (never with an error).
  Future<ClaimFlowState> get done => _done.future;
  bool get isCancelled => _cancelled.isCompleted;

  /// Stops waiting. A repeater whose name was changed is still restored; there is no way to skip that.
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    _poke();
  }

  /// The app came back to the foreground (or the radio reconnected): re-check the clock now instead of finishing a sleep.
  void appResumed() => _poke();

  void _poke() {
    if (!_wake.isCompleted) _wake.complete();
  }

  void _emit(ClaimFlowState s) {
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  void _checkCancel() {
    if (isCancelled) throw const _Cancelled();
  }

  /// Runs [f]; a cancel while it is pending throws [_Cancelled] (the call itself still finishes in the background).
  Future<T> _cancellable<T>(Future<T> f) {
    if (isCancelled) {
      f.then<void>((_) {}, onError: (_) {});
      return Future<T>.error(const _Cancelled());
    }
    return Future.any<T>([f, _cancelled.future.then<T>((_) => throw const _Cancelled())]);
  }

  /// Sleeps [d], or until woken by [appResumed] / [cancel].
  Future<void> _sleep(Duration d) async {
    if (_wake.isCompleted) _wake = Completer<void>();
    await Future.any<void>([wait(d), _wake.future]);
  }

  void _finish(ClaimFlowState s) {
    _emit(s);
    // listeners get the last state before `done` completes
    _states.close().whenComplete(() {
      if (!_done.isCompleted) _done.complete(s);
    });
  }

  static ClaimFlowState _failed(ClaimFlowState base, ClaimOutcome o, String msg, {int? status}) => ClaimFlowState(
      step: ClaimStep.done,
      outcome: o,
      message: msg,
      code: base.code,
      expiresAt: base.expiresAt,
      originalName: base.originalName,
      temporaryName: base.temporaryName,
      restore: base.restore,
      restoreCommands: base.restoreCommands,
      serverStatus: status);

  /// Words a server refusal in plain language.
  static String serverMessage(CmatException e) {
    switch (e.status) {
      case 401:
        return 'The server does not know this phone\'s driver key.';
      case 403:
        return 'The server will not take claims from this key yet.';
      case 409:
        return 'This radio has a claim in progress or is claimed by someone else. ${e.message}';
      case 410:
        return 'That claim code ran out of time. Start again.';
      case 422:
        return 'The server could not match the radio\'s signature to this radio.';
      case 429:
        final s = e.retryAfterSec;
        return 'Too many claim attempts. Try again ${s == null ? 'in a few minutes' : 'in about ${(s / 60).ceil()} min'}.';
      case 400:
        return 'The server did not accept that radio key.';
    }
    return e.status == null ? 'Could not reach the server (${e.message}).' : e.message;
  }
}

// ------------------------------------------------------------------ A) claim my own radio

class OwnRadioClaimFlow extends _FlowBase {
  final ClaimRadio radio;
  OwnRadioClaimFlow({required this.radio, required super.client, required super.driverKey, super.now, super.wait});

  /// Starts the flow; await [done] (or listen to [states]). Call once.
  Future<ClaimFlowState> run() async {
    unawaited(_run());
    return done;
  }

  Future<void> _run() async {
    try {
      final key = radio.selfPublicKey;
      if (!radio.isConnected || key == null || !isPublicKeyHex(key)) {
        return _finish(_FlowBase._failed(state, ClaimOutcome.noRadio, 'Connect your radio first. This claims the radio that is connected.'));
      }
      _emit(const ClaimFlowState(step: ClaimStep.starting, message: 'Asking the server for a challenge…'));
      final ClaimChallenge ch;
      try {
        ch = await _cancellable(client.claimStart(driverKey, key, ClaimKind.sign));
      } on CmatException catch (e) {
        return _finish(_FlowBase._failed(state, _refusal(e), _FlowBase.serverMessage(e), status: e.status));
      }
      _emit(ClaimFlowState(step: ClaimStep.signing, message: 'Your radio is signing the challenge…', expiresAt: ch.expiresAt));
      final Uint8List sig;
      try {
        sig = await _cancellable(radio.sign(ch.message!));
      } on ClaimRadioException catch (e) {
        return _finish(_FlowBase._failed(
            state,
            e.kind == ClaimRadioError.notConnected ? ClaimOutcome.radioLost : ClaimOutcome.signFailed,
            e.kind == ClaimRadioError.notConnected
                ? 'The radio disconnected. Reconnect it and try again.'
                : e.kind == ClaimRadioError.unsupported
                    ? 'This radio\'s firmware cannot sign. Update it, then try again.'
                    : 'The radio could not sign (${e.message}).'));
      }
      _emit(ClaimFlowState(step: ClaimStep.completing, message: 'Checking the signature with the server…', expiresAt: ch.expiresAt));
      try {
        final claim = await _cancellable(client.claimComplete(driverKey, ch.id, toHex(sig)));
        _finish(ClaimFlowState(step: ClaimStep.done, outcome: ClaimOutcome.verified, claim: claim, message: '${claim.label} is yours.'));
      } on CmatException catch (e) {
        final o = e.status == 410 ? ClaimOutcome.expired : (e.status == 422 ? ClaimOutcome.signatureRejected : _refusal(e));
        _finish(_FlowBase._failed(state, o, _FlowBase.serverMessage(e), status: e.status));
      }
    } on _Cancelled {
      _finish(_FlowBase._failed(state, ClaimOutcome.cancelled, 'Cancelled. Nothing was changed.'));
    } catch (e) {
      _finish(_FlowBase._failed(state, ClaimOutcome.serverUnavailable, 'Something went wrong ($e). Nothing was changed.'));
    }
  }
}

ClaimOutcome _refusal(CmatException e) => e.status == null || e.status! >= 500 ? ClaimOutcome.serverUnavailable : ClaimOutcome.serverRefused;

// ------------------------------------------------------------------ B) claim a repeater over the air

class RepeaterClaimFlow extends _FlowBase {
  ClaimRadio radio;
  final ClaimRestoreStore store;
  final ClaimTiming timing;
  RepeaterClaimFlow({
    required this.radio,
    required super.client,
    required super.driverKey,
    required this.store,
    this.timing = const ClaimTiming(),
    super.now,
    super.wait,
  });

  String? _password;
  String? _pubkey;
  String _nodeName = '';

  /// Claims [pubkey] (64 hex). [password] is the repeater's admin password; it is only held in this object (memory) and
  /// dropped when the flow ends and its name is safe. [nodeName] is only used to label the radio's contact entry.
  Future<ClaimFlowState> run({required String pubkey, required String password, String nodeName = ''}) {
    _pubkey = pubkey.toLowerCase();
    _password = password;
    _nodeName = nodeName;
    unawaited(_run());
    return done;
  }

  /// Finishes an earlier restore that was never confirmed (app closed, radio lost): logs in again and puts [pending]'s
  /// name back. No claim is made.
  Future<ClaimFlowState> runRestoreOnly({required PendingRestore pending, required String password}) {
    _pubkey = pending.pubkey;
    _password = password;
    unawaited(_restoreOnly(pending));
    return done;
  }

  /// The radio is back after a drop: continue restoring if that was waiting.
  void attachRadio(ClaimRadio newRadio) {
    radio = newRadio;
    _poke();
  }

  // The state carried into the next emit.
  String? _code, _original, _temp;
  DateTime? _expires;
  RestoreState _restore = RestoreState.notNeeded;

  ClaimFlowState _s(ClaimStep step, String message, {ClaimOutcome outcome = ClaimOutcome.none, NodeClaim? claim, int? status}) =>
      ClaimFlowState(
        step: step,
        outcome: outcome,
        message: message,
        claim: claim,
        code: _code,
        expiresAt: _expires,
        originalName: _original,
        temporaryName: _temp,
        restore: _restore,
        restoreCommands: _restore == RestoreState.failed && _original != null ? restoreCommands(_original!) : const [],
        serverStatus: status,
      );

  void _end(ClaimOutcome o, String message, {NodeClaim? claim, int? status}) {
    _password = null; // nothing needs it any more
    var m = message;
    if (_original != null) {
      if (_restore == RestoreState.confirmed && !m.contains('back to normal')) {
        m = '$m The repeater\'s name is back to normal.';
      } else if (_restore == RestoreState.failed && !m.contains('commands below')) {
        m = '$m The repeater\'s name could not be confirmed: type the commands below.';
      }
    }
    _finish(_s(ClaimStep.done, m, outcome: o, claim: claim, status: status));
  }

  Future<void> _run() async {
    final key = _pubkey!;
    ClaimOutcome? outcome;
    String message = '';
    NodeClaim? claim;
    var loggedIn = false;
    try {
      if (!isPublicKeyHex(key)) return _end(ClaimOutcome.serverRefused, 'That is not a repeater key (64 hex characters).');
      if (!radio.isConnected) return _end(ClaimOutcome.noRadio, 'Connect your radio first. It talks to the repeater for you.');
      // 1. the code
      _emit(_s(ClaimStep.starting, 'Asking the server for a claim code…'));
      final ClaimChallenge ch;
      try {
        ch = await _cancellable(client.claimStart(driverKey, key, ClaimKind.advert));
      } on CmatException catch (e) {
        return _end(_refusal(e), _FlowBase.serverMessage(e), status: e.status);
      }
      _code = ch.code;
      _expires = ch.expiresAt;

      // 2. log in over the mesh
      _emit(_s(ClaimStep.loggingIn, 'Logging in to the repeater over the mesh. This can take up to a minute…'));
      try {
        await _cancellable(radio.ensureContact(key, nodeType: AdvType.repeater, name: _nodeName));
        final login = await _cancellable(radio.login(key, _password!));
        loggedIn = true;
        if (!login.isAdmin) {
          await radio.logout(key);
          return _end(ClaimOutcome.notAdmin,
              'The repeater let you in as a guest, not as admin. Claiming needs the ADMIN password (the guest password cannot change the name).');
        }
      } on ClaimRadioException catch (e) {
        return _end(_loginOutcome(e), _loginMessage(e));
      }

      // 3. read the current name
      _emit(_s(ClaimStep.readingName, 'Reading the repeater\'s current name…'));
      final pending = (await store.load()).where((p) => p.pubkey == key).firstOrNull;
      String? current;
      try {
        current = await _readName(key);
      } on ClaimRadioException catch (e) {
        return _end(e.kind == ClaimRadioError.notConnected ? ClaimOutcome.radioLost : ClaimOutcome.nameUnreadable,
            e.kind == ClaimRadioError.notConnected
                ? 'The radio disconnected before anything was changed. Reconnect and try again.'
                : 'The repeater did not tell us its name, so nothing was changed. Move closer and try again.');
      }
      if (current == null) {
        return _end(ClaimOutcome.nameUnreadable, 'The repeater did not tell us its name, so nothing was changed. Move closer and try again.');
      }
      // A name left over from an earlier attempt that never got restored: keep the ORIGINAL we saved then.
      _original = pending != null && current != pending.originalName && current.contains(RegExp(r' ?MS[0-9A-Z]{4}$')) ? pending.originalName : current;
      _temp = composeClaimName(_original!, ch.code!);

      // 4. from here on the name is at risk: remember how to put it back BEFORE touching it
      await store.put(PendingRestore(pubkey: key, originalName: _original!, since: now().toUtc()));
      _restore = RestoreState.inProgress;
      _emit(_s(ClaimStep.settingName, 'Adding the code ${ch.code} to the repeater\'s name for a short while…'));

      var verified = false;
      var expired = false;
      var lost = false;
      try {
        _checkCancel();
        final ok = await _setName(key, _temp!);
        if (!ok) {
          outcome = ClaimOutcome.setNameFailed;
          message = 'The repeater did not accept the new name.';
        } else {
          _emit(_s(ClaimStep.advertising, 'Announcing the repeater so an observer can hear the code…'));
          await _sendAdvert(key);
          final codeSetAt = now();
          var readvertised = false;
          _emit(_s(ClaimStep.waitingForObserver, 'Waiting for an observer to hear ${ch.code}…'));
          while (true) {
            _checkCancel();
            if (!radio.isConnected) {
              lost = true;
              outcome = ClaimOutcome.radioLost;
              message = 'The radio disconnected.';
              break;
            }
            try {
              final st = await _cancellable(client.claimStatus(driverKey, ch.id));
              if (st.state == ClaimState.verified) {
                verified = true;
                claim = st.claim;
                break;
              }
              if (st.state == ClaimState.expired) {
                expired = true;
                break;
              }
            } on CmatException {
              // a blip while polling is not a failed claim; the name is restored below either way
            }
            final held = now().difference(codeSetAt);
            if (held >= timing.nameHold || now().isAfter(ch.expiresAt)) break;
            if (!readvertised && held >= timing.nameHold ~/ 2) {
              readvertised = true;
              await _sendAdvert(key); // one more shout in case the first was missed
            }
            await _sleep(timing.poll);
          }
        }
      } on _Cancelled {
        outcome = ClaimOutcome.cancelled;
        message = 'Cancelled.';
      } on ClaimRadioException catch (e) {
        lost = e.kind == ClaimRadioError.notConnected;
        outcome = lost ? ClaimOutcome.radioLost : ClaimOutcome.setNameFailed;
        message = lost ? 'The radio disconnected.' : 'The repeater stopped answering.';
      }

      // 5. ALWAYS put the name back (cancel included), whatever happened
      await _restoreName(key);

      if (verified) {
        outcome = ClaimOutcome.verified;
        message = _restore == RestoreState.confirmed
            ? 'The repeater is yours. Its name is back to normal.'
            : 'The repeater is yours, BUT its name still needs to be put back: type the commands below.';
      } else if (expired) {
        outcome = ClaimOutcome.expired;
        message = 'The code ran out before an observer reported it. Try again closer to an observer, or use the website steps.';
      } else if (outcome == null) {
        // nobody heard it in the hold time: the name is back; keep listening for a late report until the code expires
        if (_restore == RestoreState.confirmed) {
          _emit(_s(ClaimStep.checkingLater, 'The name is back to normal. Still waiting for an observer\'s report of ${ch.code}…'));
          while (!isCancelled && now().isBefore(ch.expiresAt)) {
            await _sleep(timing.latePoll);
            if (isCancelled) break;
            try {
              final st = await _cancellable(client.claimStatus(driverKey, ch.id));
              if (st.state == ClaimState.verified) {
                verified = true;
                claim = st.claim;
                break;
              }
              if (st.state == ClaimState.expired) break;
            } on CmatException {
              // keep trying until the code expires
            } on _Cancelled {
              break;
            }
          }
        }
        if (verified) {
          outcome = ClaimOutcome.verified;
          message = 'The repeater is yours. Its name is back to normal.';
        } else {
          outcome = isCancelled ? ClaimOutcome.cancelled : ClaimOutcome.expired;
          message = isCancelled
              ? 'Cancelled. The repeater\'s name is back to normal.'
              : 'No observer reported the code in time. The name is back to normal. Try again closer to an observer, or use the website steps.';
        }
      }
      if (verified && claim == null) {
        try {
          claim = (await client.myRadios(driverKey)).where((c) => c.pubkey == key).firstOrNull;
        } on CmatException {
          // the claim exists on the server; the list will show it
        }
      }
      if (lost && _restore != RestoreState.confirmed) {
        // wait here for the radio to come back (attachRadio / appResumed) so the restore can finish
        _emit(_s(ClaimStep.restoring, 'Waiting for the radio to reconnect to put the repeater\'s name back…'));
        await _waitForReconnectAndRestore(key);
        if (_restore == RestoreState.confirmed && outcome == ClaimOutcome.radioLost) {
          message = 'The radio disconnected. The repeater\'s name is back to normal now.';
        }
      }
      _end(outcome, message, claim: claim);
    } on _Cancelled {
      _end(ClaimOutcome.cancelled, 'Cancelled. Nothing was changed.');
    } catch (e) {
      // anything unexpected AFTER the name was touched still gets the restore
      if (_restore == RestoreState.inProgress) await _restoreName(key);
      _end(ClaimOutcome.serverUnavailable, 'Something went wrong ($e).${_restore == RestoreState.confirmed ? ' The repeater\'s name is back to normal.' : ''}');
    } finally {
      if (loggedIn) {
        try {
          await radio.logout(key);
        } catch (_) {}
      }
    }
  }

  Future<void> _restoreOnly(PendingRestore p) async {
    final key = p.pubkey;
    _original = p.originalName;
    _restore = RestoreState.inProgress;
    try {
      if (!radio.isConnected) return _end(ClaimOutcome.noRadio, 'Connect your radio first.');
      _emit(_s(ClaimStep.loggingIn, 'Logging in to the repeater over the mesh…'));
      try {
        await _cancellable(radio.ensureContact(key, nodeType: AdvType.repeater));
        final login = await _cancellable(radio.login(key, _password!));
        if (!login.isAdmin) {
          _restore = RestoreState.failed;
          return _end(ClaimOutcome.notAdmin, 'That password only logged in as a guest. Use the ADMIN password.');
        }
      } on ClaimRadioException catch (e) {
        _restore = RestoreState.failed;
        return _end(_loginOutcome(e), _loginMessage(e));
      }
      await _restoreName(key);
      _end(_restore == RestoreState.confirmed ? ClaimOutcome.verified : ClaimOutcome.radioLost,
          _restore == RestoreState.confirmed ? 'The repeater\'s name is back to normal.' : 'The name could not be confirmed. Type the commands below.');
    } on _Cancelled {
      _restore = RestoreState.failed;
      _end(ClaimOutcome.cancelled, 'Cancelled. The repeater\'s name still needs to be put back.');
    } finally {
      try {
        await radio.logout(key);
      } catch (_) {}
    }
  }

  ClaimOutcome _loginOutcome(ClaimRadioException e) => switch (e.kind) {
        ClaimRadioError.notConnected => ClaimOutcome.radioLost,
        ClaimRadioError.silent => ClaimOutcome.loginSilent,
        ClaimRadioError.noContact => ClaimOutcome.noContact,
        _ => ClaimOutcome.loginRefused,
      };

  String _loginMessage(ClaimRadioException e) => switch (e.kind) {
        ClaimRadioError.notConnected => 'The radio disconnected. Reconnect it and try again. Nothing was changed.',
        ClaimRadioError.silent =>
          'No answer from the repeater. Either it is out of range of your radio, or the admin password is wrong (a repeater never replies to a wrong password). Nothing was changed.',
        ClaimRadioError.noContact => 'Your radio could not add this repeater to its contacts (its list may be full). Nothing was changed.',
        ClaimRadioError.unsupported => 'This radio\'s firmware cannot log in to repeaters. Update it. Nothing was changed.',
        _ => 'The repeater refused the login. Nothing was changed.',
      };

  /// `get name` -> `> The Name`. One retry; null when the reply is not a name.
  Future<String?> _readName(String key) async {
    for (var i = 0; i < 2; i++) {
      final r = await _cancellable(radio.runCli(key, 'get name'));
      if (r.startsWith('>')) return r.substring(1).trimLeft();
    }
    return null;
  }

  /// `set name X` -> `OK`. A lost reply is checked by reading the name back; retried once.
  Future<bool> _setName(String key, String name) async {
    for (var i = 0; i < 2; i++) {
      try {
        final r = await _cancellable(radio.runCli(key, 'set name $name'));
        if (r.startsWith('OK')) return true;
        if (r.toLowerCase().startsWith('error')) return false;
      } on ClaimRadioException catch (e) {
        if (e.kind == ClaimRadioError.notConnected) rethrow;
      }
      // reply lost or odd: did it take?
      try {
        final now = await _cancellable(radio.runCli(key, 'get name'));
        if (now.startsWith('>') && now.substring(1).trimLeft() == name) return true;
      } on ClaimRadioException catch (e) {
        if (e.kind == ClaimRadioError.notConnected) rethrow;
      }
    }
    return false;
  }

  Future<void> _sendAdvert(String key) async {
    for (var i = 0; i < 2; i++) {
      try {
        final r = await _cancellable(radio.runCli(key, 'advert'));
        if (r.startsWith('OK')) return;
      } on ClaimRadioException catch (e) {
        if (e.kind == ClaimRadioError.notConnected) rethrow;
      }
    }
  }

  /// Puts [_original] back with retries and reads it back to confirm. Not cancellable. Leaves [_restore] confirmed or
  /// failed; on failure the pending-restore record stays on disk. Never throws.
  Future<void> _restoreName(String key) async {
    final original = _original;
    if (original == null) return;
    _restore = RestoreState.inProgress;
    _emit(_s(ClaimStep.restoring, 'Putting the repeater\'s name back…'));
    for (var i = 0; i < timing.restoreBackoff.length; i++) {
      if (timing.restoreBackoff[i] > Duration.zero) await wait(timing.restoreBackoff[i]);
      if (!radio.isConnected) break; // nothing more to try until it is back
      try {
        final r = await radio.runCli(key, 'set name $original');
        if (!r.startsWith('OK')) continue;
        await radio.runCli(key, 'advert').then<void>((_) {}, onError: (_) {}); // best effort; the name is what matters
        final check = await radio.runCli(key, 'get name');
        if (check.startsWith('>') && check.substring(1).trimLeft() == original) {
          _restore = RestoreState.confirmed;
          await store.remove(key);
          _emit(_s(ClaimStep.restoring, 'The repeater\'s name is back to normal.'));
          return;
        }
      } on ClaimRadioException catch (e) {
        if (e.kind == ClaimRadioError.notConnected) break;
      } catch (_) {
        // try again
      }
    }
    _restore = RestoreState.failed;
    _emit(_s(ClaimStep.restoring, 'Could not confirm the repeater\'s name is back. Type the commands below.'));
  }

  /// After a radio drop: wait (up to the code's expiry plus a margin) for [attachRadio] / the radio coming back, then
  /// restore. The person can stop waiting with [cancel]; the pending record stays on disk.
  Future<void> _waitForReconnectAndRestore(String key) async {
    final give = (_expires ?? now()).add(const Duration(minutes: 10));
    while (_restore != RestoreState.confirmed && !isCancelled && now().isBefore(give)) {
      if (radio.isConnected) {
        try {
          await radio.ensureContact(key, nodeType: AdvType.repeater, name: _nodeName);
          await radio.login(key, _password ?? '');
        } catch (_) {
          // the keep-alive may still be valid; try the restore anyway
        }
        await _restoreName(key);
        if (_restore == RestoreState.confirmed) return;
      }
      await _sleep(timing.latePoll);
    }
  }
}
