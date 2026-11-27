// Analytics > "My Repeaters" (build 77, Round 2 W6): the repeaters and rooms the person starred or claimed in the app,
// with the numbers the website's My Repeaters page shows (status, relays, share of traffic, signal, last heard). The
// website page read stars saved in a browser and was always empty in the app; this one reads the app's own stars and
// claims ("My nodes").
//
// Data: `GET /v1/insights/repeaters` (every repeater of the region, one call) filtered on the phone, so the list of
// what the person starred is never sent. Loads when shown and on pull to refresh, never by polling.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network_request.dart';
import '../../../core/time_format.dart';
import '../../../core/v1/insights_api.dart';
import '../../../core/v1/nodes_api.dart' show nodeRoleLabel, nodeStatusLabel;
import '../../region/region_common.dart' show RegionOfflineEmpty, groupInt;
import '../../shell/shell_controller.dart' show ShellController;
import '../../theme.dart';
import '../../widgets.dart' show EmptyState;
import '../network_context.dart';
import '../nodes/node_routes.dart';
import '../nodes/node_ui.dart' show StatusDot, UpdatedLine, readableName;
import '../packets/packet_ui.dart' show dotJoin, snrText;

/// Worst status first, then by name.
List<RepeaterInsight> myRepeatersInOrder(Iterable<RepeaterInsight> rows) {
  int rank(String s) => switch (s) { 'silent' => 0, 'degraded' => 1, 'unknown' => 2, _ => 3 };
  return [...rows]..sort((a, b) {
      final r = rank(a.status).compareTo(rank(b.status));
      return r != 0 ? r : a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
}

class MyRepeatersPanel extends StatefulWidget {
  final String baseUrl, regionSlug;

  /// Test seam for "Updated X ago".
  final DateTime Function() clock;
  const MyRepeatersPanel({super.key, required this.baseUrl, required this.regionSlug, this.clock = DateTime.now});

  @override
  State<MyRepeatersPanel> createState() => _MyRepeatersPanelState();
}

enum _Load { loading, ready, notLive, offline, failed }

class _MyRepeatersPanelState extends State<MyRepeatersPanel> {
  _Load _state = _Load.loading;
  List<RepeaterInsight> _all = const [];
  DateTime? _loadedAt;
  String? _error;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final g = ++_gen;
    final api = insightsApiFactory(widget.baseUrl);
    try {
      final rows = await api.repeaters();
      if (!mounted || g != _gen) return;
      setState(() {
        _all = rows;
        _loadedAt = widget.clock().toUtc();
        _state = _Load.ready;
      });
    } on V1NotLive {
      if (mounted && g == _gen) setState(() => _state = _Load.notLive);
    } on V1Error catch (e) {
      if (!mounted || g != _gen) return;
      setState(() {
        _state = e.offline ? _Load.offline : _Load.failed;
        _error = e.message;
      });
    } catch (_) {
      if (mounted && g == _gen) setState(() => _state = _Load.failed);
    } finally {
      api.close();
    }
  }

  void _openNodes() {
    final shell = ShellController.of(context);
    if (shell == null) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    shell.openNetwork(NetworkRequest.section(NetworkSection.nodes, region: widget.regionSlug));
  }

  @override
  Widget build(BuildContext context) => FavouritesListener(builder: (context, _) => _body(context, myNodesOf(context).keys));

  Widget _body(BuildContext context, Set<String> mine) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    if (mine.isEmpty) {
      return ListView(key: const Key('my-repeaters'), children: [
        EmptyState(
          key: const Key('my-repeaters-empty'),
          icon: Icons.star_border,
          title: 'No repeaters of yours yet',
          body: 'Star a repeater with the star on its page, or claim your own radio, and it shows up here with its status and traffic.',
          action: OutlinedButton(key: const Key('my-repeaters-find'), onPressed: _openNodes, child: const Text('Find a repeater in Nodes')),
        ),
      ]);
    }
    switch (_state) {
      case _Load.loading:
        return const Center(child: CircularProgressIndicator(key: Key('my-repeaters-loading')));
      case _Load.offline:
        return SingleChildScrollView(child: RegionOfflineEmpty(what: 'your repeaters', onRetry: _load));
      case _Load.notLive:
      case _Load.failed:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_state == _Load.notLive ? 'These figures are not available for this region yet.' : (_error ?? 'Your repeaters did not load.'),
                  key: const Key('my-repeaters-error'), textAlign: TextAlign.center),
              const SizedBox(height: Gap.m),
              FilledButton(key: const Key('my-repeaters-retry'), onPressed: _load, child: const Text('Try again')),
            ]),
          ),
        );
      case _Load.ready:
        break;
    }
    final found = [for (final r in _all) if (mine.contains(r.key)) r];
    final rows = myRepeatersInOrder(found.where((r) => r.role == 'repeater' || r.role == 'room'));
    final notHere = mine.length - found.length;
    final notRelay = found.length - rows.length;
    int count(String s) => rows.where((r) => r.status == s).length;
    final relays = rows.any((r) => r.relays24h != null) ? rows.fold<int>(0, (a, r) => a + (r.relays24h ?? 0)) : null;
    final notes = [
      if (notHere > 0) '$notHere of your nodes ${notHere == 1 ? 'is' : 'are'} not in this region',
      if (notRelay > 0) '$notRelay ${notRelay == 1 ? 'is not a repeater or room' : 'are not repeaters or rooms'}',
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('my-repeaters'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
        children: [
          KeyedSubtree(key: const Key('my-repeaters-updated'), child: UpdatedLine(at: _loadedAt, clock: widget.clock, padding: EdgeInsets.zero)),
          const SizedBox(height: Gap.s),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.l),
              child: Text('None of your ${mine.length} starred or claimed nodes is a repeater or room in this region.', key: const Key('my-repeaters-none'), style: t.textTheme.bodyMedium),
            )
          else ...[
            Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
              _Figure(id: 'total', label: 'My repeaters', value: groupInt(rows.length)),
              _Figure(id: 'active', label: nodeStatusLabel('active'), value: groupInt(count('active'))),
              _Figure(id: 'degraded', label: nodeStatusLabel('degraded'), value: groupInt(count('degraded'))),
              _Figure(id: 'silent', label: nodeStatusLabel('silent'), value: groupInt(count('silent'))),
              if (relays != null) _Figure(id: 'relays', label: 'Relayed in 24 h', value: groupInt(relays)),
            ]),
            const SizedBox(height: Gap.m),
            Text('Worst first. Tap one for its page.', style: muted),
            for (final r in rows) _RepeaterTile(row: r, onTap: () => openNetworkNode(context, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, nodeKey: r.key)),
          ],
          if (notes.isNotEmpty) Padding(padding: const EdgeInsets.only(top: Gap.m), child: Text('${notes.join('; ')}.', key: const Key('my-repeaters-note'), style: muted)),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  final String id, label, value;
  const _Figure({required this.id, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 100),
      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
      decoration: BoxDecoration(color: t.colorScheme.surface, borderRadius: BorderRadius.circular(Corners.card), border: Border.all(color: t.colorScheme.outlineVariant)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(value, key: Key('my-repeaters-figure-$id'), style: numberStyle(context, size: 24)),
        Text(label, style: t.textTheme.labelMedium),
      ]),
    );
  }
}

class _RepeaterTile extends StatelessWidget {
  final RepeaterInsight row;
  final VoidCallback onTap;
  const _RepeaterTile({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final r = row;
    final what = dotJoin([nodeRoleLabel(r.role), nodeStatusLabel(r.status), r.lastHeardAt == null ? 'never heard' : 'heard ${relativeTime(r.lastHeardAt)}']);
    final figures = dotJoin([
      if (r.relays24h != null) 'relayed ${groupInt(r.relays24h!)} in 24 h',
      if (r.trafficShare != null) '${(r.trafficShare!.clamp(0.0, 1.0) * 100).toStringAsFixed(1)}% of traffic',
      if (r.snrMean7d != null) 'signal ${snrText(r.snrMean7d)}',
    ]);
    return ListTile(
      key: Key('my-repeater-${r.key}'),
      contentPadding: EdgeInsets.zero,
      minTileHeight: 64,
      leading: Padding(padding: const EdgeInsets.only(top: 6), child: StatusDot(r.status)),
      title: Text(readableName(r.label), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(what, style: muted),
        if (figures.isNotEmpty) Text(figures, style: muted),
      ]),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
