// PhotoController: the button state from photo-config and the key, the cached config, own ids, delete (404 = done), report,
// the auto-load setting; and the on-disk picture cache (200 kept, 410 remembered, offline = failed).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/app/photo_controller.dart';
import 'package:meshsonar/chat/photo_prefs.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/core/photo_cache.dart';

import '../support/photo_fakes.dart';

void main() {
  late ChatStore store;
  setUp(() => store = ChatStore.inMemory());
  tearDown(() => store.close());

  group('button', () {
    test('hidden until photo-config says enabled; ready with an approved key', () async {
      final t = FakePhotoTransport()..config = PhotoConfig.disabled;
      final p = fakePhotos(store, transport: t);
      expect(p.button, PhotoButton.hidden);
      await p.refreshConfig(force: true);
      expect(p.button, PhotoButton.hidden);
      t.config = const PhotoConfig(enabled: true);
      await p.refreshConfig(force: true);
      expect(p.button, PhotoButton.ready);
    });

    test('no key, or a key not approved: the button explains', () async {
      final a = fakePhotos(store, key: null);
      await a.refreshConfig(force: true);
      expect(a.button, PhotoButton.needsKey);
      final b = fakePhotos(store, approved: false);
      await b.refreshConfig(force: true);
      expect(b.button, PhotoButton.needsKey);
    });

    test('unreachable hides the button even with an old cached yes', () async {
      saveCachedPhotoConfig(store, const PhotoConfig(enabled: true), 0);
      final t = FakePhotoTransport()..configError = const PhotoError(PhotoErrorKind.network);
      final p = fakePhotos(store, transport: t);
      expect(p.button, PhotoButton.ready, reason: 'cached answer first');
      await p.refreshConfig();
      expect(p.button, PhotoButton.hidden);
      t.configError = null;
      await p.refreshConfig();
      expect(p.button, PhotoButton.ready);
    });

    test('a fresh cached answer is not read again', () async {
      final t = FakePhotoTransport();
      final p = fakePhotos(store, transport: t);
      await p.refreshConfig(force: true);
      t.configError = StateError('should not be called');
      await p.refreshConfig();
      expect(p.button, PhotoButton.ready);
      expect(loadCachedPhotoConfig(store)!.config.enabled, isTrue);
    });

    test('a 503 photos_disabled on upload hides the button', () async {
      final t = FakePhotoTransport()..uploadError = const PhotoError(PhotoErrorKind.disabled, status: 503);
      final p = fakePhotos(store, transport: t);
      await p.refreshConfig(force: true);
      await expectLater(p.upload([1, 2, 3]), throwsA(isA<PhotoError>()));
      expect(p.button, PhotoButton.hidden);
    });
  });

  group('own photos', () {
    test('an upload is remembered as own; delete forgets it and the cached picture', () async {
      final t = FakePhotoTransport();
      final src = FakePhotoSource();
      final p = fakePhotos(store, transport: t, source: src);
      final r = await p.upload([1, 2, 3]);
      expect(r.url, photoUrlA);
      expect(p.isOwn('k3Xq9TzA'), isTrue);
      expect(loadOwnPhotoIds(store), {'k3Xq9TzA'});
      await p.delete(photoUrlA);
      expect(t.deletes, ['k3Xq9TzA']);
      expect(p.isOwn('k3Xq9TzA'), isFalse);
      expect(src.forgotten, [photoUrlA]);
    });

    test('delete of a photo already gone (404) counts as done; other errors are thrown', () async {
      final t = FakePhotoTransport()..deleteError = const PhotoError(PhotoErrorKind.notFound, status: 404);
      final p = fakePhotos(store, transport: t);
      addOwnPhotoId(store, 'k3Xq9TzA');
      await p.delete(photoUrlA);
      t.deleteError = const PhotoError(PhotoErrorKind.network);
      await expectLater(p.delete(photoUrlB), throwsA(isA<PhotoError>()));
    });

    test('report sends the id, reason and key', () async {
      final t = FakePhotoTransport();
      final p = fakePhotos(store, transport: t);
      await p.report(photoUrlA, PhotoReportReason.violence);
      expect(t.reports.single, ('k3Xq9TzA', PhotoReportReason.violence, 'drv-key'));
      final anon = fakePhotos(store, transport: t, key: null);
      await anon.report(photoUrlA, PhotoReportReason.spam);
      expect(t.reports.last.$3, isNull);
    });

    test('upload without a key never reaches the server', () async {
      final t = FakePhotoTransport();
      final p = fakePhotos(store, transport: t, key: '');
      await expectLater(p.upload([1]), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.noKey)));
      expect(t.uploads, isEmpty);
    });
  });

  test('Load photos automatically: on by default, saved', () {
    final p = fakePhotos(store);
    expect(p.autoLoad, isTrue);
    var told = 0;
    p.addListener(() => told++);
    p.autoLoad = false;
    expect(told, 1);
    expect(loadPhotosAutoLoad(store), isFalse);
    expect(fakePhotos(store).autoLoad, isFalse);
    p.autoLoad = true;
    expect(loadPhotosAutoLoad(store), isTrue);
  });

  group('HttpPhotoCache', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('photo_cache_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('200 is fetched once and then served from disk', () async {
      var calls = 0;
      final seen = <String>[];
      final c = HttpPhotoCache(dir, client: MockClient((r) async {
        calls++;
        seen.add(r.url.toString());
        return http.Response.bytes(tinyPng, 200, headers: {'content-type': 'image/webp'});
      }));
      final a = await c.fetch(photoUrlA, PhotoVariant.thumb);
      expect(a.state, PhotoFetchState.ok);
      expect(seen.single, '$photoUrlA/thumb');
      final b = await c.fetch(photoUrlA, PhotoVariant.thumb);
      expect(b.bytes, tinyPng);
      expect(calls, 1);
      expect(await c.cached(photoUrlA, PhotoVariant.thumb), tinyPng);
      await c.fetch(photoUrlA, PhotoVariant.full);
      expect(seen.last, '$photoUrlA/full');
    });

    test('410 is remembered as removed; 404 and offline are failures', () async {
      var status = 410;
      var calls = 0;
      final c = HttpPhotoCache(dir, client: MockClient((r) async {
        calls++;
        if (status == 0) throw http.ClientException('offline');
        return http.Response('', status);
      }));
      expect((await c.fetch(photoUrlA, PhotoVariant.thumb)).state, PhotoFetchState.removed);
      expect(await c.knownRemoved(photoUrlA), isTrue);
      expect((await c.fetch(photoUrlA, PhotoVariant.full)).state, PhotoFetchState.removed);
      expect(calls, 1);
      status = 404;
      expect((await c.fetch(photoUrlB, PhotoVariant.thumb)).state, PhotoFetchState.failed);
      status = 0;
      expect((await c.fetch(photoUrlB, PhotoVariant.thumb)).state, PhotoFetchState.failed);
    });

    test('a link that is not a photo link is never fetched', () async {
      var calls = 0;
      final c = HttpPhotoCache(dir, client: MockClient((r) async {
        calls++;
        return http.Response('', 200);
      }));
      expect((await c.fetch('https://example.com/p/k3Xq9TzA', PhotoVariant.thumb)).state, PhotoFetchState.failed);
      expect(calls, 0);
    });

    test('trim keeps the folder under its cap, oldest first', () async {
      final c = HttpPhotoCache(dir, maxBytes: 150, client: MockClient((r) async => http.Response.bytes(List.filled(100, 7), 200)));
      await c.fetch(photoUrlA, PhotoVariant.thumb);
      File('${dir.path}/k3Xq9TzA_thumb.img').setLastModifiedSync(DateTime(2020));
      await c.fetch(photoUrlB, PhotoVariant.thumb);
      await c.trim();
      expect(await c.cached(photoUrlA, PhotoVariant.thumb), isNull);
      expect(await c.cached(photoUrlB, PhotoVariant.thumb), isNotNull);
    });
  });
}
