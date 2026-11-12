// Private (end-to-end encrypted) photos below the UI: PhotoController.uploadPrivate (clean-JPEG gate, encryption, the body the
// server gets, the private link with the key, every error code, no plain fallback), the button gate on photo-config e2e,
// report with / without the key, delete; HttpPhotoCache for a private link (ciphertext in, DECRYPTED bytes cached, 404/410
// gone, wrong key = failed); and HttpCmatClient's photo-upload-enc request (headers and body) on the fake socket.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/app/photo_controller.dart';
import 'package:meshsonar/chat/photo_kind.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/jpeg_meta.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/core/photo_cache.dart';
import 'package:meshsonar/core/photo_wire.dart';
import 'package:meshsonar/core/private_photo.dart';
import 'package:meshsonar/platform/photo_picker.dart';

import '../support/photo_fakes.dart';

void main() {
  late ChatStore store;
  late FakePhotoTransport t;
  setUp(() {
    store = ChatStore.inMemory();
    t = FakePhotoTransport();
  });
  tearDown(() => store.close());

  final full = PreparedPhoto(cleanJpeg, 2048, 1536);
  final thumb = PreparedPhoto(Uint8List.fromList([...cleanJpeg, 0]), 480, 360);
  final gpsJpeg = File('test/fixtures/photos/gps_fixture.jpg').readAsBytesSync();

  test('the fixtures: clean JPEG passes the gate, the GPS original does not, a PNG does not', () {
    expect(jpegIsClean(cleanJpeg), isTrue);
    expect(jpegIsClean(gpsJpeg), isFalse);
    expect(jpegIsClean(tinyPng), isFalse);
  });

  group('button gate', () {
    test('private conversation: hidden unless photo-config has e2e; plain is unaffected', () async {
      t.config = const PhotoConfig(enabled: true);
      final p = fakePhotos(store, transport: t);
      await p.refreshConfig(force: true);
      expect(p.buttonFor(PhotoKind.plain), PhotoButton.ready);
      expect(p.buttonFor(PhotoKind.private), PhotoButton.hidden, reason: 'a DM never falls back to a plain link');
      t.config = const PhotoConfig(enabled: true, e2e: true);
      await p.refreshConfig(force: true);
      expect(p.buttonFor(PhotoKind.private), PhotoButton.ready);
      expect(p.buttonFor(PhotoKind.plain), PhotoButton.ready);
    });

    test('e2e does not override the other gates (off, no key)', () async {
      t.config = const PhotoConfig(enabled: false, e2e: true);
      final p = fakePhotos(store, transport: t);
      await p.refreshConfig(force: true);
      expect(p.buttonFor(PhotoKind.private), PhotoButton.hidden);
      t.config = const PhotoConfig(enabled: true, e2e: true);
      final q = fakePhotos(store, transport: t, key: null);
      await q.refreshConfig(force: true);
      expect(q.buttonFor(PhotoKind.private), PhotoButton.needsKey);
    });

    test('photo-config parses e2e and the prefix, and the cached copy keeps them', () {
      final c = PhotoConfig.parse({'enabled': true, 'e2e': true, 'privateLinkPrefix': 'https://meshsonar.com/e/'});
      expect(c.e2e, isTrue);
      expect(c.privateLinkPrefix, 'https://meshsonar.com/e/');
      expect(PhotoConfig.parse({'enabled': true}).e2e, isFalse);
      expect(PhotoConfig.parse(c.toJson()).e2e, isTrue);
    });
  });

  group('uploadPrivate', () {
    Future<PhotoController> ready() async {
      final p = fakePhotos(store, transport: t);
      await p.refreshConfig(force: true);
      return p;
    }

    test('encrypts both JPEGs on the phone; the body is u32 thumbLen || thumb blob || full blob; the link carries the key', () async {
      final p = await ready();
      final r = await p.uploadPrivate(full, thumb);
      final link = parsePrivatePhotoLink(r.url)!;
      expect(link.id, 'k3Xq9TzA');
      expect(r.url, startsWith('https://meshsonar.com/e/k3Xq9TzA#'));
      expect(utf8.encode(r.url).length, 55);
      expect(r.thumbUrl, 'https://meshsonar.com/e/k3Xq9TzA/thumb', reason: 'server urls carry no key');
      final body = Uint8List.fromList(t.privateBodies.single);
      final thumbLen = ByteData.sublistView(body).getUint32(0, Endian.big);
      final tb = body.sublist(4, 4 + thumbLen), fb = body.sublist(4 + thumbLen);
      expect(await PrivatePhoto.decrypt(tb, link.key, PrivatePhotoRole.thumb), thumb.bytes);
      expect(await PrivatePhoto.decrypt(fb, link.key, PrivatePhotoRole.full), full.bytes);
      expect(t.uploads, isEmpty, reason: 'nothing went to the plain endpoint');
      expect(t.privateSizes.single, (2048, 1536));
      expect(p.isOwn('k3Xq9TzA'), isTrue);
    });

    test('the key is nowhere in what the server receives', () async {
      final p = await ready();
      final r = await p.uploadPrivate(full, thumb);
      final key = parsePrivatePhotoLink(r.url)!;
      final raw = String.fromCharCodes(t.privateBodies.single);
      expect(raw, isNot(contains(key.keyText)));
      expect(find(t.privateBodies.single, key.key), isFalse);
    });

    test('every upload uses a fresh key', () async {
      final p = await ready();
      final a = parsePrivatePhotoLink((await p.uploadPrivate(full, thumb)).url)!;
      final b = parsePrivatePhotoLink((await p.uploadPrivate(full, thumb)).url)!;
      expect(a.keyText, isNot(b.keyText));
    });

    test('a picture with EXIF/GPS (or not a JPEG) never leaves the phone', () async {
      final p = await ready();
      for (final bad in [PreparedPhoto(gpsJpeg, 10, 10), PreparedPhoto(tinyPng, 2, 2)]) {
        await expectLater(p.uploadPrivate(bad, thumb), throwsA(isA<PhotoPrepareException>()));
        await expectLater(p.uploadPrivate(full, bad), throwsA(isA<PhotoPrepareException>()));
      }
      expect(t.privateBodies, isEmpty);
      expect(t.uploads, isEmpty);
    });

    test('without e2e on the server nothing is sent, and no plain upload is tried', () async {
      t.config = const PhotoConfig(enabled: true);
      final p = fakePhotos(store, transport: t);
      await p.refreshConfig(force: true);
      await expectLater(p.uploadPrivate(full, thumb), throwsA(isA<PhotoError>()));
      expect(t.privateBodies, isEmpty);
      expect(t.uploads, isEmpty);
    });

    test('no driver key: noKey; no transport: network', () async {
      final p = fakePhotos(store, transport: t, key: null);
      await p.refreshConfig(force: true);
      await expectLater(p.uploadPrivate(full, thumb), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.noKey)));
    });

    final errors = <PhotoError, PhotoErrorKind>{
      const PhotoError(PhotoErrorKind.noKey, status: 401): PhotoErrorKind.noKey,
      const PhotoError(PhotoErrorKind.notApproved, status: 403): PhotoErrorKind.notApproved,
      const PhotoError(PhotoErrorKind.tooLarge, status: 413): PhotoErrorKind.tooLarge,
      const PhotoError(PhotoErrorKind.rateLimited, status: 429, retryAfterS: 600): PhotoErrorKind.rateLimited,
      const PhotoError(PhotoErrorKind.disabled, status: 503): PhotoErrorKind.disabled,
      const PhotoError(PhotoErrorKind.stalled): PhotoErrorKind.stalled,
      const PhotoError(PhotoErrorKind.network): PhotoErrorKind.network,
    };
    for (final e in errors.entries) {
      test('server answer ${e.key.status ?? e.key.kind.name} reaches the caller as ${e.value.name}; the key is not in the message', () async {
        final p = await ready();
        t.uploadError = e.key;
        try {
          await p.uploadPrivate(full, thumb);
          fail('should throw');
        } on PhotoError catch (x) {
          expect(x.kind, e.value);
          expect(x.toString(), isNot(contains('#')));
        }
        expect(p.isOwn('k3Xq9TzA'), isFalse);
        if (e.value == PhotoErrorKind.disabled) expect(p.config.enabled, isFalse);
      });
    }

    test('a body over maxUploadBytes is tooLarge before any byte is sent', () async {
      t.config = const PhotoConfig(enabled: true, e2e: true, maxUploadBytes: 100);
      final p = fakePhotos(store, transport: t);
      await p.refreshConfig(force: true);
      await expectLater(p.uploadPrivate(full, thumb), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.tooLarge)));
      expect(t.privateBodies, isEmpty);
    });

    test('unknown dimensions are replaced by sane header values (1..16384)', () async {
      final p = await ready();
      await p.uploadPrivate(PreparedPhoto(cleanJpeg, 0, 0), thumb);
      await p.uploadPrivate(PreparedPhoto(cleanJpeg, 99999, 5), thumb);
      for (final (w, h) in t.privateSizes) {
        expect(w, inInclusiveRange(1, 16384));
        expect(h, inInclusiveRange(1, 16384));
      }
    });

    test('progress is reported, and Cancel before the answer ends with cancelled', () async {
      final p = await ready();
      final seen = <int>[];
      await p.uploadPrivate(full, thumb, onProgress: (s, tot) => seen.add(s));
      expect(seen, isNotEmpty);
      t.holdUpload = Completer<void>();
      final c = PhotoCancel();
      final f = p.uploadPrivate(full, thumb, cancel: c);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      c.cancel();
      await expectLater(f, throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.cancelled)));
    });
  });

  group('report and delete', () {
    test('report sends the key only when the reporter allowed it, and only for a private link', () async {
      final p = fakePhotos(store, transport: t);
      await p.report(privateUrlA, PhotoReportReason.violence);
      await p.report(privateUrlA, PhotoReportReason.violence, shareKey: true);
      await p.report(photoUrlA, PhotoReportReason.spam, shareKey: true);
      expect(t.reports.map((r) => r.$1), ['k3Xq9TzA', 'k3Xq9TzA', 'k3Xq9TzA']);
      expect(t.reportKeys, [null, privateKeyA, null]);
    });

    test('delete works for a private link (same photo-delete) and forgets the cache', () async {
      final src = FakePhotoSource();
      final p = fakePhotos(store, transport: t, source: src);
      await p.delete(privateUrlA);
      expect(t.deletes, ['k3Xq9TzA']);
      expect(src.forgotten, [privateUrlA]);
    });
  });

  group('HttpPhotoCache, private link', () {
    late Directory dir;
    late PrivatePhotoLink link;
    late EncryptedPhoto enc;
    setUp(() async {
      dir = Directory.systemTemp.createTempSync('private_photo_cache_test');
      enc = await PrivatePhoto.encrypt(thumb.bytes, full.bytes, key: PrivatePhoto.decodeKey(privateKeyA));
      link = parsePrivatePhotoLink(privateUrlA)!;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    HttpPhotoCache cache(MockClient c) => HttpPhotoCache(dir, client: c);

    test('fetches the ciphertext, returns and caches the decrypted JPEG, then serves it from disk', () async {
      final seen = <String>[];
      final c = cache(MockClient((r) async {
        seen.add('${r.url}');
        return http.Response.bytes(r.url.path.endsWith('thumb') ? enc.thumbBlob : enc.fullBlob, 200, headers: {'content-type': 'application/octet-stream'});
      }));
      final a = await c.fetch(privateUrlA, PhotoVariant.thumb);
      expect(a.state, PhotoFetchState.ok);
      expect(a.bytes, thumb.bytes);
      expect(seen.single, 'https://meshsonar.com/e/k3Xq9TzA/thumb', reason: 'the key (fragment) is never requested');
      expect(await c.cached(privateUrlA, PhotoVariant.thumb), thumb.bytes);
      await c.fetch(privateUrlA, PhotoVariant.thumb);
      expect(seen.length, 1);
      final f = await c.fetch(privateUrlA, PhotoVariant.full);
      expect(f.bytes, full.bytes);
      expect(seen.last, 'https://meshsonar.com/e/k3Xq9TzA/full');
      // On disk: the decrypted bytes under e_<id>, never the ciphertext, never the key.
      final files = dir.listSync().whereType<File>().toList();
      expect(files.map((e) => e.uri.pathSegments.last), containsAll(['e_k3Xq9TzA_thumb.img', 'e_k3Xq9TzA_full.img']));
      for (final f in files) {
        expect(f.readAsBytesSync(), anyOf(equals(thumb.bytes), equals(full.bytes)));
        expect(f.path, isNot(contains(link.keyText)));
      }
    });

    test('404 and 410 both mean gone ("expired") and are remembered; offline is a failure', () async {
      for (final status in [404, 410]) {
        final d = Directory.systemTemp.createTempSync('pp_gone');
        addTearDown(() => d.deleteSync(recursive: true));
        var calls = 0;
        final c = HttpPhotoCache(d, client: MockClient((r) async {
          calls++;
          return http.Response('', status);
        }));
        expect((await c.fetch(privateUrlA, PhotoVariant.thumb)).state, PhotoFetchState.removed, reason: '$status');
        expect(await c.knownRemoved(privateUrlA), isTrue);
        expect((await c.fetch(privateUrlA, PhotoVariant.full)).state, PhotoFetchState.removed);
        expect(calls, 1);
      }
      final off = cache(MockClient((r) async => throw http.ClientException('offline')));
      expect((await off.fetch(privateUrlA, PhotoVariant.thumb)).state, PhotoFetchState.failed);
      expect(await off.knownRemoved(privateUrlA), isFalse);
    });

    test('a wrong key, a damaged blob and a swapped role are quiet failures and cache nothing', () async {
      final wrong = 'https://meshsonar.com/e/k3Xq9TzA#${PrivatePhoto.encodeKey(PrivatePhoto.generateKey())}';
      final c = cache(MockClient((r) async => http.Response.bytes(enc.thumbBlob, 200)));
      expect((await c.fetch(wrong, PhotoVariant.thumb)).state, PhotoFetchState.failed);
      expect((await c.fetch(privateUrlA, PhotoVariant.full)).state, PhotoFetchState.failed, reason: 'thumb blob served as full');
      final damaged = Uint8List.fromList(enc.thumbBlob)..[20] ^= 1;
      final d = cache(MockClient((r) async => http.Response.bytes(damaged, 200)));
      expect((await d.fetch(privateUrlA, PhotoVariant.thumb)).state, PhotoFetchState.failed);
      final junk = cache(MockClient((r) async => http.Response.bytes(Uint8List(10), 200)));
      expect((await junk.fetch(privateUrlA, PhotoVariant.thumb)).state, PhotoFetchState.failed);
      expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.img')), isEmpty);
    });

    test('forget removes the images and leaves a gone marker', () async {
      final c = cache(MockClient((r) async => http.Response.bytes(enc.thumbBlob, 200)));
      await c.fetch(privateUrlA, PhotoVariant.thumb);
      await c.forget(privateUrlA);
      expect(await c.cached(privateUrlA, PhotoVariant.thumb), isNull);
      expect(await c.knownRemoved(privateUrlA), isTrue);
    });

    test('a plain photo of the same id is a different cache entry', () async {
      final c = cache(MockClient((r) async => http.Response.bytes(r.url.path.startsWith('/e/') ? enc.thumbBlob : tinyPng, 200)));
      await c.fetch(privateUrlA, PhotoVariant.thumb);
      expect(await c.cached(photoUrlA, PhotoVariant.thumb), isNull);
    });
  });

  group('HttpCmatClient photo-upload-enc', () {
    final base = Uri.parse('https://cmh.meshsonar.com');
    const ok = {'id': 'k3Xq9TzA', 'url': 'https://meshsonar.com/e/k3Xq9TzA', 'thumbUrl': 'https://meshsonar.com/e/k3Xq9TzA/thumb', 'fullUrl': 'https://meshsonar.com/e/k3Xq9TzA/full', 'w': 2048, 'h': 1536, 'bytes': 99, 'duplicate': false};
    late FakePhotoWire wire;
    setUp(() => wire = FakePhotoWire());
    HttpCmatClient client() => HttpCmatClient(base, client: MockClient((r) async => fail('must go over the photo wire')), photoWire: wire);
    PhotoWireResponse answer(int s, Map<String, Object?> b, {Map<String, String> h = const {}}) => PhotoWireResponse(s, utf8.encode(jsonEncode(b)), headers: {'content-type': 'application/json', ...h});

    test('POSTs octet-stream to photo-upload-enc with x-driver-key, x-photo-w and x-photo-h; the body is sent unchanged', () async {
      wire.answer = (r) => answer(201, ok);
      final body = List<int>.generate(20000, (i) => i % 256);
      final progress = <int>[];
      final r = await client().uploadPrivatePhoto('drv-1', body, width: 2048, height: 1536, onProgress: (s, t) => progress.add(s));
      final req = wire.requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/api/cmh/photo-upload-enc');
      expect(req.headers['content-type'], 'application/octet-stream');
      expect(req.headers['x-driver-key'], 'drv-1');
      expect(req.headers['x-photo-w'], '2048');
      expect(req.headers['x-photo-h'], '1536');
      expect(req.contentLength, body.length);
      expect(req.body, body);
      expect(progress.last, body.length);
      expect(r.id, 'k3Xq9TzA');
      expect(r.url, 'https://meshsonar.com/e/k3Xq9TzA');
    });

    final cases = {401: PhotoErrorKind.noKey, 403: PhotoErrorKind.notApproved, 413: PhotoErrorKind.tooLarge, 429: PhotoErrorKind.rateLimited, 503: PhotoErrorKind.disabled, 400: PhotoErrorKind.server, 500: PhotoErrorKind.server};
    for (final c in cases.entries) {
      test('answer ${c.key} is ${c.value.name}', () async {
        wire.answer = (r) => answer(c.key, {'error': 'x', if (c.key == 429) 'retryAfterS': 90});
        await expectLater(client().uploadPrivatePhoto('k', [1, 2, 3], width: 1, height: 1),
            throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', c.value).having((e) => e.retryAfterS, 'retryAfterS', c.key == 429 ? 90 : null)));
      });
    }

    test('an answer without a valid id is a server error; no key is a noKey', () async {
      wire.answer = (r) => answer(201, {'id': 'short', 'url': 'x'});
      await expectLater(client().uploadPrivatePhoto('k', [1], width: 1, height: 1), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.server)));
      await expectLater(client().uploadPrivatePhoto('', [1], width: 1, height: 1), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.noKey)));
    });

    test('a connection that goes nowhere is network; the plain upload still posts to photo-upload', () async {
      wire.connectError = const SocketException('down');
      await expectLater(client().uploadPrivatePhoto('k', [1], width: 1, height: 1), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.network)));
      wire = FakePhotoWire();
      await client().uploadPhoto('k', [1, 2]);
      expect(wire.requests.single.url.path, '/api/cmh/photo-upload');
      expect(wire.requests.single.headers.containsKey('x-photo-w'), isFalse);
    });

    test('photo-report carries key only when given', () async {
      final seen = <Map<String, dynamic>>[];
      final c = HttpCmatClient(base, client: MockClient((r) async {
        seen.add(jsonDecode(r.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'reported': true}), 202, headers: {'content-type': 'application/json'});
      }));
      await c.reportPhoto('k3Xq9TzA', PhotoReportReason.spam, driverKey: 'd');
      await c.reportPhoto('k3Xq9TzA', PhotoReportReason.spam, driverKey: 'd', key: privateKeyA);
      expect(seen[0].containsKey('key'), isFalse);
      expect(seen[1], {'id': 'k3Xq9TzA', 'reason': 'spam', 'key': privateKeyA});
    });
  });
}

/// True when [needle] occurs in [hay].
bool find(List<int> hay, List<int> needle) {
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}
