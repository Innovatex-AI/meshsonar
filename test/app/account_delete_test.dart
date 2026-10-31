// "Delete my account" in the app (App Store guideline 5.1.1(v)): AppState.deleteAccountOnServer. The key and the server's
// copy go together or not at all: a failure changes nothing and queues nothing; success forgets the key, turns the
// automatic key off (no new anonymous key at once), clears what belonged to the key, and keeps the local drives unless
// the person chose to delete them too.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/account_delete_hook.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';

import '../ui/fakes.dart';

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _can = SiteConfig(region: _region, capabilities: {'driverDelete', 'driveContextErase'});
const _cannot = SiteConfig(region: _region, capabilities: {'driveContextErase'});
final t0 = DateTime.utc(2026, 10, 16, 18);

Future<Harness> open({SiteConfig? caps = _can, bool drives = true}) async {
  final h = Harness();
  h.approveKey();
  h.settings.autoKeyOn = true; // a key-less phone would make a new anonymous key at once if autoKey stayed on
  h.settings.saved = h.settings.saved.copyWith(contextErasePending: {'all'});
  (h.state.client as FakeCmatClient).siteConfigResult = caps;
  (h.state.client as FakeCmatClient).eraseError = const CmatException('network error: offline'); // the remembered erase cannot finish
  if (drives) {
    for (final id in ['d1', 'd2']) {
      h.store.seed(DriveSession(id: id, startedAt: t0, endedAt: t0.add(const Duration(minutes: 5))),
          [DrivePing(id: '$id-p1', ts: t0, lat: 40.1, lon: -82.9)]);
    }
  }
  await h.state.init();
  await h.state.refreshUploadSiteConfig(force: true);
  return h;
}

FakeCmatClient fake(Harness h) => h.state.client as FakeCmatClient;

void main() {
  test('capability: only a server that advertises driverDelete counts; unknown counts as no', () async {
    expect((await open()).state.serverCanDeleteAccount, isTrue);
    expect((await open(caps: _cannot)).state.serverCanDeleteAccount, isFalse);
    expect((await open(caps: null)).state.serverCanDeleteAccount, isFalse);
  });

  test('success: the server is asked with this key, then the key, auto key, pending erase and caches are gone; drives stay', () async {
    final h = await open();
    final key = h.state.settings.driverKey!;
    final o = await h.state.deleteAccountOnServer();
    expect(o.status, AccountDeleteStatus.done);
    expect(o.message, contains('3 drives'));
    expect(o.message, contains('120 pings'));
    expect(fake(h).deletedDrivers, [key]);
    expect(h.state.hasKey, isFalse);
    expect(h.state.settings.autoKey, isFalse);
    expect(h.state.settings.keyStatus, DriverKeyStatus.none);
    expect(h.state.settings.contextErasePending, isEmpty, reason: 'a remembered erase for a key that no longer exists is dropped');
    expect(h.settings.saved.driverKey, isNull, reason: 'saved to disk, not only in memory');
    expect(h.settings.saved.autoKey, isFalse);
    expect(h.store.sessionsById.keys, unorderedEquals(['d1', 'd2']), reason: 'local drives are kept by default');
    expect(await h.state.storedDriverSummary(), isNull);
  });

  test('no new anonymous key is created afterwards, not even by the foreground / launch hooks', () async {
    final h = await open();
    await h.state.deleteAccountOnServer();
    expect(await h.state.ensureKey(), isFalse);
    expect(fake(h).requestCalls, 0);
    expect(h.state.hasKey, isFalse);
  });

  test('alsoDeleteLocalDrives removes the drives on this phone too', () async {
    final h = await open();
    final o = await h.state.deleteAccountOnServer(alsoDeleteLocalDrives: true);
    expect(o.removed, isTrue);
    expect(h.store.sessionsById, isEmpty);
  });

  test('a failed local-drive choice never happens on a failed server delete: drives stay when the server refused', () async {
    final h = await open();
    fake(h).driverDeleteError = const CmatException('boom', status: 500);
    final o = await h.state.deleteAccountOnServer(alsoDeleteLocalDrives: true);
    expect(o.status, AccountDeleteStatus.failed);
    expect(h.store.sessionsById.keys, unorderedEquals(['d1', 'd2']));
  });

  test('offline: says it needs a connection, changes nothing, queues nothing', () async {
    final h = await open();
    fake(h).driverDeleteError = const CmatException('network error: offline');
    final o = await h.state.deleteAccountOnServer();
    expect(o.status, AccountDeleteStatus.offline);
    expect(o.message, contains('needs an internet connection'));
    expect(o.message, contains('nothing is waiting'));
    expect(h.state.hasKey, isTrue);
    expect(h.state.settings.autoKey, isTrue);
    expect(h.state.settings.contextErasePending, {'all'}, reason: 'unrelated state untouched');
    // retry works once there is signal
    fake(h).driverDeleteError = null;
    expect((await h.state.deleteAccountOnServer()).status, AccountDeleteStatus.done);
    expect(h.state.hasKey, isFalse);
  });

  test('429, 500 and an unreadable answer keep everything and say so plainly', () async {
    for (final e in [
      const CmatException('slow', status: 429),
      const CmatException('down', status: 503),
      const CmatException('server sent an unreadable answer', status: 200),
    ]) {
      final h = await open();
      fake(h).driverDeleteError = e;
      final o = await h.state.deleteAccountOnServer();
      expect(o.removed, isFalse, reason: '${e.status}');
      expect(o.message, isNotEmpty);
      expect(h.state.hasKey, isTrue, reason: '${e.status}');
      expect(h.state.settings.autoKey, isTrue);
      expect(fake(h).deletedDrivers, isEmpty);
    }
    final h = await open();
    fake(h).driverDeleteError = const CmatException('slow', status: 429);
    expect((await h.state.deleteAccountOnServer()).status, AccountDeleteStatus.rateLimited);
  });

  test('401 (the server no longer has the key): treated as already deleted, the dead key leaves this phone', () async {
    final h = await open();
    fake(h).driverDeleteError = const CmatException('x-driver-key required', status: 401);
    final o = await h.state.deleteAccountOnServer();
    expect(o.status, AccountDeleteStatus.alreadyGone);
    expect(o.removed, isTrue);
    expect(h.state.hasKey, isFalse);
    expect(h.state.settings.autoKey, isFalse);
  });

  test('a repeat after success has no key: noKey, and the server is not called again', () async {
    final h = await open();
    await h.state.deleteAccountOnServer();
    final again = await h.state.deleteAccountOnServer();
    expect(again.status, AccountDeleteStatus.noKey);
    expect(fake(h).deletedDrivers, hasLength(1));
  });

  test('404 / 405 (an older server): unavailable, key kept, the website hand-off stays', () async {
    final h = await open();
    fake(h).driverDeleteError = const CmatException('not found', status: 404);
    final o = await h.state.deleteAccountOnServer();
    expect(o.status, AccountDeleteStatus.unavailable);
    expect(h.state.hasKey, isTrue);
  });

  test('the recording drive is never deleted with the account', () async {
    final h = await open();
    await h.state.deleteAccountOnServer(alsoDeleteLocalDrives: true);
    expect(h.state.currentSession, isNull);
  });
}
