// App-side owner of radio proof at connect (ID step 2). A ChangeNotifier like ClaimController; AppState owns one and calls
// [radioChanged] where it already calls `claims.radioChanged()`, and ONLY while `capabilities.radioProof` is on and a driver
// key exists. With the capability absent (production at build 73) nothing here is ever constructed or called.
//
// One proof per radio per session: a radio that was proved (or refused, or failed) is not asked again until the app restarts;
// [retry] is the person's own "try again". The question "Is that you?" is shown by lib/ui/claims/radio_proof_sheet.dart
// (RadioProofHost) from [pending].
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/radio_proof_flow.dart';
import '../radio/claim_radio.dart';

class RadioProofController extends ChangeNotifier {
  final CmatClient Function() client;
  final String? Function() driverKey;
  final ClaimRadio? Function() radio;
  final bool Function() enabled;
  final DateTime Function() clock;
  final Future<void> Function(Duration d)? wait;
  final Duration pollEvery;

  /// Called when a proof finished and the person's radios or devices changed (refresh the lists).
  final Future<void> Function()? onOwnershipChanged;

  /// Says how a proof ended in one line (AppState's notice toast: the shell shows it).
  final void Function(String message)? say;

  RadioProofController({
    required this.client,
    required this.driverKey,
    required this.radio,
    required this.enabled,
    DateTime Function()? clock,
    this.wait,
    this.pollEvery = const Duration(seconds: 4),
    this.onOwnershipChanged,
    this.say,
  }) : clock = clock ?? DateTime.now;

  final Set<String> _tried = {};
  RadioProofFlow? _flow;
  ProofFlowState _last = const ProofFlowState();

  /// The running or last flow's state (idle before any).
  ProofFlowState get state => _last;
  RadioProofFlow? get flow => _flow;

  /// The question is waiting for an answer.
  bool get pending => _last.asking;

  /// Proofs started this session (tests).
  int get started => _tried.length;

  /// The companion link changed (connected, reconnected, or gone). Starts the proof for a radio not tried this session.
  void radioChanged() {
    if (!enabled()) return;
    final r = radio(), key = driverKey();
    if (r == null || key == null || key.isEmpty) return;
    final pk = r.selfPublicKey;
    if (!r.isConnected || pk == null || pk.isEmpty) return;
    if (_flow != null && !_flow!.state.finished && _flow!.state.step != ProofStep.idle) return; // one at a time
    if (!_tried.add(pk.toLowerCase())) return;
    _start(r, key);
  }

  /// "Try again" after a failure (the person's own tap).
  void retry() {
    if (!enabled()) return;
    final r = radio(), key = driverKey();
    if (r == null || key == null || key.isEmpty) return;
    if (_flow != null && !_flow!.state.finished) return;
    final pk = r.selfPublicKey;
    if (pk != null) _tried.add(pk.toLowerCase());
    _start(r, key);
  }

  void _start(ClaimRadio r, String key) {
    final f = RadioProofFlow(radio: r, client: client(), driverKey: key, now: clock, wait: wait, pollEvery: pollEvery);
    _flow = f;
    f.states.listen((s) {
      _last = s;
      notifyListeners();
    }, onError: (Object _) {});
    unawaited(
      f.run().then((s) async {
        _last = s;
        switch (s.outcome) {
          case ProofOutcome.yours || ProofOutcome.noRadio || ProofOutcome.cancelled || ProofOutcome.none:
            break; // nothing to say: all is as it was
          default:
            if (s.message.isNotEmpty) say?.call(s.message);
        }
        if (s.ownershipChanged) {
          try {
            await onOwnershipChanged?.call();
          } catch (_) {}
        }
        notifyListeners();
      }),
    );
    _last = const ProofFlowState(step: ProofStep.starting, message: 'Asking the server to check your radio…');
    notifyListeners();
  }

  /// The person's answer to "Is that you?".
  void answer({required bool join}) => _flow?.decide(join: join);

  /// Closes the question without answering (it expires on the server; asking again needs a reconnect).
  void dismiss() {
    _flow?.cancel();
  }

  /// A finished result has been shown.
  void clearFinished() {
    if (_flow?.state.finished ?? false) {
      _flow = null;
      _last = const ProofFlowState();
      notifyListeners();
    }
  }
}
