// Network > Observers (build 71; build 77 Round 2 N-U4, N-U11): the observers of a region as their own section.
// Website twin: `/observers`. `GET /v1/observers`, every page of it.
//
// Three kinds are tracked and all are listed: MeshSonar observers (stations that report straight to MeshSonar), phone
// observers, and outside feeds. Order: favourites, then online, then stale, then offline, newest report first.
// Chips with counts narrow the list: All, Online, MeshSonar, Phone, Outside. "Updated X ago · pull to refresh" says
// how old the list is (it loads when shown and on pull to refresh, never by polling: battery rules).
// Server states: `/v1` live; not live (today's region observer list, with a note); offline (the stored copy with
// "Offline - as of", or a no-connection view with Retry). A region nothing reports to shows the server's own sentence.
import 'package:flutter/material.dart';

import '../../../core/time_format.dart';
import '../../../core/v1/nodes_api.dart';
import '../../region/region_common.dart' show RegionOfflineAsOf, RegionOfflineEmpty;
import '../../theme.dart';
import '../network_context.dart';
import '../packets/packet_ui.dart' show WebTwinLine, dotJoin, plainServerText;
import 'node_routes.dart';
import 'node_ui.dart';

/// Favourites first, then the order the rows came in.
List<T> favouritesFirst<T>(List<T> rows, bool Function(T) fav) => [...rows.where(fav), ...rows.where((r) => !fav(r))];

/// The chips of the Observers list.
enum ObserverChip {
  all('All'),
  online('Online'),
  meshsonar('MeshSonar'),
  phone('Phone'),
  outside('Outside');

  final String label;
  const ObserverChip(this.label);

  bool matches(ObserverRow r) => switch (this) {
        ObserverChip.all => true,
        ObserverChip.online => r.status == 'online',
        ObserverChip.meshsonar => r.kind == 'fixed',
        ObserverChip.phone => r.kind == 'phone',
        ObserverChip.outside => r.kind == 'outside',
      };
}

/// Pages of `GET /v1/observers` read before the list stops asking (200 a page).
const int observerListMaxPages = 10;

/// The standalone observers list: `ObserversDirectoryView(baseUrl: region.url, regionSlug: region.slug)`.
class ObserversDirectoryView extends StatefulWidget {
  final String baseUrl, regionSlug;

  /// Test seam for "Updated X ago".
  final DateTime Function() clock;
  const ObserversDirectoryView({super.key, required this.baseUrl, required this.regionSlug, this.clock = DateTime.now});
  @override
  State<ObserversDirectoryView> createState() => _ObserversDirectoryViewState();
}

class _ObserversDirectoryViewState extends State<ObserversDirectoryView> {
  late Future<ObserverListPage> _f = _fetch();
  ObserverChip _chip = ObserverChip.all;

  /// Every observer of the region: the first page, then the rest while the server says there is more.
  Future<ObserverListPage> _fetch() async {
    final api = nodesApiFactory(widget.baseUrl);
    try {
      final first = await api.observers();
      var rows = first.rows;
      var next = first.next;
      for (var i = 1; next != null && i < observerListMaxPages; i++) {
        try {
          final p = await api.observers(cursor: next);
          final seen = {for (final r in rows) r.id};
          rows = [...rows, ...p.rows.where((r) => !seen.contains(r.id))];
          next = p.next;
        } catch (_) {
          break; // what loaded is shown
        }
      }
      return ObserverListPage(
          rows: rows, next: next, source: first.source, offlineAsOf: first.offlineAsOf, status: first.status, sources: first.sources, loadedAt: widget.clock().toUtc());
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

  Widget _chips(BuildContext context, List<ObserverRow> all) => SingleChildScrollView(
        key: const Key('observers-chips'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
        child: Row(children: [
          for (final c in ObserverChip.values)
            Padding(
              padding: const EdgeInsets.only(right: Gap.s),
              child: ChoiceChip(
                key: Key('observers-chip-${c.name}'),
                label: Text('${c.label} ${all.where(c.matches).length}'),
                selected: _chip == c,
                onSelected: (_) => setState(() => _chip = c),
              ),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
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
          bool fav(ObserverRow r) => store.isFavourite(FavouriteKind.observer, r.id);
          final all = p.rows;
          final rows = favouritesFirst(observersInListOrder(all.where(_chip.matches)), fav);
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
                    child: Text('A simpler list for this region: airtime and clock figures are not available here yet.', key: const Key('observers-legacy-note'), style: muted),
                  ),
                if (all.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, 0),
                    child: Text(
                        '${all.where((r) => r.status == 'online').length} of ${all.length} online. Observers are listening stations that report what they hear; tap one for its details.',
                        key: const Key('observers-intro'),
                        style: muted),
                  ),
                  _chips(context, all),
                  // An offline copy says its own age above; a fresh list says when it was loaded.
                  if (p.offlineAsOf == null) KeyedSubtree(key: const Key('observers-updated'), child: UpdatedLine(at: p.loadedAt, clock: widget.clock)),
                ],
                if (all.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: Column(children: [
                      Text((p.status != null && p.status!.state.name != 'ready' ? plainServerText(p.status!.reason) : null) ?? 'No observer hears this region yet.',
                          key: const Key('observers-empty'), textAlign: TextAlign.center),
                      const SizedBox(height: Gap.m),
                      OutlinedButton(key: const Key('observers-empty-retry'), onPressed: _reload, child: const Text('Check again')),
                    ]),
                  )
                else if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: Column(children: [
                      Text('No observer matches "${_chip.label}".', key: const Key('observers-none-match'), textAlign: TextAlign.center),
                      const SizedBox(height: Gap.m),
                      OutlinedButton(key: const Key('observers-show-all'), onPressed: () => setState(() => _chip = ObserverChip.all), child: const Text('Show every observer')),
                    ]),
                  ),
                for (final r in rows) _ObserverTile(row: r, fav: fav(r), onTap: () => openNetworkObserver(context, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, observerId: r.id)),
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

/// One observer row. Two short lines under the name, each kept whole: what it is and whether it reports, then its
/// figures. A separator never starts a line (Round 2 N-V5).
class _ObserverTile extends StatelessWidget {
  final ObserverRow row;
  final bool fav;
  final VoidCallback onTap;
  const _ObserverTile({required this.row, required this.fav, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final r = row;
    final what = dotJoin([
      observerKindWords(r),
      observerStatusLabel(r.status, label: r.statusLabel),
      r.lastSeen == null ? 'no report yet' : 'seen ${relativeTime(r.lastSeen)}',
    ]);
    final figures = dotJoin([
      if (r.packets1h != null) '${r.packets1h} packet${r.packets1h == 1 ? '' : 's'} last hour',
      if (r.nodesHeard24h != null) '${r.nodesHeard24h} node${r.nodesHeard24h == 1 ? '' : 's'} in 24 h',
      if (r.noiseReading != null) 'noise ${r.noiseReading!.round()} dBm',
    ]);
    return ListTile(
      key: Key('observer-row-${r.id}'),
      minTileHeight: 72,
      leading: Padding(padding: const EdgeInsets.only(top: 6), child: StatusDot(r.status)),
      title: Row(children: [
        Flexible(child: Text(readableName(r.name), maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (fav) ...[
          const SizedBox(width: Gap.xs),
          // A favourite is a choice, not a warning: the accent, never amber.
          Icon(Icons.star, size: 16, color: t.colorScheme.primary, semanticLabel: 'Favourite'),
        ],
      ]),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(what, key: Key('observer-row-what-${r.id}'), style: muted),
        if (figures.isNotEmpty) Text(figures, key: Key('observer-row-figures-${r.id}'), style: muted),
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (r.dutyCycleWarn) Icon(Icons.warning_amber_rounded, color: MeshSonarColors.of(context).warning, semanticLabel: 'Sending too much'),
        const Icon(Icons.chevron_right),
      ]),
      onTap: onTap,
    );
  }
}
