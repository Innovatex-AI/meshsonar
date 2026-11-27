// Tools > Status (build 77, Round 2 W9): is the data arriving? A small native screen, since it is the page people
// open when something looks wrong. One call, `GET /v1/status`, and three states: loading, the answer, or a plain
// error with Try again (offline: the no-connection view). Website twin: `/status`.
//
// The answer, in plain words: a headline (Working / Partly working / Not working), each source of packets with when it
// was last heard and its packets in the last full hour ("Not counted yet" when the server did not count them, never
// 0), the summaries the server builds ("Up to date" or "Running late"), and the server's notices. Internal names
// (pipeline ids, rollup ids, the API version, the switched-on feature list) are not shown.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/time_format.dart';
import '../../../core/v1/insights_api.dart';
import '../../region/region_common.dart' show RegionOfflineEmpty, groupInt;
import '../../theme.dart';
import '../analytics/in_place_header.dart';
import '../nodes/node_ui.dart' show StatusDot, UpdatedLine;
import '../packets/packet_ui.dart' show WebTwinLine, dotJoin;
import 'tool_common.dart' show kToolPagePadding;

/// The headline for the server's overall state.
String statusOverallWords(String overall) => switch (overall) {
      'ok' => 'Working',
      'degraded' => 'Partly working',
      'down' => 'Not working',
      _ => 'Not known',
    };

/// A source's state in a word.
String statusSourceWords(String state) => switch (state) {
      'ok' => 'Working',
      'degraded' => 'Partly working',
      'down' => 'Not working',
      _ => 'Not known',
    };

/// The [StatusDot] colour word for a state (online green, stale amber, offline red, else neutral).
String _dot(String state) => switch (state) { 'ok' => 'online', 'degraded' || 'stale' => 'stale', 'down' => 'offline', _ => 'unknown' };

/// The name of a summary the server builds: its own words, else the app's.
String statusSummaryName(StatusSummary s) =>
    s.label ??
    switch (s.name) {
      'e3_hour' => 'Hourly packet counts',
      _ => 'Daily summary',
    };

class StatusScreen extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;

  /// Given: the screen sits in place inside the Tools section and its back arrow calls this.
  final VoidCallback? onClose;

  /// Test seam for "Updated X ago".
  final DateTime Function() clock;
  const StatusScreen({super.key, required this.baseUrl, this.regionSlug, this.onClose, this.clock = DateTime.now});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  StatusReport? _report;
  DateTime? _loadedAt;
  Object? _error;
  bool _loading = true;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final g = ++_gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = insightsApiFactory(widget.baseUrl);
    try {
      final r = await api.status();
      if (!mounted || g != _gen) return;
      setState(() {
        _report = r;
        _loadedAt = widget.clock().toUtc();
        _loading = false;
      });
    } catch (e) {
      if (!mounted || g != _gen) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) => ToolFrame(frameKey: const Key('tool-status'), title: 'Status', onClose: widget.onClose, body: _body(context));

  Widget _body(BuildContext context) {
    final t = Theme.of(context);
    final r = _report;
    if (_loading && r == null) {
      return Center(
        key: const Key('status-loading'),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: Gap.m),
          Text('Checking whether the data is arriving…', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      );
    }
    final e = _error;
    if (r == null) {
      if (e is V1Error && e.offline) return SingleChildScrollView(child: RegionOfflineEmpty(what: 'the status', onRetry: _load));
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(e is V1NotLive ? 'The status is not available from this server yet.' : "Can't reach MeshSonar.", key: const Key('status-error'), textAlign: TextAlign.center),
            const SizedBox(height: Gap.m),
            FilledButton(key: const Key('status-retry'), onPressed: _load, child: const Text('Try again')),
          ]),
        ),
      );
    }
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final late = r.summaries.where((s) => s.state != 'ok').toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('status-page'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: kToolPagePadding,
        children: [
          Row(children: [
            StatusDot(_dot(r.overall), size: 14),
            const SizedBox(width: Gap.s),
            Expanded(child: Text(statusOverallWords(r.overall), key: const Key('status-overall'), style: t.textTheme.titleLarge)),
          ]),
          UpdatedLine(at: _loadedAt, clock: widget.clock, padding: const EdgeInsets.only(top: Gap.xs)),
          if (r.notices.isNotEmpty) ...[
            const SizedBox(height: Gap.m),
            for (final n in r.notices) Padding(padding: const EdgeInsets.only(bottom: Gap.xs), child: Text(n, style: t.textTheme.bodyMedium)),
          ],
          const SizedBox(height: Gap.l),
          Semantics(header: true, child: Text('Where packets come from', style: t.textTheme.titleMedium)),
          for (final s in r.sources) _source(context, s),
          if (r.summaries.isNotEmpty) ...[
            const SizedBox(height: Gap.l),
            Semantics(header: true, child: Text('Summaries', style: t.textTheme.titleMedium)),
            // One line when everything is up to date; each late one by name otherwise.
            if (late.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Row(children: [
                  const StatusDot('online'),
                  const SizedBox(width: Gap.s),
                  Expanded(child: Text('All ${r.summaries.length} are up to date.', key: const Key('status-summaries-ok'), style: t.textTheme.bodyMedium)),
                ]),
              )
            else
              for (final s in late)
                Padding(
                  key: Key('status-summary-${s.name}'),
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Padding(padding: EdgeInsets.only(top: 4), child: StatusDot('stale')),
                    const SizedBox(width: Gap.s),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(statusSummaryName(s), style: t.textTheme.bodyMedium),
                        Text(dotJoin(['Running late', if (s.lastAt != null) 'last built ${relativeTime(s.lastAt)}']), style: muted),
                      ]),
                    ),
                  ]),
                ),
          ],
          const SizedBox(height: Gap.l),
          if (widget.regionSlug != null) WebTwinLine(Uri(scheme: 'https', host: '${widget.regionSlug}.meshsonar.com', path: '/status')),
        ],
      ),
    );
  }

  Widget _source(BuildContext context, StatusSource s) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final line = dotJoin([
      statusSourceWords(s.state),
      s.lastAt == null ? 'not heard yet' : 'last heard ${relativeTime(s.lastAt)}',
      s.rate1h == null ? 'last hour not counted yet' : '${groupInt(s.rate1h!)} packet${s.rate1h == 1 ? '' : 's'} in the last hour',
      if (s.socketsTotal != null && s.socketsTotal! > 0) '${s.socketsConnected ?? 0} of ${s.socketsTotal} connected',
    ]);
    return Padding(
      key: Key('status-source-${s.pipeline}'),
      padding: const EdgeInsets.only(top: Gap.s),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 4), child: StatusDot(_dot(s.state))),
        const SizedBox(width: Gap.s),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(statusSourceName(s), style: t.textTheme.bodyMedium),
            Text(line, key: Key('status-source-line-${s.pipeline}'), style: muted),
          ]),
        ),
      ]),
    );
  }
}
