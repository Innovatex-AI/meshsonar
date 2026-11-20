// The Network tab's region header pieces (AZ-3.1): the pulse chip and the one-line summary. Both read the `/v1` client
// (lib/core/v1/network_api.dart) for the viewed region's host and stay quiet when there is nothing to say:
// - PulseChip (network-pulse-plan-2026-11-19.md section 4, app-next-pass-list item 6) reads GET /v1/pulse and
//   GET /v1/summary and says one of three things: green "Normal" (the pulse read is live and nothing is open), amber
//   "Unusual: <title>" (open events, the most serious first; red for an alert), grey "No packet feed" (the region's
//   summary shows no packets: none in 24 h, or the newest packet more than [noPacketFeedAfter] older than the server's
//   own `meta.generatedAt`, so the phone's clock never decides). It HIDES itself when the server has no pulse read yet,
//   on any error and on a stored (offline) copy: a stale "something is happening" would mislead.
// - WhatChangedCard (same plan, "What changed" card at the top of Analyze) shows the newest 3 pulse items, open or
//   closed, with their time in plain words; an item whose `links.web` is a Network link opens it in the app. It hides
//   when the server has no pulse read or nothing changed in the window. Push for pulse events is AZ-3.8 (not here).
// - NetworkSummaryLine reads GET /v1/summary (falls back to region-overview) and shows the figures it has; nothing on
//   an error (the sections below show their own states).
import 'package:flutter/material.dart';

import '../../core/network_request.dart';

import '../../core/region_cache.dart' show asOfLabel;
import '../../core/v1/network_api.dart';
import '../design/app_surfaces.dart' show showAppSheet;
import '../region/region_common.dart' show groupInt, agoText;
import '../shell/shell_controller.dart' show ShellScope;
import '../theme.dart';

/// The pulse chip's states (network-pulse-plan section 4).
enum PulseChipState { hidden, normal, unusual, noFeed }

/// How old the newest packet may be, against the server's own time, before the chip says "No packet feed".
const Duration noPacketFeedAfter = Duration(hours: 2);

/// True when the summary shows no packet feed: no packets in 24 h, or the newest packet more than [noPacketFeedAfter]
/// before the server built the answer. Null summary (not read) = unknown = false.
bool noPacketFeed(NetworkRead<NetworkSummary>? summary) {
  if (summary == null) return false;
  final d = summary.data;
  if (d.packets24h == 0) return true;
  final last = d.lastPacketAt;
  final at = summary.meta?.generatedAt ?? summary.meta?.dataAt;
  if (last == null || at == null) return false;
  return at.difference(last) > noPacketFeedAfter;
}

/// What the chip shows for a pulse read (null = the server has no pulse read) and a summary read.
PulseChipState pulseChipStateOf(NetworkRead<List<PulseEvent>>? pulse, NetworkRead<NetworkSummary>? summary) {
  if (pulse == null || pulse.offlineAsOf != null) return PulseChipState.hidden;
  if (noPacketFeed(summary)) return PulseChipState.noFeed;
  final open = [for (final e in pulse.data) if (e.state == 'open') e];
  return open.isEmpty ? PulseChipState.normal : PulseChipState.unusual;
}

class PulseChip extends StatefulWidget {
  final String baseUrl;
  const PulseChip({super.key, required this.baseUrl});

  @override
  State<PulseChip> createState() => _PulseChipState();
}

class _PulseChipState extends State<PulseChip> {
  late Future<(NetworkRead<List<PulseEvent>>?, NetworkRead<NetworkSummary>?)> _f;

  @override
  void initState() {
    super.initState();
    _f = _load();
  }

  @override
  void didUpdateWidget(PulseChip old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl) _f = _load();
  }

  Future<(NetworkRead<List<PulseEvent>>?, NetworkRead<NetworkSummary>?)> _load() async {
    final api = networkApiFactory(widget.baseUrl);
    try {
      final pulse = api.pulse().then<NetworkRead<List<PulseEvent>>?>((v) => v, onError: (_) => null);
      final summary = api.summary().then<NetworkRead<NetworkSummary>?>((v) => v, onError: (_) => null);
      return (await pulse, await summary);
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<(NetworkRead<List<PulseEvent>>?, NetworkRead<NetworkSummary>?)>(
        future: _f,
        builder: (context, snap) {
          final pulse = snap.data?.$1;
          final state = snap.hasData ? pulseChipStateOf(pulse, snap.data!.$2) : PulseChipState.hidden;
          if (state == PulseChipState.hidden) return const SizedBox.shrink(key: Key('pulse-chip-hidden'));
          final t = Theme.of(context);
          final mc = MeshSonarColors.of(context);
          final open = [for (final e in pulse!.data) if (e.state == 'open') e];
          final top = open.isEmpty ? null : open.first;
          final (IconData icon, Color color, String label, String spoken) = switch (state) {
            PulseChipState.noFeed => (Icons.portable_wifi_off, mc.textMuted, 'No packet feed', 'Pulse: no packet feed'),
            PulseChipState.unusual => (
                top!.severity == 'alert' ? Icons.error_outline : Icons.warning_amber_rounded,
                top.severity == 'alert' ? t.colorScheme.error : mc.beacon,
                'Unusual: ${top.title}${open.length > 1 ? ' +${open.length - 1}' : ''}',
                'Pulse: ${open.length} open ${open.length == 1 ? 'event' : 'events'}. ${top.title}',
              ),
            _ => (Icons.check_circle_outline, mc.levelStrong, 'Normal', 'Pulse: normal, nothing unusual right now'),
          };
          return Semantics(
            button: true,
            label: spoken,
            excludeSemantics: true,
            child: ActionChip(
              key: const Key('pulse-chip'),
              avatar: Icon(icon, size: 18, color: color),
              side: BorderSide(color: color.withValues(alpha: 0.6)),
              label: Text(label, key: Key('pulse-chip-${state.name}'), maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: () => showAppSheet<void>(
                context,
                detents: const [0.5, 0.92],
                builder: (ctx, c) => _PulseSheet(events: open, state: state, controller: c),
              ),
            ),
          );
        },
      );
}

class _PulseSheet extends StatelessWidget {
  final List<PulseEvent> events;
  final PulseChipState state;
  final ScrollController controller;
  const _PulseSheet({required this.events, required this.state, required this.controller});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return ListView(
      key: const Key('pulse-sheet'),
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Semantics(header: true, child: Text(state == PulseChipState.unusual ? 'Unusual right now' : 'Network pulse', style: t.textTheme.titleLarge)),
        const SizedBox(height: 8),
        if (state == PulseChipState.noFeed)
          Text('No packets have reached the server from this region lately, so the pulse cannot say whether anything is unusual.',
              key: const Key('pulse-sheet-no-feed'), style: muted),
        if (state == PulseChipState.normal)
          Text('Nothing unusual right now: traffic and repeaters look as they usually do for this hour.', key: const Key('pulse-sheet-normal'), style: muted),
        for (final e in events) _PulseTile(e, inSheet: true),
      ],
    );
  }
}

/// One pulse item: title, detail, when; tapping opens its Network link in the app when it has one.
class _PulseTile extends StatelessWidget {
  final PulseEvent e;
  final bool showState;

  /// True inside the pulse sheet: the sheet closes before the link opens.
  final bool inSheet;
  const _PulseTile(this.e, {this.showState = false, this.inSheet = false});

  @override
  Widget build(BuildContext context) {
    final link = pulseLinkOf(e);
    final when = e.endedAt != null && showState ? 'Ended ${agoText(e.endedAt)}' : (e.startedAt != null ? 'Since ${agoText(e.startedAt)}' : null);
    return ListTile(
      key: ValueKey('pulse-item-${e.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text(e.title),
      subtitle: Text([if (e.detail.isNotEmpty) e.detail, ?when].join('\n')),
      trailing: link == null ? null : const Icon(Icons.chevron_right),
      onTap: link == null
          ? null
          : () {
              final shell = ShellScope.maybeRead(context);
              if (shell == null) return;
              if (inSheet) Navigator.of(context).maybePop();
              shell.openNetwork(link);
            },
    );
  }
}

/// The in-app view a pulse item links to (`links.web` read as a Network link); null when it has none the app opens.
NetworkRequest? pulseLinkOf(PulseEvent e) => e.webLink == null ? null : NetworkRequest.parse(e.webLink!);

/// The newest [n] pulse items, open or closed, newest first by start time.
List<PulseEvent> newestPulse(List<PulseEvent> all, [int n = 3]) {
  final out = [...all]..sort((a, b) => (b.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(a.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0)));
  return out.take(n).toList();
}

/// "What changed": the newest 3 pulse items at the top of Analyze (network-pulse-plan section 4).
class WhatChangedCard extends StatefulWidget {
  final String baseUrl;
  const WhatChangedCard({super.key, required this.baseUrl});

  @override
  State<WhatChangedCard> createState() => _WhatChangedCardState();
}

class _WhatChangedCardState extends State<WhatChangedCard> {
  late Future<NetworkRead<List<PulseEvent>>?> _f;

  @override
  void initState() {
    super.initState();
    _f = _load();
  }

  @override
  void didUpdateWidget(WhatChangedCard old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl) _f = _load();
  }

  Future<NetworkRead<List<PulseEvent>>?> _load() async {
    final api = networkApiFactory(widget.baseUrl);
    try {
      return await api.pulse(state: 'all');
    } catch (_) {
      return null;
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<NetworkRead<List<PulseEvent>>?>(
        future: _f,
        builder: (context, snap) {
          final r = snap.data;
          final items = r == null ? const <PulseEvent>[] : newestPulse(r.data);
          if (items.isEmpty) return const SizedBox.shrink(key: Key('what-changed-hidden'));
          final t = Theme.of(context);
          return Card(
            key: const Key('what-changed'),
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(header: true, child: Text('What changed', style: t.textTheme.titleMedium)),
                if (r!.offlineAsOf != null)
                  Text(asOfLabel(r.offlineAsOf!, DateTime.now().toUtc(), offline: true),
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                for (final e in items) _PulseTile(e, showState: true),
              ]),
            ),
          );
        },
      );
}

class NetworkSummaryLine extends StatefulWidget {
  final String baseUrl;
  final DateTime Function() now;
  const NetworkSummaryLine({super.key, required this.baseUrl, this.now = DateTime.now});

  @override
  State<NetworkSummaryLine> createState() => _NetworkSummaryLineState();
}

class _NetworkSummaryLineState extends State<NetworkSummaryLine> {
  late Future<NetworkRead<NetworkSummary>?> _f;

  @override
  void initState() {
    super.initState();
    _f = _load();
  }

  @override
  void didUpdateWidget(NetworkSummaryLine old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl) _f = _load();
  }

  Future<NetworkRead<NetworkSummary>?> _load() async {
    final api = networkApiFactory(widget.baseUrl);
    try {
      return await api.summary();
    } catch (_) {
      return null;
    } finally {
      api.close();
    }
  }

  /// The parts of the line, only for figures the server sent.
  static List<String> partsOf(NetworkSummary s) => [
        if (s.packetsLastHour != null)
          '${groupInt(s.packetsLastHour!)} packets last hour'
        else if (s.packets24h != null)
          '${groupInt(s.packets24h!)} packets in 24 h',
        if (s.repeatersActive24h != null) '${groupInt(s.repeatersActive24h!)} repeaters heard',
        if (s.observersOnlineTotal != null) '${groupInt(s.observersOnlineTotal!)} observers online',
      ];

  @override
  Widget build(BuildContext context) => FutureBuilder<NetworkRead<NetworkSummary>?>(
        future: _f,
        builder: (context, snap) {
          final r = snap.data;
          final parts = r == null ? const <String>[] : partsOf(r.data);
          if (parts.isEmpty) return const SizedBox.shrink(key: Key('network-summary-hidden'));
          final t = Theme.of(context);
          final asOf = r!.offlineAsOf;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              [...parts, if (asOf != null) asOfLabel(asOf, widget.now().toUtc(), offline: true)].join(' · '),
              key: const Key('network-summary'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          );
        },
      );
}
