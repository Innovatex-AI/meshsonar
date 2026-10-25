// "Observers": the region's observers with online state, last seen and packet counts. Data: `region-observers`.
import 'package:flutter/material.dart';

import '../../core/region_overview_api.dart';
import '../theme.dart';
import '../widgets.dart';
import 'region_common.dart';

class ObserversPanel extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;
  const ObserversPanel({
    super.key,
    required this.baseUrl,
    required this.regionSlug,
  });

  @override
  State<ObserversPanel> createState() => _ObserversPanelState();
}

class _ObserversPanelState extends State<ObserversPanel> {
  late RegionOverviewApi _api;
  Future<RegionObservers>? _future;

  @override
  void initState() {
    super.initState();
    _api = regionApiFactory(widget.baseUrl);
    _future = _api.observers();
  }

  @override
  void didUpdateWidget(ObserversPanel old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl || old.regionSlug != widget.regionSlug) {
      _api.close();
      _api = regionApiFactory(widget.baseUrl);
      _reload();
    }
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  void _reload() => setState(() {
    _future = _api.observers();
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RegionObservers>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(Gap.xl),
            child: Center(
              child: CircularProgressIndicator(key: Key('observers-loading')),
            ),
          );
        }
        final err = snap.error;
        if (err is RegionApiException && err.offline) {
          return RegionOfflineEmpty(what: 'the observers', onRetry: _reload);
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ErrorBanner('${snap.error}'),
                TextButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          );
        }
        final asOf = snap.data!.offlineAsOf;
        final body = ObserversContent(data: snap.data!, onRefresh: _reload);
        if (asOf == null) return body;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [RegionOfflineAsOf(asOf: asOf, onRetry: _reload), body],
        );
      },
    );
  }
}

/// The loaded state, separate so it can be tested without HTTP. Online first, then most recently seen.
class ObserversContent extends StatelessWidget {
  final RegionObservers data;
  final VoidCallback? onRefresh;
  const ObserversContent({super.key, required this.data, this.onRefresh});

  static List<RegionObserver> sorted(List<RegionObserver> rows) {
    final l = [...rows];
    l.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      final x = a.lastSeen, y = b.lastSeen;
      if (x == null && y == null) {
        return a.displayName.toLowerCase().compareTo(
          b.displayName.toLowerCase(),
        );
      }
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });
    return l;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final rows = sorted(data.rows);
    final online = rows.where((r) => r.online).length;
    return Column(
      key: const Key('observers-content'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Observers', style: t.textTheme.titleLarge)),
            if (onRefresh != null)
              IconButton(
                tooltip: 'Refresh',
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        RegionStatusBlock(data.status),
        const SizedBox(height: Gap.s),
        if (rows.isEmpty)
          const EmptyState(
            icon: Icons.sensors_off_outlined,
            title: 'No observers listed',
            body: 'This region has no observers on record yet.',
          )
        else ...[
          Text(
            '$online online of ${rows.length}',
            key: const Key('observers-count'),
            style: t.textTheme.labelLarge,
          ),
          const SizedBox(height: Gap.xs),
          for (final r in rows) ObserverTile(observer: r),
        ],
      ],
    );
  }
}

class ObserverTile extends StatelessWidget {
  final RegionObserver observer;
  const ObserverTile({super.key, required this.observer});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final o = observer;
    final dot = o.online ? t.colorScheme.primary : m.silent;
    final bits = <String>[
      o.online ? 'Online' : 'Offline',
      'seen ${agoText(o.lastSeen)}',
      if (o.packetsPerHour != null) '${groupInt(o.packetsPerHour!)} pkt/h',
      if (o.nodesHeard24h != null) '${groupInt(o.nodesHeard24h!)} nodes 24 h',
      if (o.noiseFloorDbm != null) 'noise ${o.noiseFloorDbm!.round()} dBm',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        key: Key('observer-${o.key}'),
        leading: Container(
          key: Key(o.online ? 'dot-online' : 'dot-offline'),
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        title: Text(
          o.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(bits.join(' · ')),
        trailing: o.source == 'meshsonar'
            ? Icon(
                Icons.verified_outlined,
                size: 18,
                color: t.colorScheme.primary,
              )
            : null,
      ),
    );
  }
}
