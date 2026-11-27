// "Export region report" sheet (opened from the Region tab's app bar): fetches the region's `region-report` (through the
// ETag client, so offline it offers the stored copy and says how old it is) and shares it as a text summary, a PDF
// (lib/core/region_report_pdf.dart), the JSON
// file (pretty-printed like the website's download), all tables in one CSV, or any single table as its own CSV with
// the website's file name and bytes (lib/core/region_report_export.dart). Empty tables are disabled (never an empty
// file). Only public data the endpoint already publishes; files go only to the share sheet.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/region_cache.dart' show asOfLabel;
import '../../core/time_format.dart' show relativeDuration;
import '../../core/region_dataset_fetch.dart';
import '../../core/region_report_export.dart';
import '../../core/region_report_pdf.dart';
import '../../core/report_pdf.dart';
import '../report/pdf_export.dart';
import '../app.dart';
import '../design/app_surfaces.dart';

/// Writes [content] to a file called [name] and opens the share sheet.
typedef ShareText = Future<void> Function(String name, String content);

/// Same for binary content (the PDF).
typedef ShareBytes = Future<void> Function(String name, Uint8List content);

Future<void> showRegionReportExport(BuildContext context, {required String baseUrl, required String regionSlug, http.Client? client}) =>
    showAppSheet<void>(
      context,
      detents: const [0.6, 0.92],
      builder: (_, c) => RegionReportExportSheet(baseUrl: baseUrl, regionSlug: regionSlug, client: client),
    );

class RegionReportExportSheet extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;

  /// Test seams.
  final http.Client? client;
  final ShareText? share;
  final ShareBytes? shareBytes;
  final DateTime Function() now;
  const RegionReportExportSheet(
      {super.key, required this.baseUrl, required this.regionSlug, this.client, this.share, this.shareBytes, this.now = DateTime.now});

  @override
  State<RegionReportExportSheet> createState() => _RegionReportExportSheetState();
}

class _RegionReportExportSheetState extends State<RegionReportExportSheet> {
  late Future<RegionFetch<RegionReportExport>> _future = _load();
  bool _busy = false;

  /// The single-table CSV files (rarely wanted) stay folded away until asked for.
  bool _tablesOpen = false;

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
    setState(() => _busy = true);
    try {
      await (widget.share ?? _defaultShare)(name, content());
    } catch (e) {
      if (mounted) showAppToast(context, 'Couldn\'t share the report. $e', kind: AppToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sharePdf(RegionReportExport e) async {
    final units = AppScope.unitsOf(context);
    final name = '${e.slug}-region-report.pdf';
    setState(() => _busy = true);
    try {
      final doc = regionReportPdf(e, units: units);
      if (widget.shareBytes != null) {
        await widget.shareBytes!(name, await renderReportPdf(doc, fonts: await loadReportFonts()));
      } else {
        await shareReportPdf(AppScope.read(context), name, doc);
      }
    } catch (err) {
      if (mounted) showAppToast(context, 'Couldn\'t make the PDF. Text, JSON and CSV still work. $err', kind: AppToastKind.error);
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
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.cloud_off),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: Text(r?.notFound == true
                          ? 'There is no report for ${widget.regionSlug.toUpperCase()} yet.'
                          : 'The report did not load. Check your connection and try again.${r?.error == null ? '' : ' (${r!.error})'}'),
                    ),
                  ]),
                  if (r?.notFound != true) ...[
                    const SizedBox(height: Gap.m),
                    // A full-width button under the message (it was a small text button squeezed beside it).
                    FilledButton(
                        key: const Key('export-retry'),
                        onPressed: () => setState(() {
                              _future = _load();
                            }),
                        child: const Text('Try again')),
                  ],
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
                Semantics(header: true, child: Text('Export ${e.name} report', style: t.textTheme.titleLarge)),
                const SizedBox(height: 4),
                Text(
                  [
                    'Pick a format to share or save',
                    if (g != null) 'made ${agoWords(widget.now().toUtc().difference(g))} ago',
                    if (r.offlineAsOf != null) asOfLabel(r.offlineAsOf!, widget.now().toUtc(), offline: true),
                    'times are UTC',
                  ].join(' · '),
                  key: const Key('export-asof'),
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                if (_busy)
                  const Padding(
                    key: Key('export-busy'),
                    padding: EdgeInsets.only(top: Gap.s),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [LinearProgressIndicator(), SizedBox(height: 4), Text('Preparing the file…')]),
                  ),
                // Build 76: the format most people want first; each row says what the file is for, not its file name.
                ListTile(
                  key: const Key('export-pdf'),
                  leading: const Icon(Icons.picture_as_pdf_outlined),
                  title: const Text('PDF report'),
                  subtitle: const Text('To read or print: charts and every table'),
                  trailing: const Icon(Icons.ios_share, size: 18),
                  onTap: _busy ? null : () => _sharePdf(e),
                ),
                ListTile(
                  key: const Key('export-text'),
                  leading: const Icon(Icons.notes),
                  title: const Text('Text summary'),
                  subtitle: const Text('Short enough to paste into a message'),
                  trailing: const Icon(Icons.ios_share, size: 18),
                  onTap: _busy ? null : () => _share(e.textName, e.toText),
                ),
                ListTile(
                  key: const Key('export-csv-all'),
                  leading: const Icon(Icons.table_chart_outlined),
                  title: const Text('Spreadsheet (CSV)'),
                  subtitle: const Text('Every table in one file'),
                  trailing: const Icon(Icons.ios_share, size: 18),
                  onTap: _busy ? null : () => _share(e.allTablesName, e.allTablesCsv),
                ),
                ListTile(
                  key: const Key('export-json'),
                  leading: const Icon(Icons.data_object),
                  title: const Text('Data file (JSON)'),
                  subtitle: const Text('The full report, for other programs'),
                  trailing: const Icon(Icons.ios_share, size: 18),
                  onTap: _busy ? null : () => _share(e.jsonName, e.toJsonFile),
                ),
                const Divider(),
                ListTile(
                  key: const Key('export-tables-toggle'),
                  leading: const Icon(Icons.view_list_outlined),
                  title: const Text('One table at a time (CSV)'),
                  subtitle: Text('${tables.where((x) => !x.isEmpty).length} of ${tables.length} tables have rows'),
                  trailing: Icon(_tablesOpen ? Icons.expand_less : Icons.expand_more),
                  onTap: () => setState(() => _tablesOpen = !_tablesOpen),
                ),
                if (_tablesOpen)
                  for (final x in tables)
                    ListTile(
                      key: Key('export-table-${x.id}'),
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

/// "5 min" / "3 h" / "2 d": the app's one wording for an age (lib/core/time_format.dart relativeDuration), without
/// "ago" for "made 5 min ago".
String agoWords(Duration d) => d.inSeconds < 90 ? 'under a minute' : relativeDuration(d).replaceFirst(RegExp(r' ago$'), '');
