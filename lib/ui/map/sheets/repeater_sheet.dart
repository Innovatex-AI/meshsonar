// Tap a repeater on a clustered map layer (global network list or the region roster): a bottom sheet with its name,
// type, full key (copyable), last advert / last heard, distance from you (Units setting), the roster's own figures
// when the key is in the viewed region's roster, the data source, and "Open repeater page" when the region is known.
// Several repeaters on one spot (one tower) open a list first. Design: stream-1-maps.md 4.6.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/heard.dart' show haversineM;
import '../../../core/region_repeaters_api.dart' show RepeaterActivity;
import '../../../core/repeater_points.dart' show advertText;
import '../../../core/units.dart' show Units;
import '../../app.dart' show AppScope;
import '../../theme.dart';
import '../layers/repeater_cluster_layer.dart' show networkBandColors, rosterBandColors;
import '../layers/repeater_map_source.dart';
import '../map_layers.dart' show formatSnrShort;
import '../../claims/claim_widgets.dart' show ClaimRepeaterAction;

/// What the sheet needs from the host besides the point.
class RepeaterSheetContext {
  /// The phone's position, or null without a fix.
  final LatLng? position;

  /// Opens the region repeater page (the host passes `openRepeaterDetail`); null = no link.
  final void Function(BuildContext context, RepeaterPoint point)? openRegionPage;

  final DateTime Function() clock;

  /// Units to format with; null = the Settings units ([AppScope.unitsOf]).
  final Units? units;
  const RepeaterSheetContext({this.position, this.openRegionPage, this.clock = DateTime.now, this.units});
}

Future<void> showRepeaterSheet(BuildContext context, RepeaterPoint point, {RepeaterSheetContext ctx = const RepeaterSheetContext()}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(child: RepeaterSheet(point: point, ctx: ctx)),
  );
}

/// Several repeaters drawn on the same spot: pick one.
Future<void> showRepeaterListSheet(BuildContext context, List<RepeaterPoint> points, {RepeaterSheetContext ctx = const RepeaterSheetContext()}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: RepeaterListSheet(
        points: points,
        onPick: (p) {
          Navigator.of(sheet).pop();
          showRepeaterSheet(context, p, ctx: ctx);
        },
      ),
    ),
  );
}

String roleText(bool isRoom) => isRoom ? 'Room server' : 'Repeater';

String rosterStatusText(RepeaterActivity a) => switch (a) {
  RepeaterActivity.active => 'Active',
  RepeaterActivity.quiet => 'Quiet',
  RepeaterActivity.fresh => 'New',
  RepeaterActivity.stale => 'Stale',
};

/// The source line under the figures.
String sourceText(RepeaterPoint p) => switch (p.source) {
  RepeaterPointSource.global => p.attribution ?? 'Data: MeshCore Map (map.meshcore.io)',
  RepeaterPointSource.roster => 'MeshSonar region roster${p.region == null ? '' : ' (${p.region!.name})'}',
};

Color _dotColor(BuildContext context, RepeaterPoint p) {
  final c = p.source == RepeaterPointSource.global ? networkBandColors(context) : rosterBandColors();
  return c[p.band < c.length ? p.band : c.length - 1];
}

class RepeaterSheet extends StatelessWidget {
  final RepeaterPoint point;
  final RepeaterSheetContext ctx;

  /// False when the sheet is embedded in the map's info panel (there is no route of its own to pop).
  final bool dismissOnOpen;
  const RepeaterSheet({super.key, required this.point, this.ctx = const RepeaterSheetContext(), this.dismissOnOpen = true});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final units = ctx.units ?? AppScope.unitsOf(context);
    final now = ctx.clock();
    final p = point;
    final r = p.roster;
    Widget stat(String label, String value, {Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(width: Gap.s),
          Flexible(
            child: Text(
              value,
              key: key,
              textAlign: TextAlign.end,
              style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    final pos = ctx.position;
    final distance = pos == null ? null : haversineM(pos.latitude, pos.longitude, p.lat, p.lon);
    final seenVerb = p.source == RepeaterPointSource.global ? 'Last advert' : 'Last heard';
    final open = ctx.openRegionPage;
    return SingleChildScrollView(
      child: Padding(
        key: const Key('repeater-sheet'),
        padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: p.isRoom ? null : _dotColor(context, p),
                    shape: BoxShape.circle,
                    border: p.isRoom ? Border.all(color: _dotColor(context, p), width: 3) : null,
                  ),
                ),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: Text(p.name, key: const Key('repeater-sheet-name'), style: t.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(roleText(p.isRoom), key: const Key('repeater-sheet-role'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.s),
            _KeyRow(keyHex: p.key),
            const SizedBox(height: Gap.xs),
            stat(seenVerb, seenText(p.lastSeen, now), key: const Key('repeater-sheet-seen')),
            stat(
              'Distance from you',
              distance == null ? 'No position fix' : units.distance(distance),
              key: const Key('repeater-sheet-distance'),
            ),
            if (r != null) ...[
              stat('Status', rosterStatusText(r.status), key: const Key('repeater-sheet-status')),
              if (r.snrMeanDb != null) stat('Mean SNR (24 h)', '${formatSnrShort(r.snrMeanDb!)} dB'),
              if (r.signalGrade != null) stat('Signal grade', r.signalGrade!),
              if (r.adverts24h != null) stat('Adverts (24 h)', '${r.adverts24h}'),
              if (r.neighbours != null) stat('Neighbours', '${r.neighbours}'),
              stat('Hash prefix', r.hashPrefix.toUpperCase() + (r.ambiguous ? ' (shared)' : '')),
            ],
            const SizedBox(height: Gap.s),
            Text(sourceText(p), key: const Key('repeater-sheet-source'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            if (open != null && p.region != null) ...[
              const SizedBox(height: Gap.m),
              FilledButton.icon(
                key: const Key('repeater-sheet-open'),
                onPressed: () {
                  if (dismissOnOpen) Navigator.of(context).pop();
                  open(context, p);
                },
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open repeater page'),
              ),
            ],
            ClaimRepeaterAction(keyHex: p.key, name: p.name, isRoom: p.isRoom),
          ],
        ),
      ),
    );
  }
}

/// "3 h ago (2026-10-24)" (the website's advert wording without the verb), or "Not reported".
String seenText(DateTime? t, DateTime now) => t == null ? 'Not reported' : advertText(t, now, verb: '').trim();

class _KeyRow extends StatelessWidget {
  final String keyHex;
  const _KeyRow({required this.keyHex});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mono = t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontFamilyFallback: const ['Menlo', 'Courier']);
    final head = keyHex.length >= 8 ? keyHex.substring(0, 8) : keyHex;
    final tail = keyHex.length >= 8 ? keyHex.substring(8) : '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text.rich(
            key: const Key('repeater-sheet-key'),
            TextSpan(
              style: mono,
              children: [
                TextSpan(text: head, style: const TextStyle(fontWeight: FontWeight.w800)),
                TextSpan(text: tail),
              ],
            ),
          ),
        ),
        IconButton(
          key: const Key('repeater-sheet-copy'),
          tooltip: 'Copy key',
          icon: const Icon(Icons.copy, size: 20),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: keyHex));
            if (!context.mounted) return;
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Key copied')));
          },
        ),
      ],
    );
  }
}

class RepeaterListSheet extends StatelessWidget {
  final List<RepeaterPoint> points;
  final ValueChanged<RepeaterPoint> onPick;
  const RepeaterListSheet({super.key, required this.points, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      key: const Key('repeater-list-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
          child: Text('${points.length} repeaters at this spot', style: t.textTheme.titleLarge),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final p in points)
                ListTile(
                  key: ValueKey('repeater-list-${p.key}'),
                  leading: Icon(p.isRoom ? Icons.meeting_room_outlined : Icons.cell_tower, color: _dotColor(context, p)),
                  title: Text(p.name),
                  subtitle: Text('${roleText(p.isRoom)} · ${p.key.substring(0, p.key.length >= 8 ? 8 : p.key.length)}'),
                  onTap: () => onPick(p),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
