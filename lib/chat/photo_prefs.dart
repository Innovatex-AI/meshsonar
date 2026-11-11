// Photo message preferences, kept in the chat `settings` table (like quick replies): "Load photos automatically" (on by
// default), the ids of photos this phone uploaded (so the viewer offers Delete photo only for them), and the last answer of
// `photo-config` with when it was read. Pure Dart.
import 'dart:convert';

import '../core/photo_api.dart';
import 'store.dart';

const String photosAutoLoadKey = 'photos_autoload';
const String ownPhotoIdsKey = 'photos_own_ids';
const String photoConfigKey = 'photos_config';

/// On unless switched off.
bool loadPhotosAutoLoad(ChatStore store) => store.db.setting(photosAutoLoadKey) != '0';

void savePhotosAutoLoad(ChatStore store, bool on) => store.db.putSetting(photosAutoLoadKey, on ? null : '0');

/// At most this many own ids are remembered (newest kept).
const int maxOwnPhotoIds = 2000;

Set<String> loadOwnPhotoIds(ChatStore store) {
  final raw = store.db.setting(ownPhotoIdsKey);
  if (raw == null) return <String>{};
  try {
    final v = jsonDecode(raw);
    if (v is List) return {for (final e in v) if (e is String) e};
  } catch (_) {}
  return <String>{};
}

void addOwnPhotoId(ChatStore store, String id) {
  final ids = loadOwnPhotoIds(store).toList()
    ..remove(id)
    ..add(id);
  final keep = ids.length > maxOwnPhotoIds ? ids.sublist(ids.length - maxOwnPhotoIds) : ids;
  store.db.putSetting(ownPhotoIdsKey, jsonEncode(keep));
}

void removeOwnPhotoId(ChatStore store, String id) {
  final ids = loadOwnPhotoIds(store)..remove(id);
  store.db.putSetting(ownPhotoIdsKey, ids.isEmpty ? null : jsonEncode(ids.toList()));
}

/// The cached `photo-config` answer and when it was read (ms), or null.
({PhotoConfig config, int atMs})? loadCachedPhotoConfig(ChatStore store) {
  final raw = store.db.setting(photoConfigKey);
  if (raw == null) return null;
  try {
    final v = jsonDecode(raw);
    if (v is Map && v['at'] is num && v['config'] is Map) {
      return (config: PhotoConfig.parse((v['config'] as Map).cast<String, dynamic>()), atMs: (v['at'] as num).toInt());
    }
  } catch (_) {}
  return null;
}

void saveCachedPhotoConfig(ChatStore store, PhotoConfig c, int atMs) =>
    store.db.putSetting(photoConfigKey, jsonEncode({'at': atMs, 'config': c.toJson()}));
