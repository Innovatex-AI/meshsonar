// The photo endpoints of HttpCmatClient against contract v1, with a fake HTTP client: config, upload (progress, cancel,
// every error code), delete and report.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/photo_api.dart';

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
      final c = HttpCmatClient(base, client: MockClient((r) async {
        seen = r;
        return json(200, {'enabled': true, 'maxUploadBytes': 10485760, 'maxEdgePx': 2048, 'linkPrefix': 'https://meshsonar.com/p/'});
      }));
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
    test('sends raw bytes with the driver key and content type; reports progress', () async {
      late http.Request seen;
      final c = HttpCmatClient(base, client: MockClient((r) async {
        seen = r;
        return json(201, ok201);
      }));
      final body = List<int>.generate(40000, (i) => i % 251);
      final progress = <int>[];
      final r = await c.uploadPhoto('drv-1', body, onProgress: (s, t) => progress.add(s));
      expect(seen.method, 'POST');
      expect(seen.url.path, '/api/cmh/photo-upload');
      expect(seen.headers['x-driver-key'], 'drv-1');
      expect(seen.headers['content-type'], 'image/jpeg');
      expect(seen.bodyBytes, body);
      expect(r.id, 'k3Xq9TzA');
      expect(r.url, 'https://meshsonar.com/p/k3Xq9TzA');
      expect(r.thumbUrl, endsWith('/thumb'));
      expect(r.w, 2048);
      expect(progress.last, body.length);
      expect(progress.length, greaterThan(1));
    });

    test('a duplicate re-send (200 or 201 with duplicate) still gives the link', () async {
      final c = HttpCmatClient(base, client: MockClient((r) async => json(200, {...ok201, 'duplicate': true})));
      expect((await c.uploadPhoto('k', [1, 2, 3])).duplicate, isTrue);
    });

    Future<PhotoError> failWith(http.Response res) async {
      final c = HttpCmatClient(base, client: MockClient((r) async => res));
      try {
        await c.uploadPhoto('k', [1, 2, 3]);
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
        final err = await failWith(json(e.key, {'error': e.key == 503 ? 'photos_disabled' : 'nope'}));
        expect(err.kind, e.value, reason: '${e.key}');
        expect(err.status, e.key);
        expect(err.message, isNotEmpty);
      }
      expect((await failWith(json(401, {'error': 'x'}))).message, contains('driver key'));
      expect((await failWith(json(403, {'error': 'x'}))).message, contains('not approved'));
      expect((await failWith(json(413, {'error': 'x'}))).message, contains('too large'));
      expect((await failWith(json(415, {'error': 'x'}))).message, contains('not a photo'));
      expect((await failWith(json(503, {'error': 'photos_disabled'}))).message, contains('switched off'));
    });

    test('429 carries retryAfterS from the body, else Retry-After', () async {
      final a = await failWith(json(429, {'error': 'daily_limit', 'retryAfterS': 3600}));
      expect(a.kind, PhotoErrorKind.rateLimited);
      expect(a.retryAfterS, 3600);
      expect(a.message, 'Photo limit reached. Try again in 60 minutes.');
      final b = await failWith(json(429, {'error': 'x'}, headers: {'retry-after': '40'}));
      expect(b.retryAfterS, 40);
      expect(b.message, contains('in 40 seconds'));
      expect(b.retryable, isTrue);
    });

    test('a 201 without a usable photo link is a server error', () async {
      final e = await failWith(json(201, {'id': 'k3Xq9TzA', 'url': 'https://example.com/x'}));
      expect(e.kind, PhotoErrorKind.server);
    });

    test('network failure', () async {
      final c = HttpCmatClient(base, client: MockClient((r) async => throw http.ClientException('no route')));
      await expectLater(c.uploadPhoto('k', [1]), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.network)));
    });

    test('no key is refused before any request', () async {
      var calls = 0;
      final c = HttpCmatClient(base, client: MockClient((r) async {
        calls++;
        return json(201, ok201);
      }));
      await expectLater(c.uploadPhoto('', [1]), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.noKey)));
      expect(calls, 0);
    });

    test('cancel stops the upload and reports cancelled', () async {
      final gate = Completer<void>();
      final c = HttpCmatClient(base, client: MockClient((r) async {
        await gate.future;
        return json(201, ok201);
      }));
      final cancel = PhotoCancel();
      final f = c.uploadPhoto('k', List.filled(100, 1), cancel: cancel);
      cancel.cancel();
      gate.complete();
      await expectLater(f, throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.cancelled)));
      // Cancelled before it started: nothing is sent at all.
      final pre = PhotoCancel()..cancel();
      await expectLater(c.uploadPhoto('k', [1], cancel: pre), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.cancelled)));
    });
  });

  group('photo-delete and photo-report', () {
    test('delete posts {id} with the key; 404 maps to notFound', () async {
      late http.Request seen;
      final c = HttpCmatClient(base, client: MockClient((r) async {
        seen = r;
        return json(200, {'deleted': true});
      }));
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
      final c = HttpCmatClient(base, client: MockClient((r) async {
        seen.add(r);
        return json(202, {'reported': true});
      }));
      await c.reportPhoto('k3Xq9TzA', PhotoReportReason.spam);
      await c.reportPhoto('k3Xq9TzA', PhotoReportReason.childSafety, driverKey: 'drv');
      expect(seen[0].url.path, '/api/cmh/photo-report');
      expect(jsonDecode(seen[0].body), {'id': 'k3Xq9TzA', 'reason': 'spam'});
      expect(seen[0].headers.containsKey('x-driver-key'), isFalse);
      expect(jsonDecode(seen[1].body)['reason'], 'child_safety');
      expect(seen[1].headers['x-driver-key'], 'drv');
      final limited = HttpCmatClient(base, client: MockClient((r) async => json(429, {'error': 'rate', 'retryAfterS': 600})));
      await expectLater(limited.reportPhoto('x', PhotoReportReason.other),
          throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.rateLimited).having((e) => e.retryAfterS, 's', 600)));
    });
  });

  test('waitText', () {
    expect(waitText(null), 'later');
    expect(waitText(30), 'in 30 seconds');
    expect(waitText(600), 'in 10 minutes');
    expect(waitText(7200), 'in 2 hours');
  });
}
