// "Claim several repeaters in one sitting" (ID step 6, app half): the rows of one session and the one-at-a-time proving.
// Each repeater is proven the way the server already takes for a repeater: an ADMIN login over the person's own radio, which
// the app attests (claim method `login`). The flow is the existing RepeaterClaimFlow (lib/core/claim_flow.dart) started through
// ClaimController, so nothing on a repeater is changed and the admin password lives in that flow's memory only: this controller
// never receives, stores or logs it beyond handing it to the flow.
//
// A radio can talk to one repeater at a time, so rows are proven one after another; "Claim another" is simply the next row.
// Used only while AppState.repeaterBatchEnabled (the server offers radio proof and repeater login claims).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/claim_flow.dart';
import '../core/node_claim.dart';
import 'claims.dart';

enum BatchRowState { notStarted, proving, claimed, failed }

class BatchRow {
  /// 64 lower-case hex characters.
  final String key;
  final String name;
  final BatchRowState state;

  /// While proving: what the flow is doing now. After a failure: why, in words. After success: a line about the claim.
  final String? message;

  /// A failure's short title (for example "No answer from the repeater").
  final String? title;

  /// How the claim was proven, when it is claimed (from the server's answer).
  final ClaimMethod? method;

  /// The repeater was already this person's: nothing was proven or changed.
  final bool alreadyYours;
  const BatchRow({
    required this.key,
    this.name = '',
    this.state = BatchRowState.notStarted,
    this.message,
    this.title,
    this.method,
    this.alreadyYours = false,
  });

  String get label => name.isEmpty ? 'Repeater ${key.substring(0, 8)}' : name;

  /// A copy with [state] and the texts replaced as given. [message] and [title] are replaced even when null (a row's texts always
  /// belong to its current state).
  BatchRow withState(BatchRowState state, {String? message, String? title, ClaimMethod? method, bool? alreadyYours}) => BatchRow(
    key: key,
    name: name,
    state: state,
    message: message,
    title: title,
    method: method ?? this.method,
    alreadyYours: alreadyYours ?? this.alreadyYours,
  );
}

/// The words for a failed claim of a repeater by login. The server answers 409 when another owner holds the repeater and a
/// login may not take it over (the ladder in PLATFORM_CONTRACT.md: `recently_claimed`).
String batchFailureReason(ClaimFlowState st) {
  if (st.serverStatus == 409) {
    return 'Someone else claimed this repeater recently. An admin login can replace another login claim only after 24 hours, '
        'and never one proven by a signature or an advert.';
  }
  return st.message;
}

class RepeaterBatchController extends ChangeNotifier {
  final ClaimController claims;
  final bool Function() connected;
  RepeaterBatchController({required this.claims, required this.connected});

  final List<BatchRow> _rows = [];
  List<BatchRow> get rows => List.unmodifiable(_rows);

  /// The row being proven now, if any.
  String? _active;
  String? get activeKey => _active;
  bool get busy => _active != null;
  RepeaterClaimFlow? _flow;

  int get claimedCount => _rows.where((r) => r.state == BatchRowState.claimed).length;
  int get failedCount => _rows.where((r) => r.state == BatchRowState.failed).length;
  int get waitingCount => _rows.where((r) => r.state == BatchRowState.notStarted).length;

  BatchRow? row(String key) {
    for (final r in _rows) {
      if (r.key == key.toLowerCase()) return r;
    }
    return null;
  }

  /// Puts a repeater in the session. False when [key] is not 64 hex characters, or is already a row. A repeater this person
  /// already owns is added as claimed ("already yours") so the list stays one honest picture of the sitting.
  bool add(String key, {String name = ''}) {
    final k = normalizePublicKey(key);
    if (k == null || row(k) != null) return false;
    final mine = claims.claimFor(k);
    _rows.add(
      mine != null
          ? BatchRow(
              key: k,
              name: name.isEmpty ? mine.label : name,
              state: BatchRowState.claimed,
              method: mine.method,
              alreadyYours: true,
              message: 'Already yours.',
            )
          : BatchRow(key: k, name: name),
    );
    notifyListeners();
    return true;
  }

  /// Takes a row out (not while it is being proven).
  void remove(String key) {
    final k = key.toLowerCase();
    if (_active == k) return;
    _rows.removeWhere((r) => r.key == k);
    notifyListeners();
  }

  /// Drops the rows that are done (claimed), keeping the ones still to do or to retry.
  void clearClaimed() {
    _rows.removeWhere((r) => r.state == BatchRowState.claimed && r.key != _active);
    notifyListeners();
  }

  void _set(String key, BatchRow Function(BatchRow r) f) {
    final i = _rows.indexWhere((r) => r.key == key);
    if (i < 0) return;
    _rows[i] = f(_rows[i]);
    notifyListeners();
  }

  /// Proves [key] with [password] (the repeater's admin password; handed to the flow and nowhere else). One at a time: false
  /// when another row is being proven or there is nothing to prove. Never throws; the outcome is on the row.
  bool prove(String key, String password) {
    final k = key.toLowerCase();
    final r = row(k);
    if (r == null || password.isEmpty || busy) return false;
    if (r.state == BatchRowState.claimed) return false;
    if (!connected()) {
      _set(
        k,
        (x) => x.withState(
          BatchRowState.failed,
          title: claimOutcomeTitleWords(ClaimOutcome.noRadio),
          message:
              'Connect your radio first (More > Radio). It talks to the repeater for you, so it has to be within reach of the repeater.',
        ),
      );
      return true;
    }
    final flow = claims.startRepeaterClaim(pubkey: k, password: password, nodeName: r.name);
    if (flow == null) {
      _set(
        k,
        (x) => x.withState(
          BatchRowState.failed,
          title: claimOutcomeTitleWords(ClaimOutcome.noRadio),
          message: 'Connect your radio first (More > Radio).',
        ),
      );
      return true;
    }
    _active = k;
    _flow = flow;
    _set(k, (x) => x.withState(BatchRowState.proving, message: 'Starting…'));
    final sub = flow.states.listen((s) {
      if (!s.finished && s.message.isNotEmpty) {
        _set(k, (x) => x.withState(BatchRowState.proving, message: s.message));
      }
    }, onError: (Object _) {});
    unawaited(
      flow.done.then((s) {
        sub.cancel();
        _active = null;
        _flow = null;
        _finish(k, s);
        claims.clearFlows();
      }),
    );
    return true;
  }

  void _finish(String key, ClaimFlowState s) {
    switch (s.outcome) {
      case ClaimOutcome.verified:
        _set(key, (x) => x.withState(BatchRowState.claimed, method: s.claim?.method ?? ClaimMethod.login, message: 'Claimed.'));
      case ClaimOutcome.alreadyYours:
        _set(key, (x) => x.withState(BatchRowState.claimed, method: s.claim?.method, alreadyYours: true, message: 'Already yours.'));
      case ClaimOutcome.cancelled:
        _set(key, (x) => x.withState(BatchRowState.notStarted));
      default:
        _set(key, (x) => x.withState(BatchRowState.failed, title: claimOutcomeTitleWords(s.outcome), message: batchFailureReason(s)));
    }
  }

  /// Stops the repeater being proven now (the flow ends as cancelled and the row goes back to "not started").
  void cancel() => _flow?.cancel();
}

/// Short title of a claim outcome, in plain words (the same words Claim a repeater shows).
String claimOutcomeTitleWords(ClaimOutcome o) => switch (o) {
  ClaimOutcome.verified => 'The repeater is yours',
  ClaimOutcome.alreadyYours => 'Already yours',
  ClaimOutcome.cancelled => 'Cancelled',
  ClaimOutcome.noRadio => 'Connect your radio',
  ClaimOutcome.radioLost => 'The radio disconnected',
  ClaimOutcome.notAdmin => 'Not the admin password',
  ClaimOutcome.loginSilent => 'No answer from the repeater',
  ClaimOutcome.loginRefused => 'Login refused',
  ClaimOutcome.noContact => 'Your radio could not add the repeater',
  ClaimOutcome.nameUnreadable => 'Could not read the repeater\'s name',
  ClaimOutcome.setNameFailed => 'Could not set the repeater\'s name',
  ClaimOutcome.expired => 'The claim ran out',
  ClaimOutcome.serverRefused => 'The server said no',
  ClaimOutcome.serverUnavailable => 'Could not finish',
  ClaimOutcome.signFailed => 'The radio could not sign',
  ClaimOutcome.signatureRejected => 'The signature did not match',
  ClaimOutcome.none => '',
};
