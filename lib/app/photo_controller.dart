// Photo messages, app side (meshsonar-infra docs/planning/photo-messages-2026-11-10.md): whether the composer offers the
// photo button (server `photo-config`, cached), the upload with progress / cancel / retry, Delete photo for the person's own
// uploads, Report, and "Load photos automatically". Published in [PhotoWiring.controller] by ChatWiring; widgets take an
// injected controller in tests. The mesh only ever carries the link text.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chat/photo_kind.dart';
import '../chat/photo_prefs.dart';
import '../chat/store.dart';
import '../core/jpeg_meta.dart';
import '../core/photo_api.dart';
import '../core/photo_cache.dart';
import '../core/private_photo.dart';
import '../platform/photo_picker.dart';

/// What the composer shows for photos.
enum PhotoButton {
  /// Server says off, or it could not be reached: no button.
  hidden,

  /// Photos are on but this phone has no approved driver key: the button explains when tapped.
  needsKey,

  /// Ready.
  ready,
}

class PhotoController extends ChangeNotifier {
  final ChatStore store;

  /// The photo endpoints of the server the app talks to now (null = none).
  final PhotoTransport? Function() transport;
  final String? Function() driverKey;
  final bool Function() keyApproved;
  final PhotoSource source;
  final PhotoPicker picker;
  final int Function() nowMs;

  /// How long a `photo-config` answer is trusted before it is read again.
  static const Duration configTtl = Duration(minutes: 30);

  PhotoConfig? _config;
  bool _reachable = true;
  int _readAtMs = 0;
  Future<void>? _refreshing;
  Set<String> _own;
  bool _autoLoad;

  PhotoController({
    required this.store,
    required this.transport,
    required this.driverKey,
    required this.keyApproved,
    required this.source,
    required this.picker,
    int Function()? nowMs,
  })  : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _own = loadOwnPhotoIds(store),
        _autoLoad = loadPhotosAutoLoad(store) {
    final c = loadCachedPhotoConfig(store);
    if (c != null) {
      _config = c.config;
      _readAtMs = c.atMs;
    }
  }

  PhotoConfig get config => _config ?? PhotoConfig.disabled;

  PhotoButton get button {
    if (!_reachable || !config.enabled || transport() == null) return PhotoButton.hidden;
    if ((driverKey() ?? '').isEmpty || !keyApproved()) return PhotoButton.needsKey;
    return PhotoButton.ready;
  }

  /// Reads `photo-config` when the cached answer is older than [configTtl] (or [force]). Unreachable hides the button
  /// until the next successful read.
  Future<void> refreshConfig({bool force = false}) {
    if (!force && _config != null && nowMs() - _readAtMs < configTtl.inMilliseconds && _reachable) return Future.value();
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    final t = transport();
    if (t == null) return;
    final before = button;
    try {
      final c = await t.photoConfig();
      _config = c;
      _reachable = true;
      _readAtMs = nowMs();
      saveCachedPhotoConfig(store, c, _readAtMs);
    } catch (_) {
      _reachable = false;
    }
    if (button != before) notifyListeners();
  }

  /// The photo button for a conversation of [kind]. A private conversation never falls back to a plain link: without the
  /// server's `e2e: true` (photo-config) its button is hidden.
  PhotoButton buttonFor(PhotoKind kind) {
    final b = button;
    if (kind == PhotoKind.private && !config.e2e) return PhotoButton.hidden;
    return b;
  }

  /// The driver key or its approval changed (AppState): the button may change between "explain" and "ready".
  void keyStateChanged() => notifyListeners();

  // ---------- upload ----------

  /// Uploads prepared JPEG bytes. Throws [PhotoError]. The id is remembered as this phone's own.
  Future<PhotoUploadResult> upload(List<int> jpeg, {void Function(int sent, int total)? onProgress, PhotoCancel? cancel}) async {
    final t = transport();
    if (t == null) throw const PhotoError(PhotoErrorKind.network);
    final key = driverKey() ?? '';
    if (key.isEmpty) throw const PhotoError(PhotoErrorKind.noKey);
    if (jpeg.length > config.maxUploadBytes && config.enabled) throw const PhotoError(PhotoErrorKind.tooLarge, status: 413);
    try {
      final r = await t.uploadPhoto(key, jpeg, onProgress: onProgress, cancel: cancel);
      addOwnPhotoId(store, r.id);
      _own = loadOwnPhotoIds(store);
      notifyListeners();
      return r;
    } on PhotoError catch (e) {
      if (e.kind == PhotoErrorKind.disabled) {
        _config = PhotoConfig.disabled;
        notifyListeners();
      }
      rethrow;
    }
  }

  /// Private (end-to-end encrypted) upload of [full] with its [thumb]. Both JPEGs are proven free of EXIF and GPS, then
  /// encrypted under a fresh key on this phone; only ciphertext is sent. Returns the result with `url` = the private link
  /// (`https://meshsonar.com/e/<id>#<key>`), the only place the key goes. Throws [PhotoError], or [PhotoPrepareException]
  /// when a picture could not be proven clean. The key is never logged or put in an error.
  Future<PhotoUploadResult> uploadPrivate(PreparedPhoto full, PreparedPhoto thumb, {void Function(int sent, int total)? onProgress, PhotoCancel? cancel}) async {
    final t = transport();
    if (t == null) throw const PhotoError(PhotoErrorKind.network);
    final driver = driverKey() ?? '';
    if (driver.isEmpty) throw const PhotoError(PhotoErrorKind.noKey);
    // Never a plain link for a private conversation, so without e2e on the server there is nothing to send.
    if (!config.e2e) throw const PhotoError(PhotoErrorKind.disabled);
    for (final b in [full.bytes, thumb.bytes]) {
      if (!jpegIsClean(b)) throw const PhotoPrepareException('Could not remove the photo details (like location) safely, so it was not sent.');
    }
    final enc = await PrivatePhoto.encrypt(thumb.bytes, full.bytes);
    final body = enc.uploadBody;
    if (enc.thumbBlob.length > PrivatePhoto.maxThumbBlobBytes || body.length > config.maxUploadBytes) throw const PhotoError(PhotoErrorKind.tooLarge, status: 413);
    int dim(int v, int fallback) => v > 0 ? v.clamp(1, 16384) : fallback;
    final w = dim(full.width, config.maxEdgePx), h = dim(full.height, (config.maxEdgePx * 3 / 4).round());
    try {
      final r = await t.uploadPrivatePhoto(driver, body, width: w, height: h, onProgress: onProgress, cancel: cancel);
      addOwnPhotoId(store, r.id);
      _own = loadOwnPhotoIds(store);
      notifyListeners();
      return r.withUrl(buildPrivatePhotoLink(r.id, enc.key));
    } on PhotoError catch (e) {
      if (e.kind == PhotoErrorKind.disabled) {
        _config = PhotoConfig.disabled;
        notifyListeners();
      }
      rethrow;
    }
  }

  // ---------- own photos, delete, report ----------

  bool isOwn(String id) => _own.contains(id);

  /// Deletes an own photo on the server; 404 (already gone) counts as done. Throws [PhotoError] otherwise.
  Future<void> delete(String url) async {
    final id = anyPhotoIdOf(url);
    if (id == null) return;
    final t = transport();
    final key = driverKey() ?? '';
    if (t == null) throw const PhotoError(PhotoErrorKind.network);
    if (key.isEmpty) throw const PhotoError(PhotoErrorKind.noKey);
    try {
      await t.deletePhoto(key, id);
    } on PhotoError catch (e) {
      if (e.kind != PhotoErrorKind.notFound) rethrow;
    }
    removeOwnPhotoId(store, id);
    _own = loadOwnPhotoIds(store);
    await source.forget(url);
    notifyListeners();
  }

  /// [shareKey]: the reporter chose "Let moderators see this photo"; only then (and only for a private photo) the key from
  /// the link goes to the server with the report. Throws [PhotoError].
  Future<void> report(String url, PhotoReportReason reason, {bool shareKey = false}) async {
    final id = anyPhotoIdOf(url);
    if (id == null) return;
    final t = transport();
    if (t == null) throw const PhotoError(PhotoErrorKind.network);
    final key = driverKey();
    final evidence = shareKey ? parsePrivatePhotoLink(url)?.keyText : null;
    await t.reportPhoto(id, reason, driverKey: (key ?? '').isEmpty ? null : key, key: evidence);
  }

  // ---------- setting ----------

  bool get autoLoad => _autoLoad;
  set autoLoad(bool on) {
    if (on == _autoLoad) return;
    _autoLoad = on;
    savePhotosAutoLoad(store, on);
    notifyListeners();
  }
}

class PhotoWiring {
  PhotoWiring._();

  /// The live photo controller; null until chat is open (and in tests unless set).
  static final ValueNotifier<PhotoController?> controller = ValueNotifier<PhotoController?>(null);
}
