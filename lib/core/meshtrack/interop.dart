// Receive-only parsers for positions from other apps on a MeshTrack group (meshtrack plan section 5.9, MT-12). Used
// ONLY on MeshTrack group channels, after `parseMeshTrack` said the body is not MT1:
//
//   typed by a person (official MeshCore app, any app):
//     a Plus Code, full (`87G8Q2X5+7F2`) or short (`Q2X5+7F`, recovered near the receiver's own position)
//     `lat, lon` (the whole message, both with a decimal point, e.g. `39.96121, -82.99881`)
//     a `geo:` URI anywhere in the text (`geo:39.96121,-82.99881`, `geo:0,0?q=39.9,-82.9(Label)`)
//   -> a pin marked "typed"; the message is NOT consumed (it stays chat: a person wrote it for people to read).
//
//   MeshCore-TEAM (github.com/tmacinc/MeshCore-TEAM, format read from its telemetry_message.dart; no code copied):
//     `#TEL:` + base64 (padding optional) of exactly 11 bytes:
//       [lat int32 BE x1e7][lon int32 BE x1e7][companion battery][phone battery][forwarding status]
//     Only the position is used (battery and status are out of v1). The sender is the channel name prefix.
//   -> a pin from TEAM; consumed (machine text, TEAM's own app hides it too). `#CAP:` (TEAM capability adverts) is
//      consumed with no position.
//
// Never throws; 0,0 ("null island") and out-of-range coordinates are dropped. Pure Dart: no Flutter imports.
import 'dart:convert';
import 'dart:typed_data';

import 'plus_code.dart';

/// Where a friend's position came from.
enum MtSource {
  /// Our MT1 format.
  meshTrack,

  /// Typed by a person: Plus Code, `lat, lon` or `geo:`.
  typed,

  /// MeshCore-TEAM `#TEL:`.
  team,
}

/// What [parseInterop] found.
sealed class MtInterop {
  const MtInterop();

  /// Hide this message from chat (machine text).
  bool get consume;
}

/// A position from another app or typed by a person.
final class MtInteropPosition extends MtInterop {
  final double lat;
  final double lon;

  /// Uncertainty in metres (Plus Code area, decimals typed, `u=` of a geo URI).
  final double accuracyM;
  final MtSource source;
  const MtInteropPosition(this.lat, this.lon, {required this.accuracyM, required this.source});
  @override
  bool get consume => source == MtSource.team;
}

/// Machine text from another app with nothing to show (`#CAP:`): consumed, no position.
final class MtInteropIgnore extends MtInterop {
  const MtInteropIgnore();
  @override
  bool get consume => true;
}

const String kTeamTelPrefix = '#TEL:';
const String kTeamCapPrefix = '#CAP:';

/// Parses a group message BODY from another app. [refLat]/[refLon] (the receiver's own last position) are needed to
/// recover a short Plus Code; without them a short code is ignored. Null = nothing for MeshTrack (ordinary chat).
MtInterop? parseInterop(String body, {double? refLat, double? refLon}) {
  try {
    if (body.length > 640) return null;
    final t = body.trim();
    if (t.startsWith(kTeamTelPrefix)) return parseTeamTel(t);
    if (t.startsWith(kTeamCapPrefix)) return const MtInteropIgnore();
    return _geoUri(t) ?? _latLon(t) ?? _plusCode(t, refLat, refLon);
  } catch (_) {
    return null;
  }
}

/// A MeshCore-TEAM `#TEL:` message; null when it is not one or the payload is bad.
MtInteropPosition? parseTeamTel(String text) {
  try {
    final t = text.trim();
    if (!t.startsWith(kTeamTelPrefix)) return null;
    var p = t.substring(kTeamTelPrefix.length).split(RegExp(r'\s')).first;
    if (p.length < 15 || p.length > 16) return null;
    if (!RegExp(r'^[A-Za-z0-9+/]{15}=?$').hasMatch(p)) return null;
    p = p.padRight(p.length + (4 - p.length % 4) % 4, '=');
    final raw = base64.decode(p);
    if (raw.length != 11) return null;
    final d = ByteData.sublistView(Uint8List.fromList(raw));
    final lat = d.getInt32(0, Endian.big) / 1e7;
    final lon = d.getInt32(4, Endian.big) / 1e7;
    if (!_ok(lat, lon)) return null;
    return MtInteropPosition(lat, lon, accuracyM: 10, source: MtSource.team);
  } catch (_) {
    return null;
  }
}

bool _ok(double lat, double lon) =>
    lat.isFinite && lon.isFinite && lat.abs() <= 90 && lon.abs() <= 180 && !(lat == 0 && lon == 0);

final RegExp _geoRe = RegExp(r'geo:(-?\d{1,3}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)(?:,-?\d+(?:\.\d+)?)?((?:;[^\s?;]*)*)(?:\?(\S*))?',
    caseSensitive: false);
final RegExp _pairRe = RegExp(r'(-?\d{1,3}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)');

MtInteropPosition? _geoUri(String t) {
  final m = _geoRe.firstMatch(t);
  if (m == null) return null;
  var lat = double.parse(m.group(1)!), lon = double.parse(m.group(2)!);
  var acc = 10.0;
  final params = m.group(3) ?? '';
  final u = RegExp(r';u=(\d+(?:\.\d+)?)', caseSensitive: false).firstMatch(params);
  if (u != null) acc = double.parse(u.group(1)!).clamp(1, 100000).toDouble();
  if (lat == 0 && lon == 0) {
    final q = m.group(4);
    if (q == null) return null;
    final qm = RegExp(r'(?:^|&)q=([^&]*)').firstMatch(q);
    if (qm == null) return null;
    final pair = _pairRe.firstMatch(Uri.decodeComponent(qm.group(1)!.replaceAll('+', ' ')));
    if (pair == null) return null;
    lat = double.parse(pair.group(1)!);
    lon = double.parse(pair.group(2)!);
  }
  if (!_ok(lat, lon)) return null;
  return MtInteropPosition(lat, lon, accuracyM: acc, source: MtSource.typed);
}

final RegExp _wholePairRe = RegExp(r'^\(?\s*(-?\d{1,2}\.(\d+))\s*,\s*(-?\d{1,3}\.(\d+))\s*\)?$');

MtInteropPosition? _latLon(String t) {
  final m = _wholePairRe.firstMatch(t);
  if (m == null) return null;
  final lat = double.parse(m.group(1)!), lon = double.parse(m.group(3)!);
  if (!_ok(lat, lon)) return null;
  // Fewest decimals typed sets the uncertainty: 1 -> 11 km, 3 -> 111 m, 5 -> 1.1 m.
  final dec = m.group(2)!.length < m.group(4)!.length ? m.group(2)!.length : m.group(4)!.length;
  var acc = 111320.0;
  for (var i = 0; i < dec; i++) {
    acc /= 10;
  }
  return MtInteropPosition(lat, lon, accuracyM: acc < 1 ? 1 : acc, source: MtSource.typed);
}

MtInteropPosition? _plusCode(String t, double? refLat, double? refLon) {
  String? found;
  for (final raw in t.split(RegExp(r'\s+'))) {
    final tok = raw.replaceAll(RegExp(r'^[(\[<"]+|[)\]>",.;:!?]+$'), '');
    if (!tok.contains('+')) continue;
    final sep = tok.indexOf('+');
    final full = PlusCode.isFull(tok) && sep == 8 && tok.replaceAll('0', '').length >= 9;
    // A short code needs 4+ characters before the '+' and 2+ after, so chat like "22+22" is not a position.
    final short = PlusCode.isShort(tok) && sep >= 4 && tok.length - sep - 1 >= 2;
    if (!full && !short) continue;
    if (found != null) return null; // two codes in one message: ambiguous, ignore
    found = tok;
  }
  if (found == null) return null;
  String? fullCode = found;
  if (PlusCode.isShort(found)) {
    if (refLat == null || refLon == null) return null;
    fullCode = PlusCode.recoverNearest(found, refLat, refLon);
  }
  if (fullCode == null) return null;
  final a = PlusCode.tryDecode(fullCode);
  if (a == null || !_ok(a.lat, a.lon)) return null;
  return MtInteropPosition(a.lat, a.lon, accuracyM: a.heightM / 2, source: MtSource.typed);
}
