// Where the phone is at launch, and where the maps open (Stream 4). Pure Dart.
//
// The app never waits for GPS to show something: the last place the phone was seen (LastKnownStore, written by every
// live fix) is applied at once, a fresh fix refines it when it arrives (bounded by a timeout), and only then does the
// idle region watcher start. With no fix at all the maps open on the last viewed region, else on the whole hub.
//
// Location permission is described here as plain states with one action each; the platform probe that reads them
// lives behind [LocationAccessProbe] (lib/platform/location_access.dart), so this file stays testable without plugins.
import 'dart:async';

import '../radio/radio_api.dart';
import 'region_lookup.dart';
import 'region_pick.dart';

/// A fix older than this is "stale" (Andy, Oct 24 2026: 72 hours). It is labelled with its age ("Last known location,
/// 4 d ago") and may still centre the map as a fallback, but it never moves the region: no switch, no "you entered
/// another region" notice, no preset prompt. A fix exactly 72 h old is not stale.
const Duration staleFixAge = Duration(hours: 72);

/// A fix at most this old counts as "live" (the phone is there now). An OS-cached position handed back by a GPS call can
/// be hours old; it centres the map but does not replace a launch seed as the region the phone is in.
const Duration liveFixAge = Duration(minutes: 15);

/// How long launch waits for a fresh GPS fix before giving up on it (the last-known fix is already on screen).
const Duration launchFixTimeout = Duration(seconds: 20);

/// The best-known position of the phone.
class PhoneFix {
  final GeoFix fix;

  /// True when it came from the GPS during this run; false for the last-known fix read from disk at launch.
  final bool live;
  const PhoneFix(this.fix, {required this.live});

  Duration age(DateTime now) {
    final d = now.toUtc().difference(fix.at.toUtc());
    return d.isNegative ? Duration.zero : d;
  }

  bool isStale(DateTime now) => age(now) > staleFixAge;

  /// True when the phone is known to be there right now (a GPS fix of this run, at most [liveFixAge] old).
  bool isLive(DateTime now) => live && age(now) <= liveFixAge;
}

/// "Last known location, 2 d ago" style label for a fix that is not live; null for a live one.
String? phoneFixLabel(PhoneFix? p, DateTime now) {
  if (p == null || p.isLive(now)) return null;
  final d = p.age(now);
  final String ago;
  if (d.inMinutes < 1) {
    ago = 'just now';
  } else if (d.inMinutes < 60) {
    ago = '${d.inMinutes} min ago';
  } else if (d.inHours < 48) {
    ago = '${d.inHours} h ago';
  } else {
    ago = '${d.inDays} d ago';
  }
  return 'Last known location, $ago';
}

/// One GPS fix within [timeout]. Never throws: an error, a timeout or "no fix" all come back as null ([onError] hears
/// errors and timeouts for the diagnostics log).
Future<GeoFix?> fixWithin(LocationSource source, Duration timeout, {void Function(Object error)? onError}) async {
  try {
    return await source.current().timeout(timeout);
  } on TimeoutException catch (e) {
    onError?.call(e);
    return null;
  } catch (e) {
    onError?.call(e);
    return null;
  }
}

// ---------------------------------------------------------------------------------------------------------- permission

/// What the platform says about location for MeshSonar. Read without prompting.
enum LocationAccess {
  /// Not read yet (or the platform cannot say).
  unknown,

  /// Never asked: one tap shows the system question.
  notAsked,

  /// Refused, but the system lets the app ask again (Android).
  denied,

  /// Refused for good ("Don't allow" on iOS, "Don't ask again" on Android): only the phone's Settings can change it.
  deniedForever,

  /// Blocked by a device policy or Screen Time (iOS): the person may not be able to change it at all.
  restricted,

  /// Allowed, but iOS/Android "Precise Location" is off: fine for the region, too coarse to place pings.
  approximate,

  /// Location services are off for the whole phone.
  servicesOff,

  /// Allowed with precise location.
  granted,
}

/// The one thing a location note offers.
enum LocationAction {
  /// Show the system permission question (only ever after the person taps it).
  ask,

  /// Open MeshSonar's page in the phone's Settings.
  openAppSettings,

  /// Open the phone's location services settings.
  openLocationSettings,
}

/// A plain-language location state and its action; null when nothing needs saying.
class LocationNote {
  final LocationAccess access;
  final String message;
  final LocationAction? action;
  final String? actionLabel;

  /// Offer the region picker too (location cannot follow the phone right now).
  final bool offerRegionPicker;
  const LocationNote(this.access, this.message, {this.action, this.actionLabel, this.offerRegionPicker = true});
}

/// The note for [access]. [regionName] is what the app shows instead (the last region), if any.
LocationNote? locationNoteFor(LocationAccess access, {String? regionName}) {
  final showing = regionName == null ? '' : ' Showing $regionName.';
  switch (access) {
    case LocationAccess.unknown:
    case LocationAccess.granted:
      return null;
    case LocationAccess.notAsked:
      return LocationNote(access, 'Allow location so the map opens where you are.$showing',
          action: LocationAction.ask, actionLabel: 'Allow location');
    case LocationAccess.denied:
      return LocationNote(access, 'Location is not allowed for MeshSonar.$showing',
          action: LocationAction.ask, actionLabel: 'Allow location');
    case LocationAccess.deniedForever:
      return LocationNote(access, 'Location is off for MeshSonar. Turn it on in Settings to follow you.$showing',
          action: LocationAction.openAppSettings, actionLabel: 'Open Settings');
    case LocationAccess.restricted:
      return LocationNote(access, 'Location is blocked on this phone (device policy or Screen Time).$showing',
          action: LocationAction.openAppSettings, actionLabel: 'Open Settings');
    case LocationAccess.approximate:
      return const LocationNote(LocationAccess.approximate, 'Approximate location is on: the region works, but drives need Precise Location.',
          action: LocationAction.openAppSettings, actionLabel: 'Open Settings', offerRegionPicker: false);
    case LocationAccess.servicesOff:
      return LocationNote(access, 'Location services are off on this phone.$showing',
          action: LocationAction.openLocationSettings, actionLabel: 'Open Settings');
  }
}

/// Reads and (only when the person taps) requests location permission. The real one wraps geolocator
/// (lib/platform/location_access.dart); tests use a fake. [check] must never show a system prompt.
abstract class LocationAccessProbe {
  Future<LocationAccess> check();

  /// Shows the system question (if the platform still allows one) and returns the new state.
  Future<LocationAccess> request();

  /// Opens MeshSonar's page in the phone's Settings; false if it could not.
  Future<bool> openAppSettings();

  /// Opens the phone's location services settings; false if it could not.
  Future<bool> openLocationSettings();
}

// ------------------------------------------------------------------------------------------------------- map start view

enum MapStartKind {
  /// The phone's position (last-known or fresh).
  phone,

  /// The viewed region's bbox centre (no fix, or the person is viewing another region than the one they are in).
  region,

  /// The middle of every region (no fix and no region picked or viewed before).
  hub,

  /// Nothing known at all (first run, offline, no fix): a whole-world view.
  world,
}

class MapStart {
  final MapStartKind kind;
  final double? lat;
  final double? lon;
  const MapStart(this.kind, {this.lat, this.lon});
  static const world = MapStart(MapStartKind.world);
}

/// Centre of the union of every region's bbox; null when no region has one.
({double lat, double lon})? hubCenter(List<RegionIndexEntry> index) {
  double? w, s, e, n;
  for (final r in index) {
    final b = r.bbox;
    if (b == null || b.length < 4) continue;
    w = w == null || b[0] < w ? b[0] : w;
    s = s == null || b[1] < s ? b[1] : s;
    e = e == null || b[2] > e ? b[2] : e;
    n = n == null || b[3] > n ? b[3] : n;
  }
  if (w == null) return null;
  return (lat: (s! + n!) / 2, lon: (w + e!) / 2);
}

/// Where a map with nothing of its own to show (no drive on it) opens:
///  1. the phone ([phone]), unless the person picked a region to view ([viewingIsManual]) that does not contain it;
///  2. the viewed region's centre, when that region was picked or remembered ([viewingRemembered]);
///  3. the middle of every region (hub view);
///  4. the whole world.
MapStart mapStartFor({
  required PhoneFix? phone,
  required RegionIndexEntry? viewing,
  required bool viewingIsManual,
  required bool viewingRemembered,
  required List<RegionIndexEntry> index,
  DateTime? now,
}) {
  final p = phone;
  if (p != null) {
    final manualElsewhere = viewingIsManual && viewing != null && !_holds(viewing, p.fix.lat, p.fix.lon);
    // A stale fix (older than [staleFixAge], judged at [now]) is only a fallback: a picked or remembered region that
    // does not contain it wins, since the stale fix never moved the region there.
    final staleElsewhere = now != null &&
        p.isStale(now) &&
        viewing != null &&
        (viewingIsManual || viewingRemembered) &&
        !_holds(viewing, p.fix.lat, p.fix.lon);
    if (!manualElsewhere && !staleElsewhere) return MapStart(MapStartKind.phone, lat: p.fix.lat, lon: p.fix.lon);
  }
  if (viewing != null && (viewingIsManual || viewingRemembered || p != null)) {
    final c = regionCenter(viewing);
    if (c != null) return MapStart(MapStartKind.region, lat: c.lat, lon: c.lon);
  }
  final h = hubCenter(index);
  if (h != null) return MapStart(MapStartKind.hub, lat: h.lat, lon: h.lon);
  if (viewing != null) {
    final c = regionCenter(viewing);
    if (c != null) return MapStart(MapStartKind.region, lat: c.lat, lon: c.lon);
  }
  return MapStart.world;
}

bool _holds(RegionIndexEntry r, double lat, double lon) {
  final b = r.bbox;
  if (b == null || b.length < 4) return false;
  if (lon < b[0] || lon > b[2] || lat < b[1] || lat > b[3]) return false;
  final bd = r.boundary;
  return bd == null || pointInBoundary(bd, lat, lon);
}
