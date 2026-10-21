// Which MeshSonar region (CMH, DAY, …) the phone is physically in, right now, purely on-device: a badge on the
// Drive screen, and a one-shot notice on crossing into a different region. Live, local, in-app awareness only —
// the server already tags every ping's true region correctly at upload time regardless of connectivity, so this
// is NOT what decides a ping's region. Pure Dart: no Flutter imports (this repo's lib/core layering rule).
//
// Source: `GET /api/cmh/regions-index` (and any `<region>.meshsonar.com` host), verified live on 2026-10-20:
//   {"regions": [{"code","slug","name","url","bbox":[west,south,east,north]|null,
//                 "boundary":{"type":"Polygon"|"MultiPolygon","coordinates":[...]}|null}], "asOf": "..."}
//
// Scope cut, deliberate: matching this pass is bbox-only (point-in-rectangle). `boundary` is parsed and cached
// (useful later, e.g. a proper point-in-polygon pass) but never evaluated here — point-in-polygon-with-holes
// against real-world region boundaries was genuine algorithmic risk to take on today. Where more than one
// region's bbox contains a fix (regions can legitimately overlap near a shared border), the region whose bbox
// centroid is nearest the fix wins: simple and defensible, not a geometric guarantee — a judgment call for this
// pass.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// One region from `regions-index`. [bbox] is `[west, south, east, north]` degrees, or null if the server
/// hasn't set one up for this region yet (never matches). [boundary] is the raw GeoJSON `Polygon` or
/// `MultiPolygon` geometry — kept for later, not evaluated by [regionAt] (see file header).
class RegionIndexEntry {
  final String code;
  final String slug;
  final String name;
  final String url;
  final List<double>? bbox;
  final Map<String, dynamic>? boundary;
  const RegionIndexEntry({
    required this.code,
    required this.slug,
    required this.name,
    required this.url,
    this.bbox,
    this.boundary,
  });

  Map<String, dynamic> toJson() => {
        'code': code,
        'slug': slug,
        'name': name,
        'url': url,
        'bbox': bbox,
        'boundary': boundary,
      };

  /// Null if a required field is missing or the wrong shape — callers skip the entry so one malformed region
  /// never loses the rest of the index.
  static RegionIndexEntry? tryParse(Object? j) {
    if (j is! Map) return null;
    final code = j['code'], slug = j['slug'], name = j['name'], url = j['url'];
    if (code is! String || code.isEmpty) return null;
    if (slug is! String || name is! String || url is! String) return null;

    List<double>? bbox;
    final rawBbox = j['bbox'];
    if (rawBbox is List && rawBbox.length == 4 && rawBbox.every((v) => v is num && v.isFinite)) {
      bbox = rawBbox.map((v) => (v as num).toDouble()).toList(growable: false);
    }

    Map<String, dynamic>? boundary;
    final rawBoundary = j['boundary'];
    if (rawBoundary is Map) {
      final type = rawBoundary['type'];
      if (type == 'Polygon' || type == 'MultiPolygon') boundary = rawBoundary.cast<String, dynamic>();
    }

    return RegionIndexEntry(code: code, slug: slug, name: name, url: url, bbox: bbox, boundary: boundary);
  }
}

/// Great-circle distance in metres. Same formula as `lib/radio/wardrive_engine.dart`'s `haversineM` and
/// `lib/core/position_filter.dart`'s `_distM`, duplicated rather than imported: lib/core doesn't depend on
/// lib/radio (the dependency runs the other way), and this file otherwise has zero lib/core dependencies either.
double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Which region [lat]/[lon] falls in, bbox-only (see file header for the scope cut and the overlap rule).
/// Null when nothing in [index] has a bbox containing the fix — outside every known region, not an error.
RegionIndexEntry? regionAt(List<RegionIndexEntry> index, double lat, double lon) {
  if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) return null;
  RegionIndexEntry? best;
  var bestDistM = double.infinity;
  for (final r in index) {
    final b = r.bbox;
    if (b == null) continue;
    final west = b[0], south = b[1], east = b[2], north = b[3];
    if (lon < west || lon > east || lat < south || lat > north) continue;
    final centroidLat = (south + north) / 2, centroidLon = (west + east) / 2;
    final d = _haversineM(lat, lon, centroidLat, centroidLon);
    if (d < bestDistM) {
      bestDistM = d;
      best = r;
    }
  }
  return best;
}

/// Local cache of the last-fetched regions-index, same shape as `FileRepeaterCache`/`MemoryRepeaterCache` in
/// `lib/app/services.dart`: one small JSON file, written atomically (temp file + rename); never throws — a
/// damaged or missing cache only costs region awareness, never blocks the app.
abstract class RegionIndexCache {
  Future<List<RegionIndexEntry>> load();
  Future<void> save(List<RegionIndexEntry> regions);
}

class FileRegionIndexCache implements RegionIndexCache {
  final File file;
  FileRegionIndexCache(this.file);

  @override
  Future<List<RegionIndexEntry>> load() async {
    try {
      if (!await file.exists()) return const [];
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return const [];
      final out = <RegionIndexEntry>[];
      for (final r in raw) {
        final parsed = RegionIndexEntry.tryParse(r);
        if (parsed != null) out.add(parsed);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(List<RegionIndexEntry> regions) async {
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(regions.map((r) => r.toJson()).toList()), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Keep the in-memory copy; the next launch just refetches.
    }
  }
}

/// In-memory cache (tests, or when no file system is wanted).
class MemoryRegionIndexCache implements RegionIndexCache {
  List<RegionIndexEntry> items;
  MemoryRegionIndexCache([this.items = const []]);
  @override
  Future<List<RegionIndexEntry>> load() async => items;
  @override
  Future<void> save(List<RegionIndexEntry> regions) async => items = List.of(regions);
}

/// Fetches and caches the regions index: a fetch that fails (offline, an older server with no `regions-index`)
/// falls back to whatever was last cached, so the phone can still answer "which region am I in" after a
/// connectivity drop. [fetch] is injected (the real app wires `CmatClient.regionsIndex`) so this class never
/// imports `http` — same separation RepeaterDirectory uses for its own fetch.
class RegionIndexService {
  final Future<List<RegionIndexEntry>> Function() fetch;
  final RegionIndexCache cache;
  RegionIndexService({required this.fetch, required this.cache});

  List<RegionIndexEntry> _regions = const [];

  /// The best index available right now: the on-disk cache before the first fetch answers, then whatever the
  /// most recent successful fetch returned. Empty only when neither has ever produced anything (first run,
  /// never been online).
  List<RegionIndexEntry> get regions => _regions;

  /// True once [regions] has ever held something (cache or a live fetch). False only before that first success.
  bool everLoaded = false;

  /// Plain-language reason the last fetch failed; null after a successful one. [regions] (the cache, or the
  /// last successful fetch) is still served either way — a failure here means "possibly-stale", not "nothing".
  String? lastError;

  Future<List<RegionIndexEntry>>? _inFlight;

  /// Loads whatever is on disk into [regions], without touching the network. Call once at startup, before the
  /// first [refresh], so there's something to show while the live fetch is in flight.
  Future<List<RegionIndexEntry>> loadCached() async {
    final cached = await cache.load();
    if (cached.isNotEmpty) {
      _regions = cached;
      everLoaded = true;
    }
    return _regions;
  }

  /// Fetches the live index and caches it. On failure, [regions] is left exactly as it was — a network hiccup
  /// never blanks region awareness, it just means the cache (if any) is now possibly stale ([lastError] is set
  /// accordingly). Concurrent calls share one fetch.
  Future<List<RegionIndexEntry>> refresh() => _inFlight ??= _refresh().whenComplete(() => _inFlight = null);

  Future<List<RegionIndexEntry>> _refresh() async {
    try {
      final r = await fetch();
      _regions = r;
      everLoaded = true;
      lastError = null;
      await cache.save(r);
    } catch (e) {
      lastError = e.toString();
    }
    return _regions;
  }
}
