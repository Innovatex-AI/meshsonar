// Which MeshSonar region (CMH, DAY, …) the phone is physically in, right now, purely on-device: a badge on the
// Drive screen, and a one-shot notice on crossing into a different region. Live, local, in-app awareness only —
// the server already tags every ping's true region correctly at upload time regardless of connectivity, so this
// is NOT what decides a ping's region. Pure Dart: no Flutter imports (this repo's lib/core layering rule).
//
// Source: `GET /api/cmh/regions-index` (and any `<region>.meshsonar.com` host), verified live on 2026-10-20:
//   {"regions": [{"code","slug","name","url","bbox":[west,south,east,north]|null,
//                 "boundary":{"type":"Polygon"|"MultiPolygon","coordinates":[...]}|null}], "asOf": "..."}
//
// Matching is bbox first, then the real `boundary` (point-in-polygon with holes, lib/core/region_pick.dart on typed
// arrays from lib/core/region_geometry.dart). Where more than one region holds a fix (shared borders, nested zones)
// the smallest wins; the server decides a ping's real region.
//
// At 559 regions the index is 3.4 MB / 1.1 MB gzip / ~180k vertices: it is parsed off the main isolate, written to the
// cache only when it changed, and answered from the ETag cache (304) otherwise.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'api.dart' show CmatException;

/// One region from `regions-index`. [bbox] is `[west, south, east, north]` degrees, or null if the server
/// hasn't set one up for this region yet (never matches). [boundary] is the raw GeoJSON `Polygon` or
/// `MultiPolygon` geometry. [regionAt] (bbox only) ignores it; `regionContaining` / `regionsContaining` in region_pick.dart
/// evaluate it.
class RegionIndexEntry {
  final String code;
  final String slug;
  final String name;
  final String url;
  final List<double>? bbox;
  final Map<String, dynamic>? boundary;

  /// The country as the server states it: English name and ISO 3166-1 alpha-2 code (`country`, `country_code`). Null when
  /// the server does not know the region's country. See [countryReported] for "the server never said anything".
  final String? country;
  final String? countryCode;

  /// True when the server's answer carried the country keys at all (even as null). False for an older server (and for
  /// a cache written before the keys existed): only then does the app fall back to reading the code off the end of the
  /// region's name ("Aachen, DE"). A server that says "unknown" is believed, not second-guessed.
  final bool countryReported;

  /// True while the region's outline was drawn by machine from open data (Natural Earth plus node positions) and no
  /// person has reviewed it yet (`machine_derived`). Absent from an older server = false.
  final bool machineDerived;
  const RegionIndexEntry({
    required this.code,
    required this.slug,
    required this.name,
    required this.url,
    this.bbox,
    this.boundary,
    this.country,
    this.countryCode,
    bool? countryReported,
    this.machineDerived = false,
  }) : countryReported = countryReported ?? (countryCode != null || country != null);

  Map<String, dynamic> toJson() => {
        'code': code,
        'slug': slug,
        'name': name,
        'url': url,
        'bbox': bbox,
        'boundary': boundary,
        if (countryReported) 'country': country,
        if (countryReported) 'country_code': countryCode,
        if (machineDerived) 'machine_derived': true,
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

    // Country: a two-letter code (any case) and a non-empty name; anything else is "unknown", never a guess.
    final rawCc = j['country_code'], rawCountry = j['country'];
    final cc = rawCc is String && RegExp(r'^[A-Za-z]{2}$').hasMatch(rawCc.trim()) ? rawCc.trim().toUpperCase() : null;
    final countryName = rawCountry is String && rawCountry.trim().isNotEmpty ? rawCountry.trim() : null;

    return RegionIndexEntry(
      code: code,
      slug: slug,
      name: name,
      url: url,
      bbox: bbox,
      boundary: boundary,
      country: cc == null ? null : countryName,
      countryCode: cc,
      countryReported: j.containsKey('country_code') || j.containsKey('country'),
      machineDerived: j['machine_derived'] == true,
    );
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

/// Bodies bigger than this are parsed on a background isolate (a 3.4 MB regions-index takes ~20 ms on a laptop and
/// several times that on a phone: a visible stutter on the main isolate). Small ones stay inline (tests, custom servers).
const int regionsIndexIsolateThreshold = 256 * 1024;

/// Parses a `regions-index` body: `{"regions":[...],"asOf":"..."}`. A malformed region is skipped, not fatal. Throws
/// [FormatException] when the body is not that shape.
List<RegionIndexEntry> parseRegionsIndexBody(String body) {
  final j = jsonDecode(body);
  if (j is! Map) throw const FormatException('server sent an unreadable regions-index answer');
  final raw = j['regions'];
  if (raw is! List) throw const FormatException('server sent a regions-index answer without regions');
  if (j['asOf'] is! String) throw const FormatException('server sent a regions-index answer without asOf');
  return _entriesOf(raw);
}

List<RegionIndexEntry> _entriesOf(List<dynamic> raw) {
  final out = <RegionIndexEntry>[];
  for (final r in raw) {
    final parsed = RegionIndexEntry.tryParse(r);
    if (parsed != null) out.add(parsed);
  }
  return out;
}

/// [parseRegionsIndexBody], on a background isolate when the body is big. The result moves back without a copy.
Future<List<RegionIndexEntry>> parseRegionsIndexBodyOffMain(String body) async {
  if (body.length < regionsIndexIsolateThreshold) return parseRegionsIndexBody(body);
  final r = await Isolate.run(() {
    final list = parseRegionsIndexBody(body);
    return (list, _computeFingerprint(list));
  });
  _knownFingerprint[r.$1] = r.$2;
  return r.$1;
}

final Expando<int> _knownFingerprint = Expando('regionsFingerprint');

/// An order-sensitive digest of an index: codes, names, URLs, bboxes and every boundary coordinate. Two indexes with the
/// same digest are treated as the same (so a 304 answer, or a 200 with identical content, neither rewrites the 3.4 MB
/// cache file nor makes the app re-evaluate the region). A list that came out of [parseRegionsIndexBodyOffMain] or the
/// file cache already knows its digest (worked out on the background isolate); any other list is walked once.
int regionsFingerprint(List<RegionIndexEntry> index) => _knownFingerprint[index] ??= _computeFingerprint(index);

int _computeFingerprint(List<RegionIndexEntry> index) {
  var h = 0xcbf29ce484222325 & 0x7fffffffffffffff;
  void mix(int v) => h = ((h ^ (v & 0x7fffffffffffffff)) * 0x100000001b3) & 0x7fffffffffffffff;
  void mixD(double d) => mix((d * 1e6).round());
  void walk(Object? o) {
    if (o is List) {
      if (o.length >= 2 && o[0] is num && o[1] is num) {
        mixD((o[0] as num).toDouble());
        mixD((o[1] as num).toDouble());
      } else {
        mix(o.length);
        for (final x in o) {
          walk(x);
        }
      }
    }
  }

  for (final r in index) {
    mix(r.code.hashCode);
    mix(r.slug.hashCode);
    mix(r.name.hashCode);
    mix(r.url.hashCode);
    mix((r.countryCode ?? '').hashCode);
    mix((r.country ?? '').hashCode);
    mix(r.machineDerived ? 1 : 0);
    final b = r.bbox;
    if (b != null) b.forEach(mixD);
    final bd = r.boundary;
    if (bd != null) {
      mix((bd['type'] as String).hashCode);
      walk(bd['coordinates']);
    }
  }
  return h;
}

List<RegionIndexEntry> _parseCached(String text) {
  final raw = jsonDecode(text);
  return raw is List ? _entriesOf(raw) : const [];
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
      final text = await file.readAsString();
      if (text.length < regionsIndexIsolateThreshold) return _parseCached(text);
      final r = await Isolate.run(() {
        final list = _parseCached(text);
        return (list, _computeFingerprint(list));
      });
      _knownFingerprint[r.$1] = r.$2;
      return r.$1;
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
///
/// At 559 regions every refresh matters: an answer that is the same index keeps the SAME list object (so everything
/// keyed on it stays warm) and writes nothing; a failing server is not hammered (429 honours Retry-After, other
/// failures back off); a refresh is only due again after [maxAge].
class RegionIndexService {
  final Future<List<RegionIndexEntry>> Function() fetch;
  final RegionIndexCache cache;

  /// Fetches the full-detail outline of some regions (`regions-index?slug=a,b`). Null = the server cannot.
  final Future<List<RegionIndexEntry>> Function(List<String> slugs)? fetchDetail;
  final DateTime Function() clock;

  /// How long a fetched index is current before [due] says it is time to ask again (the server sends max-age 300 and an
  /// ETag, so asking is a 304 most of the time; 6 h keeps even that rare).
  final Duration maxAge;
  RegionIndexService({required this.fetch, required this.cache, this.fetchDetail, DateTime Function()? clock, this.maxAge = const Duration(hours: 6)})
      : clock = clock ?? DateTime.now;

  List<RegionIndexEntry> _regions = const [];
  int _fingerprint = 0;

  /// The best index available right now: the on-disk cache before the first fetch answers, then whatever the
  /// most recent successful fetch returned (with full-detail outlines swapped in where [refine] fetched them). Empty
  /// only when neither has ever produced anything (first run, never been online).
  List<RegionIndexEntry> get regions => _regions;

  /// True once [regions] has ever held something (cache or a live fetch). False only before that first success.
  bool everLoaded = false;

  /// Plain-language reason the last fetch failed; null after a successful one. [regions] (the cache, or the
  /// last successful fetch) is still served either way — a failure here means "possibly-stale", not "nothing".
  String? lastError;

  /// HTTP status of the last failure (429 = rate limited), null when it had none (offline) or after a success.
  int? lastErrorStatus;

  /// When the last live answer arrived (null until one has this run).
  DateTime? lastSuccessAt;

  /// While set and in the future, [refresh] without `force` does not ask the server (429 / repeated failures).
  DateTime? backoffUntil;
  int _failures = 0;

  /// True when a refresh makes sense now: never fetched this run, or older than [maxAge], and not backing off.
  bool get due {
    final now = clock();
    if (backoffUntil != null && now.isBefore(backoffUntil!)) return false;
    final at = lastSuccessAt;
    return at == null || now.difference(at) >= maxAge;
  }

  Future<List<RegionIndexEntry>>? _inFlight;

  /// Loads whatever is on disk into [regions], without touching the network. Call once at startup, before the
  /// first [refresh], so there's something to show while the live fetch is in flight.
  Future<List<RegionIndexEntry>> loadCached() async {
    final cached = await cache.load();
    if (cached.isNotEmpty) {
      _regions = cached;
      _fingerprint = regionsFingerprint(cached);
      _refined.clear();
        _refineTried.clear();
      everLoaded = true;
    }
    return _regions;
  }

  /// Fetches the live index and caches it. On failure, [regions] is left exactly as it was — a network hiccup
  /// never blanks region awareness, it just means the cache (if any) is now possibly stale ([lastError] is set
  /// accordingly). Concurrent calls share one fetch. Always asks (launch, a server change, a person's retry);
  /// [refreshIfDue] is the polite one.
  Future<List<RegionIndexEntry>> refresh() => _inFlight ??= _refresh().whenComplete(() => _inFlight = null);

  /// Refreshes only when [due]: not while a failure or a 429 is backing off, and not more than every [maxAge].
  Future<List<RegionIndexEntry>> refreshIfDue() => due ? refresh() : Future.value(_regions);

  Future<List<RegionIndexEntry>> _refresh() async {
    try {
      final r = await fetch();
      final fp = regionsFingerprint(r);
      lastError = null;
      lastErrorStatus = null;
      lastSuccessAt = clock();
      backoffUntil = null;
      _failures = 0;
      if (!everLoaded || fp != _fingerprint) {
        _regions = r;
        _fingerprint = fp;
        _refined.clear();
        _refineTried.clear();
        everLoaded = true;
        await cache.save(r);
      } // else: the same index as the one held (or cached): nothing to rewrite, and the list object stays.
    } catch (e) {
      lastError = e.toString();
      final status = e is CmatException ? e.status : null;
      lastErrorStatus = status;
      _failures++;
      final retry = e is CmatException ? e.retryAfterSec : null;
      final wait = status == 429
          ? Duration(seconds: (retry ?? 60).clamp(5, 900))
          : Duration(seconds: (30 * (1 << (_failures - 1).clamp(0, 4))).clamp(30, 600));
      backoffUntil = clock().add(wait);
    }
    return _regions;
  }

  final Map<String, RegionIndexEntry> _refined = {};
  final Set<String> _refineTried = {};

  /// The codes whose full-detail outline is already in [regions].
  Set<String> get refinedCodes => _refined.keys.toSet();

  /// Swaps in the full-detail outline of the regions with these [codes] (the hub index is thinned to ~300 m, which is
  /// coarser than a GPS fix; near an edge the exact outline decides). Returns true when [regions] changed. In memory
  /// only: the next full refresh brings the thinned index back and the next edge visit refines again. A failure, or a
  /// server that cannot, leaves [regions] as it is.
  Future<bool> refine(List<String> codes) async {
    final f = fetchDetail;
    if (f == null) return false;
    final want = [
      for (final c in codes)
        if (!_refineTried.contains(c)) for (final r in _regions) if (r.code == c) r,
    ];
    if (want.isEmpty) return false;
    final before = _regions;
    try {
      final got = await f([for (final r in want) r.slug]);
      if (!identical(before, _regions)) return false; // the index was replaced while this was in flight
      _refineTried.addAll([for (final r in want) r.code]); // asked once: a region the server does not return is not asked again
      final byCode = {for (final r in got) if (r.boundary != null) r.code: r};
      if (byCode.isEmpty) return false;
      _refined.addAll(byCode);
      _regions = [for (final r in _regions) byCode[r.code] ?? r];
      return true;
    } catch (_) {
      return false;
    }
  }
}
