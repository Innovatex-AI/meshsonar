// Network > Observers (build 71): the observers of a region as their own section. Website twin: `/observers`.
// `GET /v1/observers`, favourites first, with kind and status; tap for the observer page (observer_screen.dart).
// Server states: `/v1` live; not live (today's region observer list, with a note); offline (the stored copy with
// "Offline - as of", or a no-connection view with Retry). A region nothing reports to shows the server's own sentence.
// No polling: the list loads when shown and on pull to refresh (battery rules).
import 'package:flutter/material.dart';

import '../../../core/v1/nodes_api.dart';
import '../../region/region_common.dart' show RegionOfflineAsOf, RegionOfflineEmpty, agoText;
import '../../theme.dart';
import '../network_context.dart';
import '../packets/packet_ui.dart' show WebTwinLine, plainServerText;
import 'node_routes.dart';
import 'node_ui.dart';

/// Favourites first, then the order the server (or the roster sort) gave.
List<T> favouritesFirst<T>(List<T> rows, bool Function(T) fav) => [...rows.where(fav), ...rows.where((r) => !fav(r))];

/// The standalone observers list: `ObserversDirectoryView(baseUrl: region.url, regionSlug: region.slug)`.
class ObserversDirectoryView extends StatefulWidget {
  final String baseUrl, regionSlug;
  const ObserversDirectoryView({super.key, required this.baseUrl, required this.regionSlug});
  @override
  State<ObserversDirectoryView> createState() => _ObserversDirectoryViewState();
}

class _ObserversDirectoryViewState extends State<ObserversDirectoryView> {
  late Future<ObserverListPage> _f = _fetch();

  Future<ObserverListPage> _fetch() async {
    final api = nodesApiFactory(widget.baseUrl);
    try {
      return await api.observers();
    } finally {
      api.close();
    }
  }

  Future<void> _reload() async {
    final f = _fetch();
    setState(() {
      _f = f;
    });
    try {
      await f;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return FutureBuilder<ObserverListPage>(
      future: _f,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(
            key: const Key('observers-loading'),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              const SizedBox(height: Gap.m),
              Text('Loading the observers…', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          );
        }
        if (snap.hasError) {
          final e = snap.error;
          if (e is V1Error && e.offline) return SingleChildScrollView(child: RegionOfflineEmpty(what: 'the observers', onRetry: _reload));
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(e is V1Error ? e.message : 'The observers did not load.', key: const Key('observers-error'), textAlign: TextAlign.center),
                const SizedBox(height: Gap.m),
                FilledButton(key: const Key('observers-retry'), onPressed: _reload, child: const Text('Try again')),
              ]),
            ),
          );
        }
        final p = snap.data!;
        return FavouritesListener(builder: (context, store) {
          final rows = favouritesFirst(p.rows, (r) => store.isFavourite(FavouriteKind.observer, r.id));
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              key: const Key('observers-list'),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (p.offlineAsOf != null) Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.l), child: RegionOfflineAsOf(asOf: p.offlineAsOf!, onRetry: _reload)),
                if (p.source == NetworkReadSource.legacy)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
                    child: Text('A simpler list for this region: airtime and clock figures are not available here yet.',
                        key: const Key('observers-legacy-note'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ),
                if (rows.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.xs),
                    child: Text(
                        '${rows.where((r) => r.status == 'online').length} of ${rows.length} online. Observers are listening stations that report what they hear; tap one for its details.',
                        key: const Key('observers-intro'),
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: Column(children: [
                      Text((p.status != null && p.status!.state.name != 'ready' ? plainServerText(p.status!.reason) : null) ?? 'No observer hears this region yet.',
                          key: const Key('observers-empty'), textAlign: TextAlign.center),
                      const SizedBox(height: Gap.m),
                      OutlinedButton(key: const Key('observers-empty-retry'), onPressed: _reload, child: const Text('Check again')),
                    ]),
                  ),
                for (final r in rows)
                  ListTile(
                    key: Key('observer-row-${r.id}'),
                    minTileHeight: 56,
                    leading: Padding(padding: const EdgeInsets.only(top: 6), child: StatusDot(r.status)),
                    title: Row(children: [
                      Flexible(child: Text(readableName(r.name), maxLines: 2, overflow: TextOverflow.ellipsis)),
                      if (store.isFavourite(FavouriteKind.observer, r.id)) ...[
                        const SizedBox(width: Gap.xs),
                        Icon(Icons.star, size: 16, color: MeshSonarColors.of(context).beacon, semanticLabel: 'Favourite'),
                      ],
                    ]),
                    subtitle: Text(
                      [
                        observerKindLabel(r.kind),
                        observerStatusLabel(r.status),
                        if (r.lastSeen != null) 'seen ${agoText(r.lastSeen)}',
                        if (r.packets1h != null) '${r.packets1h} packets last hour',
                        // 0 dBm is "no reading", not a noise level.
                        if (r.noiseFloorDbm != null && r.noiseFloorDbm!.round() != 0) 'noise ${r.noiseFloorDbm!.round()} dBm',
                      ].join(' · '),
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (r.dutyCycleWarn) Icon(Icons.warning_amber_rounded, color: MeshSonarColors.of(context).beacon, semanticLabel: 'Sending too much'),
                      const Icon(Icons.chevron_right),
                    ]),
                    onTap: () => openNetworkObserver(context, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, observerId: r.id),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
                  child: WebTwinLine(Uri(scheme: 'https', host: '${widget.regionSlug}.meshsonar.com', path: '/observers')),
                ),
              ],
            ),
          );
        });
      },
    );
  }
}
