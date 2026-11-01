// Privacy zones: circles where this driver's pings are hidden from every public view (past and future drives). The same
// rules as the website's one validator (meshcore-insights src/lib/platform/zones.ts): at most 10 zones, radius 50-5000 m,
// label up to 40 characters, centre rounded to 4 decimals (about 11 m) and longitude wrapped into -180..180. The server
// rounds itself and never rejects precision, but the app sends 4 decimals so what the person sees is what is stored.
// Pure Dart: no Flutter imports (lib/core layering rule).
import 'dart:math' as math;

const int kZoneMax = 10;
const double kZoneMinRadiusM = 50;
const double kZoneMaxRadiusM = 5000;
const double kZoneDefaultRadiusM = 300;
const int kZoneLabelMax = 40;
const int kCoordDecimals = 4;

/// Trim distance (`trimM`): how much of the start and end of every drive is hidden. The server default is 500 m.
const int kTrimMaxM = 2000;
const int kTrimDefaultM = 500;

/// A coordinate rounded to [kCoordDecimals] (about 11 m), tie-for-tie like the website's `Math.round`.
double roundCoord(double v) => _jsRound(v * math.pow(10, kCoordDecimals).toDouble()) / math.pow(10, kCoordDecimals).toDouble();

// JavaScript's Math.round: floor(x + 0.5). Agrees with the website validator on every tie.
double _jsRound(double x) => (x + 0.5).floorToDouble();

/// Longitude wrapped into -180..180 (a tap on the second copy of the world reads 190, which is -170).
double wrapLon(double lon) {
  if (!lon.isFinite || (lon >= -180 && lon <= 180)) return lon;
  final w = (((lon + 180) % 360) + 360) % 360 - 180;
  return (w == -180 && lon > 0) ? 180 : w;
}

double clampLat(double lat) => lat.isFinite ? lat.clamp(-90.0, 90.0) : lat;

class PrivacyZone {
  final double lat;
  final double lon;
  final double radiusM;
  final String? label;
  const PrivacyZone({required this.lat, required this.lon, required this.radiusM, this.label});

  /// A zone as the person drew it, made valid: latitude clamped, longitude wrapped, both rounded to 4 decimals, radius
  /// clamped to 50..5000 m (whole metres), label cleaned and cut to 40 characters.
  factory PrivacyZone.normalized({required double lat, required double lon, double radiusM = kZoneDefaultRadiusM, String? label}) {
    final r = radiusM.isFinite ? radiusM.clamp(kZoneMinRadiusM, kZoneMaxRadiusM).roundToDouble() : kZoneDefaultRadiusM;
    return PrivacyZone(lat: roundCoord(clampLat(lat)), lon: roundCoord(wrapLon(lon)), radiusM: r, label: cleanLabel(label));
  }

  PrivacyZone copyWith({double? lat, double? lon, double? radiusM, Object? label = _keep}) => PrivacyZone.normalized(
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        radiusM: radiusM ?? this.radiusM,
        label: identical(label, _keep) ? this.label : label as String?,
      );

  static const Object _keep = Object();

  /// The body the server takes: `{lat, lon, radiusM, label}`. Always re-normalised, so no caller can send 5 decimals.
  Map<String, dynamic> toJson() {
    final n = PrivacyZone.normalized(lat: lat, lon: lon, radiusM: radiusM, label: label);
    return {'lat': n.lat, 'lon': n.lon, 'radiusM': n.radiusM.round(), 'label': n.label};
  }

  /// Null when [j] is not a usable zone (a bad entry never costs the rest of the list).
  static PrivacyZone? tryParse(Object? j) {
    if (j is! Map) return null;
    final lat = j['lat'], lon = j['lon'], r = j['radiusM'];
    if (lat is! num || lon is! num || r is! num) return null;
    if (!lat.isFinite || !lon.isFinite || !r.isFinite || lat.abs() > 90 || lon.abs() > 180) return null;
    return PrivacyZone.normalized(lat: lat.toDouble(), lon: lon.toDouble(), radiusM: r.toDouble(), label: j['label'] is String ? j['label'] as String : null);
  }

  @override
  bool operator ==(Object other) =>
      other is PrivacyZone && other.lat == lat && other.lon == lon && other.radiusM == radiusM && other.label == label;
  @override
  int get hashCode => Object.hash(lat, lon, radiusM, label);
  @override
  String toString() => 'PrivacyZone($lat, $lon, ${radiusM.round()} m${label == null ? '' : ', $label'})';
}

/// A label without control characters, trimmed, at most [kZoneLabelMax] characters; null when nothing is left.
String? cleanLabel(String? s) {
  if (s == null) return null;
  final t = s.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '').trim();
  if (t.isEmpty) return null;
  return t.length > kZoneLabelMax ? t.substring(0, kZoneLabelMax).trim() : t;
}

/// What a field of a zone being edited is wrong with, in plain words (null = fine). The same checks as the server's.
String? zoneRadiusProblem(double r) => !r.isFinite || r < kZoneMinRadiusM || r > kZoneMaxRadiusM
    ? 'Radius must be ${kZoneMinRadiusM.round()} to ${kZoneMaxRadiusM.round()} m.'
    : null;
String? zoneLatProblem(double v) => !v.isFinite || v < -90 || v > 90 ? 'Latitude must be from -90 to 90.' : null;
String? zoneLonProblem(double v) => !v.isFinite || v < -180 || v > 180 ? 'Longitude must be from -180 to 180.' : null;

/// Metres between two points (haversine).
double distanceM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}

/// Metres per screen pixel at [lat] and a flutter_map zoom (256 px tiles).
double metresPerPixel(double lat, double zoom) => 156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);

/// Which zone a tap SELECTS: the zone whose circle holds the tap (the smallest one when circles overlap); a circle too
/// small to hit counts as [minPx] wide. Null = the tap is on empty map (the editor then adds nothing unless "add" mode is
/// on). [zoom] is the map zoom at the tap.
int? pickZone(List<PrivacyZone> zones, double lat, double lon, double zoom, {double minPx = 24}) {
  int? best;
  var bestR = double.infinity;
  for (var i = 0; i < zones.length; i++) {
    final z = zones[i];
    final mpp = metresPerPixel(z.lat, zoom);
    final r = math.max(z.radiusM, minPx * mpp);
    if (distanceM(z.lat, z.lon, lat, lon) <= r && r < bestR) {
      best = i;
      bestR = r;
    }
  }
  return best;
}

/// Where a zone's resize handle sits: [distM] due east of ([lat], [lon]).
({double lat, double lon}) eastOf(double lat, double lon, double distM) {
  final dLon = distM / (111320 * math.max(0.01, math.cos(lat * math.pi / 180)));
  return (lat: lat, lon: wrapLon(lon + dLon));
}

/// Where the zones live: the account (shared by every key of the person) or this key alone.
enum ZoneScope { account, driver }

ZoneScope? parseZoneScope(Object? v) => switch (v) {
      'account' => ZoneScope.account,
      'driver' => ZoneScope.driver,
      _ => null,
    };

/// The state the editor works on and the file keeps: the zones, the trim distance, which of them have not reached the
/// server yet, and what the server said last.
class PrivacyZoneState {
  final List<PrivacyZone> zones;
  final int trimM;

  /// True while a change made on this phone has not been sent (offline, or no driver key yet). The local list wins until
  /// it is sent; the server's list replaces the local one only when nothing is waiting.
  final bool pending;
  final ZoneScope? scope;
  final DateTime? syncedAt;
  const PrivacyZoneState({this.zones = const [], this.trimM = kTrimDefaultM, this.pending = false, this.scope, this.syncedAt});

  PrivacyZoneState copyWith({List<PrivacyZone>? zones, int? trimM, bool? pending, Object? scope = _keepScope, DateTime? syncedAt}) =>
      PrivacyZoneState(
        zones: zones ?? this.zones,
        trimM: trimM ?? this.trimM,
        pending: pending ?? this.pending,
        scope: identical(scope, _keepScope) ? this.scope : scope as ZoneScope?,
        syncedAt: syncedAt ?? this.syncedAt,
      );
  static const Object _keepScope = Object();

  Map<String, dynamic> toJson() => {
        'zones': [for (final z in zones) z.toJson()],
        'trimM': trimM,
        'pending': pending,
        if (scope != null) 'scope': scope!.name,
        if (syncedAt != null) 'syncedAt': syncedAt!.toUtc().toIso8601String(),
      };

  static PrivacyZoneState fromJson(Object? j) {
    if (j is! Map) return const PrivacyZoneState();
    final raw = j['zones'];
    final zones = <PrivacyZone>[];
    if (raw is List) {
      for (final x in raw) {
        final z = PrivacyZone.tryParse(x);
        if (z != null && zones.length < kZoneMax) zones.add(z);
      }
    }
    final t = j['trimM'];
    return PrivacyZoneState(
      zones: zones,
      trimM: t is num && t.isFinite ? t.round().clamp(0, kTrimMaxM) : kTrimDefaultM,
      pending: j['pending'] == true,
      scope: parseZoneScope(j['scope']),
      syncedAt: j['syncedAt'] is String ? DateTime.tryParse(j['syncedAt'] as String) : null,
    );
  }
}

/// The server's answer to `GET/POST driver-privacy`: `{privacy: {trimM, privacyZones, scope}}`.
class DriverPrivacy {
  final List<PrivacyZone> zones;
  final int trimM;
  final ZoneScope scope;
  const DriverPrivacy({required this.zones, required this.trimM, required this.scope});

  /// Null when [j] is not that shape.
  static DriverPrivacy? tryParse(Object? j) {
    final p = j is Map ? j['privacy'] : null;
    if (p is! Map) return null;
    final raw = p['privacyZones'], t = p['trimM'];
    if (raw is! List || t is! num || !t.isFinite) return null;
    return DriverPrivacy(
      zones: [for (final x in raw) ?PrivacyZone.tryParse(x)],
      trimM: t.round().clamp(0, kTrimMaxM),
      scope: parseZoneScope(p['scope']) ?? ZoneScope.driver,
    );
  }
}
