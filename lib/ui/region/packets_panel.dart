// "Live packets" panel for one region: recent packets from the website's `region-packets` read, pull-to-refresh, and a
// live mode that polls every 10 s while the panel is visible (route/tab on top, app foreground). No SSE, by design.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/region_packets_api.dart';
import '../theme.dart';

enum PacketsLoad { loading, ready, error }

class PacketsPanel extends StatefulWidget {
  final Uri baseUrl;
  final String regionSlug;

  /// Test seam; defaults to an [HttpRegionPacketsApi] on [baseUrl].
  final RegionPacketsApi? api;

  /// Live poll interval; 10 s in production.
  final Duration pollEvery;
  const PacketsPanel({
    super.key,
    required this.baseUrl,
    required this.regionSlug,
    this.api,
    this.pollEvery = const Duration(seconds: 10),
  });

  @override
  State<PacketsPanel> createState() => _PacketsPanelState();
}

class _PacketsPanelState extends State<PacketsPanel> with WidgetsBindingObserver {
  static const _maxRows = 200;
  static const _routeChips = <int?, String>{null: 'All', 1: 'Flood', 2: 'Direct', 0: 'T-flood', 3: 'T-direct'};

  late RegionPacketsApi _api;
  List<PacketRow> _rows = const [];
  PacketsStatus? _status;
  PacketsLoad _load = PacketsLoad.loading;
  String? _error;
  bool _busy = false; // server asked us to back off
  bool _reconnecting = false; // a poll failed but we still show older rows
  bool _live = true;
  int? _route;
  bool _foreground = true;
  bool _visible = true;
  bool _inFlight = false;
  int _gen = 0; // bumped on region/filter change so stale responses are dropped
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = widget.api ?? HttpRegionPacketsApi(widget.baseUrl);
    _fetch();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = TickerMode.valuesOf(context).enabled; // false when an enclosing tab/route is hidden
    if (v != _visible) {
      _visible = v;
      _syncTimer();
      if (v) _fetch();
    }
  }

  @override
  void didUpdateWidget(PacketsPanel old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl || old.regionSlug != widget.regionSlug) {
      if (widget.api == null) _api = HttpRegionPacketsApi(widget.baseUrl);
      _gen++;
      _rows = const [];
      _status = null;
      _error = null;
      _busy = _reconnecting = false;
      _load = PacketsLoad.loading;
      _fetch();
    }
    if (old.pollEvery != widget.pollEvery) _syncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final fg = s == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    _syncTimer();
    if (fg) _fetch();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  bool get _polling => _live && _visible && _foreground;

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (_polling) _timer = Timer.periodic(widget.pollEvery, (_) => _fetch());
  }

  Future<void> _fetch() async {
    if (_inFlight || !mounted) return;
    _inFlight = true;
    final gen = _gen;
    try {
      final page = await _api.packets(limit: 50, route: _route);
      if (!mounted || gen != _gen) return;
      setState(() {
        _rows = _merge(_rows, page.rows);
        _status = page.status;
        _load = PacketsLoad.ready;
        _error = null;
        _busy = false;
        _reconnecting = false;
      });
    } on PacketsException catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        if (_rows.isEmpty) {
          _load = PacketsLoad.error;
          _error = e.message;
        }
        _busy = e.busy;
        _reconnecting = !e.busy;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        if (_rows.isEmpty) {
          _load = PacketsLoad.error;
          _error = 'unexpected error';
        }
        _reconnecting = true;
      });
    } finally {
      _inFlight = false;
      if (mounted) _syncTimer();
    }
  }

  /// Newest first, deduped by hash (fresh copy wins), capped.
  static List<PacketRow> _merge(List<PacketRow> old, List<PacketRow> fresh) {
    final byHash = <String, PacketRow>{for (final r in old) r.hash: r, for (final r in fresh) r.hash: r};
    final out = byHash.values.toList()..sort((a, b) => b.firstAt.compareTo(a.firstAt));
    return out.length > _maxRows ? out.sublist(0, _maxRows) : out;
  }

  void _setRoute(int? r) {
    if (r == _route) return;
    setState(() {
      _route = r;
      _gen++;
      _rows = const [];
      _load = PacketsLoad.loading;
      _error = null;
    });
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.s, 0),
          child: Row(children: [
            Expanded(child: Text('Live packets', style: tt.titleMedium)),
            Text(_live ? 'Live' : 'Paused', style: tt.labelMedium?.copyWith(color: _live ? cs.primary : cs.onSurfaceVariant)),
            Switch(
              key: const Key('packets-live-switch'),
              value: _live,
              onChanged: (v) {
                setState(() => _live = v);
                _syncTimer();
                if (v) _fetch();
              },
            ),
          ]),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.l),
            children: [
              for (final e in _routeChips.entries)
                Padding(
                  padding: const EdgeInsets.only(right: Gap.s),
                  child: ChoiceChip(
                    key: Key('packets-route-${e.key ?? 'all'}'),
                    label: Text(e.value),
                    selected: _route == e.key,
                    onSelected: (_) => _setRoute(e.key),
                  ),
                ),
            ],
          ),
        ),
        if (_busy) _banner(context, 'Server busy, retrying shortly.', Icons.hourglass_top),
        if (_reconnecting) _banner(context, 'Reconnecting... showing the last packets.', Icons.sync_problem),
        Expanded(child: RefreshIndicator(onRefresh: _fetch, child: _body(context))),
      ],
    );
  }

  Widget _banner(BuildContext context, String text, IconData icon) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const Key('packets-banner'),
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
      child: Row(children: [
        Icon(icon, size: 16, color: cs.onSurfaceVariant),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
      ]),
    );
  }

  /// Always scrollable so pull-to-refresh works on empty and error states too.
  Widget _message(BuildContext context, {required IconData icon, required String title, String? detail, Key? key}) {
    final tt = Theme.of(context).textTheme;
    return ListView(
      key: key,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(Gap.xl),
      children: [
        const SizedBox(height: Gap.xl),
        Icon(icon, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: Gap.m),
        Text(title, textAlign: TextAlign.center, style: tt.titleSmall),
        if (detail != null) ...[
          const SizedBox(height: Gap.s),
          Text(detail, textAlign: TextAlign.center, style: tt.bodyMedium),
        ],
        const SizedBox(height: Gap.s),
        Text('Pull down to refresh.', textAlign: TextAlign.center, style: tt.bodySmall),
      ],
    );
  }

  Widget _body(BuildContext context) {
    if (_load == PacketsLoad.loading) {
      return ListView(physics: const AlwaysScrollableScrollPhysics(), children: const [
        SizedBox(height: 80),
        Center(child: CircularProgressIndicator(key: Key('packets-loading'))),
      ]);
    }
    if (_load == PacketsLoad.error) {
      return _message(context,
          key: const Key('packets-error'), icon: Icons.cloud_off, title: 'Could not load packets', detail: _error);
    }
    if (_rows.isEmpty) {
      final st = _status;
      final pending = st != null && (st.state == SourcedState.pending || st.state == SourcedState.unavailable);
      return _message(context,
          key: const Key('packets-empty'),
          icon: pending ? Icons.sensors_off : Icons.inbox_outlined,
          title: pending ? 'No packet feed for ${widget.regionSlug} yet' : 'No recent packets',
          detail: st?.reason ?? (_route != null ? 'Nothing matches this route filter.' : null));
    }
    final st = _status;
    final note = st != null && st.state != SourcedState.ready ? (st.reason ?? 'Data is ${st.state.name}.') : null;
    return ListView.separated(
      key: const Key('packets-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _rows.length + (note != null ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (c, i) {
        if (note != null) {
          if (i == 0) return _banner(c, note, Icons.info_outline);
          i--;
        }
        return PacketTile(row: _rows[i], now: DateTime.now().toUtc());
      },
    );
  }
}

/// "12s", "5m", "3h", "2d" ago.
String packetAge(DateTime at, DateTime now) {
  final s = now.difference(at).inSeconds;
  if (s < 0) return 'now';
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
}

class PacketTile extends StatelessWidget {
  final PacketRow row;
  final DateTime now;
  const PacketTile({super.key, required this.row, required this.now});

  Color _snrColor(BuildContext context, double snr) {
    final c = MeshSonarColors.of(context);
    if (snr >= 5) return c.snrStrong;
    if (snr >= -5) return c.snrMid;
    return c.snrWeak;
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final hops = row.minHops == 0 ? 'direct' : '${row.minHops} hop${row.minHops == 1 ? '' : 's'}';
    final sub = <String>[
      packetRouteName(row.route),
      hops,
      if (row.hashSize != null) '${row.hashSize}-byte hash',
      '${row.observers} observer${row.observers == 1 ? '' : 's'}',
    ].join(' · ');
    final snr = row.bestSnrDb;
    return ListTile(
      dense: true,
      title: Text(row.originName == null ? packetTypeName(row.type) : '${packetTypeName(row.type)} · ${row.originName}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(packetAge(row.firstAt, now), style: tt.labelMedium),
        if (snr != null)
          Text('${snr.toStringAsFixed(snr.truncateToDouble() == snr ? 0 : 1)} dB',
              style: tt.labelSmall?.copyWith(color: _snrColor(context, snr))),
      ]),
    );
  }
}
