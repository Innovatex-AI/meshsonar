// Network > Packets > List (AZ-3.2). Website twin: `/packets` (with the same query: `?type=&route=&observer=&node=
// &hash=&channel=&scope=&source=&filter=&window=`), and `/tools/decode` for "Decode a packet".
//
// - Network: `GET /v1/packets` grouped by hash (observer count and best SNR on each row, tap the arrow for the
//   observations), cursor paging with infinite scroll and no row cap, pull to refresh, live updates (newer rows every
//   [PacketListView.pollEvery]) with pause / resume, time-window chips, every filter in a thumb-sized sheet, active
//   filter chips, saved filters, and a share link of the list state.
// - My radio (when a radio is connected): the packets the radio heard this session (the Rx log), decoded on the phone.
// - Server states: `/v1` live; not live (today's `region-packets`, with a banner naming the filters it cannot apply);
//   offline (the stored copy with "Offline - as of", or a plain no-connection view with Retry).
// - Battery: no polling while the list is not on screen (TickerMode), the app is in the background, live is paused,
//   or the battery mode is Saver (pull to refresh still works).
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/network_request.dart';
import '../../../core/power_profile.dart';
import '../../../core/v1/channels_api.dart' show isNoPacketFeed;
import '../../../core/v1/local_decoder.dart';
import '../../../core/v1/my_radio_packets.dart';
import '../../../core/v1/network_api.dart' show NetworkReadSource;
import '../../../core/v1/packets_api.dart';
import '../../../radio/tools/rx_log.dart';
import '../../region/region_common.dart' show RegionOfflineAsOf, RegionOfflineEmpty, clockUtc;
import '../../theme.dart';
import 'decode_packet_screen.dart';
import 'packet_context.dart';
import 'packet_detail_screen.dart';
import 'packet_filter_sheet.dart';
import 'packet_ui.dart';

/// The window chips, in order (the contract's list windows without 3h). 30d and 90d need a narrowing filter (contract 3.3).
final List<String> packetWindowChips = [for (final w in packetWindows.keys) if (w != '3h') w];

enum _Load { loading, ready, error }

class PacketListView extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;

  /// The request that opened the list (filters and window from a link); null = defaults.
  final NetworkRequest? request;

  /// Test seams.
  final PacketsApi? api;
  final RxLog? radioLog;
  final DateTime Function()? clock;
  final Duration pollEvery;
  const PacketListView({
    super.key,
    required this.baseUrl,
    required this.regionSlug,
    this.request,
    this.api,
    this.radioLog,
    this.clock,
    this.pollEvery = const Duration(seconds: 15),
  });

  @override
  State<PacketListView> createState() => _PacketListViewState();
}

class _PacketListViewState extends State<PacketListView> with WidgetsBindingObserver {
  late final PacketsApi _api = widget.api ?? packetsApiFactory(widget.baseUrl);
  late PacketFilter _filter = widget.request?.listFilter ?? PacketFilter.none;
  late PacketWindow _window = _windowOf(widget.request);
  final ScrollController _scroll = ScrollController();

  // Network list
  List<PacketListRow> _rows = const [];
  String? _next, _prev;
  bool _legacy = false;
  DateTime? _asOf;
  List<String> _unapplied = const [];
  String? _statusNote;

  /// The server said no packet feed covers this scope (`no_packet_feed`): its sentence, shown as a plain card.
  String? _noFeedReason;
  bool? _nodeTrusted;
  _Load _load = _Load.loading;
  V1Error? _error;
  bool _loadingMore = false;
  bool _pollFailed = false;
  int _gen = 0;
  final Map<String, Future<List<PacketObservation>>> _expanded = {};
  FilterCatalogue? _catalogue;

  // Live and visibility
  bool _live = true;
  bool _visible = true;
  bool _foreground = true;
  Timer? _timer;
  bool _inFlight = false;

  // My radio
  bool _mine = false;
  StreamSubscription<void>? _radioSub;
  List<LocalChannelKey> _keys = const [];

  static PacketWindow _windowOf(NetworkRequest? r) {
    if (r?.window != null && packetWindows.containsKey(r!.window)) return PacketWindow.named(r.window!);
    if (r?.since != null) return PacketWindow.range(r!.since!, r.until);
    return PacketWindow.defaultWindow;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PowerProfile.addListener(_onPower);
    _scroll.addListener(_onScroll);
    unawaited(_reload());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final k = await packetHashtagKeys(context);
      if (mounted) setState(() => _keys = k);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = TickerMode.valuesOf(context).enabled;
    if (v != _visible) {
      _visible = v;
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final fg = s == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    _sync();
  }

  void _onPower() {
    if (mounted) setState(_sync);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PowerProfile.removeListener(_onPower);
    _timer?.cancel();
    _radioSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  bool get _saver => PowerProfile.current.mode == BatteryMode.saver;

  /// Polling runs only while it can be seen and is wanted.
  bool get _polling => _live && _visible && _foreground && !_saver && !_mine;

  void _sync() {
    _timer?.cancel();
    _timer = null;
    if (_polling) _timer = Timer.periodic(widget.pollEvery, (_) => unawaited(_poll()));
    final log = _logCache;
    final wantRadio = _mine && _live && _visible && _foreground && log != null;
    if (wantRadio && _radioSub == null) {
      _radioSub = log.changed.listen((_) {
        if (mounted) setState(() {});
      });
    } else if (!wantRadio && _radioSub != null) {
      unawaited(_radioSub!.cancel());
      _radioSub = null;
    }
  }

  RxLog? get _radioLog => widget.radioLog ?? packetRadioTools(context)?.rxLog;

  /// The radio log seen at the last build (null = no radio connected).
  RxLog? _logCache;

  // ------------------------------------------------------------------ network list

  Future<void> _reload() async {
    final gen = ++_gen;
    setState(() {
      _load = _rows.isEmpty ? _Load.loading : _load;
      _error = null;
    });
    try {
      final p = await _api.list(_filter, _window);
      if (!mounted || gen != _gen) return;
      setState(() {
        _apply(p, replace: true);
        _load = _Load.ready;
      });
      _fillIfShort();
    } on V1Error catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e;
        if (_rows.isEmpty) _load = _Load.error;
      });
    } finally {
      if (mounted && gen == _gen) _sync();
    }
  }

  void _apply(PacketListPage p, {bool replace = false, bool newer = false}) {
    if (replace) {
      _rows = p.rows;
      _next = p.next;
      _prev = p.prev;
      _expanded.clear();
    } else if (newer) {
      final seen = {for (final r in p.rows) r.hash};
      _rows = [...p.rows, ..._rows.where((r) => !seen.contains(r.hash))]..sort((a, b) => b.firstSeen.compareTo(a.firstSeen));
      if (p.prev != null) _prev = p.prev;
    } else {
      final seen = {for (final r in _rows) r.hash};
      _rows = [..._rows, ...p.rows.where((r) => !seen.contains(r.hash))];
      _next = p.next;
    }
    _legacy = p.source == NetworkReadSource.legacy;
    _asOf = p.offlineAsOf;
    _unapplied = p.unapplied;
    _nodeTrusted = p.nodeListTrusted;
    final st = p.status;
    _noFeedReason = _rows.isEmpty && isNoPacketFeed(st) ? st!.reason : null;
    _statusNote = _noFeedReason == null && st != null && st.state.name != 'ready' ? (plainServerText(st.reason) ?? 'The data is ${st.state.name}.') : null;
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _next == null || _load != _Load.ready) return;
    final gen = _gen;
    setState(() => _loadingMore = true);
    try {
      final p = await _api.list(_filter, _window, cursor: _next, legacyCursor: _legacy);
      if (!mounted || gen != _gen) return;
      setState(() => _apply(p));
    } on V1Error catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
      if (mounted && gen == _gen && _error == null) _fillIfShort();
    }
  }

  /// Infinite scroll also when a page does not fill the screen (no scroll event would ever come).
  void _fillIfShort() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _next == null || _loadingMore) return;
      if (_scroll.position.maxScrollExtent <= 0) unawaited(_loadMore());
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 600) unawaited(_loadMore());
  }

  /// Live catch-up: newer rows from `page.prev` on `/v1`, the first page again on the fallback.
  Future<void> _poll() async {
    if (_inFlight || !_polling || _load != _Load.ready) return;
    _inFlight = true;
    final gen = _gen;
    try {
      final p = !_legacy && _prev != null ? await _api.list(_filter, _window, cursor: _prev) : await _api.list(_filter, _window);
      if (!mounted || gen != _gen) return;
      setState(() {
        _apply(p, newer: true);
        _pollFailed = false;
      });
    } on V1Error {
      if (mounted && gen == _gen) setState(() => _pollFailed = true);
    } finally {
      _inFlight = false;
    }
  }

  void _setFilter(PacketFilter f, {PacketWindow? window}) {
    var w = window ?? _window;
    if (w.long && !f.narrows) w = const PacketWindow.named('7d');
    setState(() {
      _filter = f;
      _window = w;
      _rows = const [];
      _load = _Load.loading;
    });
    unawaited(_reload());
  }

  Future<void> _openSheet() async {
    final cat = _catalogue ??= await _api.filterFields();
    if (!mounted) return;
    final r = await showPacketFilterSheet(context, filter: _filter, catalogue: cat, store: savedPacketFilterStore(context), window: _window.name);
    if (r == null || !mounted) return;
    _setFilter(r.filter, window: r.window != null && packetWindows.containsKey(r.window) ? PacketWindow.named(r.window!) : null);
  }

  NetworkRequest get _shareRequest => NetworkRequest.packetList(_filter, region: widget.regionSlug, window: _window.name, since: _window.since, until: _window.until);

  Future<void> _share() async {
    final link = _shareRequest.toWebUri().toString();
    if (packetShareOverride != null) return packetShareOverride!(link);
    await SharePlus.instance.share(ShareParams(text: link, subject: 'MeshSonar packets'));
  }

  void _openDecode() => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DecodePacketScreen(baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, api: widget.api)));

  void _openRow(String hash) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NetworkPacketScreen(baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, hash: hash, api: widget.api, radioLog: widget.radioLog, clock: widget.clock)));

  void _setMine(bool v) {
    if (v == _mine) return;
    setState(() => _mine = v);
    if (v) packetRadioTools(context)?.startListening();
    _sync();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final log = _logCache = _radioLog;
    if (log == null && _mine) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _mine = false);
      });
    }
    return Column(
      key: const Key('packet-list-view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (log != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, 0),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
              child: CupertinoSlidingSegmentedControl<bool>(
                key: const Key('packets-source-switch'),
                groupValue: _mine,
                thumbColor: t.colorScheme.surfaceContainerHighest,
                backgroundColor: t.colorScheme.onSurface.withValues(alpha: 0.10),
                children: const {
                  false: SizedBox(height: 44, child: Center(child: Text('Network', key: Key('packets-source-network')))),
                  true: SizedBox(height: 44, child: Center(child: Text('My radio', key: Key('packets-source-mine')))),
                },
                onValueChanged: (v) => _setMine(v ?? false),
              ),
            ),
          ),
        _toolbar(context),
        if (!_mine) ...[
          _windowChips(context),
          if (_filter.chips.isNotEmpty) _activeChips(context),
        ],
        Expanded(child: _mine && log != null ? _myRadio(context, log) : _network(context)),
      ],
    );
  }

  Widget _toolbar(BuildContext context) {
    final t = Theme.of(context);
    final n = _filter.chips.length;
    // One row, always: the three actions on the left (they scroll sideways if a label grows), Share at the right end.
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.s, Gap.xs, Gap.s, 0),
      child: Row(key: const Key('packets-toolbar'), children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              if (!_mine)
                TextButton.icon(
                  key: const Key('packets-filters'),
                  onPressed: _openSheet,
                  icon: const Icon(Icons.tune),
                  label: Text(n == 0 ? 'Filters' : 'Filters ($n)'),
                ),
              TextButton.icon(
                key: const Key('packets-live-toggle'),
                onPressed: () {
                  setState(() => _live = !_live);
                  _sync();
                  if (_live && !_mine) unawaited(_poll());
                },
                icon: Icon(_live ? Icons.pause_circle_outline : Icons.play_circle_outline),
                label: Text(_live ? (_mine || !_saver ? 'Live' : 'Live (paused in Saver)') : 'Paused'),
                style: TextButton.styleFrom(foregroundColor: _live ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
              ),
              Tooltip(
                message: 'Decode a packet',
                child: TextButton.icon(key: const Key('packets-decode'), onPressed: _openDecode, icon: const Icon(Icons.data_object), label: const Text('Decode')),
              ),
            ]),
          ),
        ),
        if (!_mine) IconButton(key: const Key('packets-share'), tooltip: 'Share this list', onPressed: _share, icon: const Icon(Icons.ios_share)),
      ]),
    );
  }

  Widget _windowChips(BuildContext context) => SizedBox(
        height: 48,
        child: SingleChildScrollView(
          key: const Key('packets-windows'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.l),
          child: Row(children: [
            for (final w in packetWindowChips)
              Padding(
                padding: const EdgeInsets.only(right: Gap.s),
                child: ChoiceChip(
                  key: Key('packets-window-$w'),
                  label: Text(w),
                  selected: _window.name == w,
                  tooltip: (w == '30d' || w == '90d') && !_filter.narrows ? 'Needs a node, observer, channel or hash filter' : null,
                  onSelected: (w == '30d' || w == '90d') && !_filter.narrows ? null : (_) => _setFilter(_filter, window: PacketWindow.named(w)),
                ),
              ),
          ]),
        ),
      );

  Widget _activeChips(BuildContext context) => SizedBox(
        height: 48,
        child: SingleChildScrollView(
          key: const Key('packets-active-filters'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.l),
          child: Row(children: [
            for (final c in _filter.chips)
              Padding(
                padding: const EdgeInsets.only(right: Gap.s),
                child: InputChip(
                  key: ValueKey('packets-chip-${c.id}'),
                  label: Text(c.label),
                  onPressed: _openSheet,
                  onDeleted: () => _setFilter(_filter.without(c.id)),
                  deleteButtonTooltipMessage: 'Remove ${c.label}',
                ),
              ),
          ]),
        ),
      );

  Widget _network(BuildContext context) {
    final now = (widget.clock ?? DateTime.now)().toUtc();
    if (_load == _Load.loading) {
      return ListView(physics: const AlwaysScrollableScrollPhysics(), children: const [
        SizedBox(height: 80),
        Center(child: CircularProgressIndicator(key: Key('packets-loading'))),
      ]);
    }
    if (_load == _Load.error) {
      final e = _error!;
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(Gap.l), children: [
          if (e.offline)
            RegionOfflineEmpty(what: 'packets', onRetry: _reload)
          else ...[
            PacketNote(e.code == 'bad_filter' ? 'The server did not accept the filter: ${e.message}' : 'Packets did not load: ${e.message}',
                key: const Key('packets-error'), icon: Icons.cloud_off),
            Align(alignment: Alignment.centerLeft, child: FilledButton(onPressed: _reload, child: const Text('Try again'))),
          ],
        ]),
      );
    }
    final head = <Widget>[
      if (_asOf != null) Padding(padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, 0), child: RegionOfflineAsOf(asOf: _asOf!, onRetry: _reload)),
      if (_legacy && _unapplied.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l),
          child: PacketNote(
            'This server has not got the new packet search yet, so these filters are not applied: ${_unapplied.join(', ')}.',
            key: const Key('packets-unapplied'),
            icon: Icons.filter_alt_off,
          ),
        ),
      if (_statusNote != null) Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.l), child: PacketNote(_statusNote!, key: const Key('packets-status'))),
      if (_nodeTrusted == false)
        const Padding(
            padding: EdgeInsets.symmetric(horizontal: Gap.l),
            child: PacketNote('The node list here is not complete, so hops are named with less certainty.', icon: Icons.rule)),
      if (_pollFailed && _asOf == null)
        const Padding(padding: EdgeInsets.symmetric(horizontal: Gap.l), child: PacketNote('Reconnecting… showing the last packets.', icon: Icons.sync_problem)),
      if (_live && _saver) const Padding(padding: EdgeInsets.symmetric(horizontal: Gap.l), child: PacketNote('Live updates pause in Saver mode. Pull down to refresh.', icon: Icons.battery_saver)),
    ];
    final footer = _next != null
        ? Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Center(
              child: _loadingMore
                  ? const CircularProgressIndicator(key: Key('packets-loading-more'))
                  : TextButton(key: const Key('packets-more'), onPressed: _loadMore, child: const Text('Load older packets')),
            ),
          )
        : Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Column(children: [
              Text(_rows.isEmpty ? '' : 'No older packets in this window.', style: Theme.of(context).textTheme.bodySmall),
              WebTwinLine(_shareRequest.toWebUri()),
            ]),
          );
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        key: const Key('packets-list'),
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: head.length + (_rows.isEmpty ? 1 : _rows.length) + 1,
        itemBuilder: (c, i) {
          if (i < head.length) return head[i];
          i -= head.length;
          if (_rows.isEmpty) {
            if (i == 0) {
              if (_noFeedReason != null && !_mine) return NoPacketFeedCard(regionName: widget.regionSlug, reason: _noFeedReason);
              return Padding(
                key: const Key('packets-empty'),
                padding: const EdgeInsets.all(Gap.xl),
                child: Text(
                  _filter.isEmpty ? 'No packets in the last ${_window.name ?? 'window'}.' : 'No packets match these filters in this window.',
                  textAlign: TextAlign.center,
                ),
              );
            }
            return footer;
          }
          if (i == _rows.length) return footer;
          final r = _rows[i];
          return _PacketRowTile(
            key: ValueKey('packet-row-${r.hash}'),
            row: r,
            now: now,
            expanded: _expanded[r.hash],
            onTap: () => _openRow(r.hash),
            onExpand: () => setState(() {
              if (_expanded.containsKey(r.hash)) {
                _expanded.remove(r.hash);
              } else {
                _expanded[r.hash] = _api.observationsForRow(r.hash);
              }
            }),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------------ my radio

  Widget _myRadio(BuildContext context, RxLog log) {
    final t = Theme.of(context);
    final now = (widget.clock ?? DateTime.now)().toUtc();
    final items = myRadioPackets(log, hashtagKeys: _keys);
    final notes = <Widget>[
      PacketNote(
        'Packets your radio heard since the app opened (the last ${log.capacity}, kept in memory only). Decoded on this phone: Public and hashtag '
        'channel text is shown; private channels and direct messages stay encrypted.',
        key: const Key('myradio-note'),
        icon: Icons.settings_input_antenna,
      ),
      if (log.missedWhilePaused > 0)
        PacketNote('${log.missedWhilePaused} packets arrived while the Rx log was paused and were not kept.', icon: Icons.pause),
      if (!_live) const PacketNote('Paused: new packets are kept but the list is not redrawn.', icon: Icons.pause_circle_outline),
    ];
    return ListView.builder(
      key: const Key('myradio-list'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.l),
      itemCount: notes.length + (items.isEmpty ? 1 : items.length),
      itemBuilder: (c, i) {
        if (i < notes.length) return notes[i];
        i -= notes.length;
        if (items.isEmpty) {
          return const Padding(
            key: Key('myradio-empty'),
            padding: EdgeInsets.all(Gap.xl),
            child: Text('Nothing heard yet. Packets show up here as your radio hears them.', textAlign: TextAlign.center),
          );
        }
        final p = items[i];
        final d = p.detail;
        final title = d == null ? 'Not a valid packet' : (d.origin?.name != null ? '${packetTypeLabel(d.typeName)}: ${d.origin!.name}' : (d.channel != null ? '${packetTypeLabel(d.typeName)} on ${d.channel!.label}' : packetTypeLabel(d.typeName)));
        final sub = d == null
            ? (p.problem ?? '')
            : [packetRouteLabel(d.route), d.hops == 0 ? 'heard direct' : '${d.hops} hop${d.hops == 1 ? '' : 's'}', '${d.size} bytes', d.hash.substring(0, 8)].join(' · ');
        return ListTile(
          key: ValueKey('myradio-row-${p.entry.seq}'),
          contentPadding: EdgeInsets.zero,
          minTileHeight: 56,
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(ageText(p.entry.at.toUtc(), now), style: t.textTheme.labelMedium),
            if (p.entry.snrDb != null) Text(snrText(p.entry.snrDb), style: t.textTheme.labelSmall?.copyWith(color: snrColor(context, p.entry.snrDb!))),
          ]),
          onTap: d == null
              ? null
              : () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => NetworkPacketScreen(baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, hash: d.hash, local: d, api: widget.api, radioLog: log, clock: widget.clock))),
        );
      },
    );
  }
}

class _PacketRowTile extends StatelessWidget {
  final PacketListRow row;
  final DateTime now;
  final Future<List<PacketObservation>>? expanded;
  final VoidCallback onTap, onExpand;
  const _PacketRowTile({super.key, required this.row, required this.now, required this.expanded, required this.onTap, required this.onExpand});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final obs = row.observerCount;
    final sub = [
      packetRouteLabel(row.route),
      row.hops == 0 ? 'heard direct' : '${row.hops} hop${row.hops == 1 ? '' : 's'}',
      '$obs observer${obs == 1 ? '' : 's'}',
      if (row.observationCount != null && row.observationCount! > obs) '${row.observationCount} heard',
    ].join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.xs, Gap.s),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(row.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge),
                Text(sub, style: muted),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(ageText(row.firstSeen, now), style: t.textTheme.labelMedium),
              if (row.bestSnr != null)
                Text(snrText(row.bestSnr), key: ValueKey('packet-row-snr-${row.hash}'), style: t.textTheme.labelSmall?.copyWith(color: snrColor(context, row.bestSnr!))),
            ]),
            IconButton(
              key: Key('packet-row-expand-${row.hash}'),
              tooltip: expanded == null ? 'Show who heard it' : 'Hide who heard it',
              icon: Icon(expanded == null ? Icons.expand_more : Icons.expand_less),
              onPressed: onExpand,
            ),
          ]),
        ),
      ),
      if (expanded != null)
        FutureBuilder<List<PacketObservation>>(
          future: expanded,
          builder: (c, s) {
            if (s.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(Gap.s), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))));
            }
            if (s.hasError) return Padding(padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s), child: Text('Observers did not load.', style: muted));
            final list = s.data ?? const [];
            return Padding(
              key: ValueKey('packet-row-obs-${row.hash}'),
              padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.l, Gap.s),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (list.isEmpty) Text('No observer rows kept for this packet.', style: muted),
                for (final o in list)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${o.observer.name} · ${snrText(o.snr)} · ${clockUtc(o.at)}${o.path.isEmpty ? '' : ' · ${o.path.join(' > ')}'}',
                      style: t.textTheme.bodySmall,
                    ),
                  ),
              ]),
            );
          },
        ),
      const Divider(height: 1),
    ]);
  }
}
