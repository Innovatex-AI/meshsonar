// The claim flows (pure Dart, no Flutter). A claim only lets a driver MANAGE a radio; it never gates whether the radio's
// data is recorded, uploaded or counted.
//
//   A) [OwnRadioClaimFlow]: "Claim my radio". claim-start(sign) with the connected companion's own public key, the radio
//      signs the server's message with its identity key (CMD_SIGN_*), claim-complete. No radio traffic, no password.
//   B) [RepeaterClaimFlow]: "Claim a repeater". claim-start(login), the app logs in to the repeater over the user's own
//      companion (admin password stays in memory only, never sent anywhere), and a successful ADMIN login is the proof:
//      claim-complete carries the attestation. NOTHING on the repeater is changed. ([runRestoreOnly] only finishes a name
//      restore left over from builds before 0.25, which put a code in the name.)
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

  /// claim-start said this key already owns the radio: nothing was started or changed.
  alreadyYours,
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
  final Completer<void> _wake = Completer<void>();

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

  /// Runs [f]; a cancel while it is pending throws [_Cancelled] (the call itself still finishes in the background).
  Future<T> _cancellable<T>(Future<T> f) {
    if (isCancelled) {
      f.then<void>((_) {}, onError: (_) {});
      return Future<T>.error(const _Cancelled());
    }
    return Future.any<T>([f, _cancelled.future.then<T>((_) => throw const _Cancelled())]);
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
  static String serverMessage(CmatException e) => claimServerMessage(e);
}

/// Words a server refusal in plain language (machine `code` first, then the status).
String claimServerMessage(CmatException e) {
  switch (e.code) {
    case 'no_such_challenge':
      return 'The server no longer knows that claim attempt. Start again.';
    case 'not_owner':
      return 'This radio is not yours to change.';
    case 'no_such_claim':
      return 'That claim no longer exists.';
  }
  switch (e.status) {
      case 401:
        return 'The server does not know this phone\'s driver key.';
      case 403:
        return 'The server will not take claims from this key yet.';
      case 409:
        return 'The server could not start that claim. ${e.message}';
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
      } on ClaimAlreadyYours catch (a) {
        return _finish(ClaimFlowState(
            step: ClaimStep.done, outcome: ClaimOutcome.alreadyYours, claim: a.claim, message: 'This radio is already yours. Nothing was changed.'));
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

  /// Login-only claim: claim-start(login), log in to the repeater as ADMIN over the user's own radio, then tell the server.
  /// NOTHING on the repeater is changed: no name, no advert, no CLI command at all. (The old flow put a code in the name and
  /// waited for an observer; Andy: "if a login works that's enough".)
  Future<void> _run() async {
    final key = _pubkey!;
    var loggedIn = false;
    try {
      if (!isPublicKeyHex(key)) return _end(ClaimOutcome.serverRefused, 'That is not a repeater key (64 hex characters).');
      if (!radio.isConnected) return _end(ClaimOutcome.noRadio, 'Connect your radio first. It talks to the repeater for you.');
      final self = radio.selfPublicKey;
      if (self == null) return _end(ClaimOutcome.noRadio, 'Connect your radio first. It talks to the repeater for you.');

      _emit(_s(ClaimStep.starting, 'Asking the server…'));
      final ClaimChallenge ch;
      try {
        ch = await _cancellable(client.claimStart(driverKey, key, ClaimKind.login));
      } on ClaimAlreadyYours catch (a) {
        return _end(ClaimOutcome.alreadyYours, 'This repeater is already yours. Nothing was changed on it and no password was needed.', claim: a.claim);
      } on CmatException catch (e) {
        return _end(_refusal(e), _FlowBase.serverMessage(e), status: e.status);
      }
      _expires = ch.expiresAt;

      _emit(_s(ClaimStep.loggingIn, 'Logging in to the repeater over the mesh. This can take up to a minute…'));
      final RemoteLogin login;
      try {
        await _cancellable(radio.ensureContact(key, nodeType: AdvType.repeater, name: _nodeName));
        login = await _cancellable(radio.login(key, _password!));
        loggedIn = true;
      } on ClaimRadioException catch (e) {
        return _end(_loginOutcome(e), _loginMessage(e));
      }
      final loginAt = now().toUtc();
      if (!login.isAdmin) {
        return _end(ClaimOutcome.notAdmin,
            'The repeater let you in as a guest, not as admin. Claiming needs the ADMIN password. Nothing was changed.');
      }

      _emit(_s(ClaimStep.completing, 'Telling the server you control this repeater…'));
      final NodeClaim claim;
      try {
        claim = await _cancellable(client.claimCompleteLogin(driverKey, ch.id,
            isAdmin: true, firmwareLevel: login.firmwareLevel, loginAt: loginAt, radioPubKey: self));
      } on CmatException catch (e) {
        return _end(_refusal(e), _FlowBase.serverMessage(e), status: e.status);
      }
      _end(ClaimOutcome.verified, 'The repeater is yours. Nothing on it was changed.', claim: claim);
    } on _Cancelled {
      _end(ClaimOutcome.cancelled, 'Cancelled. Nothing was changed.');
    } catch (e) {
      _end(ClaimOutcome.serverUnavailable, 'Something went wrong ($e). Nothing on the repeater was changed.');
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
}
