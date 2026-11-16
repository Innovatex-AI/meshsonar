// The `friends` map layer (MeshTrack, meshsonar-infra docs/planning/meshtrack-plan-2026-11-16.md section 7 "Map layer";
// registry.dart kFriendsLayerId, app-only, never on the website). Drawn from `MeshTrackService.state` only:
//   * a pin per friend heard on a group whose See switch is on: initials in a disc, a course arrow while moving;
//   * a short trail (the core keeps 30 min / 20 points) that fades with age; no line across a jump (`breakBefore`);
//   * the meet-up flag of each group with its label (plain text);
//   * my own last sent position as a hollow ring while I share;
//   * an "asked" pin per person who answered "Ask for location" (MT-13, contact screen): the friend disc with an "Asked"
//     mark under it, aging like a friend's pin. Memory only (MeshTrackState.asked).
// Staleness (section 6): full colour < 5 min, faded 5-15 min, grey 15 min - 2 h, not drawn after (list only).
// Additive: other layers are untouched. Colours from the theme and MapTokens (ink, halo, stale grey).
//
// Keys: 'friends-trails-layer', 'friends-layer', 'map-friend-<channelId>-<name>' (+ '-fresh' / '-faded' / '-grey' state key
// on the disc), 'map-friend-arrow-<channelId>-<name>', 'map-meet-<channelId>', 'map-friend-me', 'map-asked-<key 8 hex>'
// (+ '-fresh' / '-faded' / '-grey').
// Also: [showMeetHereMenu], the Drive map's long-press "Meet here".
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../../../core/meshtrack/meshtrack_service.dart';
import '../../design/app_surfaces.dart' show AppAction, AppToastKind, showAppActionSheet, showAppToast;
import '../../design/map_tokens.dart';
import '../../meshtrack/meshtrack_copy.dart' show askedPinMark, askedPinSemantics;

/// The layer's id (registry, layer prefs, `meshsonar://` links).
const String kFriendsLayerId = 'friends';

/// How a friend's pin looks for its staleness: opacity and whether it turns grey. List-only friends are not drawn.
({double opacity, bool grey})? friendLook(MtStaleness s) => switch (s) {
      MtStaleness.fresh => (opacity: 1.0, grey: false),
      MtStaleness.faded => (opacity: 0.55, grey: false),
      MtStaleness.grey => (opacity: 0.6, grey: true),
      MtStaleness.listOnly => null,
    };

/// Up to two letters: the first letters of the first two words ("Sam Lee" -> "SL"), else the first two characters ("KE4BFI"
/// -> "KE").
String friendInitials(String name) {
  final words = name.trim().split(RegExp(r'[\s_\-.]+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  String first(String w) => String.fromCharCode(w.runes.first);
  if (words.length >= 2) return (first(words[0]) + first(words[1])).toUpperCase();
  final r = words[0].runes.toList();
  return String.fromCharCodes(r.take(2)).toUpperCase();
}

/// "just now", "3 min ago", "2 h ago".
String lastHeardText(DateTime lastHeard, DateTime now) {
  final d = now.difference(lastHeard);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  return '${d.inHours} h ago';
}

/// One line of a trail: two points and how strongly it is drawn (1 = newest).
typedef FriendTrailSegment = ({LatLng a, LatLng b, double strength, bool grey});

/// One friend pin as drawn.
typedef FriendPin = ({int channelId, MtFriend friend, double opacity, bool grey, double? arrowDeg});

/// One "asked" pin as drawn (Ask for location).
typedef AskedPin = ({MtAskedPosition asked, double opacity, bool grey});

/// Everything the layer draws, from one state snapshot (pure: tested without a map).
class FriendsLayerData {
  final List<FriendPin> pins;
  final List<FriendTrailSegment> segments;
  final List<({int channelId, MtMeetPin meet})> meets;
  final MtMyPosition? me;
  final List<AskedPin> asked;
  const FriendsLayerData({this.pins = const [], this.segments = const [], this.meets = const [], this.me, this.asked = const []});

  bool get isEmpty => pins.isEmpty && segments.isEmpty && meets.isEmpty && me == null && asked.isEmpty;

  static FriendsLayerData of(MeshTrackState s, DateTime now) {
    final pins = <FriendPin>[];
    final segs = <FriendTrailSegment>[];
    final meets = <({int channelId, MtMeetPin meet})>[];
    for (final g in s.groups) {
      if (!g.config.see) continue;
      final m = g.meet;
      if (m != null) meets.add((channelId: g.channelId, meet: m));
      for (final f in g.friends) {
        final look = friendLook(f.staleness);
        if (look == null || !f.onMap) continue;
        final moving = !f.parked && !f.stopped && (f.speedKmh ?? 0) >= 5 && f.courseDeg != null && f.staleness != MtStaleness.grey;
        pins.add((channelId: g.channelId, friend: f, opacity: look.opacity, grey: look.grey, arrowDeg: moving ? f.courseDeg!.toDouble() : null));
        segs.addAll(trailSegments(f.trail, now, grey: look.grey, opacity: look.opacity));
      }
    }
    final asked = <AskedPin>[
      for (final a in s.asked)
        if (friendLook(mtStaleness(a.at, now)) case final look?) (asked: a, opacity: look.opacity, grey: look.grey),
    ];
    return FriendsLayerData(pins: pins, segments: segs, meets: meets, me: s.sharing ? s.myLastSent : null, asked: asked);
  }
}

/// The lines of one trail, oldest first: no line into a point marked [MtTrailPoint.breakBefore] (a jump), each line weaker
/// the older its newer end is (1 at now, 0.15 at 30 min), scaled by the pin's [opacity].
List<FriendTrailSegment> trailSegments(List<MtTrailPoint> trail, DateTime now, {bool grey = false, double opacity = 1}) {
  final out = <FriendTrailSegment>[];
  for (var i = 1; i < trail.length; i++) {
    final p = trail[i - 1], q = trail[i];
    if (q.breakBefore) continue;
    final age = now.difference(q.at).inSeconds.clamp(0, 1800);
    final strength = (1 - 0.85 * age / 1800) * opacity;
    out.add((a: LatLng(p.lat, p.lon), b: LatLng(q.lat, q.lon), strength: strength, grey: grey));
  }
  return out;
}

/// The colours of the layer in one theme.
class FriendsColours {
  final Color pin, onPin, grey, ink, halo, meet;
  const FriendsColours({required this.pin, required this.onPin, required this.grey, required this.ink, required this.halo, required this.meet});
  static FriendsColours of(BuildContext context) {
    final t = Theme.of(context);
    final b = t.brightness;
    return FriendsColours(
      pin: t.colorScheme.primary,
      onPin: t.colorScheme.onPrimary,
      grey: MapTokens.repeaterStale(b),
      ink: MapTokens.mapInk(b),
      halo: MapTokens.mapHalo(b),
      meet: t.colorScheme.tertiary,
    );
  }
}

/// The friends layer's map children for [service] (trails under the markers), rebuilt on every MeshTrack change and every
/// staleness tick. Insert into the map's children while the layer is on.
List<Widget> friendsLayerWidgets(MeshTrackService service, {DateTime Function()? now}) => [
      _FriendsListen(key: const Key('friends-trails-layer'), service: service, now: now, trails: true),
      _FriendsListen(key: const Key('friends-layer'), service: service, now: now, trails: false),
    ];

class _FriendsListen extends StatefulWidget {
  final MeshTrackService service;
  final DateTime Function()? now;
  final bool trails;
  const _FriendsListen({super.key, required this.service, required this.trails, this.now});
  @override
  State<_FriendsListen> createState() => _FriendsListenState();
}

class _FriendsListenState extends State<_FriendsListen> {
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_changed);
  }

  @override
  void didUpdateWidget(_FriendsListen old) {
    super.didUpdateWidget(old);
    if (!identical(old.service, widget.service)) {
      old.service.removeListener(_changed);
      widget.service.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final data = FriendsLayerData.of(widget.service.state, (widget.now ?? DateTime.now)().toUtc());
    return widget.trails ? FriendsTrailsLayer(data: data) : FriendsMarkersLayer(data: data, now: widget.now);
  }
}

/// The trails (one short line per step, fading with age).
class FriendsTrailsLayer extends StatelessWidget {
  final FriendsLayerData data;
  const FriendsTrailsLayer({super.key, required this.data});
  @override
  Widget build(BuildContext context) {
    final c = FriendsColours.of(context);
    return PolylineLayer(
      polylines: [
        for (final s in data.segments)
          Polyline(
            points: [s.a, s.b],
            strokeWidth: 3,
            color: (s.grey ? c.grey : c.pin).withValues(alpha: s.strength.clamp(0.1, 1.0)),
            borderStrokeWidth: 1,
            borderColor: c.halo.withValues(alpha: 0.5 * s.strength.clamp(0.1, 1.0)),
          ),
      ],
    );
  }
}

/// Meet flags, my ring and the friend pins (pins on top).
class FriendsMarkersLayer extends StatelessWidget {
  final FriendsLayerData data;
  final DateTime Function()? now;
  const FriendsMarkersLayer({super.key, required this.data, this.now});

  @override
  Widget build(BuildContext context) {
    final c = FriendsColours.of(context);
    final at = (now ?? DateTime.now)().toUtc();
    final me = data.me;
    return MarkerLayer(
      rotate: true,
      markers: [
        for (final m in data.meets)
          Marker(
            point: LatLng(m.meet.lat, m.meet.lon),
            width: 140,
            height: 64,
            alignment: Alignment.topCenter,
            child: _MeetFlag(key: ValueKey('map-meet-${m.channelId}'), label: m.meet.label, colours: c),
          ),
        if (me != null)
          Marker(
            point: LatLng(me.lat, me.lon),
            width: 28,
            height: 28,
            child: Semantics(
              label: 'Your last shared position',
              excludeSemantics: true,
              child: CustomPaint(key: const ValueKey('map-friend-me'), painter: _RingPainter(colour: c.pin, halo: c.halo)),
            ),
          ),
        for (final a in data.asked)
          Marker(
            point: LatLng(a.asked.lat, a.asked.lon),
            width: 72,
            height: 64,
            alignment: const Alignment(0, 0.25), // the disc centre (24 of 64 pt from the top) sits on the point
            child: _AskedPin(pin: a, colours: c, ago: lastHeardText(a.asked.at, at)),
          ),
        for (final p in data.pins)
          Marker(
            point: LatLng(p.friend.lat, p.friend.lon),
            width: 48,
            height: 48,
            child: _FriendPin(pin: p, colours: c, lastHeard: lastHeardText(p.friend.lastHeard, at)),
          ),
      ],
    );
  }
}

class _FriendPin extends StatelessWidget {
  final FriendPin pin;
  final FriendsColours colours;
  final String lastHeard;
  const _FriendPin({required this.pin, required this.colours, required this.lastHeard});

  @override
  Widget build(BuildContext context) {
    final f = pin.friend;
    final id = '${pin.channelId}-${f.name}';
    final state = pin.grey ? 'grey' : (pin.opacity < 1 ? 'faded' : 'fresh');
    final fill = pin.grey ? colours.grey : colours.pin;
    final arrow = pin.arrowDeg;
    // The marker stays upright (rotate: true); the arrow follows the map's rotation so it points along the road.
    final mapRotation = MapCamera.maybeOf(context)?.rotation ?? 0;
    return Semantics(
      label: '${f.name}, last heard $lastHeard${f.parked ? ', parked' : ''}',
      excludeSemantics: true,
      child: Opacity(
        key: ValueKey('map-friend-$id'),
        opacity: pin.opacity,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (arrow != null)
              Transform.rotate(
                key: ValueKey('map-friend-arrow-$id'),
                angle: (arrow + mapRotation) * math.pi / 180,
                child: CustomPaint(size: const Size(48, 48), painter: _ArrowPainter(colour: fill, halo: colours.halo)),
              ),
            Container(
              key: ValueKey('map-friend-$id-$state'),
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                shape: BoxShape.circle,
                border: Border.all(color: colours.halo, width: 2),
              ),
              child: Text(
                friendInitials(f.name),
                maxLines: 1,
                textScaler: TextScaler.noScaling, // a map glyph: fixed size like the other markers
                style: TextStyle(color: pin.grey ? colours.halo : colours.onPin, fontSize: 12, fontWeight: FontWeight.w700, height: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A person who answered "Ask for location": the friend disc (initials) with an "Asked" mark under it. The disc centre is
/// the position (the marker is shifted so the disc, not the whole box, sits on the point).
class _AskedPin extends StatelessWidget {
  final AskedPin pin;
  final FriendsColours colours;
  final String ago;
  const _AskedPin({required this.pin, required this.colours, required this.ago});

  @override
  Widget build(BuildContext context) {
    final a = pin.asked;
    final id = a.keyHex.length >= 8 ? a.keyHex.substring(0, 8) : a.keyHex;
    final state = pin.grey ? 'grey' : (pin.opacity < 1 ? 'faded' : 'fresh');
    final fill = pin.grey ? colours.grey : colours.pin;
    return Semantics(
      label: askedPinSemantics(a.name, ago),
      excludeSemantics: true,
      child: Opacity(
        key: ValueKey('map-asked-$id'),
        opacity: pin.opacity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 9),
            Container(
              key: ValueKey('map-asked-$id-$state'),
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: fill, shape: BoxShape.circle, border: Border.all(color: colours.halo, width: 2)),
              child: Text(
                friendInitials(a.name),
                maxLines: 1,
                textScaler: TextScaler.noScaling,
                style: TextStyle(color: pin.grey ? colours.halo : colours.onPin, fontSize: 12, fontWeight: FontWeight.w700, height: 1),
              ),
            ),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: colours.halo.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(6)),
              child: Text(
                askedPinMark,
                maxLines: 1,
                textScaler: TextScaler.noScaling,
                style: TextStyle(color: colours.ink, fontSize: 10, fontWeight: FontWeight.w600, height: 1.2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MeetFlag extends StatelessWidget {
  final String? label;
  final FriendsColours colours;
  const _MeetFlag({super.key, required this.label, required this.colours});
  @override
  Widget build(BuildContext context) {
    final l = label;
    return Semantics(
      label: l == null || l.isEmpty ? 'Meet-up point' : 'Meet-up point: $l',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.flag_rounded, size: 30, color: colours.meet, shadows: [Shadow(color: colours.halo, blurRadius: 3)]),
          if (l != null && l.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: colours.halo.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(6)),
              child: Text(
                l,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: TextScaler.noScaling,
                style: TextStyle(color: colours.ink, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final Color colour, halo;
  _RingPainter({required this.colour, required this.halo});
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 - 3;
    canvas.drawCircle(c, r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..color = halo.withValues(alpha: 0.85));
    canvas.drawCircle(c, r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = colour);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.colour != colour || old.halo != halo;
}

/// A small triangle on the disc's edge, pointing up (north) before rotation.
class _ArrowPainter extends CustomPainter {
  final Color colour, halo;
  _ArrowPainter({required this.colour, required this.halo});
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final path = Path()
      ..moveTo(cx, 1)
      ..lineTo(cx + 7, 11)
      ..lineTo(cx - 7, 11)
      ..close();
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeJoin = StrokeJoin.round
      ..color = halo.withValues(alpha: 0.9));
    canvas.drawPath(path, Paint()..color = colour);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.colour != colour || old.halo != halo;
}

// ------------------------------------------------------------------ the Drive map's long-press "Meet here"

/// Long-press on the Drive map with at least one group: "Meet here" for each group (the one choice is the group). Calls
/// `meetHere`; a spot inside a privacy zone, no radio or a group not on this radio is said plainly. True when a menu showed.
Future<bool> showMeetHereMenu(BuildContext context, MeshTrackService service, double lat, double lon) async {
  final groups = [for (final g in service.state.groups) if (g.config.onRadio) g];
  if (groups.isEmpty) return false;
  final id = await showAppActionSheet<int>(
    context,
    title: 'Meet here',
    message: 'Puts a meet-up point here for the group.',
    sheetKey: const Key('meet-here-sheet'),
    actions: [
      for (final g in groups) AppAction(groups.length == 1 ? 'Meet here' : 'Meet here with ${g.name}', g.channelId, key: Key('meet-here-${g.channelId}')),
    ],
  );
  if (id == null || !context.mounted) return true;
  final before = service.state.group(id)?.meet;
  final r = service.meetHere(id, lat, lon);
  final msg = switch (r) {
    MtResult.ok => null,
    MtResult.privacyZone => 'That spot is inside one of your privacy zones, so it was not shared.',
    MtResult.zonesNotLoaded => 'Your privacy zones are still loading. Try again in a moment.',
    MtResult.radioDisconnected => 'Connect your radio to share a meet-up point.',
    MtResult.notOnRadio => 'This group is not on this radio.',
    _ => 'The meet-up point could not be shared.',
  };
  if (msg != null) {
    showAppToast(context, msg, kind: AppToastKind.error);
  } else {
    showAppToast(context, 'Meet-up point shared', kind: AppToastKind.success, actionLabel: 'Undo', onAction: () {
      // Undo puts back the meet-up point that was there before (or none).
      if (before == null) {
        service.clearMeet(id);
      } else {
        service.meetHere(id, before.lat, before.lon, label: before.label);
      }
    });
  }
  return true;
}
