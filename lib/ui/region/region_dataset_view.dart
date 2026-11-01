// Shared shell of the RF and Growth tabs: loading, error with Retry, "not published here" (404), the server's status
// chip + reason (RegionStatusBlock, quoted verbatim), the offline "as of" label when the ETag cache served a stored
// copy, an honest empty state, and pull to refresh. The tab supplies only the data view.
import 'package:flutter/material.dart';

import '../../core/region_cache.dart' show asOfLabel;
import '../../core/region_dataset_fetch.dart';
import '../../core/region_overview_api.dart' show RegionDataStatus;
import '../theme.dart';
import 'region_common.dart';

class RegionDatasetView<T extends Object> extends StatefulWidget {
  /// Key prefix: `<id>-loading`, `<id>-error`, `<id>-notfound`, `<id>-offline`, `<id>-empty`, `<id>-list`.
  final String id;
  final String title;
  final Future<RegionFetch<T>> Function() load;
  final RegionDataStatus Function(T data) status;
  final bool Function(T data) isEmpty;
  final String emptyText;
  final List<Widget> Function(BuildContext context, T data) build;

  /// Re-load when this changes (the region).
  final Object reloadKey;
  final DateTime Function() now;

  const RegionDatasetView({
    super.key,
    required this.id,
    required this.title,
    required this.load,
    required this.status,
    required this.isEmpty,
    required this.emptyText,
    required this.build,
    required this.reloadKey,
    this.now = DateTime.now,
  });

  @override
  State<RegionDatasetView<T>> createState() => _RegionDatasetViewState<T>();
}

class _RegionDatasetViewState<T extends Object> extends State<RegionDatasetView<T>> {
  late Future<RegionFetch<T>> _future = widget.load();

  @override
  void didUpdateWidget(RegionDatasetView<T> old) {
    super.didUpdateWidget(old);
    if (old.reloadKey != widget.reloadKey) _retry();
  }

  void _retry() => setState(() {
        _future = widget.load();
      });

  @override
  Widget build(BuildContext context) {
    final id = widget.id;
    return FutureBuilder<RegionFetch<T>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(key: Key('$id-loading'), child: const CircularProgressIndicator());
        }
        final r = snap.data;
        if (r == null || !r.ok) {
          final nf = r?.notFound ?? false;
          return _Notice(
            key: Key(nf ? '$id-notfound' : '$id-error'),
            icon: nf ? Icons.info_outline : Icons.cloud_off,
            text: nf ? '${widget.title} is not published for this region.' : '${widget.title} could not load. ${r?.error ?? snap.error ?? ''}',
            onRetry: nf ? null : _retry,
          );
        }
        final d = r.data!;
        final t = Theme.of(context);
        return RefreshIndicator(
          onRefresh: () async {
            _retry();
            await _future;
          },
          child: ListView(
            key: Key('$id-list'),
            padding: const EdgeInsets.all(Gap.l),
            children: [
              Text(widget.title, style: t.textTheme.titleLarge),
              const SizedBox(height: Gap.s),
              // The server's own reason often says the same thing as the empty text ("No findings have been written yet"): say it once.
              RegionStatusBlock(widget.status(d), hideReasonIf: widget.isEmpty(d) ? widget.emptyText : null),
              if (r.offlineAsOf != null) ...[
                const SizedBox(height: Gap.s),
                Row(key: Key('$id-offline'), children: [
                  Icon(Icons.cloud_off, size: 16, color: t.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('${asOfLabel(r.offlineAsOf!, widget.now().toUtc(), offline: true)}. Pull to refresh when back online.',
                        style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ),
                ]),
              ],
              const SizedBox(height: Gap.m),
              if (widget.isEmpty(d))
                Text(widget.emptyText, key: Key('$id-empty'), style: t.textTheme.bodyMedium)
              else
                ...widget.build(context, d),
            ],
          ),
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback? onRetry;
  const _Notice({super.key, required this.icon, required this.text, this.onRetry});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Row(children: [
          Icon(icon),
          const SizedBox(width: Gap.m),
          Expanded(child: Text(text)),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
        ]),
      );
}

/// A titled card around one chart or block.
class DatasetCard extends StatelessWidget {
  final Widget child;
  const DatasetCard({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: Gap.m),
        child: Padding(padding: const EdgeInsets.all(Gap.l), child: child),
      );
}

/// A row of small figure tiles ("Observers reporting 2").
class FigureStrip extends StatelessWidget {
  final List<(String label, String value, String? hint)> figures;
  const FigureStrip(this.figures, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final (label, value, hint) in figures)
        Container(
          constraints: const BoxConstraints(minWidth: 130),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.textTheme.labelMedium),
            Text(value, style: t.textTheme.titleMedium),
            if (hint != null) Text(hint, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
    ]);
  }
}
