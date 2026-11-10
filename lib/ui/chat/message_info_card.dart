// How a message travelled, at a glance (chat + radio round, CR4): the card under a long-pressed bubble, the repeats list of
// the details sheet, and the path map. Names come from HopResolver (radio contacts, then the network roster); a prefix two
// known repeaters share is shown in the warning colour with "2 possible", like the official app's red prefix.
import '../map/overlays/mini_map_credit.dart';
import '../map/basemap_layer.dart' show BasemapLayer;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../chat/hop_resolver.dart';
import '../../chat/message_info.dart';
import '../../chat/models.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import '../theme.dart' show MeshSonarColors;

String _clock(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

String _secs(int ms) {
  if (ms < 950) return '$ms ms';
  final s = ms / 1000;
  return s < 10 ? '${s.toStringAsFixed(1)} s' : '${s.round()} s';
}

/// Times of a message in one line: "Sent 09:41:02 · Delivered (2.3 s)" / "Received 09:41:05 · their clock 09:40:58".
String messageTimesLine(ChatMessage m) {
  if (m.isOutgoing) {
    final parts = ['Sent ${_clock(m.tsLocalMs)}'];
    if (m.state == MessageState.acked) parts.add(m.ackMs == null ? 'Delivered' : 'Delivered (round trip ${_secs(m.ackMs!)})');
    if (m.state == MessageState.likelyDelivered) parts.add('Probably delivered (they replied)');
    return parts.join(' · ');
  }
  return 'Received ${_clock(m.tsLocalMs)} · their clock ${_clock(m.tsSender * 1000)}';
}

/// The chain "You › Ridge › Hill › Maya" with ambiguous or unknown hops marked. [ends] are the first and last labels.
class HopChain extends StatelessWidget {
  final String first;
  final List<HopNode> nodes;
  final String last;
  const HopChain({super.key, required this.first, required this.nodes, required this.last});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget chip(String text, {bool hop = false, bool warn = false, bool unknown = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: c.surfaceHigh,
            borderRadius: BorderRadius.circular(Corners.chip),
            border: Border.all(color: warn ? c.warning : (hop ? c.beacon : c.outline.withValues(alpha: 0.4))),
          ),
          child: Text(text, style: AppType.footnote.copyWith(color: warn ? c.warning : (unknown ? c.textMuted : c.textPrimary))),
        );
    final spoken = [first, for (final n in nodes) n.description, last].join(', then ');
    return Semantics(
      label: 'Route: $spoken',
      child: ExcludeSemantics(
        child: Wrap(
          key: const Key('hop-chain'),
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            chip(first),
            for (final n in nodes) ...[
              Text('›', style: AppType.footnote.copyWith(color: c.textMuted)),
              chip(n.ambiguous ? '${n.label} · ${n.candidates.length} possible' : n.label, hop: true, warn: n.ambiguous, unknown: !n.known),
            ],
            Text('›', style: AppType.footnote.copyWith(color: c.textMuted)),
            chip(last),
          ],
        ),
      ),
    );
  }
}

/// The card shown under a long-pressed bubble (CR4): route, numbers, repeats, times. Read-only; the actions sit below it in
/// the context menu.
class MessageInfoCard extends StatelessWidget {
  final ChatMessage message;
  final MessageInfo info;
  final List<RepeatView> repeats;

  /// The other side's name (DM contact or channel sender) and your own label for the chain ends.
  final String peer;
  final String self;
  const MessageInfoCard({super.key, required this.message, required this.info, this.repeats = const [], required this.peer, this.self = 'You'});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final m = message;
    final isChannel = m.convKind == ConvKind.channel;
    final lines = <Widget>[];
    void line(String text, {Key? key, Color? color}) => lines.add(Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(text, key: key, style: AppType.footnote.copyWith(color: color ?? c.textPrimary)),
        ));

    // Route chain: for a received message sender › hops › you; for a sent DM you › hops › them.
    if (info.nodes.isNotEmpty) {
      lines.add(m.isOutgoing ? HopChain(first: self, nodes: info.nodes, last: peer) : HopChain(first: peer, nodes: info.nodes, last: self));
    }
    final numbers = <String>[
      info.routeWord,
      if (info.signalText != null) info.signalText!,
      if (!m.isOutgoing && m.airMs != null) 'on air ${_secs(m.airMs!)}',
    ];
    line(numbers.join(' · '), key: const Key('card-route'));
    if (m.isOutgoing && !isChannel && info.nodes.isNotEmpty && !info.routeIsActual) {
      line('Saved route; this message was sent before routes were recorded.', color: c.textMuted);
    }
    if (isChannel && m.isOutgoing) {
      line(
        repeats.isEmpty ? 'No repeater heard it yet' : 'Relayed by ${relayedBySummary(repeats)}',
        key: const Key('card-repeats'),
        color: repeats.isEmpty ? c.textMuted : null,
      );
    } else if (isChannel && repeats.length > 1) {
      line('Arrived by ${repeats.length} routes', key: const Key('card-arrivals'));
    }
    line(messageTimesLine(m), key: const Key('card-times'), color: c.textMuted);

    return Container(
      key: const Key('message-info-card'),
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(Corners.card)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: lines),
    );
  }
}

/// Every heard copy as a list (details sheet): who relayed it, by which path, signal and when.
class RepeatsList extends StatelessWidget {
  final ChatMessage message;
  final List<RepeatView> repeats;
  final String self;
  const RepeatsList({super.key, required this.message, required this.repeats, this.self = 'You'});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final sent = message.isOutgoing;
    return Column(
      key: const Key('repeats-list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < repeats.length; i++)
          Container(
            key: Key('repeat-$i'),
            width: double.infinity,
            margin: const EdgeInsets.only(top: Gap.xs),
            padding: const EdgeInsets.all(Gap.s),
            decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.small)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                sent ? 'Relayed by ${repeats[i].relayedBy?.description ?? 'unknown'}' : 'Route ${i + 1}: ${repeats[i].hops} ${repeats[i].hops == 1 ? 'repeater' : 'repeaters'}',
                style: AppType.subhead.copyWith(color: c.textPrimary, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              if (repeats[i].path.isNotEmpty)
                HopChain(
                  first: sent ? self : (message.senderName ?? 'Sender'),
                  nodes: repeats[i].path,
                  last: sent ? 'your radio' : self,
                ),
              const SizedBox(height: 4),
              Text(
                [
                  if (repeats[i].signal != null) repeats[i].signal!,
                  if (repeats[i].afterMs != null) '+${_secs(repeats[i].afterMs!)}',
                  _clock(repeats[i].repeat.heardMs),
                ].join(' · '),
                style: AppType.footnote.copyWith(color: c.textMuted),
              ),
            ]),
          ),
      ],
    );
  }
}

/// The path of a message on a map: every hop with a known position, in order, joined by a line. Hops without a position are
/// listed under it. [mapBuilder] is the seam tests use (no tile downloads).
class MessagePathMapScreen extends StatelessWidget {
  final String title;
  final List<HopNode> nodes;

  /// Join the hops with a line (one route). False for the repeaters of a sent channel message: each relayed it on its own,
  /// so a line between them would draw a route that never existed.
  final bool connect;
  const MessagePathMapScreen({super.key, required this.title, required this.nodes, this.connect = true});

  static Widget Function(BuildContext context, List<HopNode> placed, bool connect)? mapBuilder;

  static Future<void> open(BuildContext context, {required String title, required List<HopNode> nodes, bool connect = true}) =>
      Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => MessagePathMapScreen(title: title, nodes: nodes, connect: connect)));

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final placed = [for (final n in nodes) if (n.hasPosition && n.known) n];
    final missing = [for (final n in nodes) if (!(n.hasPosition && n.known)) n];
    return CupertinoPageScaffold(
      key: const Key('path-map-screen'),
      backgroundColor: c.bg,
      navigationBar: CupertinoNavigationBar(middle: Text(title)),
      // CupertinoPageScaffold has no Material text style; without this the labels get Flutter's debug underline.
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
        child: Column(children: [
          Expanded(
            child: placed.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.xl),
                      child: Text('None of these repeaters has a known position.',
                          key: const Key('path-map-none'), textAlign: TextAlign.center, style: AppType.body.copyWith(color: c.textMuted)),
                    ),
                  )
                : (mapBuilder ?? _defaultMap)(context, placed, connect),
          ),
          if (missing.isNotEmpty)
            Container(
              key: const Key('path-map-missing'),
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.m),
              child: Text(
                'Not on the map (no known position): ${missing.map((n) => n.description).join('; ')}',
                style: AppType.footnote.copyWith(color: c.textMuted),
              ),
            ),
        ]),
        ),
      ),
    );
  }

  static Widget _defaultMap(BuildContext context, List<HopNode> placed, bool connect) {
    final m = MeshSonarColors.of(context);
    final pts = [for (final n in placed) LatLng(n.lat!, n.lon!)];
    final fit = pts.length == 1
        ? MapOptions(initialCenter: pts.single, initialZoom: 12, backgroundColor: m.mapBackground)
        : MapOptions(
            initialCameraFit: CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(48)), backgroundColor: m.mapBackground);
    return Stack(children: [
      FlutterMap(
        key: const Key('path-map'),
        options: fit,
        children: [
          const BasemapLayer(),
          if (connect && pts.length > 1) PolylineLayer(polylines: [Polyline(points: pts, strokeWidth: 3, color: m.beacon)]),
          MarkerLayer(markers: [
            for (var i = 0; i < placed.length; i++)
              Marker(
                point: pts[i],
                width: 140,
                height: 44,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AppSymbolIcon(AppSymbols.antenna, color: m.beacon, size: 22, scaleWithText: false),
                  Text(connect ? '${i + 1}. ${placed[i].label}' : placed[i].label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.caption.copyWith(fontWeight: FontWeight.w600)),
                ]),
              ),
          ]),
          const MiniMapCredit(),
        ],
      ),
    ]);
  }
}
