// MeshTrack v1 wire format (meshsonar-infra docs/planning/meshtrack-plan-2026-11-16.md section 3).
//
// Every MeshTrack message is ordinary MeshCore channel text on a group's private channel; the firmware adds the
// `name: ` prefix, so everything here works on the BODY after it. ASCII only, tokens separated by one space, version
// prefix `MT1`:
//
//   MT1 @<code>[ s<kmh>][ c<deg>]   position (s 0-300 km/h, c 0-359; c left out below 5 km/h)
//   MT1 @<code> s0                  parked (last position before going quiet)
//   MT1 ?                           "where are you?" to everyone sharing
//   MT1 ? <name>                    to one name
//   MT1 !<code>[ <label>]           meet-up point (label <= 24 bytes, printable)
//   MT1 !x                          clear the meet-up point
//   MT1 x                           I stopped sharing
//
// Parse tolerance: trim, runs of spaces collapsed, `MT1` case-insensitive, code letters upper-cased, unknown trailing
// tokens ignored, a bad optional token (s999, c400) drops that field only, a bad code drops the message. Anything that
// does not parse (MT2+, "MT1 hi", plain chat) returns null and is NOT consumed: it stays an ordinary chat message.
//
// Pure Dart: no Flutter imports (lib/core layering rule).
import 'dart:convert';

import 'plus_code.dart';

/// Version prefix of MeshTrack v1.
const String kMtPrefix = 'MT1';

/// Longest body accepted (the radio's text limit).
const int kMtMaxBodyBytes = 160;

/// Longest name in `MT1 ? <name>` (MeshCore names are at most 31 bytes).
const int kMtMaxNameBytes = 31;

/// Longest meet-up label.
const int kMtMaxLabelBytes = 24;

/// Highest speed carried (km/h).
const int kMtMaxSpeedKmh = 300;

/// Below this speed no course is sent (it is noise when crawling).
const int kMtCourseMinKmh = 5;

/// A parsed MeshTrack message. Exhaustive: [MtPosition], [MtRequest], [MtMeet], [MtMeetClear], [MtStop].
sealed class MtMessage {
  const MtMessage();
}

/// `MT1 @<code>[ s<kmh>][ c<deg>]`.
final class MtPosition extends MtMessage {
  /// The code as received, upper-cased.
  final String code;
  final PlusCodeArea area;

  /// km/h, null when not sent or out of range.
  final int? speedKmh;

  /// Degrees 0-359, null when not sent or out of range.
  final int? courseDeg;
  const MtPosition(this.code, this.area, {this.speedKmh, this.courseDeg});

  /// `s0`: the sender parked and goes quiet.
  bool get parked => speedKmh == 0;
  double get lat => area.lat;
  double get lon => area.lon;
}

/// `MT1 ?` (all, [name] null) or `MT1 ? <name>`.
final class MtRequest extends MtMessage {
  final String? name;
  const MtRequest([this.name]);
}

/// `MT1 !<code>[ <label>]`.
final class MtMeet extends MtMessage {
  final String code;
  final PlusCodeArea area;

  /// Plain text only (never a link), at most 24 bytes, control characters removed.
  final String? label;
  const MtMeet(this.code, this.area, {this.label});
  double get lat => area.lat;
  double get lon => area.lon;
}

/// `MT1 !x`.
final class MtMeetClear extends MtMessage {
  const MtMeetClear();
}

/// `MT1 x`.
final class MtStop extends MtMessage {
  const MtStop();
}

final RegExp _spaces = RegExp(r'[ \t]+');

/// Parses a channel message BODY (after `name: `). Null = not a MeshTrack v1 message (leave it as chat). Never throws.
MtMessage? parseMeshTrack(String body) {
  try {
    return _parse(body);
  } catch (_) {
    return null;
  }
}

MtMessage? _parse(String body) {
  if (body.length > kMtMaxBodyBytes * 4) return null; // cheap guard before encoding
  if (utf8.encode(body).length > kMtMaxBodyBytes) return null;
  if (body.contains('\n') || body.contains('\r')) return null;
  final t = body.trim().replaceAll(_spaces, ' ');
  final tokens = t.split(' ');
  if (tokens.length < 2 || tokens[0].toUpperCase() != kMtPrefix) return null;
  final verb = tokens[1];
  if (verb.length >= 2 && verb[0] == '@') {
    final code = verb.substring(1).toUpperCase();
    final area = _decode(code);
    if (area == null) return null;
    int? speed, course;
    var sSeen = false, cSeen = false;
    for (final tok in tokens.skip(2)) {
      if (tok.length < 2) continue;
      final k = tok[0].toLowerCase();
      if (k == 's' && !sSeen) {
        sSeen = true;
        speed = _intIn(tok.substring(1), 0, kMtMaxSpeedKmh);
      } else if (k == 'c' && !cSeen) {
        cSeen = true;
        course = _intIn(tok.substring(1), 0, 359);
      }
    }
    return MtPosition(code, area, speedKmh: speed, courseDeg: course);
  }
  if (verb == '?') {
    if (tokens.length == 2) return const MtRequest();
    final name = cutUtf8Bytes(tokens.skip(2).join(' ').trim(), kMtMaxNameBytes);
    return name.isEmpty ? const MtRequest() : MtRequest(name);
  }
  if (verb.length >= 2 && verb[0] == '!') {
    final rest = verb.substring(1);
    if (rest.toLowerCase() == 'x') return const MtMeetClear();
    final code = rest.toUpperCase();
    final area = _decode(code);
    if (area == null) return null;
    final label = cleanMeetLabel(tokens.skip(2).join(' '));
    return MtMeet(code, area, label: label);
  }
  if (verb.toLowerCase() == 'x') return const MtStop();
  return null;
}

PlusCodeArea? _decode(String code) {
  // Full codes only (a short code needs a reference place, which a wire message never carries).
  final a = PlusCode.tryDecode(code);
  if (a == null) return null;
  if (!a.lat.isFinite || !a.lon.isFinite || a.lat.abs() > 90 || a.lon.abs() > 180) return null;
  return a;
}

int? _intIn(String s, int lo, int hi) {
  if (s.isEmpty || s.length > 4) return null;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return null;
  }
  final v = int.parse(s);
  return v < lo || v > hi ? null : v;
}

/// [s] cut to at most [maxBytes] UTF-8 bytes without splitting a character.
String cutUtf8Bytes(String s, int maxBytes) {
  if (utf8.encode(s).length <= maxBytes) return s;
  final out = StringBuffer();
  var n = 0;
  for (final r in s.runes) {
    final b = utf8.encode(String.fromCharCode(r)).length;
    if (n + b > maxBytes) break;
    out.writeCharCode(r);
    n += b;
  }
  return out.toString();
}

/// A meet-up label made safe to show: control characters dropped, spaces collapsed, cut to 24 bytes; null when empty.
String? cleanMeetLabel(String? raw) {
  if (raw == null) return null;
  final b = StringBuffer();
  for (final r in raw.runes) {
    if (r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || r == 0x2028 || r == 0x2029) continue;
    b.writeCharCode(r);
  }
  final s = cutUtf8Bytes(b.toString().replaceAll(_spaces, ' ').trim(), kMtMaxLabelBytes).trim();
  return s.isEmpty ? null : s;
}

/// `MT1 @<code>[ s<kmh>][ c<deg>]`. [speedKmh] is clamped to 0-300; the course is left out below 5 km/h or when unknown.
String formatMtPosition(String code, {int? speedKmh, int? courseDeg}) {
  final b = StringBuffer('$kMtPrefix @$code');
  int? s;
  if (speedKmh != null) {
    s = speedKmh.clamp(0, kMtMaxSpeedKmh);
    b.write(' s$s');
  }
  if (courseDeg != null && s != null && s >= kMtCourseMinKmh) b.write(' c${((courseDeg % 360) + 360) % 360}');
  return b.toString();
}

/// `MT1 @<code> s0`.
String formatMtParked(String code) => '$kMtPrefix @$code s0';

/// `MT1 ?` or `MT1 ? <name>`.
String formatMtRequest([String? name]) {
  final n = name == null ? '' : cutUtf8Bytes(name.replaceAll(RegExp(r'\s+'), ' ').trim(), kMtMaxNameBytes);
  return n.isEmpty ? '$kMtPrefix ?' : '$kMtPrefix ? $n';
}

/// `MT1 !<code>[ <label>]`.
String formatMtMeet(String code, {String? label}) {
  final l = cleanMeetLabel(label);
  return l == null ? '$kMtPrefix !$code' : '$kMtPrefix !$code $l';
}

/// `MT1 !x`.
const String kMtMeetClearText = '$kMtPrefix !x';

/// `MT1 x`.
const String kMtStopText = '$kMtPrefix x';

/// What a chat bubble or a Chats row preview shows for a MeshTrack message [body] instead of its wire text ("MT1 @86GV…
/// s40 c46" is not for people), or null when [body] is not a MeshTrack message. Groups hide these from chat unless "Show
/// position messages" is on; this covers the ones kept as chat (that switch, and messages heard before a channel became
/// a group).
String? mtReadable(String body) => switch (parseMeshTrack(body)) {
      null => null,
      MtPosition(parked: true) => 'MeshTrack: parked here',
      MtPosition() => 'MeshTrack: shared a position',
      MtRequest(name: null) => 'MeshTrack: asked where everyone is',
      MtRequest(:final name?) => 'MeshTrack: asked where $name is',
      MtMeet(label: final l?) when l.isNotEmpty => 'MeshTrack: meet-up point "$l"',
      MtMeet() => 'MeshTrack: set a meet-up point',
      MtMeetClear() => 'MeshTrack: cleared the meet-up point',
      MtStop() => 'MeshTrack: stopped sharing',
    };
