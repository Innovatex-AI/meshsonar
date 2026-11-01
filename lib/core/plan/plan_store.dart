// Last-good-result store for the Plan tools: one JSON file per key (the raw server body plus when it was fetched), so a tool
// reopened offline still shows its last answer, labelled "as of". Same atomic-write and small-LRU pattern as the region
// cache (lib/core/region_cache.dart) but its own directory, so "Clear cache" in Data & storage leaves the tools alone and
// the tools never evict region data. Null directory = memory only (tests, no file system). Pure Dart.
import 'dart:convert';
import 'dart:io';

class StoredResult {
  final String body;
  final DateTime at;
  const StoredResult(this.body, this.at);
}

class PlanStore {
  final Directory? dir;
  final int maxEntries;
  final DateTime Function() clock;
  final Map<String, StoredResult> _mem = {};
  PlanStore({this.dir, this.maxEntries = 30, DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  File? _file(String key) => dir == null ? null : File('${dir!.path}${Platform.pathSeparator}pt_${key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.json');

  Future<StoredResult?> read(String key) async {
    final m = _mem[key];
    if (m != null) return m;
    try {
      final f = _file(key);
      if (f == null || !await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['body'] is! String) return null;
      final at = DateTime.tryParse('${j['at']}');
      if (at == null) return null;
      return _mem[key] = StoredResult(j['body'] as String, at);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, String body) async {
    final at = clock().toUtc();
    _mem[key] = StoredResult(body, at);
    try {
      final f = _file(key);
      if (f == null) return;
      await dir!.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({'key': key, 'body': body, 'at': at.toIso8601String()}), flush: true);
      await tmp.rename(f.path);
      await _evict();
    } catch (_) {
      // A full or read-only disk only costs the cache.
    }
  }

  Future<void> _evict() async {
    final d = dir;
    if (d == null) return;
    final files = <(File, DateTime)>[];
    await for (final e in d.list()) {
      if (e is File && e.path.endsWith('.json')) files.add((e, (await e.stat()).modified));
    }
    if (files.length <= maxEntries) return;
    files.sort((a, b) => a.$2.compareTo(b.$2));
    for (final f in files.take(files.length - maxEntries)) {
      try {
        await f.$1.delete();
      } catch (_) {}
    }
  }

  Future<void> clear() async {
    _mem.clear();
    final d = dir;
    if (d == null) return;
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}
