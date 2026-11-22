// Radio proof at connect (ID step 2, app half; plan identity-claims-observers D3/D4). Pure Dart, no Flutter.
//
//   run():  radio-proof-start {pubkey} -> the server's text -> the CONNECTED RADIO signs it (CMD_SIGN_*) -> radio-proof-complete
//           claimed       nobody owned the radio: it is this person's now ("<radio> is yours")
//           yours         already this person's (maybe through another device): nothing to do
//           ownedByOther  the flow stops at step `asking` and waits for decide(): "This radio is on <name>'s account. Is that you?"
//   decide(join: true)   "Yes, add this iPad": this device joins that person (instant, or `waitingApproval` while the owner
//                        has "ask me first" on; polled every few seconds until approved, denied or the decide window ends)
//   decide(join: false)  "No, the radio is mine now": the radio alone moves here; never the old owner's drives or settings
//
// SAFETY: the app signs ONLY the server's `meshsonar-login:v1:<host>:connect:<this radio's key>:<random>:<expiry>` text
// (person_identity.dart signableProofText). Anything else (a broker login `v1_...`, another key, another purpose) is refused
// before the radio is asked, and nothing is sent to the server.
// Nothing here gates recording, uploading or counting a ping: a failed or refused proof only means the radio is not tied to a
// person yet. The flag-off path never constructs this class.
import 'dart:async';
import 'dart:typed_data';

import '../radio/claim_radio.dart';
import '../radio/crypto.dart' show toHex;
import 'api.dart';
import 'node_claim.dart';
import 'person_identity.dart';

enum ProofStep { idle, starting, signing, completing, asking, deciding, waitingApproval, done }

enum ProofOutcome {
  none,
  claimed,
  yours,
  joined,
  taken,
  joinDenied,
  refused,
  refusedText,
  signFailed,
  signatureRejected,
  expired,
  changed,
  rateLimited,
  noRadio,
  radioLost,
  cancelled,
  serverUnavailable,
}

class ProofFlowState {
  final ProofStep step;
  final ProofOutcome outcome;
  final String message;
  final NodeClaim? claim;

  /// asking / deciding / waitingApproval: who has the radio.
  final String? ownerName;
  final ClaimNodeType ownerNodeType;
  final bool canJoin;
  final bool askFirst;
  final DateTime? decideUntil;
  const ProofFlowState({
    this.step = ProofStep.idle,
    this.outcome = ProofOutcome.none,
    this.message = '',
    this.claim,
    this.ownerName,
    this.ownerNodeType = ClaimNodeType.unknown,
    this.canJoin = true,
    this.askFirst = false,
    this.decideUntil,
  });

  bool get finished => step == ProofStep.done;
  bool get asking => step == ProofStep.asking;

  /// The radio is now tied to this person (claimed, yours, taken) or the device joined the owner.
  bool get ownershipChanged => outcome == ProofOutcome.claimed || outcome == ProofOutcome.taken || outcome == ProofOutcome.joined;

  /// "This radio is on KE4BFI's account. Is that you?"
  String get question {
    final n = ownerName;
    return n == null ? 'This radio is on another account. Is that you?' : 'This radio is on $n\'s account. Is that you?';
  }
}

/// How long the question waits for an answer at most (the server's decide window is 10 minutes).
const Duration kProofAnswerWindow = Duration(minutes: 11);

class RadioProofFlow {
  final ClaimRadio radio;
  final CmatClient client;
  final String driverKey;
  final DateTime Function() now;
  final Future<void> Function(Duration d) wait;

  /// Time between polls of a pending join.
  final Duration pollEvery;
  RadioProofFlow({
    required this.radio,
    required this.client,
    required this.driverKey,
    DateTime Function()? now,
    Future<void> Function(Duration d)? wait,
    this.pollEvery = const Duration(seconds: 4),
  }) : now = now ?? DateTime.now,
       wait = wait ?? Future<void>.delayed;

  final _states = StreamController<ProofFlowState>.broadcast();
  ProofFlowState _state = const ProofFlowState();
  final Completer<ProofFlowState> _done = Completer<ProofFlowState>();
  Completer<bool>? _answer;
  bool _cancelled = false;
  String? _proofId;

  Stream<ProofFlowState> get states => _states.stream;
  ProofFlowState get state => _state;
  Future<ProofFlowState> get done => _done.future;

  void _emit(ProofFlowState s) {
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  void _finish(ProofOutcome o, String message, {NodeClaim? claim, ProofFlowState? base}) {
    _emit(
      ProofFlowState(
        step: ProofStep.done,
        outcome: o,
        message: message,
        claim: claim,
        ownerName: base?.ownerName,
        ownerNodeType: base?.ownerNodeType ?? ClaimNodeType.unknown,
      ),
    );
    _states.close().whenComplete(() {
      if (!_done.isCompleted) _done.complete(_state);
    });
  }

  /// The person answered the question. Ignored unless the flow is asking.
  void decide({required bool join}) {
    final a = _answer;
    if (a != null && !a.isCompleted) a.complete(join);
  }

  /// Gives up. Nothing on the server is changed by the app after this; an unanswered question just expires there.
  void cancel() {
    _cancelled = true;
    final a = _answer;
    if (a != null && !a.isCompleted) a.completeError(const _Cancelled());
  }

  bool _started = false;

  /// Starts the flow; await [done] (never throws). Call once.
  Future<ProofFlowState> run() {
    if (_started) return done;
    _started = true;
    unawaited(_run());
    return done;
  }

  Future<T> _step<T>(Future<T> f) {
    if (_cancelled) {
      f.then<void>((_) {}, onError: (_) {});
      return Future<T>.error(const _Cancelled());
    }
    return f;
  }

  Future<void> _run() async {
    try {
      final key = radio.selfPublicKey;
      if (!radio.isConnected || key == null || !isPublicKeyHex(key)) {
        return _finish(ProofOutcome.noRadio, 'Connect your radio first.');
      }
      _emit(const ProofFlowState(step: ProofStep.starting, message: 'Asking the server to check your radio…'));
      final ProofStart start;
      try {
        start = await _step(client.radioProofStart(driverKey, key));
      } on CmatException catch (e) {
        return _finish(_refusal(e), _serverWords(e));
      }
      _proofId = start.proofId;
      final text = signableProofText(start.message, key);
      if (text == null) {
        // never sign it, never answer the server about it
        return _finish(
          ProofOutcome.refusedText,
          'The server asked the radio to sign something that is not a MeshSonar login. It was not signed.',
        );
      }
      _emit(const ProofFlowState(step: ProofStep.signing, message: 'Your radio is signing…'));
      final Uint8List sig;
      try {
        sig = await _step(radio.sign(start.message));
      } on ClaimRadioException catch (e) {
        return _finish(
          e.kind == ClaimRadioError.notConnected ? ProofOutcome.radioLost : ProofOutcome.signFailed,
          e.kind == ClaimRadioError.notConnected
              ? 'The radio disconnected. Reconnect it and try again.'
              : e.kind == ClaimRadioError.unsupported
              ? 'This radio\'s firmware cannot sign, so it cannot be proven.'
              : 'The radio could not sign (${e.message}).',
        );
      }
      _emit(const ProofFlowState(step: ProofStep.completing, message: 'Checking the signature with the server…'));
      final ProofResult r;
      try {
        r = await _step(client.radioProofComplete(driverKey, start.proofId, toHex(sig)));
      } on CmatException catch (e) {
        return _finish(_refusal(e), _serverWords(e));
      }
      switch (r.kind) {
        case ProofKind.claimed:
          return _finish(ProofOutcome.claimed, '${r.claim!.label} is yours now.', claim: r.claim);
        case ProofKind.yours:
          return _finish(ProofOutcome.yours, '${r.claim!.label} is already yours.', claim: r.claim);
        case ProofKind.ownedByOther:
          await _ask(r);
      }
    } on _Cancelled {
      _finish(ProofOutcome.cancelled, 'Cancelled. Nothing was changed.');
    } catch (e) {
      _finish(ProofOutcome.serverUnavailable, 'Something went wrong ($e). Nothing was changed.');
    }
  }

  Future<void> _ask(ProofResult r) async {
    final asked = ProofFlowState(
      step: ProofStep.asking,
      ownerName: r.ownerName,
      ownerNodeType: r.ownerNodeType,
      canJoin: r.canJoin,
      askFirst: r.askFirst,
      decideUntil: r.decideUntil,
    );
    _emit(asked);
    final answer = _answer = Completer<bool>();
    final until = r.decideUntil;
    bool join;
    try {
      final left = until == null ? kProofAnswerWindow : until.difference(now());
      // the server's window is 10 minutes; a phone clock that is far off never makes the question wait for hours
      final span = left.isNegative ? Duration.zero : (left > kProofAnswerWindow ? kProofAnswerWindow : left);
      join = await answer.future.timeout(span);
    } on TimeoutException {
      return _finish(ProofOutcome.expired, 'That took too long. Connect the radio again to ask again.', base: asked);
    }
    if (join && !r.canJoin) join = false; // the button is not offered; never send it
    _emit(ProofFlowState(step: ProofStep.deciding, ownerName: r.ownerName, canJoin: r.canJoin, message: 'Telling the server…'));
    final id = r.proofId ?? _proofId!;
    for (;;) {
      final DecideResult d;
      try {
        d = await _step(client.radioProofDecide(driverKey, id, join: join));
      } on CmatException catch (e) {
        return _finish(_refusal(e), _serverWords(e), base: asked);
      }
      switch (d.kind) {
        case DecideKind.joined:
          return _finish(
            ProofOutcome.joined,
            'Done. This device is on ${r.ownerName == null ? 'that' : '${r.ownerName}\'s'} account now.',
            base: asked,
          );
        case DecideKind.taken:
          return _finish(ProofOutcome.taken, 'The radio is yours now.', claim: d.claim, base: asked);
        case DecideKind.joinDenied:
          return _finish(ProofOutcome.joinDenied, 'The owner turned this device down. Nothing was changed.', base: asked);
        case DecideKind.refused:
          return _finish(
            ProofOutcome.refused,
            'This device is signed in to an account, so it cannot join another. You can still take the radio.',
            base: asked,
          );
        case DecideKind.joinPending:
          _emit(
            ProofFlowState(
              step: ProofStep.waitingApproval,
              ownerName: r.ownerName,
              message: 'Waiting for ${r.ownerName ?? 'the owner'} to approve this device…',
              decideUntil: until,
            ),
          );
          if (until != null && !now().isBefore(until)) {
            return _finish(ProofOutcome.expired, 'No answer in time. Connect the radio again to ask again.', base: asked);
          }
          await _step(wait(pollEvery));
      }
    }
  }

  ProofOutcome _refusal(CmatException e) {
    if (e.code == 'bad_signature' || e.status == 422) return ProofOutcome.signatureRejected;
    if (e.code == 'device_has_account') return ProofOutcome.refused;
    if (e.status == 410) return ProofOutcome.expired;
    if (e.code == 'changed' || e.status == 409) return ProofOutcome.changed;
    if (e.status == 429) return ProofOutcome.rateLimited;
    return ProofOutcome.serverUnavailable;
  }

  String _serverWords(CmatException e) {
    if (e.code == 'bad_signature' || e.status == 422) {
      return 'The server could not match the radio\'s signature to its key. Try connecting again.';
    }
    if (e.code == 'device_has_account') {
      return 'This device is signed in to an account, so it cannot join another. You can still take the radio.';
    }
    if (e.status == 410) return 'That check expired. Connect the radio again to start a new one.';
    if (e.code == 'changed' || e.status == 409) return 'The radio changed hands meanwhile. Connect it again to prove it again.';
    if (e.status == 429) return 'Too many radio checks for now. Try again later.';
    if (e.status == 404) return 'The server does not offer radio checks right now.';
    return 'Could not reach the server (${e.message}). Nothing was changed.';
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
