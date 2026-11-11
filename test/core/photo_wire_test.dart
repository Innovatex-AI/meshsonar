// IoPhotoWire (the real dart:io socket under photo uploads) against a local loopback server: head, body and answer arrive
// intact through HttpCmatClient.uploadPhoto, progress ends at the full size, and abort ends a request in flight.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/core/photo_wire.dart';

void main() {
  late HttpServer server;
  final seen = <(String, String?, String?, int)>[];
  Completer<void>? holdAnswer;
  setUp(() async {
    seen.clear();
    holdAnswer = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      seen.add((req.uri.path, req.headers.value('x-driver-key'), req.headers.contentType?.mimeType, body.length));
      if (holdAnswer != null) await holdAnswer!.future;
      req.response
        ..statusCode = 201
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'id': 'k3Xq9TzA', 'url': 'https://meshsonar.com/p/k3Xq9TzA', 'bytes': body.length}));
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  test('uploads over a real socket with progress to the full size', () async {
    final c = HttpCmatClient(Uri.parse('http://127.0.0.1:${server.port}'), photoWire: const IoPhotoWire());
    final body = List<int>.generate(300 * 1000, (i) => i % 256);
    final progress = <int>[];
    final r = await c.uploadPhoto('drv-1', body, onProgress: (s, t) => progress.add(s));
    expect(r.id, 'k3Xq9TzA');
    expect(r.bytes, body.length);
    expect(seen.single, ('/api/cmh/photo-upload', 'drv-1', 'image/jpeg', body.length));
    expect(progress.last, body.length);
    expect(progress.length, (body.length / HttpCmatClient.photoChunkBytes).ceil() + 1);
  });

  test('cancel while waiting for the answer aborts the socket', () async {
    holdAnswer = Completer<void>();
    final c = HttpCmatClient(Uri.parse('http://127.0.0.1:${server.port}'), photoWire: const IoPhotoWire());
    final cancel = PhotoCancel();
    final f = c.uploadPhoto('k', List<int>.filled(1000, 1), cancel: cancel, onProgress: (s, t) {
      if (s == t) Timer(const Duration(milliseconds: 50), cancel.cancel);
    });
    await expectLater(f, throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.cancelled)));
    holdAnswer!.complete();
  });

  test('nothing listening is a network error', () async {
    final port = server.port;
    await server.close(force: true);
    final c = HttpCmatClient(Uri.parse('http://127.0.0.1:$port'), photoWire: const IoPhotoWire());
    await expectLater(c.uploadPhoto('k', [1, 2, 3]), throwsA(isA<PhotoError>().having((e) => e.kind, 'kind', PhotoErrorKind.network)));
  });
}
