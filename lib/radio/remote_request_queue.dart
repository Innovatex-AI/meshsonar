// RemoteRequestQueue: every request that goes to ANOTHER node through our radio (login, status, telemetry, neighbours, access
// list, path discovery, trace, anonymous request, CLI text) passes through here, one at a time.
//
// Why: the firmware keeps ONE pending slot for login / status / binary requests (MyMesh.cpp ~1577-1650) and has a 4-frame
// BLE push queue. A second request while one is out overwrites the first's slot, and a flood of LOG_RX_DATA pushes during a
// request overflows the push queue and loses the answer. Plan: meshsonar-infra/docs/planning/chat-redesign-plan-2026-11-02.md
// section 5.2.
//
// Rules:
//  - Strictly one request in flight. The next one starts only when the previous one is done, timed out (noReply), refused,
//    failed, or cancelled AND its job has returned or timed out (a cancelled job keeps the slot until it returns, so the
//    firmware slot is never double booked).
//  - Order: lower [CommandPriority] number first, FIFO within a class. A running request is never interrupted. User
//    requests (CommandPriority.user / admin) go ahead of anything queued; [CommandPriority.background] (auto refresh) is
//    DROPPED, not queued, when anything is running or waiting (or auto refresh is switched off, e.g. while driving).
//  - Silence is its own result: [RemoteNoReply] (not `failed`), and it releases the slot. A login is never retried by the
//    queue (the person chooses direct vs flood); idempotent reads may get [RemoteRequest.autoRetries].
//  - While a request is in flight the Rx log (PUSH_LOG_RX_DATA 0x88) is paused through [onRxPause]; it resumes when the
//    queue is empty again.
//  - Replies are matched by the 6-byte public key prefix (login, status, path discovery) or the 4-byte tag (binary, trace);
//    pushes that match nothing are ignored and counted ([unmatchedPushes]).
// Pure Dart (no Flutter): the UI wraps [requests] in a ValueListenableBuilder-like widget.
import 'dart:async';

import 'command_queue.dart' show CommandPriority;
import 'protocol.dart' show SentFrame;

enum RemoteKind { login, status, telemetry, neighbours, acl, ownerInfo, anon, cli, pathDiscovery, trace, contact }

enum RemoteState {
  queued,

  /// The command is going to the radio (waiting for SENT or ERR).
  sending,

  /// The radio took it (SENT); waiting for the remote node's answer.
  waitingForReply,
  done,

  /// Silence: no answer in time. For a login this is also what a wrong password looks like on most firmware.
  noReply,

  /// The radio or the remote node said no (wrong password push 0x86, ERR from the radio, refused before sending).
  refused,
  cancelled,

  /// Auto refresh that was not queued because the radio was busy.
  dropped,

  /// Anything else that went wrong (link lost, bug).
  failed,
}

/// Thrown by a job (or the queue's own deadline) for "nobody answered".
class RemoteNoReply implements Exception {
  final String message;
  const RemoteNoReply([this.message = 'No reply']);
  @override
  String toString() => 'RemoteNoReply($message)';
}

/// Thrown by a job that was told no (not the same as silence).
class RemoteRefused implements Exception {
  final String message;
  const RemoteRefused([this.message = 'Refused']);
  @override
  String toString() => 'RemoteRefused($message)';
}

/// Thrown by [RemoteRequestQueue.submit] when the request was cancelled or dropped.
class RemoteRequestAborted implements Exception {
  final RemoteState state;
  const RemoteRequestAborted(this.state);
  @override
  String toString() => 'RemoteRequestAborted(${state.name})';
}

sealed class RemoteResult<T> {
  const RemoteResult();
}

class RemoteDone<T> extends RemoteResult<T> {
  final T value;
  const RemoteDone(this.value);
}

class RemoteNoReplyResult<T> extends RemoteResult<T> {
  final Object? cause;
  const RemoteNoReplyResult([this.cause]);
}

class RemoteRefusedResult<T> extends RemoteResult<T> {
  final Object cause;
  const RemoteRefusedResult(this.cause);
}

class RemoteCancelledResult<T> extends RemoteResult<T> {
  const RemoteCancelledResult();
}

class RemoteDroppedResult<T> extends RemoteResult<T> {
  const RemoteDroppedResult();
}

class RemoteFailedResult<T> extends RemoteResult<T> {
  final Object error;
  final StackTrace stack;
  const RemoteFailedResult(this.error, this.stack);
}

/// Deadlines of an enforced request. Defaults are the plan's: ack 5 s; reply = est_timeout x 1.25 + 3 s, at least 8 s, at
/// most 45 s for flood and 20 s direct.
class RemoteTimeouts {
  final Duration ack;
  final Duration floor;
  final Duration floodCeiling;
  final Duration directCeiling;
  final Duration margin;
  final double factor;
  const RemoteTimeouts({
    this.ack = const Duration(seconds: 5),
    this.floor = const Duration(seconds: 8),
    this.floodCeiling = const Duration(seconds: 45),
    this.directCeiling = const Duration(seconds: 20),
    this.margin = const Duration(seconds: 3),
    this.factor = 1.25,
  });

  Duration replyFor(int estTimeoutMs, {required bool flood}) {
    final raw = Duration(milliseconds: (estTimeoutMs * factor).round()) + margin;
    final ceil = flood ? floodCeiling : directCeiling;
    if (raw < floor) return floor;
    if (raw > ceil) return ceil;
    return raw;
  }
}

/// What a running job sees of its own request.
class RemoteContext {
  final RemoteRequest _r;
  final RemoteRequestQueue _q;
  RemoteContext._(this._r, this._q);

  bool get isCancelled => _r.state == RemoteState.cancelled;
  RemoteRequest get request => _r;

  /// The radio took the command (RESP SENT). Moves to waitingForReply, records est_timeout and re-arms the reply deadline
  /// of an enforced request.
  void reportSent(int estTimeoutMs, {bool flood = false}) => _q._sentFor(_r, estTimeoutMs, flood);

  /// Same, from the SENT frame.
  void reportSentFrame(SentFrame f) => reportSent(f.estTimeoutMs, flood: f.flood);

  /// Say which push answers this request: the 6-byte key prefix (login, status, path discovery) and/or the 4-byte tag
  /// (binary, trace). [reply] completes when [RemoteRequestQueue.offerPush] matches.
  void expect({String? prefixHex, int? tag}) {
    _r._prefix = prefixHex?.toLowerCase();
    _r._tag = tag;
  }

  Future<Object?> get reply => _r._reply.future;
}

class RemoteRequest<T> {
  final int id;
  final RemoteKind kind;

  /// The remote node's public key (64 hex) or a label.
  final String target;
  final int priority;
  final DateTime createdAt;

  /// Retries the queue may do after silence. Always 0 for a login.
  final int autoRetries;

  /// When true the queue itself times the request out (ack, then reply deadline from est_timeout). Jobs that carry their own
  /// timeouts (the repeater admin session) leave this false.
  final bool enforceDeadline;

  RemoteState _state = RemoteState.queued;
  Duration? _estTimeout;
  bool? _flood;
  int _attempt = 0;
  String? _prefix;
  int? _tag;
  final Completer<Object?> _reply = Completer<Object?>();
  final Completer<RemoteResult<T>> _result = Completer<RemoteResult<T>>();
  final Future<T> Function(RemoteContext) _run;
  final bool Function(Object) _isNoReply;
  final bool Function(Object) _isRefused;

  RemoteRequest._(this.id, this.kind, this.target, this.priority, this.createdAt, this.autoRetries, this.enforceDeadline, this._run, this._isNoReply,
      this._isRefused) {
    _reply.future.then<void>((_) {}, onError: (_) {});
  }

  void _end(RemoteState s, RemoteResult<T> res) {
    if (isFinished) return;
    _state = s;
    if (!_result.isCompleted) _result.complete(res);
    if (!_reply.isCompleted) _reply.completeError(const RemoteRequestAborted(RemoteState.cancelled));
  }

  void _endDone(Object? v) => _end(RemoteState.done, RemoteDone<T>(v as T));
  void _endNoReply(Object? cause) => _end(RemoteState.noReply, RemoteNoReplyResult<T>(cause));
  void _endRefused(Object cause) => _end(RemoteState.refused, RemoteRefusedResult<T>(cause));
  void _endFailed(Object e, StackTrace st) => _end(RemoteState.failed, RemoteFailedResult<T>(e, st));
  void _endCancelled() => _end(RemoteState.cancelled, RemoteCancelledResult<T>());
  void _endDropped() => _end(RemoteState.dropped, RemoteDroppedResult<T>());

  RemoteState get state => _state;

  /// The radio's est_timeout from SENT, once known.
  Duration? get estTimeout => _estTimeout;
  bool? get flood => _flood;
  int get attempt => _attempt;
  bool get isFinished => _state.index >= RemoteState.done.index;
  Future<RemoteResult<T>> get result => _result.future;
  int? get tag => _tag;
  String? get prefixHex => _prefix;

  @override
  String toString() => 'RemoteRequest#$id(${kind.name}, ${_state.name})';
}

/// A tiny observable list (no Flutter): same shape as ValueListenable.
class RemoteRequestList {
  List<RemoteRequest> _value = const [];
  final List<void Function()> _listeners = [];
  final _stream = StreamController<List<RemoteRequest>>.broadcast();

  List<RemoteRequest> get value => _value;
  Stream<List<RemoteRequest>> get changes => _stream.stream;
  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);

  void _set(List<RemoteRequest> v) {
    _value = List.unmodifiable(v);
    for (final l in List.of(_listeners)) {
      l();
    }
    if (!_stream.isClosed) _stream.add(_value);
  }

  void _close() => unawaited(_stream.close());
}

class RemoteRequestQueue {
  final RemoteTimeouts timeouts;
  final DateTime Function() _clock;

  /// Called with true when the first request starts and with false when the queue is empty again: the owner pauses and
  /// resumes the link's Rx log handling.
  final void Function(bool paused)? onRxPause;

  RemoteRequestQueue({this.timeouts = const RemoteTimeouts(), DateTime Function()? clock, this.onRxPause}) : _clock = clock ?? DateTime.now;

  final List<RemoteRequest> _waiting = [];
  RemoteRequest? _current;
  bool _pumping = false;
  bool _closed = false;
  bool _rxPaused = false;
  int _seq = 0;
  int _unmatched = 0;
  Timer? _deadline;
  Completer<void>? _deadlineHit;

  /// Auto refresh may enter the queue. Switch off while driving (plan D7); user taps still run.
  bool autoRefreshEnabled = true;

  /// The current request first, then the waiting ones in run order. For the queue strip and sheet.
  final RemoteRequestList requests = RemoteRequestList();

  /// Pushes that matched nothing in flight (counted for the Rx log).
  int get unmatchedPushes => _unmatched;
  bool get busy => _current != null;
  int get waiting => _waiting.length;
  bool get rxPaused => _rxPaused;
  RemoteRequest? get current => _current;

  void _publish() {
    final order = List<RemoteRequest>.of(_waiting)..sort(_cmp);
    requests._set([?_current, ...order]);
  }

  static int _cmp(RemoteRequest a, RemoteRequest b) => a.priority != b.priority ? a.priority.compareTo(b.priority) : a.id.compareTo(b.id);

  void _setRx(bool paused) {
    if (_rxPaused == paused) return;
    _rxPaused = paused;
    onRxPause?.call(paused);
  }

  /// Adds a request. The returned handle's [RemoteRequest.result] always completes (never throws). A background request
  /// that finds the queue busy comes back already dropped.
  RemoteRequest<T> enqueue<T>({
    required RemoteKind kind,
    required String target,
    required Future<T> Function(RemoteContext ctx) run,
    int priority = CommandPriority.admin,
    int autoRetries = 0,
    bool enforceDeadline = false,
    bool Function(Object error)? isNoReply,
    bool Function(Object error)? isRefused,
  }) {
    final r = RemoteRequest<T>._(
      ++_seq,
      kind,
      target,
      priority,
      _clock(),
      kind == RemoteKind.login ? 0 : autoRetries,
      enforceDeadline,
      run,
      (e) => e is RemoteNoReply || e is TimeoutException || (isNoReply?.call(e) ?? false),
      (e) => e is RemoteRefused || (isRefused?.call(e) ?? false),
    );
    if (_closed) {
      r._endCancelled();
      return r;
    }
    if (priority >= CommandPriority.background && (_current != null || _waiting.isNotEmpty || !autoRefreshEnabled)) {
      r._endDropped();
      return r;
    }
    _waiting.add(r);
    _publish();
    _startPump();
    return r;
  }

  /// Like [enqueue] but gives the job's value, or throws what the job threw (noReply / refused / failed keep their original
  /// error) or [RemoteRequestAborted] for cancelled / dropped.
  Future<T> submit<T>({
    required RemoteKind kind,
    required String target,
    required Future<T> Function(RemoteContext ctx) run,
    int priority = CommandPriority.admin,
    int autoRetries = 0,
    bool enforceDeadline = false,
    bool Function(Object error)? isNoReply,
    bool Function(Object error)? isRefused,
  }) async {
    final r = enqueue<T>(
        kind: kind,
        target: target,
        run: run,
        priority: priority,
        autoRetries: autoRetries,
        enforceDeadline: enforceDeadline,
        isNoReply: isNoReply,
        isRefused: isRefused);
    final res = await r.result;
    switch (res) {
      case RemoteDone<T>():
        return res.value;
      case RemoteNoReplyResult<T>():
        throw res.cause ?? const RemoteNoReply();
      case RemoteRefusedResult<T>():
        throw res.cause;
      case RemoteFailedResult<T>():
        Error.throwWithStackTrace(res.error, res.stack);
      case RemoteCancelledResult<T>():
        throw const RemoteRequestAborted(RemoteState.cancelled);
      case RemoteDroppedResult<T>():
        throw const RemoteRequestAborted(RemoteState.dropped);
    }
  }

  /// Cancels a waiting request (it never runs) or a running one (its result is `cancelled` now; the slot stays taken until
  /// its job returns, so the firmware's single slot is not double booked). Returns false if it was already finished.
  bool cancel(int id) {
    for (final r in _waiting) {
      if (r.id == id) {
        _waiting.remove(r);
        r._endCancelled();
        _publish();
        _maybeResume();
        return true;
      }
    }
    final c = _current;
    if (c != null && c.id == id && !c.isFinished) {
      c._endCancelled();
      _publish();
      return true;
    }
    return false;
  }

  /// The link saw a SENT frame for a remote command: it belongs to the request in flight.
  void reportSentForCurrent(SentFrame f) {
    final c = _current;
    if (c != null) _sentFor(c, f.estTimeoutMs, f.flood);
  }

  void _sentFor(RemoteRequest r, int estMs, bool flood) {
    if (r.isFinished || !identical(r, _current)) return;
    r._estTimeout = Duration(milliseconds: estMs);
    r._flood = flood;
    r._state = RemoteState.waitingForReply;
    if (r.enforceDeadline) _arm(timeouts.replyFor(estMs, flood: flood));
    _publish();
  }

  /// Offers an incoming push to the request in flight. Matches when the key prefix (case-insensitive, either may be the
  /// longer) or the tag equals what the request expects. Returns whether it matched; otherwise it is counted and ignored.
  bool offerPush({String? prefixHex, int? tag, Object? payload}) {
    final c = _current;
    if (c != null && !c.isFinished && !c._reply.isCompleted) {
      final byTag = tag != null && c._tag != null && c._tag == tag;
      final p = prefixHex?.toLowerCase();
      final e = c._prefix;
      final byPrefix = p != null && e != null && (p.startsWith(e) || e.startsWith(p));
      // A request that expects a tag matches by tag only; a prefix-only request matches by prefix only.
      final ok = c._tag != null ? byTag : byPrefix;
      if (ok) {
        c._reply.complete(payload);
        return true;
      }
    }
    _unmatched++;
    return false;
  }

  void _arm(Duration d) {
    _deadline?.cancel();
    _deadline = Timer(d, () => _deadlineHit?.complete());
  }

  void _startPump() {
    if (_pumping) return;
    _pumping = true;
    scheduleMicrotask(_pump);
  }

  Future<void> _pump() async {
    while (_waiting.isNotEmpty && !_closed) {
      _waiting.sort(_cmp);
      final r = _waiting.removeAt(0);
      _current = r;
      _setRx(true);
      await _execute(r);
      _deadline?.cancel();
      _deadline = null;
      _current = null;
      _publish();
    }
    _pumping = false;
    _maybeResume();
  }

  void _maybeResume() {
    if (_current == null && _waiting.isEmpty && !_pumping) _setRx(false);
  }

  Future<void> _execute(RemoteRequest r) async {
    for (;;) {
      r._attempt++;
      if (r.isFinished) return; // cancelled while waiting its turn (cannot happen) or between retries
      r._state = RemoteState.sending;
      _publish();
      final hit = _deadlineHit = Completer<void>();
      if (r.enforceDeadline) _arm(timeouts.ack);
      final ctx = RemoteContext._(r, this);
      final job = Future<Object?>.sync(() => r._run(ctx)).then<_Outcome>((v) => _Outcome.value(v), onError: (Object e, StackTrace st) => _Outcome.error(e, st));
      final first = await Future.any<Object>([job, hit.future.then<Object>((_) => _timedOut)]);
      _deadline?.cancel();
      if (identical(first, _timedOut)) {
        // The deadline expired: silence. The slot is released; a late job result is ignored.
        if (!r.isFinished) {
          if (r.attempt <= r.autoRetries && r.kind != RemoteKind.login) continue;
          r._endNoReply(null);
        }
        return;
      }
      final out = first as _Outcome;
      if (r.isFinished) return; // cancelled while running: the job has now returned, the slot is free
      if (out.error == null) {
        r._endDone(out.value);
        return;
      }
      final e = out.error!;
      if (r._isNoReply(e)) {
        if (r.attempt <= r.autoRetries && r.kind != RemoteKind.login) continue;
        r._endNoReply(e);
      } else if (r._isRefused(e)) {
        r._endRefused(e);
      } else {
        r._endFailed(e, out.stack!);
      }
      return;
    }
  }

  static final Object _timedOut = Object();

  /// Cancels everything waiting and refuses new requests. A running job keeps the slot until it returns.
  void close() {
    _closed = true;
    for (final r in List.of(_waiting)) {
      _waiting.remove(r);
      r._endCancelled();
    }
    final c = _current;
    if (c != null) c._endCancelled();
    _publish();
    _deadline?.cancel();
    _setRx(false);
    requests._close();
  }
}

class _Outcome {
  final Object? value;
  final Object? error;
  final StackTrace? stack;
  _Outcome.value(this.value)
      : error = null,
        stack = null;
  _Outcome.error(this.error, this.stack) : value = null;
}
