// The background wake path with a fake radio: PUSH_MSG_WAITING -> MessageSync drain -> persist (SQLite) -> notification.
// Persist-first must hold: when a wake is cut short, whatever the radio already handed over is on disk.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_coordinator.dart';
import 'package:meshsonar/alerts/alert_prefs.dart';
import 'package:meshsonar/alerts/radio_queue_watch.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/session_adapter.dart';
import 'package:meshsonar/platform/local_notifications.dart';
import 'package:meshsonar/radio/message_sync.dart';
import 'package:meshsonar/radio/protocol.dart';

import '../chat/support.dart';
import 'fakes.dart';

class QueueRadio implements MessageSource {
  final queue = <Uint8List>[];
  bool connected = true;
  void Function(int remainingBeforePop)? onSync;
  @override
  bool get isConnected => connected;
  @override
  Future<Frame> syncNextMessage() async {
    onSync?.call(queue.length);
    return decodeFrame(queue.isEmpty ? encodeNoMoreMessages() : queue.removeAt(0));
  }
}

final key = List<int>.generate(32, (i) => i + 1);
const prefix = '010203040506';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late Harness h;
  late FakeLocalNotifications n;
  late AlertCoordinator c;
  late QueueRadio radio;
  late MessageSync sync;

  setUp(() async {
    h = Harness();
    h.store.contacts.upsert(Contact(
        radioId: radioA, publicKey: key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), type: ContactType.companion, name: 'Ann', outPathLen: -1));
    n = FakeLocalNotifications(state: NotificationPermission.granted);
    c = AlertCoordinator(notifications: n, prefs: AlertPrefs());
    await c.init();
    c.attachChat(h.service);
    c.setForeground(false); // the app is in the background: this is a wake
    radio = QueueRadio();
    sync = MessageSync(radio, pollInterval: const Duration(hours: 1));
    // exactly what RadioSessionChatAdapter.bind installs
    sync.persist = (m) async => h.service.handleInbound(RadioSessionChatAdapter.mapInbound(radioA, m));
    sync.messages.listen((_) {});
  });
  tearDown(() => sync.dispose());

  Uint8List msg(int ts, String text) => encodeContactText(key, text, txtType: txtTypePlain, timestamp: ts, pathLen: 0xFF, snrDb: 3);

  test('a wake with three waiting messages: all persisted, queue emptied, one notification per conversation', () async {
    radio.queue.addAll([msg(1, 'one'), msg(2, 'two'), msg(3, 'three')]);
    await sync.drain();
    await settle();
    expect(h.store.messages.count(), 3);
    expect(radio.queue, isEmpty);
    expect(n.shown, hasLength(3), reason: 'same conversation: the same slot is replaced, each message still alerted');
    expect(n.shown.map((e) => e.id).toSet(), hasLength(1));
    expect(n.shown.last.body, '3 new messages');
  });

  test('persist-first: before the radio is asked for the next message, the previous one is already in SQLite', () async {
    radio.queue.addAll([msg(1, 'one'), msg(2, 'two'), msg(3, 'three')]);
    final countsAtEachAsk = <int>[];
    radio.onSync = (_) => countsAtEachAsk.add(h.store.messages.count());
    await sync.drain();
    expect(countsAtEachAsk, [0, 1, 2, 3], reason: 'ask 1 sees 0 stored ... the final NO_MORE ask sees all 3');
  });

  test('the process dies while showing the notification: the messages are on disk anyway', () async {
    final failing = _ThrowingNotifications();
    final c2 = AlertCoordinator(notifications: failing, prefs: AlertPrefs());
    c2.attachChat(h.service);
    c2.setForeground(false);
    // Make this coordinator the only one relevant: drop the first so only the throwing one shows.
    c.dispose();
    radio.queue.addAll([msg(1, 'one'), msg(2, 'two')]);
    await sync.drain();
    await settle();
    expect(h.store.messages.count(), 2);
    expect(h.service.unreadBadge(), 1);
    c2.dispose();
  });

  test('the link drops mid-drain: every frame already popped is saved, the rest stays in the radio for the next drain', () async {
    radio.queue.addAll([msg(1, 'one'), msg(2, 'two'), msg(3, 'three')]);
    radio.onSync = (remaining) {
      if (remaining == 2) radio.connected = false; // the link goes while the second ask is in flight
    };
    await sync.drain();
    expect(h.store.messages.count(), 2, reason: 'the in-flight frame was still handed over and saved');
    expect(radio.queue, hasLength(1));
    radio.connected = true;
    radio.onSync = null;
    await sync.drain();
    expect(h.store.messages.count(), 3);
  });

  test('a drain reports how many frames it took (the queue watch input)', () async {
    final seen = <int>[];
    sync.onDrained = seen.add;
    radio.queue.addAll(List.generate(5, (i) => msg(i + 1, 't$i')));
    await sync.drain();
    expect(seen, [5]);
    await sync.drain(); // empty queue: no callback
    expect(seen, [5]);
    expect(sync.lastDrainFrames, 0);
  });

  test('queue watch: below 12 of 16 nothing; 12 warns; 16 says some may be lost; a normal drain does not clear it', () {
    final q = RadioQueueWatch();
    q.onDrained(11);
    expect(q.risk, QueueRisk.ok);
    expect(q.message, isNull);
    q.onDrained(12);
    expect(q.risk, QueueRisk.nearFull);
    expect(q.message, contains('12 waiting messages'));
    expect(q.message, contains('about 16'));
    q.onDrained(16);
    expect(q.risk, QueueRisk.overflowLikely);
    expect(q.message, contains('dropped'));
    q.onDrained(13);
    expect(q.risk, QueueRisk.overflowLikely, reason: 'a lesser warning does not downgrade');
    q.onDrained(2);
    expect(q.risk, QueueRisk.overflowLikely);
    q.dismiss();
    expect(q.risk, QueueRisk.ok);
  });

  test('queue watch honours a bigger queue (256)', () {
    final q = RadioQueueWatch(capacity: 256);
    q.onDrained(16);
    expect(q.risk, QueueRisk.ok);
    q.onDrained(192);
    expect(q.risk, QueueRisk.nearFull);
  });
}

class _ThrowingNotifications extends FakeLocalNotifications {
  _ThrowingNotifications() : super(state: NotificationPermission.granted);
  @override
  Future<void> show(AlertNotification n) async => throw StateError('process killed mid-notification');
}
