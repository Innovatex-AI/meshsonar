// The Network tab's header (build 71): ONE 48 pt line, [region name, tap = region switcher] [pulse chip] [search]
// [overflow: an action sheet with Share link and Export region report] (NetworkHeaderBar). On a narrow phone the name ellipsizes first, then the
// pulse chip collapses to its dot; the search and overflow buttons always keep their 44 pt.
// Its pieces (AZ-3.1): the pulse chip and the one-line summary. Both read the `/v1` client
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
import '../design/app_surfaces.dart' show AppAction, showAppActionSheet, showAppSheet;
import '../design/app_symbols.dart';
import '../../core/time_format.dart' show relativeTime;
import '../region/region_common.dart' show groupInt;
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

/// How the pulse chip is drawn: the Material chip, a 32 pt pill for the one-line header, or only its coloured icon.
enum PulseChipStyle { chip, pill, dot }

class PulseChip extends StatefulWidget {
  final String baseUrl;
  final PulseChipStyle style;
  const PulseChip({super.key, required this.baseUrl, this.style = PulseChipStyle.chip});

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
          void showSheet() => showAppSheet<void>(
                context,
                detents: const [0.5, 0.92],
                builder: (ctx, c) => _PulseSheet(events: open, state: state, controller: c),
              );
          if (widget.style != PulseChipStyle.chip) {
            final dot = widget.style == PulseChipStyle.dot;
            return Semantics(
              button: true,
              label: spoken,
              excludeSemantics: true,
              child: InkWell(
                key: const Key('pulse-chip'),
                borderRadius: BorderRadius.circular(22),
                onTap: showSheet,
                child: SizedBox(
                  height: 44,
                  width: dot ? 44 : null,
                  child: Center(
                    widthFactor: dot ? null : 1,
                    child: dot
                        ? Icon(icon, key: Key('pulse-chip-${state.name}'), size: 22, color: color)
                        : Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: color.withValues(alpha: 0.6))),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(icon, size: 16, color: color),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(label,
                                    key: Key('pulse-chip-${state.name}'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
                                    style: t.textTheme.labelMedium),
                              ),
                            ]),
                          ),
                  ),
                ),
              ),
            );
          }
          return Semantics(
            button: true,
            label: spoken,
            excludeSemantics: true,
            child: ActionChip(
              key: const Key('pulse-chip'),
              avatar: Icon(icon, size: 18, color: color),
              side: BorderSide(color: color.withValues(alpha: 0.6)),
              label: Text(label, key: Key('pulse-chip-${state.name}'), maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: showSheet,
            ),
          );
        },
      );
}

/// Opens the pulse sheet for [baseUrl] on its own (a `/pulse` link): reads the pulse, then shows what the chip shows.
/// Quiet when the server has no pulse read (as the chip hides then).
Future<void> openPulseSheet(BuildContext context, String baseUrl) async {
  final api = networkApiFactory(baseUrl);
  NetworkRead<List<PulseEvent>>? pulse;
  NetworkRead<NetworkSummary>? summary;
  try {
    pulse = await api.pulse().then<NetworkRead<List<PulseEvent>>?>((v) => v, onError: (_) => null);
    summary = await api.summary().then<NetworkRead<NetworkSummary>?>((v) => v, onError: (_) => null);
  } finally {
    api.close();
  }
  final state = pulseChipStateOf(pulse, summary);
  if (!context.mounted || state == PulseChipState.hidden) return;
  final open = [for (final e in pulse!.data) if (e.state == 'open') e];
  await showAppSheet<void>(context, detents: const [0.5, 0.92], builder: (ctx, c) => _PulseSheet(events: open, state: state, controller: c));
}

/// The one-line Network header. Heights: 48 pt line; every control is a 44 pt target.
class NetworkHeaderBar extends StatelessWidget {
  /// The region name, or "All regions".
  final String title;

  /// The host the pulse chip reads (the region's, or the hub's).
  final String? pulseBaseUrl;
  final VoidCallback onRegion;
  final VoidCallback? onSearch;
  final VoidCallback? onShare;

  /// Null hides "Export region report" (no region).
  final VoidCallback? onExport;
  const NetworkHeaderBar({super.key, required this.title, required this.pulseBaseUrl, required this.onRegion, this.onSearch, this.onShare, this.onExport});

  static const double height = 48;

  /// Below this much room for the name and the chip together, the chip shows only its dot (name first, then chip).
  static const double pillFromWidth = 270;
  static const double pillMaxWidth = 150;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    // The header keeps one line at every text size: its text grows only a little (VoiceOver reads the full names).
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    return SizedBox(
      key: const Key('network-header'),
      height: height,
      child: LayoutBuilder(builder: (context, box) {
        // 4 pt edge padding each side, two 44 pt buttons.
        final room = box.maxWidth - 8 - 88;
        final pill = room >= pillFromWidth;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(children: [
            Expanded(
              child: Semantics(
                button: true,
                label: '$title. Change region',
                excludeSemantics: true,
                child: InkWell(
                  key: const Key('network-region-button'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: onRegion,
                  child: SizedBox(
                    height: 44,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12, right: 4),
                      child: Row(children: [
                        Flexible(
                          child: Text(title,
                              key: const Key('region-title'), maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, textScaler: scaler, style: t.textTheme.titleMedium),
                        ),
                        // In the accent colour, so the name reads as a button (it opens the region picker).
                        Icon(Icons.expand_more, key: const Key('region-title-chevron'), size: 22, color: c.primary),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
            if (pulseBaseUrl != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: pill ? pillMaxWidth : 44),
                child: PulseChip(key: ValueKey('network-pulse-$pulseBaseUrl'), baseUrl: pulseBaseUrl!, style: pill ? PulseChipStyle.pill : PulseChipStyle.dot),
              ),
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                key: const Key('network-search'),
                tooltip: 'Search',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.search),
                onPressed: onSearch,
              ),
            ),
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                key: const Key('network-overflow'),
                tooltip: 'Share or export',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_horiz),
                onPressed: onShare == null && onExport == null
                    ? null
                    : () async {
                        // The app's own action sheet (no Material popup menu: test/lint/widget_ban_test.dart).
                        // Titled with the region, so it is clear what is shared or exported; each row has an icon.
                        final v = await showAppActionSheet<String>(
                          context,
                          title: title,
                          actions: [
                            if (onShare != null)
                              const AppAction('Share a link to this screen', 'share', key: Key('network-share'), symbol: AppSymbols.squareAndArrowUp),
                            if (onExport != null)
                              const AppAction('Export region report', 'export', key: Key('region-report-export'), symbol: AppSymbols.squareAndArrowDown),
                          ],
                        );
                        if (v == 'share') onShare?.call();
                        if (v == 'export') onExport?.call();
                      },
              ),
            ),
          ]),
        );
      }),
    );
  }
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
    final mc = MeshSonarColors.of(context);
    final (IconData icon, Color color, String headline) = switch (state) {
      PulseChipState.unusual => (
          Icons.warning_amber_rounded,
          mc.beacon,
          events.length == 1 ? '1 thing is unusual right now' : '${events.length} things are unusual right now',
        ),
      PulseChipState.noFeed => (Icons.portable_wifi_off, mc.textMuted, 'No packets from this region lately'),
      _ => (Icons.check_circle_outline, mc.levelStrong, 'Everything looks normal'),
    };
    return ListView(
      key: const Key('pulse-sheet'),
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // The answer first, in plain words with its colour; the explanation under it.
        Row(children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(child: Semantics(header: true, child: Text(headline, key: const Key('pulse-sheet-headline'), style: t.textTheme.titleLarge))),
        ]),
        const SizedBox(height: 8),
        if (state == PulseChipState.noFeed)
          Text('Nothing has reached the server from here, so it cannot tell whether anything is unusual. Check Observers to see who is reporting.',
              key: const Key('pulse-sheet-no-feed'), style: muted),
        if (state == PulseChipState.normal)
          Text('Traffic and repeaters look as they usually do for this hour. You will see a warning here when that changes.',
              key: const Key('pulse-sheet-normal'), style: muted),
        if (state == PulseChipState.unusual && events.any((e) => pulseLinkOf(e) != null))
          Text('Tap one to see it in the app.', key: const Key('pulse-sheet-hint'), style: muted),
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
    final when = e.endedAt != null && showState ? 'Ended ${relativeTime(e.endedAt)}' : (e.startedAt != null ? 'Since ${relativeTime(e.startedAt)}' : null);
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
