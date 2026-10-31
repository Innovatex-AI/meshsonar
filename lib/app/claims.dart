// App-side owner of radio claims: "My radios" (the server's list for this driver key), the running claim flow, and the
// name restores still owed to repeaters. A plain ChangeNotifier like AppState; AppState owns one (AppState.claims).
//
// Policy (Andy): a claim only MANAGES a radio. Nothing here is ever consulted before recording, uploading or counting a
// ping. The repeater admin password lives only inside a running flow (memory) and is dropped when the flow ends.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/claim_flow.dart';
import '../core/node_claim.dart';
import '../radio/claim_radio.dart';

class ClaimController extends ChangeNotifier {
  final CmatClient Function() client;
  final String? Function() driverKey;
  final ClaimRadio? Function() radio;
  final bool Function() enabled;
  final ClaimRestoreStore store;
  final DateTime Function() clock;
  final ClaimTiming timing;
  final Future<void> Function(Duration d)? wait;

  ClaimController({
    required this.client,
    required this.driverKey,
    required this.radio,
    required this.enabled,
    required this.store,
    DateTime Function()? clock,
    this.timing = const ClaimTiming(),
    this.wait,
  }) : clock = clock ?? DateTime.now;

  // ---------------------------------------------------------------- my radios

  List<NodeClaim> _claims = const [];
  List<NodeClaim> get claims => _claims;

  /// Radios this key manages now.
  List<NodeClaim> get active => [for (final c in _claims) if (!c.ended) c];

  /// Claims that ended in the last 90 days (released, replaced by another owner, removed by a moderator).
  List<NodeClaim> get past => [for (final c in _claims) if (c.ended) c];
  bool _loading = false;
  bool get loading => _loading;
  bool _loadedOnce = false;
  bool get loadedOnce => _loadedOnce;
  String? _error;

  /// Why the list could not be loaded, in words; null when it loaded.
  String? get error => _error;

  /// Whether this driver key has claimed [pubkey] (64 hex, any case). False until the list is known.
  bool owns(String pubkey) {
    final k = pubkey.toLowerCase();
    return _claims.any((c) => c.pubkey == k && !c.ended);
  }

  NodeClaim? claimFor(String pubkey) {
    final k = pubkey.toLowerCase();
    for (final c in _claims) {
      if (c.pubkey == k && !c.ended) return c;
    }
    return null;
  }

  Future<void>? _refreshing;

  /// Loads `my-radios`. Never throws; the reason is in [error]. Does nothing when the server has no claims or there is
  /// no approved key.
  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    await Future<void>.value(); // never notify during the caller's build (a screen asks from didChangeDependencies)
    final key = driverKey();
    if (!enabled() || key == null || key.isEmpty) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _claims = await client().myRadios(key);
      _loadedOnce = true;
    } on CmatException catch (e) {
      _error = e.status == 401 || e.status == 403 ? 'The server does not accept this key for radios yet.' : 'Could not load your radios (${e.message}).';
    } catch (e) {
      _error = 'Could not load your radios ($e).';
    }
    _loading = false;
    notifyListeners();
  }

  /// Gives up a claim. Its data stays and keeps counting. Throws [CmatException].
  Future<void> release(String pubkey) async {
    final key = driverKey();
    if (key == null) throw const CmatException('no driver key');
    await client().releaseClaim(key, pubkey);
    _claims = [for (final c in _claims) if (c.ended || c.pubkey != pubkey.toLowerCase()) c];
    notifyListeners();
  }

  /// Changes name / position visibility / notes (only the keys in [changes]; null clears). Throws [CmatException].
  Future<NodeClaim> update(String pubkey, Map<String, Object?> changes) async {
    final key = driverKey();
    if (key == null) throw const CmatException('no driver key');
    final c = await client().updateClaim(key, pubkey, changes);
    _claims = [for (final x in _claims) x.pubkey == c.pubkey ? c : x];
    notifyListeners();
    return c;
  }

  // ---------------------------------------------------------------- flows

  OwnRadioClaimFlow? _own;
  RepeaterClaimFlow? _repeater;
  OwnRadioClaimFlow? get ownFlow => _own;
  RepeaterClaimFlow? get repeaterFlow => _repeater;

  /// A repeater claim is running, or its name still has to be put back: the screen must stay open and say so.
  bool get repeaterBusy => _repeater != null && !_repeater!.state.finished;

  /// Starts "Claim my radio" on the connected radio. Null when there is no radio or no key.
  OwnRadioClaimFlow? startOwnRadioClaim() {
    final r = radio(), key = driverKey();
    if (r == null || key == null || key.isEmpty) return null;
    final f = OwnRadioClaimFlow(radio: r, client: client(), driverKey: key, now: clock, wait: wait);
    _own = f;
    unawaited(f.run().then((s) async {
      if (s.verified) await refresh();
      notifyListeners();
    }));
    f.states.listen((_) => notifyListeners(), onError: (Object _) {});
    notifyListeners();
    return f;
  }

  /// Starts "Claim a repeater". [password] stays in the flow's memory only. Null when there is no radio or key.
  RepeaterClaimFlow? startRepeaterClaim({required String pubkey, required String password, String nodeName = ''}) {
    final r = radio(), key = driverKey();
    if (r == null || key == null || key.isEmpty) return null;
    final f = RepeaterClaimFlow(radio: r, client: client(), driverKey: key, store: store, timing: timing, now: clock, wait: wait);
    _repeater = f;
    f.states.listen((_) => notifyListeners(), onError: (Object _) {});
    unawaited(f.run(pubkey: pubkey, password: password, nodeName: nodeName).then((s) async {
      if (s.verified) await refresh();
      await loadPending();
      notifyListeners();
    }));
    notifyListeners();
    return f;
  }

  /// Finishes a name restore left over from an earlier claim (app closed, radio lost).
  RepeaterClaimFlow? startRestore(PendingRestore pending, String password) {
    final r = radio(), key = driverKey();
    if (r == null || key == null) return null;
    final f = RepeaterClaimFlow(radio: r, client: client(), driverKey: key, store: store, timing: timing, now: clock, wait: wait);
    _repeater = f;
    f.states.listen((_) => notifyListeners(), onError: (Object _) {});
    unawaited(f.runRestoreOnly(pending: pending, password: password).then((_) async {
      await loadPending();
      notifyListeners();
    }));
    notifyListeners();
    return f;
  }

  /// Forget the finished flow (the screen was left).
  void clearFlows() {
    if (_repeater?.state.finished ?? true) _repeater = null;
    if (_own?.state.finished ?? true) _own = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- name restores still owed

  List<PendingRestore> _pending = const [];
  List<PendingRestore> get pending => _pending;

  Future<void> loadPending() async {
    try {
      _pending = await store.load();
    } catch (_) {
      _pending = const [];
    }
    notifyListeners();
  }

  /// The person gave up on a restore (they fixed the name themselves).
  Future<void> dismissPending(String pubkey) async {
    await store.remove(pubkey);
    await loadPending();
  }

  // ---------------------------------------------------------------- app events

  /// The companion link changed (connected, reconnected after a drop, or gone).
  void radioChanged() {
    final r = radio();
    if (r != null) _repeater?.attachRadio(r);
  }

  void appResumed() {
    _repeater?.appResumed();
    _own?.appResumed();
  }
}
