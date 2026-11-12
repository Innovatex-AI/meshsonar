// Fakes for the photo-message tests: a transport that answers per contract v1 without a server, a picture source that hands
// back fixed states, a picker that returns a prepared photo, a socket ([FakePhotoWire]) for HttpCmatClient's upload that
// drains at a set rate on (fake) time, stalls or drops on demand, and a tiny real PNG to draw.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meshsonar/app/photo_controller.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/core/jpeg_meta.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/core/photo_cache.dart';
import 'package:meshsonar/core/photo_wire.dart';
import 'package:meshsonar/platform/photo_picker.dart';

/// A 2x2 opaque PNG (blue), small enough to inline.
final Uint8List tinyPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGOI6jkBRAwQCgAtXga5P89JmQAAAABJRU5ErkJggg==');

/// A real, metadata-free JPEG (the GPS fixture of test/core/jpeg_meta_test.dart after the strip): what a private upload accepts.
final Uint8List cleanJpeg = stripJpegMetadata(File('test/fixtures/photos/gps_fixture.jpg').readAsBytesSync());

/// The private link of photo id k3Xq9TzA under the golden-vector key (fixed, so tests can predict it).
const privateKeyA = 'AAECAwQFBgcICQoLDA0ODw';
const privateUrlA = 'https://meshsonar.com/e/k3Xq9TzA#$privateKeyA';

const photoUrlA = 'https://meshsonar.com/p/k3Xq9TzA';
const photoUrlB = 'https://meshsonar.com/p/Zz00Aa11';

class FakePhotoTransport implements PhotoTransport {
  PhotoConfig config = const PhotoConfig(enabled: true, e2e: true);
  Object? configError;
  Object? uploadError;
  String nextId = 'k3Xq9TzA';
  Completer<void>? holdUpload;

  /// Holds the answer after the whole body was reported out (the composer then says "Processing…").
  Completer<void>? holdAnswer;
  final uploads = <int>[];
  final uploadedBytes = <List<int>>[];
  final deletes = <String>[];
  final reports = <(String, PhotoReportReason, String?)>[];

  /// The `key` of each report, in order (null = the reporter did not let moderators see the photo).
  final reportKeys = <String?>[];

  /// Private uploads: the whole body, and the headers' width and height.
  final privateBodies = <List<int>>[];
  final privateSizes = <(int, int)>[];
  Object? deleteError;

  @override
  Future<PhotoConfig> photoConfig() async {
    if (configError != null) throw configError!;
    return config;
  }

  @override
  Future<PhotoUploadResult> uploadPhoto(String driverKey, List<int> bytes,
      {String contentType = 'image/jpeg', void Function(int sent, int total)? onProgress, PhotoCancel? cancel}) async {
    uploads.add(bytes.length);
    uploadedBytes.add(bytes);
    onProgress?.call(bytes.length ~/ 2, bytes.length);
    final h = holdUpload;
    if (h != null) {
      await Future.any([h.future, if (cancel != null) cancel.whenCancelled]);
      if (cancel?.cancelled ?? false) throw const PhotoError(PhotoErrorKind.cancelled);
    }
    onProgress?.call(bytes.length, bytes.length);
    final a = holdAnswer;
    if (a != null) {
      await Future.any([a.future, if (cancel != null) cancel.whenCancelled]);
      if (cancel?.cancelled ?? false) throw const PhotoError(PhotoErrorKind.cancelled);
    }
    if (uploadError != null) throw uploadError!;
    final url = 'https://meshsonar.com/p/$nextId';
    return PhotoUploadResult(id: nextId, url: url, thumbUrl: '$url/thumb', fullUrl: '$url/full');
  }

  @override
  Future<PhotoUploadResult> uploadPrivatePhoto(String driverKey, List<int> body,
      {required int width, required int height, void Function(int sent, int total)? onProgress, PhotoCancel? cancel}) async {
    privateBodies.add(body);
    privateSizes.add((width, height));
    onProgress?.call(body.length ~/ 2, body.length);
    final h = holdUpload;
    if (h != null) {
      await Future.any([h.future, if (cancel != null) cancel.whenCancelled]);
      if (cancel?.cancelled ?? false) throw const PhotoError(PhotoErrorKind.cancelled);
    }
    onProgress?.call(body.length, body.length);
    final a = holdAnswer;
    if (a != null) {
      await Future.any([a.future, if (cancel != null) cancel.whenCancelled]);
      if (cancel?.cancelled ?? false) throw const PhotoError(PhotoErrorKind.cancelled);
    }
    if (uploadError != null) throw uploadError!;
    final url = 'https://meshsonar.com/e/$nextId';
    return PhotoUploadResult(id: nextId, url: url, thumbUrl: '$url/thumb', fullUrl: '$url/full');
  }

  @override
  Future<void> deletePhoto(String driverKey, String id) async {
    if (deleteError != null) throw deleteError!;
    deletes.add(id);
  }

  @override
  Future<void> reportPhoto(String id, PhotoReportReason reason, {String? driverKey, String? key}) async {
    reports.add((id, reason, driverKey));
    reportKeys.add(key);
  }
}

/// Answers every photo with one state (per url when set in [byUrl]).
class FakePhotoSource implements PhotoSource {
  PhotoFetchState state;
  final Map<String, PhotoFetchState> byUrl = {};
  final Set<String> cachedUrls = {};
  final fetches = <String>[];
  final forgotten = <String>[];
  Completer<void>? hold;
  FakePhotoSource({this.state = PhotoFetchState.ok});

  PhotoFetchState _of(String url) => byUrl[url] ?? state;

  @override
  Future<List<int>?> cached(String url, PhotoVariant v) async => cachedUrls.contains(url) ? tinyPng : null;

  @override
  Future<bool> knownRemoved(String url) async => false;

  @override
  Future<PhotoFetch> fetch(String url, PhotoVariant v) async {
    fetches.add('$url|${v.name}');
    if (hold != null) await hold!.future;
    return switch (_of(url)) {
      PhotoFetchState.ok => PhotoFetch.ok(tinyPng),
      PhotoFetchState.removed => const PhotoFetch.removed(),
      PhotoFetchState.failed => const PhotoFetch.failed(),
    };
  }

  @override
  Future<void> forget(String url) async => forgotten.add(url);
}

class FakePhotoPicker implements PhotoPicker {
  PreparedPhoto? next = PreparedPhoto(tinyPng, 2, 2);

  /// What [thumbnail] returns (a clean JPEG by default); [thumbError] makes it throw.
  PreparedPhoto thumbNext = PreparedPhoto(cleanJpeg, 1, 1);
  Object? thumbError;
  int thumbnails = 0;
  Object? error;
  final picks = <PhotoPickSource>[];
  @override
  Future<PreparedPhoto?> pick(PhotoPickSource source, {int maxEdgePx = 2048}) async {
    picks.add(source);
    if (error != null) throw error!;
    return next;
  }

  @override
  Future<PreparedPhoto> thumbnail(PreparedPhoto full, {int edge = 480, int quality = 70}) async {
    thumbnails++;
    if (thumbError != null) throw thumbError!;
    return thumbNext;
  }
}

PhotoController fakePhotos(ChatStore store,
        {FakePhotoTransport? transport, FakePhotoSource? source, FakePhotoPicker? picker, String? key = 'drv-key', bool approved = true}) =>
    PhotoController(
      store: store,
      transport: () => transport ?? FakePhotoTransport(),
      driverKey: () => key,
      keyApproved: () => approved,
      source: source ?? FakePhotoSource(),
      picker: picker ?? FakePhotoPicker(),
      nowMs: () => DateTime(2026, 11, 10, 12).millisecondsSinceEpoch,
    );

/// The socket under HttpCmatClient.uploadPhoto, without a network. Each write completes after `chunk / bytesPerSecond` of
/// (fake) time; [stallAfterBytes] makes the write that would pass it hang until abort; [connectError] / [writeError] throw;
/// [answer] builds the reply from the request ([answerDelay] later, or never when [neverAnswer]).
class FakePhotoWire implements PhotoWire {
  int? bytesPerSecond;
  int? stallAfterBytes;
  Object? connectError;
  Object? writeError;
  bool neverAnswer = false;
  Duration answerDelay = Duration.zero;
  PhotoWireResponse Function(FakeWireRequest r) answer = (r) => PhotoWireResponse(201, utf8.encode(jsonEncode({
        'id': 'k3Xq9TzA',
        'url': 'https://meshsonar.com/p/k3Xq9TzA',
        'thumbUrl': 'https://meshsonar.com/p/k3Xq9TzA/thumb',
        'fullUrl': 'https://meshsonar.com/p/k3Xq9TzA/full',
        'w': 2048,
        'h': 1536,
        'bytes': r.body.length,
        'duplicate': false,
      })), headers: const {'content-type': 'application/json'});
  final requests = <FakeWireRequest>[];

  /// Called after each accepted write with the bytes taken so far (to compare with the reported progress).
  void Function(int written)? onWritten;

  @override
  Future<PhotoWireRequest> open(String method, Uri url, Map<String, String> headers, int contentLength) async {
    if (connectError != null) throw connectError!;
    final r = FakeWireRequest(this, method, url, headers, contentLength);
    requests.add(r);
    return r;
  }
}

class FakeWireRequest implements PhotoWireRequest {
  final FakePhotoWire wire;
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final int contentLength;
  final body = <int>[];
  bool aborted = false;
  bool finished = false;
  final Completer<void> _abort = Completer<void>();
  FakeWireRequest(this.wire, this.method, this.url, this.headers, this.contentLength);

  Future<void> _hang() async {
    await _abort.future;
    throw const SocketException('connection aborted');
  }

  @override
  Future<void> write(List<int> chunk) async {
    if (aborted) throw const SocketException('connection aborted');
    if (wire.writeError != null) throw wire.writeError!;
    final stall = wire.stallAfterBytes;
    if (stall != null && body.length + chunk.length > stall) return _hang();
    final rate = wire.bytesPerSecond;
    if (rate != null) {
      await Future.any([Future<void>.delayed(Duration(microseconds: chunk.length * 1000000 ~/ rate)), _abort.future]);
      if (aborted) throw const SocketException('connection aborted');
    }
    body.addAll(chunk);
    wire.onWritten?.call(body.length);
  }

  @override
  Future<PhotoWireResponse> finish() async {
    finished = true;
    if (wire.neverAnswer) {
      await _hang();
    }
    if (wire.answerDelay > Duration.zero) await Future.any([Future<void>.delayed(wire.answerDelay), _abort.future]);
    if (aborted) throw const SocketException('connection aborted');
    return wire.answer(this);
  }

  @override
  void abort() {
    aborted = true;
    if (!_abort.isCompleted) _abort.complete();
  }
}
