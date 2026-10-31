// Map view state as a URL: one schema shared by the website's coverage page and the app's deep links.
// Design: stream-1-maps.md section 4.7. Pure Dart: no Flutter imports.
//
//   https://<region>.meshsonar.com/coverage?show=measured,repeaters,observers&color=noise&since=7d&src=meshsonar&res=9
//       &lat=39.96&lon=-82.99&z=12&until=2026-10-21
//   meshsonar://map?<same query>&region=cmh
//
// Parsing mirrors the website's `validateCoverageAreaSearch` (meshcore-insights src/components/coverage/coverage-page.tsx,
// read at 5f35ba4 and in the unmerged `network` layer branch): every parameter is checked on its own and a bad one is
// dropped, never guessed at or allowed to fail the whole link.
//   show   comma list; unknown keys dropped; "" = explicitly no layers; absent = the page's defaults
//   color  snr | heard | noise; the website's `observer` (square grid only) is read as snr, since the app's hexagon
//          map has no observer-status colouring (the website itself does the same on its hexagon grid)
//   since  7d | 24h | 1h          src  meshsonar | meshmapper          res  7..11 (integer)
//   lat/lon  both finite and in range, or neither          label  trimmed, 1..160 chars          from  rep | address | map
// App additions (the website ignores them today; request W1 asks it to accept them):
//   z      camera zoom, clamped to 3..18 (rounded to 2 decimals)
//   until  YYYY-MM-DD, a real calendar date: the coverage timeline's "as of" day
// Semantics difference: on the website lat/lon is the "checked point"; the app treats it as the camera centre (and the
// default zoom is [MapViewState.defaultZoom] when z is absent).

import 'dart:convert' show Utf8Codec;

/// Layer keys the website's coverage page knows (its `LAYERS`, in its order). `model` and `reach` are shelved there and
/// have no app layer; they are kept so a website link survives a round trip through the app.
const List<String> kWebsiteShowKeys = ['measured', 'repeaters', 'observers', 'model', 'reach', 'network'];

/// Layer keys only the app draws (its own drive layers). Written in `meshsonar://` links, never in https links.
const List<String> kAppOnlyShowKeys = ['hexes', 'links', 'neighbours', 'heard', 'pings', 'rings', 'labels'];

const Set<String> kColorKeys = {'snr', 'heard', 'noise'};
const Set<String> kSinceKeys = {'7d', '24h', '1h'};
const Set<String> kSourceKeys = {'meshsonar', 'meshmapper'};
const Set<String> kFromKeys = {'rep', 'address', 'map'};

/// The app's custom URL scheme.
const String kAppScheme = 'meshsonar';

/// The website's apex domain; region sites are `<slug>.meshsonar.com`.
const String kWebDomain = 'meshsonar.com';

/// Sub-domains of [kWebDomain] that are not regions.
const Set<String> _notRegions = {'www', 'tiles', 'api'};

final RegExp _slug = RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$');
final RegExp _day = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

class MapViewState {
  static const double minZoom = 3;
  static const double maxZoom = 18;

  /// Camera zoom used when a link has a position but no `z`.
  static const double defaultZoom = 12;

  /// Region slug (`cmh`), or null for the hub / not stated.
  final String? region;

  /// Layer keys in canonical order (website keys first, in the website's order, then app-only ones). Null = the link
  /// did not say (use the page's defaults); empty = explicitly no layers.
  final List<String>? show;
  final String? color;
  final String? since;
  final String? src;
  final int? res;
  final double? lat;
  final double? lon;
  final double? z;

  /// The timeline's "as of" day, UTC midnight.
  final DateTime? until;
  final String? label;
  final String? from;

  const MapViewState({
    this.region,
    this.show,
    this.color,
    this.since,
    this.src,
    this.res,
    this.lat,
    this.lon,
    this.z,
    this.until,
    this.label,
    this.from,
  });

  static const MapViewState empty = MapViewState();

  bool get hasPosition => lat != null && lon != null;

  /// The zoom to open at: [z], or [defaultZoom] when the link has a position, else null (let the map decide).
  double? get effectiveZoom => z ?? (hasPosition ? defaultZoom : null);

  /// A state from the current camera (what "Share this view" writes): position rounded to 5 decimals (about 1 m) and
  /// zoom to 2 decimals, so the link text is stable.
  factory MapViewState.fromCamera({
    required double lat,
    required double lon,
    required double zoom,
    String? region,
    List<String>? show,
    String? color,
    String? since,
    String? src,
    int? res,
    DateTime? until,
  }) {
    final s = MapViewState.fromParameters({
      'lat': '$lat',
      'lon': '$lon',
      'z': '$zoom',
      if (show != null) 'show': show.join(','),
      'color': ?color,
      'since': ?since,
      'src': ?src,
      if (res != null) 'res': '$res',
      if (until != null) 'until': _formatDay(until),
      'region': ?region,
    }, allowRegionParam: true);
    return s;
  }

  /// Parses a link. Accepts `https://meshsonar.com/coverage`, `https://<slug>.meshsonar.com/coverage` (a trailing
  /// slash is fine) and `meshsonar://map`; anything else is null. Individual bad parameters are dropped.
  static MapViewState? fromUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == kAppScheme) {
      final target = uri.host.isNotEmpty ? uri.host.toLowerCase() : _firstSegment(uri.path);
      if (target != 'map') return null;
      return fromParameters(queryOf(uri), allowRegionParam: true);
    }
    if (scheme != 'https' && scheme != 'http') return null;
    final host = uri.host.toLowerCase();
    String? region;
    if (host == kWebDomain) {
      region = null;
    } else if (host.endsWith('.$kWebDomain')) {
      final sub = host.substring(0, host.length - kWebDomain.length - 1);
      if (sub == 'www') {
        region = null;
      } else if (!sub.contains('.') && _slug.hasMatch(sub) && !_notRegions.contains(sub)) {
        region = sub;
      } else {
        return null;
      }
    } else {
      return null;
    }
    final path = uri.path.endsWith('/') && uri.path.length > 1 ? uri.path.substring(0, uri.path.length - 1) : uri.path;
    if (path != '/coverage') return null;
    final s = fromParameters(queryOf(uri), allowRegionParam: false);
    return region == null ? s : s.copyWith(region: region);
  }

  /// Parses query parameters (already decoded). [allowRegionParam]: read `region=` (app links only; on https the host
  /// says the region).
  static MapViewState fromParameters(Map<String, String> q, {bool allowRegionParam = false}) {
    List<String>? show;
    final rawShow = q['show'];
    if (rawShow != null) {
      final want = rawShow.split(',').map((e) => e.trim()).toSet();
      final keys = [
        for (final k in kWebsiteShowKeys)
          if (want.contains(k)) k,
        for (final k in kAppOnlyShowKeys)
          if (want.contains(k)) k,
      ];
      // Website rule: keep the list when something valid is in it, or when it was explicitly empty.
      if (keys.isNotEmpty || rawShow.trim().isEmpty) show = List.unmodifiable(keys);
    }
    final rawColor = q['color'];
    final color = rawColor == 'observer' ? 'snr' : (kColorKeys.contains(rawColor) ? rawColor : null);
    final since = kSinceKeys.contains(q['since']) ? q['since'] : null;
    final src = kSourceKeys.contains(q['src']) ? q['src'] : null;
    final resN = _num(q['res']);
    final res = (resN != null && resN == resN.roundToDouble() && resN >= 7 && resN <= 11) ? resN.toInt() : null;
    final lat = _num(q['lat']), lon = _num(q['lon']);
    final posOk = lat != null && lon != null && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
    final zN = _num(q['z']);
    final z = zN == null ? null : (zN.clamp(minZoom, maxZoom) * 100).roundToDouble() / 100;
    final until = _parseDay(q['until']);
    final rawLabel = q['label'];
    final label = (rawLabel != null && rawLabel.trim().isNotEmpty && rawLabel.length <= 160) ? rawLabel.trim() : null;
    final from = kFromKeys.contains(q['from']) ? q['from'] : null;
    final rawRegion = allowRegionParam ? q['region']?.toLowerCase() : null;
    final region = (rawRegion != null && _slug.hasMatch(rawRegion) && !_notRegions.contains(rawRegion)) ? rawRegion : null;
    return MapViewState(
      region: region,
      show: show,
      color: color,
      since: since,
      src: src,
      res: res,
      lat: posOk ? _round5(lat) : null,
      lon: posOk ? _round5(lon) : null,
      z: z,
      until: until,
      label: label,
      from: from,
    );
  }

  /// The query parameters in canonical order. [web]: website form (app-only layer keys and `region` left out).
  Map<String, String> toParameters({required bool web}) {
    final out = <String, String>{};
    if (show != null) {
      out['show'] = [
        for (final k in show!)
          if (!web || kWebsiteShowKeys.contains(k)) k,
      ].join(',');
    }
    if (color != null) out['color'] = color!;
    if (since != null) out['since'] = since!;
    if (src != null) out['src'] = src!;
    if (res != null) out['res'] = '$res';
    if (hasPosition) {
      out['lat'] = _fmt(lat!, 5);
      out['lon'] = _fmt(lon!, 5);
    }
    if (z != null) out['z'] = _fmt(z!, 2);
    if (until != null) out['until'] = _formatDay(until!);
    if (label != null) out['label'] = label!;
    if (from != null) out['from'] = from!;
    if (!web && region != null) out['region'] = region!;
    return out;
  }

  /// The link. [web]: `https://<region>.meshsonar.com/coverage?...` (the hub when no region); otherwise
  /// `meshsonar://map?...`.
  Uri toUri({required bool web}) {
    final q = toParameters(web: web);
    // Written by hand (not Uri.queryParameters) so an empty value keeps its "=" (`show=`), as the website writes it.
    final query = q.isEmpty
        ? null
        : q.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
    if (web) {
      return Uri(scheme: 'https', host: region == null ? kWebDomain : '$region.$kWebDomain', path: '/coverage', query: query);
    }
    return Uri(scheme: kAppScheme, host: 'map', query: query);
  }

  MapViewState copyWith({
    String? region,
    List<String>? show,
    String? color,
    String? since,
    String? src,
    int? res,
    double? lat,
    double? lon,
    double? z,
    DateTime? until,
    String? label,
    String? from,
  }) => MapViewState(
    region: region ?? this.region,
    show: show ?? this.show,
    color: color ?? this.color,
    since: since ?? this.since,
    src: src ?? this.src,
    res: res ?? this.res,
    lat: lat ?? this.lat,
    lon: lon ?? this.lon,
    z: z ?? this.z,
    until: until ?? this.until,
    label: label ?? this.label,
    from: from ?? this.from,
  );

  @override
  bool operator ==(Object other) =>
      other is MapViewState &&
      other.region == region &&
      _listEq(other.show, show) &&
      other.color == color &&
      other.since == since &&
      other.src == src &&
      other.res == res &&
      other.lat == lat &&
      other.lon == lon &&
      other.z == z &&
      other.until == until &&
      other.label == label &&
      other.from == from;

  @override
  int get hashCode => Object.hash(
    region,
    show == null ? null : Object.hashAll(show!),
    color,
    since,
    src,
    res,
    lat,
    lon,
    z,
    until,
    label,
    from,
  );

  @override
  String toString() => 'MapViewState(${toUri(web: false)})';
}

/// The query as a map, first value of a repeated key winning (as the website's URLSearchParams.get does). Never
/// throws: bytes that are not UTF-8 decode to U+FFFD (Uri.queryParameters would throw a FormatException).
Map<String, String> queryOf(Uri uri) {
  final out = <String, String>{};
  if (!uri.hasQuery) return out;
  const utf8 = Utf8Codec(allowMalformed: true);
  String dec(String s) {
    try {
      return Uri.decodeQueryComponent(s, encoding: utf8);
    } on FormatException {
      return '';
    } on ArgumentError {
      return '';
    }
  }

  for (final part in uri.query.split('&')) {
    if (part.isEmpty) continue;
    final i = part.indexOf('=');
    final k = dec(i < 0 ? part : part.substring(0, i));
    final v = i < 0 ? '' : dec(part.substring(i + 1));
    if (k.isEmpty) continue;
    out.putIfAbsent(k, () => v);
  }
  return out;
}

String _firstSegment(String path) {
  final p = path.startsWith('/') ? path.substring(1) : path;
  final i = p.indexOf('/');
  return (i < 0 ? p : p.substring(0, i)).toLowerCase();
}

bool _listEq(List<String>? a, List<String>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A finite number from text (website `Number(v)` on a non-blank string); null otherwise.
double? _num(String? v) {
  if (v == null || v.trim().isEmpty) return null;
  final n = double.tryParse(v.trim());
  return (n != null && n.isFinite) ? n : null;
}

double _round5(double v) => (v * 100000).roundToDouble() / 100000;

/// Fixed decimals with trailing zeros trimmed: 39.96000 -> "39.96", 12.00 -> "12".
String _fmt(double v, int dp) {
  var s = v.toStringAsFixed(dp);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return s == '-0' ? '0' : s;
}

DateTime? _parseDay(String? v) {
  if (v == null) return null;
  final m = _day.firstMatch(v.trim());
  if (m == null) return null;
  final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  final t = DateTime.utc(y, mo, d);
  return (t.year == y && t.month == mo && t.day == d) ? t : null; // rejects 2026-02-30
}

String _formatDay(DateTime t) {
  final u = t.toUtc();
  return '${u.year.toString().padLeft(4, '0')}-${u.month.toString().padLeft(2, '0')}-${u.day.toString().padLeft(2, '0')}';
}
