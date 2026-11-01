// Chat wiring against the simulated radio and an in-memory database.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';

import '../fakes.dart' show Harness;
import 'sim_chat_harness.dart';

void main() {
  late SimChatHarness h;

  setUp(() async {
    h = SimChatHarness();
    await h.state.init();
  });
  tearDown(() async {
    await ChatWiring.detach();
    await h.state.disconnect(quiet: true);
    h.chatStore.close();
  });

  test('attach publishes the controller and the Chat tab provider; offline the store is still readable', () async {
    final ctl = await ChatWiring.attach(h.state);
    expect(ctl, isNotNull);
    expect(ChatWiring.controller.value, same(ctl));
    expect(ChatTabHost.provider.value, isNotNull);
    expect(ctl!.radioConnected, isFalse);
    expect(ctl.radioId, isNull);
  });

  test('no chat store in the build (tests, null openChatStore): attach does nothing', () async {
    final plain = Harness();
    await plain.state.init();
    expect(await ChatWiring.attach(plain.state), isNull);
    expect(ChatWiring.controller.value, isNull);
  });

  test('connect: binds, reads the radio slots (Public appears), receives a channel message, sends one', () async {
    final ctl = (await ChatWiring.attach(h.state))!;
    expect(await h.state.connectSimulator(), isTrue);
    await until(() => ctl.radioId != null && ctl.store.channels.list(ctl.radioId!).isNotEmpty, what: 'Public channel row');
    final pub = ctl.store.channels.list(ctl.radioId!).single;
    expect(pub.name, 'Public');
    expect(pub.kind, ChannelKind.public);
    expect(pub.slot, 0);
    expect(ctl.radioConnected, isTrue);

    h.scanner.injectChannelMessage(0, 'Ann', 'hello from the mesh');
    await until(() => ctl.service.page(pub.convKey).messages.isNotEmpty, what: 'incoming message stored');
    expect(ctl.service.page(pub.convKey).messages.single.text, 'hello from the mesh');
    expect(ctl.unreadConversations, 1);
    expect(ChatTabHost.unread, 1);

    final r = ctl.send(pub.convKey, 'hi Ann');
    expect(r.ok, isTrue, reason: r.error);
    await until(() => h.scanner.lastTransport!.sentChannel.isNotEmpty, what: 'channel send reached the radio');
    expect(h.scanner.lastTransport!.sentChannel.single, (slot: 0, text: 'hi Ann'));
    await until(() => ctl.service.page(pub.convKey).messages.first.state != MessageState.queued, what: 'state moved on');
  });

  test('outbox resumes: a message written while the radio is away goes out after the reconnect', () async {
    final ctl = (await ChatWiring.attach(h.state))!;
    await h.state.connectSimulator();
    await until(() => ctl.store.channels.list(ctl.radioId ?? '').isNotEmpty, what: 'channel row');
    final pub = ctl.store.channels.list(ctl.radioId!).single;
    await h.state.disconnect(quiet: true);
    await until(() => !ctl.radioConnected, what: 'unbound');
    final r = ctl.send(pub.convKey, 'sent while away');
    expect(r.ok, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ctl.service.page(pub.convKey).messages.first.isPending, isTrue, reason: 'waits in the outbox');
    expect(await h.state.connectSimulator(), isTrue);
    await until(() => h.scanner.lastTransport!.sentChannel.any((e) => e.text == 'sent while away'), what: 'queued message delivered', timeout: const Duration(seconds: 20));
  });

  test('chat send never starved by pings: the user send is admitted at once, a ping right after is skipped (not delayed)', () async {
    final ctl = (await ChatWiring.attach(h.state))!;
    await h.state.connectSimulator();
    await until(() => ctl.store.channels.list(ctl.radioId ?? '').isNotEmpty, what: 'channel row');
    final pub = ctl.store.channels.list(ctl.radioId!).single;
    final arb = h.state.radioSessions.arbiter;
    expect(arb.snapshot().userSends, 0);
    ctl.send(pub.convKey, 'on air now');
    await until(() => arb.snapshot().userSends == 1, what: 'user send admitted');
    final t0 = DateTime.now();
    final d = await arb.requestPing();
    expect(DateTime.now().difference(t0).inMilliseconds, lessThan(500), reason: 'the answer is immediate: skipped, not queued');
    expect(d.go, isFalse);
    expect(d.reason, isNotNull);
    // two seconds later the ping may go again
    h.clockNow = h.clockNow.add(const Duration(seconds: 3));
    expect((await arb.requestPing(manual: true)).go, isTrue);
  });

  test('the arbiter says "paused by budget" only for budget skips, and clears when a ping goes out', () {
    var now = DateTime(2026, 11, 1, 12);
    final a = TxArbiter(clock: () => now, policy: const TxPolicy(pingBudgetFraction: 0.001));
    a.chatActive = true;
    a.airParams = () => const RadioAirParams(8, 62.5, 5);
    expect(a.pausedByBudget(), isFalse);
    a.pingSent();
    a.pingSent();
    return Future(() async {
      final d = await a.requestPing();
      expect(d.go, isFalse);
      expect(a.pausedByBudget(), isTrue);
      now = now.add(const Duration(minutes: 5));
      expect(a.pausedByBudget(), isFalse, reason: 'stale');
      a.pingSent();
      expect(a.lastSkipReason, isNull);
    });
  });

  test('passenger lock follows the drive: locked above walking pace, lifted per drive', () async {
    final ctl = (await ChatWiring.attach(h.state))!;
    final fast = DateTime.now();
    ctl.updateDrive(driving: true, sessionId: 's1', speedMps: 15, fixAt: fast);
    expect(ctl.composerLocked, isTrue);
    expect(ctl.send('c:1', 'x').error, contains('moving'));
    ctl.setPassenger(true);
    expect(ctl.composerLocked, isFalse);
    expect(ctl.isPassenger, isTrue);
    ctl.updateDrive(driving: true, sessionId: 's2', speedMps: 15, fixAt: fast);
    expect(ctl.composerLocked, isTrue, reason: 'new drive asks again');
    ctl.updateDrive(driving: false);
    expect(ctl.composerLocked, isFalse);
  });
}
