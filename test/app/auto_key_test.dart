// One-tap onboarding: a phone with no driver key creates one by itself (no form), once, quietly, and never after the
// person removed their key.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/build_flags.dart';
import 'package:meshsonar/core/api.dart';

import '../ui/fakes.dart';

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('production guard', () {
    test('a release build always may; a dev build may not on production hosts unless told', () {
      expect(mayAutoCreateDriverKey('https://meshsonar.com', devBuild: false, allowProd: false), isTrue);
      expect(mayAutoCreateDriverKey('https://meshsonar.com', devBuild: true, allowProd: false), isFalse);
      expect(mayAutoCreateDriverKey('https://cmh.meshsonar.com/', devBuild: true, allowProd: false), isFalse);
      expect(mayAutoCreateDriverKey('https://MESHSONAR.com', devBuild: true, allowProd: false), isFalse);
      expect(mayAutoCreateDriverKey('https://meshsonar.com', devBuild: true, allowProd: true), isTrue);
      expect(mayAutoCreateDriverKey('http://localhost:3000', devBuild: true, allowProd: false), isTrue);
      expect(mayAutoCreateDriverKey('https://notmeshsonar.com', devBuild: true, allowProd: false), isTrue);
    });

    test('with the guard closed, launch makes no key request at all', () async {
      final h = Harness()..mayAutoCreateKey = (_) => false;
      h.settings.autoKeyOn = true;
      await h.state.init();
      await settle();
      expect(h.client.requestCalls, 0);
      expect(h.state.hasKey, isFalse);
      expect(await h.state.ensureKey(), isFalse);
      expect(h.client.requestCalls, 0);
    });
  });

  test('launch with no key creates one with the generic name and keeps it', () async {
    final h = Harness();
    h.settings.autoKeyOn = true;
    h.client.requestResult =
        const KeyRequestResult(driverId: 'd1', key: 'ms_autokey0123456789abcdef', status: DriverKeyStatus.approved, display: 'Driver 7');
    await h.state.init();
    await settle();
    expect(h.client.requestCalls, 1);
    expect(h.client.lastRequest, {'name': 'MeshSonar driver', 'callsign': null, 'email': null});
    expect(h.state.keyApproved, isTrue);
    expect(h.settings.saved.driverKey, 'ms_autokey0123456789abcdef');
    expect(h.state.keyError, isNull);
  });

  test('an existing key is never replaced; a second call does nothing', () async {
    final h = Harness()..approveKey();
    h.settings.autoKeyOn = true;
    await h.state.init();
    await settle();
    expect(await h.state.ensureKey(), isTrue);
    expect(h.client.requestCalls, 0);
  });

  test('offline at launch: no error banner, a pause before the next try, then it succeeds', () async {
    final h = Harness();
    h.settings.autoKeyOn = true;
    h.client.requestError = Exception('offline');
    await h.state.init();
    await settle();
    expect(h.client.requestCalls, 1);
    expect(h.state.hasKey, isFalse);
    expect(h.state.keyError, isNull, reason: 'an unasked failure is not a banner');
    expect(await h.state.ensureKey(), isFalse, reason: 'inside the pause');
    expect(h.client.requestCalls, 1);
    h.client.requestError = null;
    h.client.requestResult =
        const KeyRequestResult(driverId: 'd1', key: 'ms_later0123456789abcdef', status: DriverKeyStatus.approved, display: 'Driver 8');
    // A server change resets the pause (and a new server gets its own key).
    await h.state.updateSettings(h.state.settings.copyWith(serverUrl: 'https://other.example'));
    await settle();
    expect(h.state.hasKey, isTrue);
  });

  test('removing the key turns the automatic key off for good; the form turns it back on', () async {
    final h = Harness()..approveKey();
    h.settings.autoKeyOn = true;
    await h.state.init();
    await h.state.forgetKey();
    expect(h.state.hasKey, isFalse);
    expect(h.state.settings.autoKey, isFalse);
    expect(await h.state.ensureKey(), isFalse);
    expect(h.client.requestCalls, 0);
    // A saved autoKey=false survives a relaunch.
    expect(h.settings.saved.autoKey, isFalse);
    expect(await h.state.requestKey(name: ''), isTrue);
    expect(h.client.lastRequest!['name'], 'MeshSonar driver', reason: 'a blank name uses the generic one');
    expect(h.state.settings.autoKey, isTrue);
  });

  test('a server that holds keys for approval gives a pending key, not an error', () async {
    final h = Harness();
    h.settings.autoKeyOn = true; // default fake result is pending
    await h.state.init();
    await settle();
    expect(h.state.hasKey, isTrue);
    expect(h.state.settings.keyStatus, DriverKeyStatus.pending);
  });
}
