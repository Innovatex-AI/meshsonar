// "Ask for location" (MeshTrack MT-13, meshtrack plan 5.9 row "Any MeshCore user, one person"): the pure rules. One person
// on any MeshCore app is asked for their position with MeshCore's own telemetry request (CMD_SEND_TELEMETRY_REQ 39, answer
// PUSH_CODE_TELEMETRY_RESPONSE 0x8B with CayenneLPP). Firmware reading: docs/protocol/telemetry-location-request.md
// (source-based, NOT verified on hardware, Andy's decision Nov 16 2026).
//
// Privacy (same rules as MeshTrack positions): an answered position lives in memory only (the Drive map's "asked" pin and
// the contact screen), is never uploaded, never written to disk and never logged with coordinates or names.
//
// Pure Dart: no Flutter imports. The clock is injected.

/// Asking the same contact again waits this long (airtime: one request per person per 30 s).
const Duration kAskLocationGap = Duration(seconds: 30);

/// The shortest wait for an answer when the radio sends the request straight along a known route.
const Duration kAskDirectWait = Duration(seconds: 30);

/// The shortest wait when the radio has no route and floods the request (it then also learns the way back).
const Duration kAskFloodWait = Duration(seconds: 45);

/// The longest wait, whatever the radio estimates.
const Duration kAskMaxWait = Duration(seconds: 60);

/// An asked position stays on the map this long (the same 2 h as a friend's pin), then only memory clears it.
const Duration kAskedOnMapFor = Duration(hours: 2);

/// How long to wait for the answer after the radio said SENT with [estTimeoutMs] (its own estimate: 500 ms + 16 x airtime
/// for a flood, 500 ms + (6 x airtime + 250 ms) per hop for a direct send; MyMesh.cpp 888-896). The person's radio answers
/// at once when it answers at all, so the radio's estimate, doubled plus 3 s, is enough; the floor covers busy repeaters
/// and the radio's own send queue, the ceiling keeps the spinner honest.
Duration askLocationWait({required bool flood, required int estTimeoutMs}) {
  final floor = flood ? kAskFloodWait : kAskDirectWait;
  final fromRadio = Duration(milliseconds: estTimeoutMs * 2) + const Duration(seconds: 3);
  final w = fromRadio > floor ? fromRadio : floor;
  return w > kAskMaxWait ? kAskMaxWait : w;
}

/// True when a reported position is a real place: finite, on the globe, and not 0, 0. A radio whose GPS is switched on but
/// has never had a fix (and has no saved position) reports exactly 0, 0 (EnvironmentSensorManager.cpp 684-690: node_lat /
/// node_lon start at 0), which must not become a pin off the coast of Africa.
bool askedPositionUsable(double lat, double lon) {
  if (!lat.isFinite || !lon.isFinite) return false;
  if (lat.abs() > 90 || lon.abs() > 180) return false;
  return !(lat.abs() < 0.0001 && lon.abs() < 0.0001);
}

/// One answered position. Memory only.
class MtAskedPosition {
  /// The contact's public key, hex.
  final String keyHex;
  final String name;
  final double lat;
  final double lon;

  /// Altitude the radio reported, metres; null when not sent.
  final double? altitudeM;

  /// When the answer came.
  final DateTime at;
  const MtAskedPosition({required this.keyHex, required this.name, required this.lat, required this.lon, this.altitudeM, required this.at});

  @override
  String toString() => 'MtAskedPosition(${keyHex.length >= 8 ? keyHex.substring(0, 8) : keyHex})'; // never the position
}

/// Once per [gap] per contact. Shared by every screen of one radio session, so leaving and opening the contact again does
/// not reset it.
class AskLimiter {
  final Duration gap;
  final DateTime Function() _clock;
  final Map<String, DateTime> _at = {};
  AskLimiter({this.gap = kAskLocationGap, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// How long until [keyHex] may be asked again; null = now.
  Duration? waitFor(String keyHex) {
    final at = _at[keyHex.toLowerCase()];
    if (at == null) return null;
    final left = gap - _clock().difference(at);
    return left > Duration.zero ? left : null;
  }

  /// Records an ask of [keyHex] now.
  void mark(String keyHex) => _at[keyHex.toLowerCase()] = _clock();

  /// Forgets [keyHex] (a request that never left the phone, e.g. no radio).
  void clear(String keyHex) => _at.remove(keyHex.toLowerCase());
}
