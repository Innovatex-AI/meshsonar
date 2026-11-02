// CommandQueue: the radio takes one command at a time (MeshCore docs/companion_protocol.md "Command Sequencing"; the
// firmware has single-slot pending state for login / status / binary requests, MyMesh.cpp 1577-1650). Extracted from
// MeshCoreCompanionLink, which used a Future chain; this one adds priorities.
//
// A job is any async function. Jobs run strictly one after another; the next job is picked by priority (lower number
// first), FIFO within one priority. A running job is never interrupted: a ping that is on the air finishes, but a user
// message queued behind it goes before any other queued ping. A job that throws does not stop the queue.
import 'dart:async';

/// The transmit priority classes of design doc B section 8. Lower is more urgent.
abstract final class CommandPriority {
  /// P0 a message the user sent.
  static const int user = 0;

  /// P1 maintenance that answers or manages a conversation: message sync, ACK-bearing and admin commands (login, CLI,
  /// status, trace), contact and channel reads/writes.
  static const int admin = 1;

  /// P2 self advert.
  static const int advert = 2;

  /// P3 wardrive ping and the health reads around it.
  static const int ping = 3;

  /// P4 discovery requests.
  static const int discovery = 4;

  /// P5 background refresh (auto-refresh of a repeater dashboard). Never queued behind anything: the remote request
  /// queue drops it when a request is running or waiting.
  static const int background = 5;

  /// What a command gets when nobody says otherwise: a ping's class, so an unmarked caller (the wardrive engine, which
  /// does not know about priorities) never jumps ahead of a user message.
  static const int normal = ping;
}

class CommandQueue {
  final List<_Job> _jobs = [];
  bool _running = false;
  bool _closed = false;
  int _seq = 0;

  /// Jobs waiting (not counting the one running).
  int get pending => _jobs.length;

  /// A job is running now.
  bool get busy => _running;

  /// Runs [job] when it is its turn. Completes with the job's result or error. After [close], completes with a
  /// StateError.
  Future<T> run<T>(Future<T> Function() job, {int priority = CommandPriority.normal}) {
    if (_closed) return Future<T>.error(StateError('command queue closed'));
    final c = Completer<T>();
    _jobs.add(_Job(priority, _seq++, () async {
      try {
        c.complete(await job());
      } catch (e, st) {
        c.completeError(e, st);
      }
    }, (Object e) {
      if (!c.isCompleted) c.completeError(e);
    }));
    if (!_running) {
      // Start on a later microtask, like the Future chain this replaces: the caller finishes its own synchronous work
      // (setting up a waiter, for example) before the command goes out.
      _running = true;
      scheduleMicrotask(_pump);
    }
    return c.future;
  }

  Future<void> _pump() async {
    while (_jobs.isNotEmpty) {
      var best = 0;
      for (var i = 1; i < _jobs.length; i++) {
        final a = _jobs[i], b = _jobs[best];
        if (a.priority < b.priority || (a.priority == b.priority && a.seq < b.seq)) best = i;
      }
      final next = _jobs.removeAt(best);
      await next.run();
    }
    _running = false;
  }

  /// Fails every waiting job with [reason]; later [run] calls fail too. The running job is left to finish.
  void close(Object reason) {
    _closed = true;
    final waiting = List<_Job>.of(_jobs);
    _jobs.clear();
    for (final j in waiting) {
      j.fail(reason);
    }
  }
}

class _Job {
  final int priority;
  final int seq;
  final Future<void> Function() run;
  final void Function(Object) fail;
  _Job(this.priority, this.seq, this.run, this.fail);
}
