// The slot manager on fake time: statuses, the 10-slot limit, the 120/min cap with drop-oldest, jittered backoff 1..30 s,
// auth failure and radio-can't-sign retries, token re-signing before expiry, background pause, radio loss, Keychain
// passwords, Test (status only) and the 24 h counter.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

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
}
