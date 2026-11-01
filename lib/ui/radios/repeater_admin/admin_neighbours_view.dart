// Neighbours: the repeaters this one hears directly, with SNR, how long ago, and a name when the phone's radio knows that
// key. Read from the binary neighbour list (no CLI text, no 160-character cap).
import 'package:flutter/material.dart';

import '../../../radio/repeater_admin.dart';
import '../../../radio/repeater_wire.dart';
import '../../theme.dart';
import 'admin_common.dart';
import 'admin_controller.dart';

class AdminNeighboursView extends StatefulWidget {
  final RepeaterAdminController controller;
  const AdminNeighboursView({super.key, required this.controller});
  @override
  State<AdminNeighboursView> createState() => _AdminNeighboursViewState();
}

class _AdminNeighboursViewState extends State<AdminNeighboursView> {
  RepeaterAdminController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && c.neighbours == null) c.loadNeighbours();
    });
  }

  Color _snrColor(BuildContext context, double snr) {
    final t = Theme.of(context).colorScheme;
    if (snr >= 5) return t.primary;
    if (snr >= -5) return t.onSurface;
    return t.error;
  }

  String _snrWord(double snr) => snr >= 5 ? 'strong' : (snr >= 0 ? 'good' : (snr >= -5 ? 'fair' : 'weak'));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final list = c.neighbours;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: RefreshIndicator(
              onRefresh: c.loadNeighbours,
              child: ListView(
                key: const Key('admin-neighbours'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
                children: [
                  if (c.notices['neighbours'] != null) NoticeBanner(c.notices['neighbours']!, bannerKey: const Key('neighbours-notice')),
                  Wrap(spacing: Gap.s, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    SegmentedButton<bool>(
                      key: const Key('neighbour-order'),
                      segments: const [
                        ButtonSegment(value: false, label: Text('Newest'), icon: Icon(Icons.schedule)),
                        ButtonSegment(value: true, label: Text('Strongest'), icon: Icon(Icons.signal_cellular_alt)),
                      ],
                      selected: {c.neighboursByStrength},
                      onSelectionChanged: (s) => c.setNeighbourOrder(byStrength: s.first),
                      style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(kTarget)),
                    ),
                    if (c.isAdmin)
                      OutlinedButton.icon(
                        key: const Key('discover-neighbours'),
                        style: OutlinedButton.styleFrom(minimumSize: kTarget),
                        icon: const Icon(Icons.radar),
                        label: const Text('Look for neighbours'),
                        onPressed: () => _discover(context),
                      ),
                  ]),
                  const SizedBox(height: Gap.s),
                  if (c.loadingNeighbours && list == null)
                    const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator(key: Key('neighbours-loading'))))
                  else if (list != null && list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(Gap.l),
                      child: Text('No neighbours. This repeater does not hear any other repeater right now. Use "Look for neighbours", wait a minute, then pull down to read the list again.',
                          key: const Key('neighbours-empty'), style: t.textTheme.bodyLarge?.copyWith(height: 1.35)),
                    )
                  else if (list != null) ...[
                    Padding(padding: const EdgeInsets.only(bottom: Gap.xs), child: Text('${list.length} neighbour${list.length == 1 ? '' : 's'}', style: t.textTheme.titleSmall)),
                    for (final n in list) _row(context, n),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, RepeaterNeighbour n) {
    final t = Theme.of(context);
    final name = c.nameFor(n.prefixHex);
    final color = _snrColor(context, n.snrDb);
    final word = _snrWord(n.snrDb);
    return Semantics(
      container: true,
      label: '${name ?? 'Unknown repeater ${n.prefixHex}'}, signal ${n.snrDb.toStringAsFixed(1)} decibels, $word, heard ${agoText(n.secondsAgo)}',
      excludeSemantics: true,
      child: Card(
        key: Key('neighbour-${n.prefixHex}'),
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(Gap.m),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name ?? 'Unknown repeater', style: t.textTheme.titleSmall),
                Text('Key starts ${n.prefixHex}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                Text('Heard ${agoText(n.secondsAgo)}', style: t.textTheme.bodyMedium),
              ]),
            ),
            const SizedBox(width: Gap.s),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${n.snrDb.toStringAsFixed(1)} dB', style: t.textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w700)),
              Text(word, style: t.textTheme.bodySmall?.copyWith(color: color)),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _discover(BuildContext context) async {
    final ok = await confirmAction(context,
        title: 'Look for neighbours?',
        body: 'The repeater sends a discovery request and listens for about a minute. It uses a little airtime, and the repeater answers at most 4 requests every 2 minutes. Then pull down to read its list again.',
        confirmLabel: 'Look',
        confirmKey: const Key('discover-confirm'));
    if (!ok || !context.mounted) return;
    try {
      final r = await c.discoverNeighbours();
      if (context.mounted) showSnack(context, r.ok ? 'Looking. Read the list again in a minute.' : r.message);
    } on AdminException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }
}
