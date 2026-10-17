// AppState fixes from the 0.3.0 roadmap pass: orphaned drives closed at startup, empty drive removed after a failed
// start, server URL change drops the key, heard hold applied mid-drive, rename saved in the drive and re-sent,
// names typed under 0.2.x moved into the drives.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/onboarding/ui_prefs.dart';

import '../ui/fakes.dart';

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('startup closes a drive left open by a crash at its last ping, and uploads its end', () async {
    final h = Harness()..approveKey();
    final start = DateTime.utc(2026, 10, 16, 9);
    h.store.seed(DriveSession(id: 'crashed', startedAt: start), [
      heardPing('a', const [], ts: start.add(const Duration(minutes: 3))),
      heardPing('b', const [], ts: start.add(const Duration(minutes: 17))),
    ]);
    h.store.seed(DriveSession(id: 'empty-crash', startedAt: start.add(const Duration(hours: 1))), const []);
    final finished = DriveSession(id: 'fine', startedAt: start, endedAt: start.add(const Duration(hours: 2)));
    h.store.seed(finished, const []);

    await h.state.init();
    await settle();
    expect(h.store.sessionsById['crashed']!.endedAt, start.add(const Duration(minutes: 17)));
    expect(h.store.sessionsById['empty-crash']!.endedAt, start.add(const Duration(hours: 1)));
    expect(h.store.sessionsById['fine']!.endedAt, finished.endedAt);
    expect(h.sync.syncedSessions, containsAll(['crashed', 'empty-crash']));
    expect(h.sync.syncedSessions, isNot(contains('fine')));
    expect(h.state.sessions.every((x) => x.session.endedAt != null), isTrue);
  });

  test('startup closes orphans without uploading when there is no approved key', () async {
    final h = Harness();
    h.store.seed(DriveSession(id: 'crashed', startedAt: DateTime.utc(2026, 10, 16, 9)), const []);
    await h.state.init();
    await settle();
    expect(h.store.sessionsById['crashed']!.endedAt, isNotNull);
    expect(h.sync.syncedSessions, isEmpty);
  });

  test('a failed start with no pings leaves no empty drive behind', () async {
    final h = Harness()..engineStartError = StateError('channel full');
    await h.state.init();
    expect(await h.state.connectSimulator(), isTrue);
    await h.state.startDrive();
    expect(h.state.driving, isFalse);
    expect(h.store.sessionsById, isEmpty);
    expect(h.store.calls, containsAllInOrder(['start', 'delete']));
    expect(h.state.sessions, isEmpty);
    expect(h.state.takeNotice(), contains('Couldn\'t start the drive'));
  });

  test('a failed start that already recorded a ping keeps the drive, closed', () async {
    final h = Harness()
      ..engineStartError = StateError('radio went away')
      ..engineStartPings = [silentPing('first')];
    await h.state.init();
    expect(await h.state.connectSimulator(), isTrue);
    await h.state.startDrive();
    expect(h.state.driving, isFalse);
    expect(h.store.sessionsById, hasLength(1));
    final s = h.store.sessionsById.values.single;
    expect(s.endedAt, isNotNull);
    expect(h.store.pingsBySession[s.id]!.map((p) => p.id), ['first']);
    expect(h.store.calls, isNot(contains('delete')));
  });

  test('changing the server URL removes the key and its status; other changes keep it', () async {
    final h = Harness()..approveKey();
    await h.state.init();
    expect(h.state.keyApproved, isTrue);
    await h.state.updateSettings(h.state.settings.copyWith(intervalSec: 60));
    expect(h.state.settings.driverKey, isNotNull);
    await h.state.updateSettings(h.state.settings.copyWith(serverUrl: 'https://other.example'));
    expect(h.state.settings.serverUrl, 'https://other.example');
    expect(h.state.settings.driverKey, isNull);
    expect(h.state.settings.keyStatus, DriverKeyStatus.none);
    expect(h.state.settings.display, isNull);
    expect(h.state.hasKey, isFalse);
    expect(h.settings.saved.driverKey, isNull, reason: 'saved without the key');
    expect(h.client.baseUrl, Uri.parse('https://other.example'));

    // A key requested from the new server is kept.
    expect(await h.state.requestKey(name: 'Andy'), isTrue);
    expect(h.state.settings.driverKey, 'secretkey-abcdef-1234');
  });

  test('the heard-hold slider applies to the live heard list mid-drive', () async {
    final h = Harness()..settings.saved = const Settings(heardHoldPings: 5);
    await h.state.init();
    expect(h.state.heard.holdPings, 5);
    expect(await h.state.connectSimulator(), isTrue);
    await h.state.startDrive();
    final e = h.engines.last;
    e.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 5, hops: 1)]));
    e.emit(silentPing('p2'));
    e.emit(silentPing('p3'));
    await settle();
    expect(h.state.heard.live.map((x) => x.id), ['a1b2']);

    await h.state.updateSettings(h.state.settings.copyWith(heardHoldPings: 2));
    expect(h.state.heard.holdPings, 2);
    expect(h.state.heard.live, isEmpty, reason: 'stale at once, not at the next drive');
    expect(h.state.heard.repeaters.single.state, HeardState.stale);
    await h.state.stopDrive();
  });

  test('rename is saved in the drive and marked to upload; a live drive keeps the name at Stop', () async {
    final h = Harness();
    h.store.seed(DriveSession(id: 'd1', startedAt: DateTime.utc(2026, 10, 15, 14), endedAt: DateTime.utc(2026, 10, 15, 15)),
        [silentPing('x')],
        syncedFirst: 1);
    await h.state.init();
    expect(h.state.sessions.single.hasSomethingToSync, isFalse);
    expect(await h.state.renameSession('d1', ' Route 3 north '), isTrue);
    expect(h.store.sessionsById['d1']!.label, 'Route 3 north');
    expect(h.state.sessions.single.sessionResendPending, isTrue);
    expect(h.state.sessions.single.hasSomethingToSync, isTrue);
    expect(await h.state.renameSession('d1', ''), isTrue);
    expect(h.store.sessionsById['d1']!.label, isNull);
    expect(await h.state.renameSession('missing', 'x'), isFalse);

    expect(await h.state.connectSimulator(), isTrue);
    await h.state.startDrive();
    final sid = h.state.currentSession!.id;
    await h.state.renameSession(sid, 'Live one');
    expect(h.state.currentSession!.label, 'Live one');
    await h.state.stopDrive();
    expect(h.store.sessionsById[sid]!.label, 'Live one');
    expect(h.store.sessionsById[sid]!.endedAt, isNotNull);
  });

  test('names typed under 0.2.x (phone-only) move into the drives once', () async {
    final dir = await Directory.systemTemp.createTemp('meshsonar_prefs_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/ui_prefs.json')
      ..writeAsStringSync('{"onboarding_seen": true, "labels": {"d1": "Old name", "gone": "Deleted drive"}}');
    final h = Harness();
    h.store.seed(DriveSession(id: 'd1', startedAt: DateTime.utc(2026, 10, 15, 14)), const []);
    await h.state.init();
    final prefs = FileUiPrefs(file);
    attachUiPrefs(h.state, prefs);
    await prefs.load();
    await migrateLegacyLabels(h.state, prefs);
    expect(h.store.sessionsById['d1']!.label, 'Old name');
    expect(h.store.resend, contains('d1'));
    expect(prefs.labels, isEmpty);
    expect(driveLabel(h.state, 'd1', h.store.sessionsById['d1']!.label), 'Old name');
    final again = FileUiPrefs(file);
    await again.load();
    expect(again.labels, isEmpty, reason: 'the file no longer holds them');
  });

  test('openWebPage builds the URL from the server setting and says where to go if no browser opens', () async {
    final h = Harness()..settings.saved = const Settings(serverUrl: 'https://cmat.example/');
    await h.state.init();
    expect(h.state.webPage('/me'), 'https://cmat.example/me');
    expect(await h.state.openWebPage('/me/devices'), isTrue);
    expect(h.openedUrls.single, Uri.parse('https://cmat.example/me/devices'));
    h.browserWorks = false;
    expect(await h.state.openWebPage('/me/devices'), isFalse);
    expect(h.state.takeNotice(), contains('https://cmat.example/me/devices'));
  });
}
