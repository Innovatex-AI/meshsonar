// The photo endpoints of HttpCmatClient against contract v1: config, delete and report on a fake HTTP client; the upload on
// a fake socket (FakePhotoWire) on fake time: real progress, the stall and answer timeouts, the 10 min cap, slow-but-steady
// success, cancel, every error code; and the 450 KB size budget steps.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/core/photo_budget.dart';
import 'package:meshsonar/core/photo_wire.dart';

import '../support/photo_fakes.dart';

http.Response json(int status, Object body, {Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...headers});

void main() {
  final base = Uri.parse('https://cmh.meshsonar.com');
  const ok201 = {
    'id': 'k3Xq9TzA',
    'url': 'https://meshsonar.com/p/k3Xq9TzA',
    'thumbUrl': 'https://meshsonar.com/p/k3Xq9TzA/thumb',
    'fullUrl': 'https://meshsonar.com/p/k3Xq9TzA/full',
    'w': 2048,
    'h': 1536,
    'bytes': 312000,
    'duplicate': false,
  };

  group('photo-config', () {
    test('parses the answer', () async {
      late http.Request seen;
      final c = HttpCmatClient(
        base,
        client: MockClient((r) async {
          seen = r;
          return json(200, {'enabled': true, 'maxUploadBytes': 10485760, 'maxEdgePx': 2048, 'linkPrefix': 'https://meshsonar.com/p/'});
        }),
      );
      final cfg = await c.photoConfig();
      expect(seen.method, 'GET');
      expect(seen.url.toString(), 'https://cmh.meshsonar.com/api/cmh/photo-config');
      expect(seen.headers.containsKey('x-driver-key'), isFalse);
      expect(cfg.enabled, isTrue);
      expect(cfg.maxEdgePx, 2048);
      expect(cfg.maxUploadBytes, 10485760);
    });

    test('disabled and unreachable', () async {
      expect((await HttpCmatClient(base, client: MockClient((r) async => json(200, {'enabled': false}))).photoConfig()).enabled, isFalse);
      final down = HttpCmatClient(base, client: MockClient((r) async => throw http.ClientException('offline')));
      await expectLater(down.photoConfig(), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.network)));
    });
  });

  group('photo-upload', () {
    late FakePhotoWire wire;
    setUp(() => wire = FakePhotoWire());
    HttpCmatClient up() => HttpCmatClient(base, client: MockClient((r) async => fail('photo upload must go over the photo wire')), photoWire: wire);
    PhotoWireResponse reply(int status, Object body, {Map<String, String> headers = const {}}) =>
        PhotoWireResponse(status, utf8.encode(jsonEncode(body)), headers: {'content-type': 'application/json', ...headers});

    test('sends raw bytes with the driver key and content type; reports progress', () async {
      wire.answer = (r) => reply(201, ok201);
      final body = List<int>.generate(40000, (i) => i % 251);
      final progress = <int>[];
      final r = await up().uploadPhoto('drv-1', body, onProgress: (s, t) => progress.add(s));
      final seen = wire.requests.single;
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://cmh.meshsonar.com/api/cmh/photo-upload');
      expect(seen.headers['x-driver-key'], 'drv-1');
      expect(seen.headers['content-type'], 'image/jpeg');
      expect(seen.headers['accept'], 'application/json');
      expect(seen.contentLength, body.length);
      expect(seen.body, body);
      expect(r.id, 'k3Xq9TzA');
      expect(r.url, 'https://meshsonar.com/p/k3Xq9TzA');
      expect(r.thumbUrl, endsWith('/thumb'));
      expect(r.w, 2048);
      expect(progress.first, 0);
      expect(progress.last, body.length);
      expect(progress.length, greaterThan(2));
    });

    test('progress follows the bytes the socket took, never ahead of them', () {
      fakeAsync((fa) {
        wire.bytesPerSecond = 10 * 1000;
        final written = <int>[];
        wire.onWritten = written.add;
        final progress = <int>[];
        final body = List<int>.filled(100 * 1000, 7);
        var finished = false;
        up()
            .uploadPhoto(
              'k',
              body,
              onProgress: (s, t) {
                progress.add(s);
                // At every report the socket already holds exactly that many bytes.
                expect(s, written.isEmpty ? 0 : written.last);
              },
            )
            .then((_) => finished = true);
        fa.elapse(const Duration(seconds: 1));
        // 1 s at 10 KB/s: one 8 KB chunk out, nowhere near 100%.
        expect(progress.last, HttpCmatClient.photoChunkBytes);
        fa.elapse(const Duration(seconds: 4));
        expect(progress.last, closeTo(5 * 10000, HttpCmatClient.photoChunkBytes));
        expect(finished, isFalse);
        fa.elapse(const Duration(seconds: 6));
        expect(progress.last, body.length);
        fa.flushMicrotasks();
        expect(finished, isTrue);
      });
    });

    test('a slow but steady upload (10 KB/s, 300 KB = 30 s, past the old 120 s rule for 1.2 MB) succeeds', () {
      fakeAsync((fa) {
        wire.bytesPerSecond = 10 * 1000;
        PhotoUploadResult? r;
        Object? err;
        up()
            .uploadPhoto('k', List<int>.filled(300 * 1000, 1))
            .then(
              (v) {
                r = v;
              },
              onError: (Object e) {
                err = e;
              },
            );
        fa.elapse(const Duration(seconds: 29));
        expect(r, isNull);
        fa.elapse(const Duration(seconds: 2));
        expect(err, isNull);
        expect(r?.id, 'k3Xq9TzA');
        expect(wire.requests.single.body.length, 300 * 1000);
      });
      // 2 KB/s for 1.2 MB is 10 min of steady progress: the hard cap ends it as stalled.
      fakeAsync((fa) {
        wire = FakePhotoWire()..bytesPerSecond = 2000;
        Object? err;
        up()
            .uploadPhoto('k', List<int>.filled(1200 * 1000, 1))
            .then(
              (_) {},
              onError: (Object e) {
                err = e;
              },
            );
        fa.elapse(const Duration(minutes: 9, seconds: 59));
        expect(err, isNull);
        fa.elapse(const Duration(seconds: 2));
        expect((err as PhotoError).kind, PhotoErrorKind.stalled);
        expect(wire.requests.single.aborted, isTrue);
      });
    });

    test('no byte out for 45 s is a stall: aborted, "Upload stalled" sentence, retryable', () {
      fakeAsync((fa) {
        wire.bytesPerSecond = 10 * 1000;
        wire.stallAfterBytes = 50 * 1000;
        Object? err;
        final progress = <int>[];
        up()
            .uploadPhoto('k', List<int>.filled(200 * 1000, 1), onProgress: (s, t) => progress.add(s))
            .then(
              (_) {},
              onError: (Object e) {
                err = e;
              },
            );
        fa.elapse(const Duration(seconds: 5)); // ~48 KB out, then nothing
        final at = progress.last;
        fa.elapse(const Duration(seconds: 44));
        expect(err, isNull, reason: 'not yet 45 s since the last byte');
        fa.elapse(const Duration(seconds: 2));
        final e = err as PhotoError;
        expect(e.kind, PhotoErrorKind.stalled);
        expect(e.retryable, isTrue);
        expect(e.message, 'Upload stalled — your connection is too slow right now. Try again or use Wi-Fi.');
        expect(progress.last, at);
        expect(wire.requests.single.aborted, isTrue);
      });
    });

    test('no answer 60 s after the last byte is a stall; an answer at 59 s is fine', () {
      fakeAsync((fa) {
        wire.neverAnswer = true;
        Object? err;
        up()
            .uploadPhoto('k', List<int>.filled(1000, 1))
            .then(
              (_) {},
              onError: (Object e) {
                err = e;
              },
            );
        fa.elapse(const Duration(seconds: 59));
        expect(err, isNull);
        fa.elapse(const Duration(seconds: 2));
        expect((err as PhotoError).kind, PhotoErrorKind.stalled);
      });
      fakeAsync((fa) {
        wire = FakePhotoWire()..answerDelay = const Duration(seconds: 59);
        PhotoUploadResult? r;
        up().uploadPhoto('k', List<int>.filled(1000, 1)).then((v) => r = v);
        fa.elapse(const Duration(seconds: 60));
        expect(r, isNotNull);
      });
    });

    test('a connection that cannot be made or drops is a network error ("Could not reach")', () async {
      wire.connectError = const SocketException('Failed host lookup');
      final a = await up().uploadPhoto('k', [1]).then<PhotoError?>((_) => null, onError: (Object e) => e as PhotoError);
      expect(a!.kind, PhotoErrorKind.network);
      expect(a.message, startsWith('Could not reach the MeshSonar server'));
      wire = FakePhotoWire()..writeError = const SocketException('Connection reset by peer');
      final b = await up().uploadPhoto('k', List.filled(20000, 1)).then<PhotoError?>((_) => null, onError: (Object e) => e as PhotoError);
      expect(b!.kind, PhotoErrorKind.network);
      wire = FakePhotoWire()..connectError = const HandshakeException('bad cert');
      expect((await up().uploadPhoto('k', [1]).then<PhotoError?>((_) => null, onError: (Object e) => e as PhotoError))!.kind, PhotoErrorKind.network);
    });

    test('a duplicate re-send (200 or 201 with duplicate) still gives the link', () async {
      wire.answer = (r) => reply(200, {...ok201, 'duplicate': true});
      expect((await up().uploadPhoto('k', [1, 2, 3])).duplicate, isTrue);
    });

    Future<PhotoError> failWith(PhotoWireResponse res) async {
      wire = FakePhotoWire()..answer = (r) => res;
      try {
        await up().uploadPhoto('k', [1, 2, 3]);
      } on PhotoError catch (e) {
        return e;
      }
      fail('no error');
    }

    test('every contract error maps to a kind and a plain sentence', () async {
      final cases = <int, PhotoErrorKind>{
        401: PhotoErrorKind.noKey,
        403: PhotoErrorKind.notApproved,
        413: PhotoErrorKind.tooLarge,
        415: PhotoErrorKind.notImage,
        503: PhotoErrorKind.disabled,
        500: PhotoErrorKind.server,
      };
      for (final e in cases.entries) {
        final err = await failWith(reply(e.key, {'error': e.key == 503 ? 'photos_disabled' : 'nope'}));
        expect(err.kind, e.value, reason: '${e.key}');
        expect(err.status, e.key);
        expect(err.message, isNotEmpty);
      }
      expect((await failWith(reply(401, {'error': 'x'}))).message, contains('driver key'));
      expect((await failWith(reply(403, {'error': 'x'}))).message, contains('not approved'));
      expect((await failWith(reply(413, {'error': 'x'}))).message, contains('too large'));
      expect((await failWith(reply(415, {'error': 'x'}))).message, contains('not a photo'));
      expect((await failWith(reply(503, {'error': 'photos_disabled'}))).message, contains('switched off'));
    });

    test('429 carries retryAfterS from the body, else Retry-After', () async {
      final a = await failWith(reply(429, {'error': 'daily_limit', 'retryAfterS': 3600}));
      expect(a.kind, PhotoErrorKind.rateLimited);
      expect(a.retryAfterS, 3600);
      expect(a.message, 'Photo limit reached. Try again in 60 minutes.');
      final b = await failWith(reply(429, {'error': 'x'}, headers: {'retry-after': '40'}));
      expect(b.retryAfterS, 40);
      expect(b.message, contains('in 40 seconds'));
      expect(b.retryable, isTrue);
    });

    test('a 201 without a usable photo link is a server error', () async {
      final e = await failWith(reply(201, {'id': 'k3Xq9TzA', 'url': 'https://example.com/x'}));
      expect(e.kind, PhotoErrorKind.server);
    });

    test('no key is refused before any request', () async {
      await expectLater(up().uploadPhoto('', [1]), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.noKey)));
      expect(wire.requests, isEmpty);
    });

    test('cancel mid-body aborts the socket and reports cancelled', () {
      fakeAsync((fa) {
        wire.bytesPerSecond = 10 * 1000;
        final cancel = PhotoCancel();
        Object? err;
        up()
            .uploadPhoto('k', List.filled(100 * 1000, 1), cancel: cancel)
            .then(
              (_) {},
              onError: (Object e) {
                err = e;
              },
            );
        fa.elapse(const Duration(seconds: 2));
        cancel.cancel();
        fa.flushMicrotasks();
        expect((err as PhotoError).kind, PhotoErrorKind.cancelled);
        expect(wire.requests.single.aborted, isTrue);
        expect(wire.requests.single.finished, isFalse);
        fa.elapse(const Duration(minutes: 11)); // no timer left behind to fire
        expect((err as PhotoError).kind, PhotoErrorKind.cancelled);
      });
    });

    test('cancelled before it started: nothing is sent at all', () async {
      final pre = PhotoCancel()..cancel();
      await expectLater(up().uploadPhoto('k', [1], cancel: pre), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.cancelled)));
      expect(wire.requests, isEmpty);
    });
  });

  group('photo size budget', () {
    test('steps: q70, q60, then 20 % smaller edges at q60, never below 800 px', () {
      expect(photoBudgetSteps(1280), [(1280, 70), (1280, 60), (1024, 60), (819, 60), (800, 60)]);
      expect(photoBudgetSteps(2048), [(2048, 70), (2048, 60), (1638, 60), (1310, 60), (1048, 60), (838, 60), (800, 60)]);
      expect(photoBudgetSteps(800), [(800, 70), (800, 60)]);
      expect(photoBudgetSteps(640), [(640, 70), (640, 60)]);
    });

    // A stand-in encoder: size grows with edge^2 and quality.
    Uint8List enc(int edge, int q) => Uint8List(edge * edge * q ~/ 250);

    test('under the budget the q80 shrink is kept untouched', () async {
      final first = Uint8List(400 * 1000);
      final calls = <(int, int)>[];
      final out = await fitPhotoBudget(first, 1280, (e, q) async {
        calls.add((e, q));
        return enc(e, q);
      });
      expect(identical(out, first), isTrue);
      expect(calls, isEmpty);
    });

    test('stops at the first step that fits', () async {
      final calls = <(int, int)>[];
      // 1280 px: q80 = 524 KB, q70 = 459 KB (over), q60 = 393 KB (fits).
      final out = await fitPhotoBudget(enc(1280, 80), 1280, (e, q) async {
        calls.add((e, q));
        return enc(e, q);
      });
      expect(calls, [(1280, 70), (1280, 60)]);
      expect(out.length, enc(1280, 60).length);
      expect(out.length, lessThanOrEqualTo(photoBudgetBytes));
    });

    test('goes down the edges when quality is not enough; the smallest wins when nothing fits', () async {
      final calls = <(int, int)>[];
      final out = await fitPhotoBudget(enc(2048, 80), 2048, (e, q) async {
        calls.add((e, q));
        return enc(e, q);
      });
      expect(calls.last, (1310, 60)); // 1638 q60 = 644 KB, 1310 q60 = 412 KB
      expect(out.length, lessThanOrEqualTo(photoBudgetBytes));
      final huge = await fitPhotoBudget(Uint8List(5000000), 1280, (e, q) async => e == 1024 ? null : Uint8List(e * 1000 + q));
      expect(huge.length, 800 * 1000 + 60);
    });
  });
  group('photo-delete and photo-report', () {
    test('delete posts {id} with the key; 404 maps to notFound', () async {
      late http.Request seen;
      final c = HttpCmatClient(
        base,
        client: MockClient((r) async {
          seen = r;
          return json(200, {'deleted': true});
        }),
      );
      await c.deletePhoto('drv', 'k3Xq9TzA');
      expect(seen.url.path, '/api/cmh/photo-delete');
      expect(seen.method, 'POST');
      expect(seen.headers['x-driver-key'], 'drv');
      expect(jsonDecode(seen.body), {'id': 'k3Xq9TzA'});
      final gone = HttpCmatClient(base, client: MockClient((r) async => json(404, {'error': 'not_found'})));
      await expectLater(gone.deletePhoto('drv', 'x'), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.notFound)));
    });

    test('report posts {id, reason}; 202 is success; the key is optional', () async {
      final seen = <http.Request>[];
      final c = HttpCmatClient(
        base,
        client: MockClient((r) async {
          seen.add(r);
          return json(202, {'reported': true});
        }),
      );
      await c.reportPhoto('k3Xq9TzA', PhotoReportReason.spam);
      await c.reportPhoto('k3Xq9TzA', PhotoReportReason.childSafety, driverKey: 'drv');
      expect(seen[0].url.path, '/api/cmh/photo-report');
      expect(jsonDecode(seen[0].body), {'id': 'k3Xq9TzA', 'reason': 'spam'});
      expect(seen[0].headers.containsKey('x-driver-key'), isFalse);
      expect(jsonDecode(seen[1].body)['reason'], 'child_safety');
      expect(seen[1].headers['x-driver-key'], 'drv');
      final limited = HttpCmatClient(base, client: MockClient((r) async => json(429, {'error': 'rate', 'retryAfterS': 600})));
      await expectLater(
        limited.reportPhoto('x', PhotoReportReason.other),
        throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.rateLimited).having((e) => e.retryAfterS, 's', 600)),
      );
    });
  });

  test('waitText', () {
    expect(waitText(null), 'later');
    expect(waitText(30), 'in 30 seconds');
    expect(waitText(600), 'in 10 minutes');
    expect(waitText(7200), 'in 2 hours');
  });
}
