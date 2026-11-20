// The Network tab's region header pieces (AZ-3.1): the pulse chip and the one-line summary. Both read the `/v1` client
// (lib/core/v1/network_api.dart) for the viewed region's host and stay quiet when there is nothing to say:
// - PulseChip reads GET /v1/pulse and HIDES itself when the server has no pulse read yet, when there are no open events,
//   on any error and on a stored (offline) copy: a stale "something is happening" would mislead.
// - NetworkSummaryLine reads GET /v1/summary (falls back to region-overview) and shows the figures it has; nothing on
//   an error (the sections below show their own states).
import 'package:flutter/material.dart';

import '../../core/region_cache.dart' show asOfLabel;
import '../../core/v1/network_api.dart';
import '../design/app_surfaces.dart' show showAppSheet;
import '../region/region_common.dart' show groupInt, agoText;

class PulseChip extends StatefulWidget {
  final String baseUrl;
  const PulseChip({super.key, required this.baseUrl});

  @override
  State<PulseChip> createState() => _PulseChipState();
}

class _PulseChipState extends State<PulseChip> {
  late Future<NetworkRead<List<PulseEvent>>?> _f;

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

  Future<NetworkRead<List<PulseEvent>>?> _load() async {
    final api = networkApiFactory(widget.baseUrl);
    try {
      return await api.pulse();
    } catch (_) {
      return null; // the chip is a hint, never an error surface
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<NetworkRead<List<PulseEvent>>?>(
        future: _f,
        builder: (context, snap) {
          final r = snap.data;
          if (r == null || r.offlineAsOf != null || r.data.isEmpty) return const SizedBox.shrink(key: Key('pulse-chip-hidden'));
          final events = r.data;
          final top = events.first;
          final t = Theme.of(context);
          final (icon, color) = switch (top.severity) {
            'alert' => (Icons.error_outline, t.colorScheme.error),
            'warn' => (Icons.warning_amber_rounded, t.colorScheme.tertiary),
            _ => (Icons.insights_outlined, t.colorScheme.primary),
          };
          final more = events.length > 1 ? ' +${events.length - 1}' : '';
          return Semantics(
            button: true,
            label: 'Pulse: ${events.length} open ${events.length == 1 ? 'event' : 'events'}. ${top.title}',
            excludeSemantics: true,
            child: ActionChip(
              key: const Key('pulse-chip'),
              avatar: Icon(icon, size: 18, color: color),
              label: Text('${top.title}$more', maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: () => showAppSheet<void>(
                context,
                detents: const [0.5, 0.92],
                builder: (ctx, c) => _PulseSheet(events: events, controller: c),
              ),
            ),
          );
        },
      );
}

class _PulseSheet extends StatelessWidget {
  final List<PulseEvent> events;
  final ScrollController controller;
  const _PulseSheet({required this.events, required this.controller});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListView(
      key: const Key('pulse-sheet'),
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Semantics(header: true, child: Text('Unusual right now', style: t.textTheme.titleLarge)),
        const SizedBox(height: 8),
        for (final e in events)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(e.title),
            subtitle: Text([if (e.detail.isNotEmpty) e.detail, if (e.startedAt != null) 'Since ${agoText(e.startedAt)}'].join('\n')),
          ),
      ],
    );
  }
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
