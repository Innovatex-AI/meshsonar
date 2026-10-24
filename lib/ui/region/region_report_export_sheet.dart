// "Export region report" sheet (opened from the Region tab's app bar): fetches the region's `region-report` (through the
// ETag client, so offline it offers the stored copy and says how old it is) and shares it as a text summary, the JSON
// file (pretty-printed like the website's download), all tables in one CSV, or any single table as its own CSV with
// the website's file name and bytes (lib/core/region_report_export.dart). Empty tables are disabled (never an empty
// file). Only public data the endpoint already publishes; files go only to the share sheet.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/region_cache.dart' show asOfLabel;
import '../../core/region_dataset_fetch.dart';
import '../../core/region_report_export.dart';
import '../app.dart';

/// Writes [content] to a file called [name] and opens the share sheet.
typedef ShareText = Future<void> Function(String name, String content);

Future<void> showRegionReportExport(BuildContext context, {required String baseUrl, required String regionSlug, http.Client? client}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => RegionReportExportSheet(baseUrl: baseUrl, regionSlug: regionSlug, client: client),
    );

class RegionReportExportSheet extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;

  /// Test seams.
  final http.Client? client;
  final ShareText? share;
  final DateTime Function() now;
  const RegionReportExportSheet(
      {super.key, required this.baseUrl, required this.regionSlug, this.client, this.share, this.now = DateTime.now});

  @override
  State<RegionReportExportSheet> createState() => _RegionReportExportSheetState();
}

class _RegionReportExportSheetState extends State<RegionReportExportSheet> {
  late Future<RegionFetch<RegionReportExport>> _future = _load();
  bool _busy = false;

  Future<RegionFetch<RegionReportExport>> _load() =>
      fetchRegionDataset(regionDatasetUri(widget.baseUrl, 'region-report'), RegionReportExport.new, client: widget.client);

  Future<void> _defaultShare(String name, String content) async {
    final s = AppScope.read(context);
    final dir = await s.services.exportDir();
    final f = File('${dir.path}/$name');
    await f.writeAsString(content);
    await s.services.shareFile(f);
  }

  Future<void> _share(String name, String Function() content) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      await (widget.share ?? _defaultShare)(name, content());
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Couldn\'t share the report. $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: FutureBuilder<RegionFetch<RegionReportExport>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(key: Key('export-loading'), child: CircularProgressIndicator()),
              );
            }
            final r = snap.data;
            if (r == null || !r.ok) {
              return Padding(
                key: const Key('export-error'),
                padding: const EdgeInsets.all(Gap.l),
                child: Row(children: [
                  const Icon(Icons.cloud_off),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: Text(r?.notFound == true
                        ? 'The region report is not published for ${widget.regionSlug.toUpperCase()}.'
                        : 'Couldn\'t load the region report. ${r?.error ?? ''}'),
                  ),
                  if (r?.notFound != true)
                    TextButton(
                        onPressed: () => setState(() {
                              _future = _load();
                            }),
                        child: const Text('Retry')),
                ]),
              );
            }
            final e = r.data!;
            final tables = e.tables();
            final g = e.generatedAt;
            return ListView(
              key: const Key('export-list'),
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
              children: [
                Text('Export ${e.name} report', style: t.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  [
                    if (g != null) 'Generated ${agoWords(widget.now().toUtc().difference(g))} ago',
                    if (r.offlineAsOf != null) asOfLabel(r.offlineAsOf!, widget.now().toUtc(), offline: true),
                    'Times in the files are UTC, like the website.',
                  ].join(' · '),
                  key: const Key('export-asof'),
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                if (_busy) const LinearProgressIndicator(),
                ListTile(
                  key: const Key('export-text'),
                  leading: const Icon(Icons.notes),
                  title: const Text('Text summary'),
                  onTap: _busy ? null : () => _share(e.textName, e.toText),
                ),
                ListTile(
                  key: const Key('export-json'),
                  leading: const Icon(Icons.data_object),
                  title: const Text('JSON (the full report)'),
                  subtitle: Text(e.jsonName),
                  onTap: _busy ? null : () => _share(e.jsonName, e.toJsonFile),
                ),
                ListTile(
                  key: const Key('export-csv-all'),
                  leading: const Icon(Icons.table_chart_outlined),
                  title: const Text('CSV, every table in one file'),
                  subtitle: const Text('First column says which table a row is from'),
                  onTap: _busy ? null : () => _share(e.allTablesName, e.allTablesCsv),
                ),
                const Divider(),
                Text('One table as CSV (the website\'s file)', style: t.textTheme.titleSmall),
                for (final x in tables)
                  ListTile(
                    key: Key('export-table-${x.id}'),
                    dense: true,
                    enabled: !x.isEmpty && !_busy,
                    title: Text(x.label),
                    subtitle: Text(x.isEmpty ? 'No rows' : '${x.rows.length} row${x.rows.length == 1 ? '' : 's'} · ${e.csvName(x.id)}'),
                    trailing: const Icon(Icons.ios_share, size: 18),
                    onTap: () => _share(e.csvName(x.id), x.toCsv),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// "5 min" / "3 h" / "2 days".
String agoWords(Duration d) {
  if (d.inMinutes < 1) return 'under a minute';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 48) return '${d.inHours} h';
  return '${d.inDays} days';
}
