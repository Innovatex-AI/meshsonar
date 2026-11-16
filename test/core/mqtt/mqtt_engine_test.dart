// The slot manager on fake time: statuses, the 10-slot limit, the 120/min cap with drop-oldest, jittered backoff 1..30 s,
// auth failure and radio-can't-sign retries, token re-signing before expiry, background pause, radio loss, Keychain
// passwords, Test (status only) and the 24 h counter.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/core/mqtt/mqtt_engine.dart';
import 'package:meshsonar/core/mqtt/mqtt_transport.dart';
import 'package:meshsonar/core/mqtt_contract.dart';
import 'package:meshsonar/core/observer_engine.dart';
import 'package:meshsonar/radio/packet.dart';

import 'support.dart';

final _t0 = DateTime.utc(2026, 11, 15, 18);

class _Env {
  final FakeAsync a;
  final FakeNet net = FakeNet();
  final InMemorySecretStore secrets = InMemorySecretStore();
  final TestRadioSigner radio = TestRadioSigner();
  late final MqttObserverEngine engine;
  _Env(this.a, {int seed = 1}) {
    engine = MqttObserverEngine(
      secrets: secrets,
      clock: () => _t0.add(a.elapsed),
      transport: net.create,
      random: Random(seed),
      testLinger: Duration.zero,
    );
  }
  void settle([Duration d = const Duration(milliseconds: 1)]) {
    a.flushMicrotasks();
    a.elapse(d);
    a.flushMicrotasks();
  }

  List<String> labels() => engine.statuses.map((s) => s.state.label).toList();

  /// One distinct public packet.
  void feed(int i) {
    final p = rx(
      rawPacket(
        PayloadType.advert,
        payload: List<int>.generate(101, (k) => (k + i) & 0xff)
          ..[0] = i & 0xff
          ..[1] = i >> 8,
      ),
    );
    engine.onPublicPacket(filtered(p)!, p);
  }
}

void _run(void Function(_Env e) body, {int seed = 1}) => fakeAsync((a) {
  final e = _Env(a, seed: seed);
  body(e);
  unawaited(e.engine.dispose());
  a.flushMicrotasks();
});

void main() {
  test('states: Off, sharing off, Waiting for radio, no IATA, Radio can\'t sign, then Connected', () {
    _run((e) {
      e.engine.update(engineState(slots: [slot('s1', enabled: false)], sign: e.radio.sign));
      expect(e.labels(), ['Off']);
      e.engine.update(engineState(sharing: false, slots: [slot('s1')], sign: e.radio.sign));
      expect(e.labels(), ['Off']);
      expect(e.engine.statuses.single.lastError, 'Observer sharing is off.');
      e.engine.update(engineState(connected: false, slots: [slot('s1')], sign: e.radio.sign));
      expect(e.labels(), ['Waiting for radio']);
      e.engine.update(engineState(key: null, slots: [slot('s1')], sign: e.radio.sign));
      expect(e.labels(), ['Waiting for radio']);
      e.engine.update(engineState(region: 'swoh', slots: [slot('s1')], sign: e.radio.sign));
      expect(e.labels(), ['Error']);
      expect(e.engine.statuses.single.lastError, contains('airport code'));
      e.engine.update(engineState(slots: [slot('s1')]));
      expect(e.labels(), ["Radio can't sign"]);
      expect(e.net.connects, isEmpty);
      e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
      expect(e.labels(), ['Connecting']);
      e.settle();
      expect(e.labels(), ['Connected']);
      final c = e.net.connects.single;
      expect(c.url, 'wss://mqtt.example.org/');
      expect(c.port, 443);
      expect(c.keepAliveSec, 55);
      expect(c.username, 'v1_${rfcPublicHex.toUpperCase()}');
      expect(c.password!.split('.'), hasLength(3));
      expect(c.clientId.length, lessThanOrEqualTo(23));
      // Status on connect: QoS 1, unretained for a custom slot, on the region's IATA.
      final st = e.net.statuses().single;
      expect(st.topic, 'meshcore/CMH/${rfcPublicHex.toUpperCase()}/status');
      expect(st.qos, 1);
      expect(st.retain, isFalse);
      expect((jsonDecode(st.payload) as Map)['status'], 'online');
    });
  });

  test('a preset slot retains status; the slot IATA wins over the region; status repeats every 5 minutes', () {
    _run((e) {
      e.engine.update(
        engineState(
          slots: [slot('s1', presetId: 'corecomms', iata: 'day')],
          sign: e.radio.sign,
        ),
      );
      e.settle();
      expect(e.net.statuses().single.retain, isTrue);
      expect(e.net.statuses().single.topic, startsWith('meshcore/DAY/'));
      e.settle(const Duration(minutes: 5));
      expect(e.net.statuses(), hasLength(2));
    });
  });

  test('the same state twice changes nothing; a name change does not reconnect; a host change does', () {
    _run((e) {
      final st = engineState(slots: [slot('s1')], sign: e.radio.sign);
      e.engine.update(st);
      e.settle();
      e.engine.update(st);
      e.engine.update(
        engineState(
          slots: [slot('s1').copyWith(name: 'Renamed')],
          sign: e.radio.sign,
        ),
      );
      e.settle();
      expect(e.net.connects, hasLength(1));
      e.engine.update(
        engineState(
          slots: [slot('s1', host: 'other.example.org')],
          sign: e.radio.sign,
        ),
      );
      e.settle();
      expect(e.net.connects, hasLength(2));
      expect(e.net.live, hasLength(1));
      expect(e.net.connects.last.url, 'wss://other.example.org/');
    });
  });

  test('ten slots at most, one connection per enabled slot, unique client ids', () {
    _run((e) {
      e.engine.update(
        engineState(
          slots: [for (var i = 1; i <= 12; i++) slot('slot-$i', host: 'h$i.example.org')],
          sign: e.radio.sign,
        ),
      );
      e.settle();
      expect(e.engine.statuses, hasLength(10));
      expect(e.net.connects, hasLength(10));
      expect(e.net.connects.map((c) => c.clientId).toSet(), hasLength(10));
      // One signing per audience (10 hosts), serialised.
      expect(e.radio.calls, 10);
    });
  });

  test('cap: 120 per minute per slot, queue of 120 drops the oldest', () {
    _run((e) {
      e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
      e.settle();
      for (var i = 0; i < 300; i++) {
        e.feed(i);
      }
      final first = e.net.packets();
      expect(first, hasLength(120));
      expect(e.engine.dropped, 60);
      e.settle(const Duration(seconds: 59));
      expect(e.net.packets(), hasLength(120));
      e.settle(const Duration(seconds: 2));
      final all = e.net.packets();
      expect(all, hasLength(240));
      // Sent: packets 0..119, then the newest 120 (180..299); 120..179 were dropped.
      int idx(String payload) {
        final raw = (jsonDecode(payload) as Map)['raw'] as String;
        final b = hexBytes(raw.toLowerCase());
        return b[2] | (b[3] << 8); // header, path_len, then payload[0..1] = i
      }

      expect([for (final p in all) idx(p.payload)], [for (var i = 0; i < 120; i++) i, for (var i = 180; i < 300; i++) i]);
      expect(e.engine.statuses.single.sent24h, 240);
    });
  });

  test('backoff: jittered 1..30 s, doubling, reset after a success', () {
    _run((e) {
      e.net.answer = (_) => const MqttConnectResult(MqttConnectOutcome.failed, 'Could not connect to mqtt.example.org.');
      e.engine.update(engineState(slots: [slot('s1', auth: MqttAuth.none)]));
      e.settle();
      expect(e.labels(), ['Error']);
      expect(e.engine.statuses.single.lastError, 'Could not connect to mqtt.example.org.');
      final times = <Duration>[];
      var seen = e.net.connects.length;
      for (var step = 0; step < 40 * 1000 && times.length < 8; step++) {
        e.a.elapse(const Duration(milliseconds: 250));
        if (e.net.connects.length != seen) {
          seen = e.net.connects.length;
          times.add(e.a.elapsed);
        }
      }
      final gaps = <double>[];
      var prev = Duration.zero;
      for (final t in times) {
        gaps.add((t - prev).inMilliseconds / 1000);
        prev = t;
      }
      const bases = [1, 2, 4, 8, 16, 30, 30, 30];
      for (var i = 0; i < gaps.length; i++) {
        expect(gaps[i], greaterThanOrEqualTo(max(1.0, bases[i] * 0.5) - 0.3), reason: 'gap $i = ${gaps[i]}');
        expect(gaps[i], lessThanOrEqualTo(bases[i] + 0.3), reason: 'gap $i = ${gaps[i]}');
      }
      expect(gaps, hasLength(8));
      e.net.answer = (_) => const MqttConnectResult(MqttConnectOutcome.accepted);
      e.settle(const Duration(seconds: 31));
      expect(e.labels(), ['Connected']);
      for (var i = 0; i < 10; i++) {
        expect(e.engine.backoffDelay(i).inMilliseconds, inInclusiveRange(1000, 30000));
      }
    });
  });

  test('a dropped connection comes back within about a second', () {
    _run((e) {
      e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
      e.settle();
      e.net.dropAll();
      expect(e.labels(), ['Error']);
      expect(e.engine.statuses.single.lastError, 'Connection lost.');
      e.feed(1); // queued while down
      e.settle(const Duration(milliseconds: 1100));
      expect(e.labels(), ['Connected']);
      expect(e.net.connects, hasLength(2));
      expect(e.net.packets(), hasLength(1));
      expect(e.radio.calls, 1); // the cached token is reused
    });
  });

  test('auth failed: shows Auth failed, retries after 5 minutes with a freshly signed token', () {
    _run((e) {
      e.net.answer = (_) =>
          const MqttConnectResult(MqttConnectOutcome.authRejected, 'The site refused the login (not authorised).');
      e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
      e.settle();
      expect(e.labels(), ['Auth failed']);
      e.feed(1); // not queued while the login is refused
      e.settle(const Duration(minutes: 4, seconds: 59));
      expect(e.net.connects, hasLength(1));
      e.net.answer = (_) => const MqttConnectResult(MqttConnectOutcome.accepted);
      e.settle(const Duration(seconds: 2));
      expect(e.net.connects, hasLength(2));
      expect(e.radio.calls, 2);
      expect(e.net.connects[0].password, isNot(e.net.connects[1].password));
      expect(e.labels(), ['Connected']);
      expect(e.net.packets(), isEmpty);
    });
  });

  test("radio can't sign: stays off, retries after 10 minutes, and at once on a new radio session", () {
    _run((e) {
      e.radio.failWith = StateError('unsupported');
      e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
      e.settle();
      expect(e.labels(), ["Radio can't sign"]);
      expect(e.net.connects, isEmpty);
      e.settle(const Duration(minutes: 9));
      expect(e.radio.calls, 1);
      e.settle(const Duration(minutes: 1, seconds: 1));
      expect(e.radio.calls, 2);
      e.radio.failWith = null;
      final other = TestRadioSigner();
      e.engine.update(engineState(slots: [slot('s1')], sign: other.sign));
      e.settle();
      expect(other.calls, 1);
      expect(e.labels(), ['Connected']);
    });
  });

  test('token refresh: re-signed about 5 minutes before it ends, then a clean reconnect', () {
    _run((e) {
      e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
      e.settle();
      final first = e.net.connects.single.password!;
      e.settle(const Duration(minutes: 54));
      expect(e.net.connects, hasLength(1));
      e.settle(const Duration(minutes: 1, seconds: 1));
      expect(e.net.connects, hasLength(2));
      expect(e.radio.calls, 2);
      final second = e.net.connects.last.password!;
      expect(second, isNot(first));
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(second.split('.')[1])))) as Map;
      expect(payload['exp'] as int, greaterThan(_t0.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000));
      expect(e.net.live, hasLength(1));
      expect(e.labels(), ['Connected']);
    });
  });

  test('background: a live link keeps publishing; a drop behind is not retried until the app is in front', () {
    _run((e) {
      e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
      e.settle();
      e.engine.update(engineState(foreground: false, slots: [slot('s1')], sign: e.radio.sign));
      e.feed(1);
      expect(e.net.packets(), hasLength(1));
      e.net.dropAll();
      expect(e.labels(), ['Paused in background']);
      e.settle(const Duration(minutes: 2));
      expect(e.net.connects, hasLength(1));
      e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
      e.settle();
      expect(e.net.connects, hasLength(2));
      expect(e.labels(), ['Connected']);
    });
  });

  test('radio lost: the slot waits for the radio, its queue is gone, and it reconnects with the radio', () {
    _run((e) {
      e.net.connectDelay = const Duration(seconds: 1);
      e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
      e.settle();
      e.feed(1); // queued while connecting
      e.engine.update(engineState(connected: false, slots: [slot('s1')]));
      e.settle(const Duration(seconds: 2));
      expect(e.labels(), ['Waiting for radio']);
      expect(e.net.live, isEmpty);
      expect(e.net.packets(), isEmpty);
      e.net.connectDelay = Duration.zero;
      e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
      e.settle();
      expect(e.labels(), ['Connected']);
      expect(e.net.packets(), isEmpty); // nothing from before the radio dropped
      expect(e.radio.calls, 2); // no token outlives the radio link
    });
  });

  test('sharing off stops every feed', () {
    _run((e) {
      e.engine.update(
        engineState(
          slots: [
            slot('s1'),
            slot('s2', host: 'b.example.org'),
          ],
          sign: e.radio.sign,
        ),
      );
      e.settle();
      expect(e.net.live, hasLength(2));
      e.engine.update(
        engineState(
          sharing: false,
          slots: [
            slot('s1'),
            slot('s2', host: 'b.example.org'),
          ],
          sign: e.radio.sign,
        ),
      );
      e.settle();
      expect(e.net.live, isEmpty);
      e.feed(1);
      expect(e.net.packets(), isEmpty);
    });
  });

  test('password slots read the Keychain entry mqtt.<slotId>; missing password is Auth failed', () {
    _run((e) {
      final s = slot('slot-3', auth: MqttAuth.password, username: 'andy');
      e.engine.update(engineState(slots: [s]));
      e.settle();
      expect(e.labels(), ['Auth failed']);
      expect(e.engine.statuses.single.lastError, contains('No username and password'));
      unawaited(e.secrets.write('mqtt.slot-3', utf8.encode('s3cret')));
      e.settle(const Duration(minutes: 5, seconds: 1));
      expect(e.labels(), ['Connected']);
      expect(e.net.connects.single.username, 'andy');
      expect(e.net.connects.single.password, 's3cret');
      expect(e.radio.calls, 0);
    });
  });

  test('saving the password (any settings update) retries a no-password slot at once', () {
    _run((e) {
      final s = slot('slot-4', auth: MqttAuth.password, username: 'andy');
      e.engine.update(engineState(slots: [s]));
      e.settle();
      expect(e.labels(), ['Auth failed']);
      unawaited(e.secrets.write('mqtt.slot-4', utf8.encode('pw')));
      e.settle();
      e.engine.update(engineState(slots: [s]));
      e.settle();
      expect(e.labels(), ['Connected']);
      expect(e.net.connects.single.password, 'pw');
    });
  });

  test('anonymous slot sends no credentials; TLS off uses ws://', () {
    _run((e) {
      e.engine.update(
        engineState(
          slots: [
            MqttSlotSettings(
              id: 'x',
              name: 'Local',
              host: '127.0.0.1',
              port: 9001,
              wsPath: '/mqtt',
              tls: false,
              auth: MqttAuth.none,
              enabled: true,
            ),
          ],
        ),
      );
      e.settle();
      final c = e.net.connects.single;
      expect(c.username, isNull);
      expect(c.password, isNull);
      expect(c.url, 'ws://127.0.0.1/mqtt');
      expect(c.port, 9001);
    });
  });

  test('Test: connects once and publishes a status message only', () {
    _run((e) {
      e.engine.update(engineState(slots: const [], sign: e.radio.sign));
      ObserverFeedStatus? r;
      unawaited(e.engine.test(slot('s9')).then((v) => r = v));
      e.settle();
      expect(r!.state, ObserverFeedState.connected);
      expect(e.net.published, hasLength(1));
      expect(e.net.published.single.topic, endsWith('/status'));
      expect(e.net.published.single.retain, isFalse);
      expect(e.net.live, isEmpty);
      e.feed(1);
      expect(e.net.packets(), isEmpty);

      e.net.answer = (_) =>
          const MqttConnectResult(MqttConnectOutcome.authRejected, 'The site refused the login (bad username or password).');
      unawaited(e.engine.test(slot('s9')).then((v) => r = v));
      e.settle();
      expect(r!.state, ObserverFeedState.authFailed);

      e.engine.update(engineState(connected: false));
      unawaited(e.engine.test(slot('s9')).then((v) => r = v));
      e.settle();
      expect(r!.state, ObserverFeedState.waitingForRadio);
    });
  });

  test('statusChanges emits on state changes and sent counts; 24 h counter ages out', () {
    _run((e) {
      final log = StatusLog(e.engine);
      e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
      e.settle();
      e.feed(1);
      e.feed(2);
      e.settle(const Duration(seconds: 2));
      final states = log.seen.map((l) => l.single.state).toList();
      expect(states.first, ObserverFeedState.connecting);
      expect(states, contains(ObserverFeedState.connected));
      expect(log.seen.last.single.sent24h, 2);
      e.settle(const Duration(hours: 24, minutes: 2));
      expect(e.engine.statuses.single.sent24h, 0);
      unawaited(log.cancel());
    });
  });

  group('last will and offline status (WS-OUT 7)', () {
    for (final preset in [false, true]) {
      test('${preset ? 'preset' : 'custom'}: will, online and offline share one topic and one retain flag', () {
        _run((e) {
          final s1 = slot('s1', presetId: preset ? 'corecomms' : null);
          e.engine.update(engineState(slots: [s1], sign: e.radio.sign));
          e.settle();
          final online = e.net.statuses().single;
          final c = e.net.connects.single;
          expect(c.hasWill, isTrue);
          expect(c.willTopic, online.topic);
          expect(c.willRetain, online.retain);
          expect(online.retain, preset, reason: 'retained only for a preset that allows it');
          expect(c.willQos, 1);
          expect((jsonDecode(c.willMessage!) as Map)['status'], 'offline');
          expect((jsonDecode(c.willMessage!) as Map)['origin_id'], rfcPublicHex.toUpperCase());
          // Turned off: offline on the same topic and retain flag, then a clean disconnect.
          e.engine.update(engineState(slots: [s1.copyWith(enabled: false)], sign: e.radio.sign));
          e.settle();
          final offline = e.net.statuses().last;
          expect((jsonDecode(offline.payload) as Map)['status'], 'offline');
          expect(offline.topic, online.topic);
          expect(offline.retain, online.retain);
          expect(offline.qos, 1);
          expect(e.net.live, isEmpty);
        });
      });
    }

    test('a preset with retain off: online, offline and will are all unretained', () {
      _run((e) {
        final s1 = slot('s1', presetId: 'corecomms').copyWith(retainStatus: false);
        e.engine.update(engineState(slots: [s1], sign: e.radio.sign));
        e.settle();
        expect(e.net.statuses().single.retain, isFalse);
        expect(e.net.connects.single.willRetain, isFalse);
        e.engine.update(engineState(sharing: false, slots: [s1], sign: e.radio.sign));
        e.settle();
        expect(e.net.statuses().last.retain, isFalse);
      });
    });

    test('sharing off, radio lost and dispose each say offline; a dropped link leaves it to the will', () {
      _run((e) {
        e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
        e.settle();
        e.engine.update(engineState(sharing: false, slots: [slot('s1')], sign: e.radio.sign));
        e.settle();
        expect(e.net.statuses().map((p) => (jsonDecode(p.payload) as Map)['status']), ['online', 'offline']);
        e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
        e.settle();
        e.engine.update(engineState(connected: false, slots: [slot('s1')]));
        e.settle();
        expect((jsonDecode(e.net.statuses().last.payload) as Map)['status'], 'offline');
        e.engine.update(engineState(slots: [slot('s1')], sign: e.radio.sign));
        e.settle();
        final n = e.net.statuses().length;
        e.net.dropAll(); // the link is lost: the app cannot publish; the broker sends the will
        e.settle();
        expect(e.net.statuses(), hasLength(n));
      });
    });

    test('Test connects without a will and publishes no offline', () {
      _run((e) {
        e.engine.update(engineState(slots: const [], sign: e.radio.sign));
        unawaited(e.engine.test(slot('s9')));
        e.settle();
        expect(e.net.connects.single.hasWill, isFalse);
        expect(e.net.statuses().map((p) => (jsonDecode(p.payload) as Map)['status']), ['online']);
      });
    });
  });

  group('client id (WS-OUT 8)', () {
    test('per install: kept in the secure store, the same after a relaunch, different on another install', () async {
      final store = InMemorySecretStore();
      final a = MqttObserverEngine(secrets: store, clock: () => _t0, random: Random(7));
      final id = await a.installId();
      expect(id, matches(RegExp(r'^[0-9a-f]{4}$')));
      expect(await a.installId(), id, reason: 'stable within a run');
      expect(await store.read(MqttObserverEngine.installIdSlot), hasLength(2));
      await a.dispose();
      // A relaunch with a different random source still reads the stored value.
      final b = MqttObserverEngine(secrets: store, clock: () => _t0, random: Random(99));
      expect(await b.installId(), id);
      await b.dispose();
      // A fresh install (empty store) gets its own.
      final ids = <String>{};
      for (var seed = 0; seed < 8; seed++) {
        final c = MqttObserverEngine(secrets: InMemorySecretStore(), clock: () => _t0, random: Random(seed));
        ids.add(await c.installId());
        await c.dispose();
      }
      expect(ids.length, greaterThan(1));
    });

    test('a store that fails still gives a random id for this run', () async {
      final e = MqttObserverEngine(secrets: _BrokenStore(), clock: () => _t0, random: Random(3));
      expect(await e.installId(), matches(RegExp(r'^[0-9a-f]{4}$')));
      await e.dispose();
    });

    test('format: ms + 8 key hex + 6 slot hex + 4 install hex (20, Test 21), same across launches, <= 23', () {
      final ids = <String>[];
      final store = InMemorySecretStore();
      for (var launch = 0; launch < 2; launch++) {
        fakeAsync((a) {
          final net = FakeNet();
          final engine = MqttObserverEngine(
            secrets: store,
            clock: () => _t0.add(a.elapsed),
            transport: net.create,
            random: Random(launch + 40),
            testLinger: Duration.zero,
          );
          final radio = TestRadioSigner();
          engine.update(engineState(slots: [slot('s1')], sign: radio.sign));
          a.flushMicrotasks();
          a.elapse(const Duration(milliseconds: 1));
          a.flushMicrotasks();
          unawaited(engine.test(slot('s1')));
          a.flushMicrotasks();
          a.elapse(const Duration(milliseconds: 1));
          a.flushMicrotasks();
          ids.addAll(net.connects.map((c) => c.clientId));
          unawaited(engine.dispose());
          a.flushMicrotasks();
        });
      }
      expect(ids, hasLength(4));
      final live = ids[0], test = ids[1];
      expect(live, matches(RegExp('^ms${rfcPublicHex.substring(0, 8)}[0-9a-f]{6}[0-9a-f]{4}\$')));
      expect(live.length, 20);
      expect(test, '${live}t');
      for (final id in ids) {
        expect(id.length, lessThanOrEqualTo(23));
      }
      expect(ids[2], live, reason: 'the same client id after a relaunch');
      expect(ids[3], test);
    });
  });

  group("MeshSonar's own broker is never a feed (WS-OUT 9)", () {
    test('a saved slot pointing there never connects, shows Not allowed, and other slots still run', () {
      _run((e) {
        e.engine.update(
          engineState(
            slots: [
              slot('s1', host: 'MQTT.MeshSonar.com.', auth: MqttAuth.none),
              slot('s2', host: 'mqtt.meshsonar.com', presetId: 'x'),
              slot('s3', host: 'mqtt.example.org', auth: MqttAuth.none),
            ],
            sign: e.radio.sign,
          ),
        );
        e.settle();
        expect(e.labels(), ['Not allowed', 'Not allowed', 'Connected']);
        expect(e.engine.statuses.first.lastError, meshSonarBrokerRefusal);
        expect(e.net.connects.map((c) => c.host), ['mqtt.example.org']);
        e.feed(1);
        expect(e.net.packets().map((p) => p.clientId).toSet(), hasLength(1));
        // Even when off, it says it is not allowed.
        e.engine.update(engineState(slots: [slot('s1', host: 'mqtt.meshsonar.com', enabled: false)], sign: e.radio.sign));
        e.settle();
        expect(e.labels(), ['Not allowed']);
        expect(e.net.connects, hasLength(1));
      });
    });

    test('Test refuses it without connecting', () {
      _run((e) {
        e.engine.update(engineState(slots: const [], sign: e.radio.sign));
        ObserverFeedStatus? r;
        unawaited(e.engine.test(slot('s9', host: 'mqtt.meshsonar.com')).then((v) => r = v));
        e.settle();
        expect(r!.state, ObserverFeedState.notAllowed);
        expect(r!.lastError, meshSonarBrokerRefusal);
        expect(e.net.connects, isEmpty);
      });
    });
  });
}

class _BrokenStore implements SecretStore {
  @override
  Future<Uint8List?> read(String ref) async => throw StateError('locked');
  @override
  Future<void> write(String ref, Uint8List secret) async => throw StateError('locked');
  @override
  Future<void> delete(String ref) async {}
}
