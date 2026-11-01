import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_prefs.dart';
import 'package:meshsonar/alerts/ble_lifecycle_log.dart';
import 'package:meshsonar/alerts/last_radio_store.dart';
import 'package:meshsonar/alerts/launch_reconnect.dart';
import 'package:meshsonar/radio/radio_api.dart';

class Rig {
  final store = MemoryLastRadioStore(const LastRadio('uuid-1', 'Radio One'));
  final waits = <Duration>[];
  final tried = <String>[];
  final results = <bool>[];
  bool connected = false;
  bool blocked = false;
  final log = BleLifecycleLog(clock: () => DateTime(2026, 11, 1, 12));
  late final LaunchReconnect lr = LaunchReconnect(
    store: store,
    connect: (RadioDevice d) async {
      tried.add(d.id);
      final ok = results.isEmpty ? false : results.removeAt(0);
      if (ok) connected = true;
      return ok;
    },
    isConnected: () => connected,
    blocked: () => blocked,
    log: log,
    wait: (d) async => waits.add(d),
  );
}

void main() {
  test('connects to the remembered radio on the first try, after the one second wait', () async {
    final r = Rig()..results.add(true);
    final states = <LaunchReconnectState>[];
    r.lr.addListener(() => states.add(r.lr.state));
    await r.lr.run();
    expect(r.tried, ['uuid-1']);
    expect(r.waits.single, const Duration(seconds: 1));
    expect(r.lr.state, LaunchReconnectState.connected);
    expect(states, containsAllInOrder([LaunchReconnectState.waiting, LaunchReconnectState.connecting, LaunchReconnectState.connected]));
  });

  test('status text names the radio while trying, and says what to check when it gave up', () async {
    final r = Rig();
    final texts = <String?>[];
    r.lr.addListener(() => texts.add(r.lr.statusText));
    await r.lr.run();
    expect(texts, contains('Reconnecting to Radio One…'));
    expect(r.lr.state, LaunchReconnectState.gaveUp);
    expect(r.lr.statusText, contains('Could not reach Radio One'));
    expect(r.tried, hasLength(8));
    expect(r.waits.map((d) => d.inSeconds), [1, 3, 6, 10, 15, 20, 30, 30], reason: 'about two minutes in all');
  });

  test('succeeds on a later try', () async {
    final r = Rig()..results.addAll([false, false, true]);
    await r.lr.run();
    expect(r.tried, hasLength(3));
    expect(r.lr.state, LaunchReconnectState.connected);
  });

  test('nothing remembered -> does nothing', () async {
    final r = Rig();
    r.store.value = null;
    await r.lr.run();
    expect(r.tried, isEmpty);
    expect(r.lr.state, LaunchReconnectState.idle);
  });

  test('radio released on purpose (store cleared) -> no automatic reconnect', () async {
    final r = Rig();
    await r.store.clear();
    await r.lr.run(reason: 'foreground');
    expect(r.tried, isEmpty);
  });

  test('already connected, or blocked (driving / manual connect running) -> does not try', () async {
    final a = Rig()..connected = true;
    await a.lr.run();
    expect(a.tried, isEmpty);
    final b = Rig()..blocked = true;
    await b.lr.run();
    expect(b.tried, isEmpty);
  });

  test('someone connects while it waits -> it stops without a second connect', () async {
    final r = Rig();
    final lr = LaunchReconnect(
      store: r.store,
      connect: (d) async {
        r.tried.add(d.id);
        return true;
      },
      isConnected: () => r.connected,
      wait: (d) async => r.connected = true, // the person connected by hand during the wait
    );
    await lr.run();
    expect(r.tried, isEmpty);
    expect(lr.state, LaunchReconnectState.connected);
  });

  test('cancel (the person disconnected) stops the loop', () async {
    final r = Rig();
    late LaunchReconnect lr;
    var waits = 0;
    lr = LaunchReconnect(
      store: r.store,
      connect: (d) async => false,
      isConnected: () => false,
      wait: (d) async {
        if (++waits == 2) lr.cancel();
      },
    );
    await lr.run();
    expect(waits, 2);
    expect(lr.state, LaunchReconnectState.idle);
  });

  test('a throwing connect counts as a failed try', () async {
    final r = Rig();
    final lr = LaunchReconnect(
      store: r.store,
      connect: (d) async => throw StateError('boom'),
      isConnected: () => false,
      wait: (d) async {},
      maxAttempts: 2,
    );
    await lr.run();
    expect(lr.state, LaunchReconnectState.gaveUp);
  });

  test('coming back to the front retries after it had given up; concurrent runs join', () async {
    final r = Rig();
    await r.lr.run();
    expect(r.lr.state, LaunchReconnectState.gaveUp);
    r.results.add(true);
    await r.lr.onForeground();
    expect(r.lr.state, LaunchReconnectState.connected);
    // connected: foreground does nothing
    final before = r.tried.length;
    await r.lr.onForeground();
    expect(r.tried.length, before);
  });

  test('the attempts are written to the lifecycle log', () async {
    final r = Rig()..results.add(true);
    await r.lr.run();
    expect(r.log.entries.map((e) => e.detail), containsAll(['start (launch) radio="Radio One"', 'try 1', 'connected after 1 try']));
  });

  group('lifecycle log survives a restart', () {
    test('lines written before the "kill" are read back after it', () async {
      final dir = await Directory.systemTemp.createTemp('blelog');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/ble.log');
      final a = BleLifecycleLog(file: f, clock: () => DateTime(2026, 11, 1, 9, 30, 5));
      a.add('lifecycle', 'paused');
      a.setForeground(false);
      a.add('inbound', 'message persisted');
      final b = BleLifecycleLog(file: f, clock: () => DateTime(2026, 11, 1, 9, 40));
      await b.load();
      b.add('launch', 'process started');
      expect(b.entries.map((e) => e.kind), ['lifecycle', 'inbound', 'launch']);
      expect(b.entries[1].foreground, isFalse);
      expect(b.entries[0].line, '2026-11-01 09:30:05 fg lifecycle paused');
      expect(b.export(header: 'H').split('\n').first, 'H');
    });
  });

  group('prefs', () {
    test('defaults: on, sound on, text hidden, quiet hours off; survive a restart', () async {
      final dir = await Directory.systemTemp.createTemp('alertprefs');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/p.json');
      final a = AlertPrefs(f);
      expect(a.enabled && a.sound && !a.showText && !a.quiet.enabled && !a.asked && !a.iosWakeKeeper, isTrue);
      await a.setShowText(true);
      await a.setQuiet(const QuietHours(enabled: true, startMinute: 60, endMinute: 120));
      await a.markAsked();
      await a.setIosWakeKeeper(true);
      final b = AlertPrefs(f);
      await b.load();
      expect(b.showText && b.asked && b.iosWakeKeeper, isTrue);
      expect(b.quiet.enabled, isTrue);
      expect(b.quiet.startMinute, 60);
    });

    test('a damaged file falls back to defaults', () async {
      final dir = await Directory.systemTemp.createTemp('alertprefs');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/p.json')..writeAsStringSync('{not json');
      final a = AlertPrefs(f);
      await a.load();
      expect(a.enabled, isTrue);
      expect(a.showText, isFalse);
    });

    test('quiet hours window maths, same-day and across midnight', () {
      const day = QuietHours(enabled: true, startMinute: 13 * 60, endMinute: 15 * 60);
      expect(day.contains(DateTime(2026, 1, 1, 14)), isTrue);
      expect(day.contains(DateTime(2026, 1, 1, 15)), isFalse);
      expect(const QuietHours(startMinute: 0, endMinute: 1439).contains(DateTime(2026, 1, 1, 5)), isFalse, reason: 'disabled');
    });
  });

  group('last radio file', () {
    test('round trip and clear', () async {
      final dir = await Directory.systemTemp.createTemp('lastradio');
      addTearDown(() => dir.delete(recursive: true));
      final s = FileLastRadioStore(File('${dir.path}/l.json'));
      expect(await s.load(), isNull);
      await s.save(const LastRadio('id9', 'Mine', publicKeyHex: 'ab'));
      final l = await s.load();
      expect(l!.id, 'id9');
      expect(l.name, 'Mine');
      expect(l.publicKeyHex, 'ab');
      await s.clear();
      expect(await s.load(), isNull);
    });
  });
}
