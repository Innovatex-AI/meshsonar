// Fakes for the photo-message tests: a transport that answers per contract v1 without a server, a picture source that hands
// back fixed states, a picker that returns a prepared photo, and a tiny real PNG to draw.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meshsonar/app/photo_controller.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/core/photo_api.dart';
import 'package:meshsonar/core/photo_cache.dart';
import 'package:meshsonar/platform/photo_picker.dart';

/// A 2x2 opaque PNG (blue), small enough to inline.
final Uint8List tinyPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGOI6jkBRAwQCgAtXga5P89JmQAAAABJRU5ErkJggg==');

const photoUrlA = 'https://meshsonar.com/p/k3Xq9TzA';
const photoUrlB = 'https://meshsonar.com/p/Zz00Aa11';

class FakePhotoTransport implements PhotoTransport {
  PhotoConfig config = const PhotoConfig(enabled: true);
  Object? configError;
  Object? uploadError;
  String nextId = 'k3Xq9TzA';
  Completer<void>? holdUpload;
  final uploads = <int>[];
  final deletes = <String>[];
  final reports = <(String, PhotoReportReason, String?)>[];
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
    onProgress?.call(bytes.length ~/ 2, bytes.length);
    final h = holdUpload;
    if (h != null) {
      await Future.any([h.future, if (cancel != null) cancel.whenCancelled]);
      if (cancel?.cancelled ?? false) throw const PhotoError(PhotoErrorKind.cancelled);
    }
    onProgress?.call(bytes.length, bytes.length);
    if (uploadError != null) throw uploadError!;
    final url = 'https://meshsonar.com/p/$nextId';
    return PhotoUploadResult(id: nextId, url: url, thumbUrl: '$url/thumb', fullUrl: '$url/full');
  }

  @override
  Future<void> deletePhoto(String driverKey, String id) async {
    if (deleteError != null) throw deleteError!;
    deletes.add(id);
  }

  @override
  Future<void> reportPhoto(String id, PhotoReportReason reason, {String? driverKey}) async => reports.add((id, reason, driverKey));
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
  Object? error;
  final picks = <PhotoPickSource>[];
  @override
  Future<PreparedPhoto?> pick(PhotoPickSource source, {int maxEdgePx = 2048}) async {
    picks.add(source);
    if (error != null) throw error!;
    return next;
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
