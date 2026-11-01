// Observer feedback for the Drive screen: states, counts, and the words the last-ping line uses.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/ping_feedback.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';

class _Client extends CmatClient {
  List<PingObservation> answer = [];
  Object? error;
  int calls = 0;
  String? lastSession;
  @override
  Future<List<PingObservation>> driveStatus(String driverKey, String sessionId) async {
    calls++;
    lastSession = sessionId;
    if (error != null) throw error!;
    return answer;
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

DrivePing ping(String id, int echoes) => DrivePing(
    id: id,
    ts: DateTime.utc(2026, 11, 1),
    lat: 40,
    lon: -83,
    kind: PingKind.tx,
    echoes: [for (var i = 0; i < echoes; i++) Echo(repeater: 'a$i', hops: 1)]);

void main() {
  final now = DateTime.utc(2026, 11, 1, 12);

  test('PingObservation reads the server shape (observers as a count or a list, via as names or {id,name})', () {
    final a = PingObservation.tryParse({'id': 'p1', 'status': 1, 'settled': true, 'observers': 3, 'lowConfidence': false, 'via': ['A', 'B']})!;
    expect(a.observers, 3);
    expect(a.settled, isTrue);
    expect(a.via, ['A', 'B']);
    final b = PingObservation.tryParse({'id': 'p2', 'observers': [1, 2], 'via': [{'id': 'x', 'name': 'N'}]})!;
    expect(b.observers, 2);
    expect(b.via, ['N']);
    expect(PingObservation.tryParse({'status': 1}), isNull);
    expect(PingObservation.tryParse('nope'), isNull);
  });

  test('waiting -> live: counts only pings with an observer; a second answer updates them', () async {
    final c = _Client();
    final f = PingFeedback();
    expect(f.state, ObserverFeedbackState.waiting);
    c.answer = [const PingObservation(id: 'p1', observers: 2, via: ['Hilltop']), const PingObservation(id: 'p2', observers: 0)];
    expect(await f.poll(c, 'k', 's1', now), isTrue);
    expect(c.lastSession, 's1');
    expect(f.state, ObserverFeedbackState.live);
    expect(f.confirmedPings, 1);
    expect(f.answeredPings, 2);
    expect(f.observerNames, {'Hilltop'});
    c.answer = [const PingObservation(id: 'p1', observers: 2, via: ['Hilltop']), const PingObservation(id: 'p2', observers: 1, via: ['Mast'])];
    expect(await f.poll(c, 'k', 's1', now), isTrue);
    expect(f.confirmedPings, 2);
    expect(await f.poll(c, 'k', 's1', now), isFalse, reason: 'nothing new, nothing to repaint');
  });

  test('an unknown session (nothing uploaded yet) stays waiting; a refused key or an old server turns it off for good', () async {
    final c = _Client()..error = const CmatException('unknown session', status: 404);
    final f = PingFeedback();
    expect(await f.poll(c, 'k', 's', now), isFalse);
    expect(f.state, ObserverFeedbackState.waiting);
    c.error = const CmatException('not supported by this client');
    expect(await f.poll(c, 'k', 's', now), isTrue);
    expect(f.state, ObserverFeedbackState.unavailable);
    final calls = c.calls;
    expect(await f.poll(c, 'k', 's', now), isFalse);
    expect(c.calls, calls, reason: 'an unavailable server is not asked again');

    final g = PingFeedback();
    c.error = const CmatException('forbidden', status: 403);
    await g.poll(c, 'k', 's', now);
    expect(g.state, ObserverFeedbackState.unavailable);
  });

  test('a network failure is quiet and retried', () async {
    final c = _Client()..error = const CmatException('offline');
    final f = PingFeedback();
    expect(await f.poll(c, 'k', 's', now), isFalse);
    expect(f.state, ObserverFeedbackState.waiting);
    expect(f.lastProblem, 'offline');
  });

  test('the last-ping line says what is known and what is not', () {
    final f = PingFeedback();
    expect(lastPingSummary(null, f), isNull);
    expect(lastPingSummary(ping('a', 3), f), 'Last ping: heard by 3 repeaters, observers confirm after the next upload');
    expect(lastPingSummary(ping('a', 1), f), startsWith('Last ping: heard by 1 repeater,'));
    expect(lastPingSummary(ping('a', 0), f), startsWith('Last ping: no repeater heard it'));
    f.state = ObserverFeedbackState.unavailable;
    expect(lastPingSummary(ping('a', 2), f), 'Last ping: heard by 2 repeaters');
    f.state = ObserverFeedbackState.live;
    f.markNoKey();
    expect(f.state, ObserverFeedbackState.noKey);
    f.reset();
    expect(f.state, ObserverFeedbackState.waiting);
  });

  test('observer wording per ping: confirmed, still reporting, none reported', () async {
    final f = PingFeedback();
    final c = _Client()
      ..answer = [const PingObservation(id: 'a', observers: 4), const PingObservation(id: 'b', settled: true), const PingObservation(id: 'c')];
    await f.poll(c, 'k', 's', now);
    expect(lastPingSummary(ping('a', 2), f), 'Last ping: heard by 2 repeaters, 4 observers confirmed');
    expect(lastPingSummary(ping('b', 0), f), 'Last ping: no repeater heard it, no observer reported it');
    expect(lastPingSummary(ping('c', 1), f), 'Last ping: heard by 1 repeater, observers still reporting');
  });
}
