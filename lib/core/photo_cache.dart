// On-disk cache of photo images (thumbs and full copies) read from `https://meshsonar.com/p/<id>/thumb|full`, and of private
// photos (`https://meshsonar.com/e/<id>#<key>`: the ciphertext is fetched from `/e/<id>/thumb|full`, decrypted in memory with
// the key from the link and only the DECRYPTED JPEG is kept, like any chat attachment; the key itself is never stored here).
// One file per image, `<id>_<thumb|full>.img` (private: `e_<id>_...`); a removed photo (410, or 404 for a private one) leaves
// a small `<id>.gone` marker so the bubble says "Photo removed" / "Photo expired" without asking again. The folder is trimmed to [maxBytes], oldest first. Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'photo_api.dart';
import 'private_photo.dart';

enum PhotoVariant { thumb, full }

enum PhotoFetchState { ok, removed, failed }

class PhotoFetch {
  final PhotoFetchState state;
  final List<int>? bytes;
  const PhotoFetch.ok(List<int> this.bytes) : state = PhotoFetchState.ok;
  const PhotoFetch.removed()
      : state = PhotoFetchState.removed,
        bytes = null;
  const PhotoFetch.failed()
      : state = PhotoFetchState.failed,
        bytes = null;
}

/// Where the bubbles and the viewer get their pictures. [HttpPhotoCache] in the app; a fixture source in tests and in the
/// debug screenshot build.
abstract class PhotoSource {
  /// The bytes already on this phone, or null (no network). Lets a bubble draw at once when the photo was seen before.
  Future<List<int>?> cached(String url, PhotoVariant v);

  /// True when this photo is known to be removed (410 seen before).
  Future<bool> knownRemoved(String url);

  /// Reads from the cache, else the network.
  Future<PhotoFetch> fetch(String url, PhotoVariant v);

  /// Forgets everything about one photo (after the owner deletes it).
  Future<void> forget(String url);
}

class HttpPhotoCache implements PhotoSource {
  final Directory dir;
  final http.Client _http;
  final int maxBytes;
  final Duration timeout;
  final Map<String, Future<PhotoFetch>> _inflight = {};
  int _writes = 0;

  HttpPhotoCache(this.dir, {http.Client? client, this.maxBytes = 150 * 1024 * 1024, this.timeout = const Duration(seconds: 30)})
      : _http = client ?? http.Client();

  /// The file stem of a photo link: `<id>` for a plain one, `e_<id>` for a private one; null for anything else.
  String? _id(String url) {
    final plain = photoIdOf(url);
    if (plain != null) return plain;
    final p = parsePrivatePhotoLink(url);
    return p == null ? null : 'e_${p.id}';
  }

  File _file(String id, PhotoVariant v) => File('${dir.path}${Platform.pathSeparator}${id}_${v.name}.img');
  File _gone(String id) => File('${dir.path}${Platform.pathSeparator}$id.gone');

  @override
  Future<List<int>?> cached(String url, PhotoVariant v) async {
    final id = _id(url);
    if (id == null) return null;
    final f = _file(id, v);
    try {
      if (await f.exists()) {
        final b = await f.readAsBytes();
        unawaited(f.setLastModified(DateTime.now()).catchError((_) {}));
        return b.isEmpty ? null : b;
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<bool> knownRemoved(String url) async {
    final id = _id(url);
    if (id == null) return false;
    try {
      return await _gone(id).exists();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PhotoFetch> fetch(String url, PhotoVariant v) {
    final key = '$url|${v.name}';
    // The block body matters: `=> _inflight.remove(key)` would return this very future and whenComplete would wait on itself.
    return _inflight[key] ??= _fetch(url, v).whenComplete(() {
      _inflight.remove(key);
    });
  }

  Future<PhotoFetch> _fetch(String url, PhotoVariant v) async {
    final id = _id(url);
    if (id == null) return const PhotoFetch.failed();
    if (await knownRemoved(url)) return const PhotoFetch.removed();
    final hit = await cached(url, v);
    if (hit != null) return PhotoFetch.ok(hit);
    final link = parsePrivatePhotoLink(url);
    final role = v == PhotoVariant.thumb ? PrivatePhotoRole.thumb : PrivatePhotoRole.full;
    final target = link != null ? link.blobUrl(role) : (v == PhotoVariant.thumb ? photoThumbUrl(url) : photoFullUrl(url));
    http.Response res;
    try {
      res = await _http.get(Uri.parse(target), headers: {'accept': link != null ? 'application/octet-stream' : 'image/webp,image/*'}).timeout(timeout);
    } catch (_) {
      return const PhotoFetch.failed();
    }
    // A private photo is deleted after 30 days: an unknown id (404) and a removed one (410) both read as gone.
    if (res.statusCode == 410 || (link != null && res.statusCode == 404)) {
      try {
        await dir.create(recursive: true);
        await _gone(id).writeAsString('410');
        await _file(id, PhotoVariant.thumb).delete().catchError((_) => File(''));
        await _file(id, PhotoVariant.full).delete().catchError((_) => File(''));
      } catch (_) {}
      return const PhotoFetch.removed();
    }
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) return const PhotoFetch.failed();
    List<int> image = res.bodyBytes;
    if (link != null) {
      try {
        image = await PrivatePhoto.decrypt(res.bodyBytes, link.key, role);
      } catch (_) {
        // Wrong key, damaged blob: nothing is cached and nothing about the key is reported.
        return const PhotoFetch.failed();
      }
    }
    try {
      await dir.create(recursive: true);
      final f = _file(id, v);
      final tmp = File('${f.path}.part');
      await tmp.writeAsBytes(image, flush: true);
      await tmp.rename(f.path);
      if (++_writes % 20 == 1) unawaited(trim());
    } catch (_) {}
    return PhotoFetch.ok(image);
  }

  @override
  Future<void> forget(String url) async {
    final id = _id(url);
    if (id == null) return;
    for (final f in [_file(id, PhotoVariant.thumb), _file(id, PhotoVariant.full)]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    try {
      await dir.create(recursive: true);
      await _gone(id).writeAsString('deleted');
    } catch (_) {}
  }

  /// Keeps the folder under [maxBytes], deleting the least recently used images first.
  Future<void> trim() async {
    try {
      if (!await dir.exists()) return;
      final files = <(File, int, DateTime)>[];
      var total = 0;
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.img')) continue;
        final st = await e.stat();
        files.add((e, st.size, st.modified));
        total += st.size;
      }
      if (total <= maxBytes) return;
      files.sort((a, b) => a.$3.compareTo(b.$3));
      for (final f in files) {
        if (total <= maxBytes) break;
        try {
          await f.$1.delete();
          total -= f.$2;
        } catch (_) {}
      }
    } catch (_) {}
  }
}
