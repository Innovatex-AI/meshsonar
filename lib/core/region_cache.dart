// Disk cache for per-region data (site-config, coverage, ...): one JSON file per key in a directory, with the
// server's ETag, the fetch time (the "as of" label) and an LRU cap so a person who drives through many regions
// never fills the phone. Pure Dart. Spec: parity spec WP-R5.
//
// Contract with the network layer: [RegionCache.fetch] hands the loader the cached ETag; the loader returns
// [CacheFetch.fresh] (200 + body + new ETag) or [CacheFetch.notModified] (304), or throws (offline / server down).
// A throw serves the cached copy flagged `offline` so the UI can say "Offline - as of 2h ago" instead of lying.
import 'dart:convert';
import 'dart:io';

import 'api.dart';
import 'storage_usage.dart';

class CacheFetch {
  final bool notModified;
  final String? body;
  final String? etag;
  const CacheFetch.fresh(String this.body, {this.etag}) : notModified = false;
  const CacheFetch.notModified()
      : notModified = true,
        body = null,
        etag = null;
}

class CachedBody {
  final String body;
  final String? etag;
  final DateTime fetchedAt;

  /// True when the live fetch failed and [body] is the stored copy.
  final bool offline;
  const CachedBody({required this.body, required this.etag, required this.fetchedAt, required this.offline});
}

class RegionCache implements StorageSized {
  final Directory dir;
  final int maxEntries;
  final DateTime Function() clock;
  RegionCache(this.dir, {this.maxEntries = 40, DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  File _file(String key) => File('${dir.path}${Platform.pathSeparator}rc_${_safe(key)}.json');
  static String _safe(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  Future<CachedBody?> read(String key, {bool offline = false}) async {
    try {
      final f = _file(key);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['body'] is! String || j['at'] is! String) return null;
      final at = DateTime.tryParse(j['at'] as String);
      if (at == null) return null;
      return CachedBody(body: j['body'] as String, etag: j['etag'] as String?, fetchedAt: at, offline: offline);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String body, String? etag, DateTime at) async {
    try {
      await dir.create(recursive: true);
      final f = _file(key);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({'key': key, 'body': body, 'etag': etag, 'at': at.toUtc().toIso8601String()}), flush: true);
      await tmp.rename(f.path);
      await _evict();
    } catch (_) {
      // A full or read-only disk only costs the cache.
    }
  }

  /// Drops the least recently written/used entries beyond [maxEntries].
  Future<void> _evict() async {
    final files = <(File, DateTime)>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.contains('${Platform.pathSeparator}rc_') && e.path.endsWith('.json')) {
        files.add((e, (await e.stat()).modified));
      }
    }
    if (files.length <= maxEntries) return;
    files.sort((a, b) => a.$2.compareTo(b.$2));
    for (final f in files.take(files.length - maxEntries)) {
      try {
        await f.$1.delete();
      } catch (_) {}
    }
  }

  /// Fetch [key] through [loader] (given the cached ETag). Returns null only when nothing is cached AND the load failed.
  Future<CachedBody?> fetch(String key, Future<CacheFetch> Function(String? etag) loader) async {
    final cached = await read(key);
    try {
      final r = await loader(cached?.etag);
      final now = clock();
      if (r.notModified) {
        if (cached == null) return null;
        await _write(key, cached.body, cached.etag, now); // touch: refreshes "as of" and LRU position
        return CachedBody(body: cached.body, etag: cached.etag, fetchedAt: now, offline: false);
      }
      await _write(key, r.body!, r.etag, now);
      return CachedBody(body: r.body!, etag: r.etag, fetchedAt: now, offline: false);
    } catch (_) {
      if (cached == null) return null;
      // Mark as used so a region you keep opening offline is not the one evicted.
      return CachedBody(body: cached.body, etag: cached.etag, fetchedAt: cached.fetchedAt, offline: true);
    }
  }

  bool _isEntry(String path) => path.contains('${Platform.pathSeparator}rc_') && (path.endsWith('.json') || path.endsWith('.tmp'));

  /// Bytes the cached entries use (Settings > Data & storage).
  @override
  Future<int> bytesUsed() => bytesOnDisk(dir, where: _isEntry);

  /// Deletes every cached entry (Settings > Data & storage). The next fetch of each key downloads it in full again.
  /// Returns how many entries were removed. Never throws.
  Future<int> clear() async {
    var n = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final e in dir.list()) {
        if (e is File && _isEntry(e.path)) {
          try {
            await e.delete();
            if (e.path.endsWith('.json')) n++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return n;
  }

  /// Stores [body] under [key] (fetched now) without going through [fetch].
  Future<void> put(String key, String body, {String? etag}) => _write(key, body, etag, clock());
}

/// "Offline - as of 2h ago" / "As of 5m ago". Pure so it is testable and the UI just prints it.
String asOfLabel(DateTime fetchedAt, DateTime now, {required bool offline}) {
  final d = now.difference(fetchedAt);
  String ago;
  if (d.inMinutes < 1) {
    ago = 'just now';
  } else if (d.inMinutes < 60) {
    ago = '${d.inMinutes}m ago';
  } else if (d.inHours < 48) {
    ago = '${d.inHours}h ago';
  } else {
    ago = '${d.inDays}d ago';
  }
  final stamp = ago == 'just now' ? ago : 'as of $ago';
  return offline ? 'Offline - $stamp' : 'Updated $ago';
}

// ---- codecs: the parsed models <-> the JSON stored on disk (our own shape, versioned by field presence) ----

String siteConfigToJson(SiteConfig c) => jsonEncode({
      'region': {'slug': c.region.slug, 'url': c.region.url},
      'preset': c.radioPreset == null
          ? null
          : {'name': c.radioPreset!.name, 'f': c.radioPreset!.freqMhz, 'bw': c.radioPreset!.bwKhz, 'sf': c.radioPreset!.sf, 'cr': c.radioPreset!.cr},
    });

SiteConfig? siteConfigFromJson(String s) {
  try {
    final j = jsonDecode(s) as Map;
    final r = j['region'] as Map;
    final p = j['preset'];
    return SiteConfig(
      region: RegionInfo(slug: r['slug'] as String, url: r['url'] as String),
      radioPreset: p is Map
          ? RadioPreset(
              name: p['name'] as String, freqMhz: (p['f'] as num).toDouble(), bwKhz: (p['bw'] as num).toDouble(), sf: (p['sf'] as num).toInt(), cr: (p['cr'] as num).toInt())
          : null,
    );
  } catch (_) {
    return null;
  }
}

String publicCoverageToJson(PublicCoverage c) => jsonEncode({
      'asOf': c.asOf,
      'grid': {'kind': c.grid.kind == CoverageGridKind.h3 ? 'h3' : 'square', 'cellDeg': c.grid.cellDeg, 'res': c.grid.res, 'pending': c.grid.pending},
      'cells': [
        for (final x in c.cells)
          [x.lat, x.lon, x.pings, x.heard, x.bestSnr, x.medianSnr, x.repeaters, x.lastAt, x.h3, x.noiseFloor],
      ],
    });

PublicCoverage? publicCoverageFromJson(String s) {
  try {
    final j = jsonDecode(s) as Map;
    final g = j['grid'] as Map;
    final grid = g['kind'] == 'h3'
        ? CoverageGrid.h3(res: (g['res'] as num).toInt(), cellDeg: (g['cellDeg'] as num).toDouble(), pending: (g['pending'] as num).toInt())
        : CoverageGrid.square(cellDeg: (g['cellDeg'] as num).toDouble());
    final cells = <CoverageCell>[
      for (final c in j['cells'] as List)
        CoverageCell(
          lat: ((c as List)[0] as num).toDouble(),
          lon: (c[1] as num).toDouble(),
          pings: (c[2] as num).toInt(),
          heard: (c[3] as num).toInt(),
          bestSnr: (c[4] as num?)?.toDouble(),
          medianSnr: (c[5] as num?)?.toDouble(),
          repeaters: (c[6] as num).toInt(),
          lastAt: c[7] as String,
          h3: c[8] as String?,
          noiseFloor: (c[9] as num?)?.toDouble(),
        ),
    ];
    return PublicCoverage(cells: cells, asOf: j['asOf'] as String, grid: grid);
  } catch (_) {
    return null;
  }
}
