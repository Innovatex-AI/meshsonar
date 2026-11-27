// One channel's messages (build 71). Website twin: `/channels/<id>`.
// - Newest at the bottom; opens at the bottom. Scrolling to the top loads the next older page (50 a page) until 500
//   rows are held; past that it says so and points at search.
// - Two hosts, one view: [ChannelReaderView] sits INSIDE Network > Channels (the section strip stays, so a link to
//   another section is never hidden under a pushed page), and [ChannelReaderScreen] is the same view as a page (from a
//   search result).
// - Light polling: every 20 s it asks for anything newer (`page.prev`), ONLY while it can be seen (its route on top,
//   its tab and section showing), the app is in the foreground and the battery mode is not Saver. Refresh asks at once.
// - The list never moves under the finger: a new message is added in place only when the person is already at the
//   bottom; otherwise it waits behind an "N new" pill (tap = show them and jump to the bottom).
// - Tap a message for its packet; the row's "..." (or a long press) has Report, Open packet and Copy text. A hidden
//   message keeps its row. Sender names are claims and are never shown as verified.
// - A private channel (no key on the server) has no reader: the channel list does not navigate to one, and a link
//   to one lands on a plain explanation here.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/power_profile.dart';
import '../../../core/v1/channels_api.dart';
import '../../../core/v1/packet_models.dart' show privateChannelName;
import '../../region/region_common.dart' show RegionOfflineAsOf, RegionOfflineEmpty, groupInt;
import '../../theme.dart';
import '../packets/packet_ui.dart' show NoPacketFeedCard, PacketNote, plainServerText;
import 'channel_search.dart';
import 'channel_ui.dart';

/// How often an open reader asks for newer messages.
const Duration channelPollEvery = Duration(seconds: 20);

/// "Public", "#test", "Private channel" (one name, Round 2 N-U5), or the id while the name is not known.
String channelTitleOf(String channelId, [String? name]) =>
    name ?? (channelId == 'public' ? 'Public' : (channelId.startsWith('tag:') ? '#${channelId.substring(4)}' : (channelId.startsWith('enc:') ? privateChannelName : channelId)));

Future<void> openChannelReader(BuildContext context, {required String baseUrl, required String? regionSlug, required String channelId, String? title}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ChannelReaderScreen(baseUrl: baseUrl, regionSlug: regionSlug, channelId: channelId, title: title)));

/// The reader as a page of its own.
class ChannelReaderScreen extends StatelessWidget {
  final String baseUrl;
  final String? regionSlug;
  final String channelId;
  final String? title;
  const ChannelReaderScreen({super.key, required this.baseUrl, required this.regionSlug, required this.channelId, this.title});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ChannelReaderView(baseUrl: baseUrl, regionSlug: regionSlug, channelId: channelId, title: title, onBack: () => Navigator.of(context).maybePop()),
        ),
      );
}

/// The reader itself: a 48 pt header (back, channel name, search, refresh) over the messages.
class ChannelReaderView extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;
  final String channelId;
  final String? title;

  /// Back to wherever it was opened from (the channel list, or the page before).
  final VoidCallback onBack;
  const ChannelReaderView({super.key, required this.baseUrl, required this.regionSlug, required this.channelId, this.title, required this.onBack});

  @override
  State<ChannelReaderView> createState() => _ChannelReaderViewState();
}

enum _Load { loading, ready, error }

class _ChannelReaderViewState extends State<ChannelReaderView> with WidgetsBindingObserver {
  late final ChannelsApi _api = channelsApiFactory(widget.baseUrl);
  final ScrollController _scroll = ScrollController();

  /// Oldest first. The list is drawn reversed (index 0 = the newest, at the bottom), so an older page added at the
  /// far end never shifts what is on screen.
  List<ChannelMessage> _rows = const [];

  /// Newer messages that arrived while the person was reading further up.
  List<ChannelMessage> _pending = const [];
  String? _next, _prev;
  DateTime? _asOf;
  _Load _load = _Load.loading;
  Object? _error;
  PacketFeedProbe _feed = PacketFeedProbe.unknown;
  String? _emptyReason;
  bool _loadingOlder = false;

  /// Scrolled well up from the newest message (the "Latest" button shows).
  bool _away = false;

  bool _foreground = true;

  /// False while its tab or section is not the one showing (tickers are off there).
  bool _visible = true;
  bool _polling = false;
  bool _refreshing = false;
  Timer? _timer;
  ModalRoute<dynamic>? _route;
  int _gen = 0;

  bool get _private => widget.channelId.startsWith('enc:');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    if (!_private) {
      unawaited(_reload());
      _timer = Timer.periodic(channelPollEvery, (_) => unawaited(_poll()));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _visible = TickerMode.valuesOf(context).enabled;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final was = _foreground;
    _foreground = s == AppLifecycleState.resumed;
    // back in front: catch up at once instead of waiting out the interval
    if (_foreground && !was) unawaited(_poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    _api.close();
    super.dispose();
  }

  /// With the reversed list, offset 0 is the bottom.
  bool get _atBottom => !_scroll.hasClients || _scroll.position.pixels <= 48;

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent - 300) unawaited(_loadOlder());
    // far from the newest: offer a way straight back down
    final away = p.pixels > 600;
    if (away != _away) setState(() => _away = away);
    // reaching the bottom shows what was waiting
    if (_pending.isNotEmpty && p.pixels <= 0) setState(_showPending);
  }

  Future<void> _reload() async {
    final gen = ++_gen;
    setState(() {
      _load = _Load.loading;
      _error = null;
    });
    try {
      final p = await _api.messages(widget.channelId);
      var feed = PacketFeedProbe.unknown;
      if (p.rows.isEmpty && widget.regionSlug != null) feed = await _api.packetFeed();
      if (!mounted || gen != _gen) return;
      setState(() {
        _rows = mergeNewer(const [], p.rows).$1;
        _pending = const [];
        _next = p.next;
        _prev = p.prev;
        _asOf = p.offlineAsOf;
        _feed = feed;
        _emptyReason = p.status.state.name != 'ready' ? plainServerText(p.status.reason) : null;
        _load = _Load.ready;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e;
        _load = _Load.error;
      });
    }
  }

  bool get _atCap => _rows.length >= channelReaderCap;

  Future<void> _loadOlder() async {
    if (_loadingOlder || _next == null || _atCap || _load != _Load.ready) return;
    final gen = _gen;
    setState(() => _loadingOlder = true);
    try {
      final p = await _api.messages(widget.channelId, cursor: _next);
      if (!mounted || gen != _gen) return;
      setState(() {
        _rows = mergeOlder(_rows, p.rows);
        _next = p.next;
      });
    } catch (_) {
      // the "Load older messages" button stays for another try
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  /// True while a poll may run: its route on top, its tab and section showing, app in front, not Saver.
  bool get _mayPoll => _foreground && _visible && (_route?.isCurrent ?? true) && PowerProfile.current.mode != BatteryMode.saver;

  Future<void> _poll({bool manual = false}) async {
    if (!mounted || _polling || _prev == null || _load != _Load.ready) return;
    if (!manual && !_mayPoll) return;
    _polling = true;
    final gen = _gen;
    try {
      final p = await _api.messages(widget.channelId, cursor: _prev);
      if (!mounted || gen != _gen) return;
      final have = {for (final m in _rows) m.id, for (final m in _pending) m.id};
      final fresh = [for (final m in p.rows) if (!have.contains(m.id)) m];
      setState(() {
        if (p.prev != null) _prev = p.prev;
        if (fresh.isEmpty) return;
        if (_atBottom) {
          _rows = mergeNewer(_rows, fresh).$1;
        } else {
          _pending = mergeNewer(_pending, fresh).$1;
        }
      });
    } catch (_) {
      // a failed poll changes nothing: the next one asks again
    } finally {
      _polling = false;
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    if (_load == _Load.ready && _prev != null) {
      await _poll(manual: true);
    } else {
      await _reload();
    }
    if (mounted) setState(() => _refreshing = false);
  }

  void _showPending() {
    _rows = mergeNewer(_rows, _pending).$1;
    _pending = const [];
  }

  void _jumpToLatest() {
    setState(_showPending);
    if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  String get _title => channelTitleOf(widget.channelId, widget.title ?? (_rows.isEmpty ? null : _rows.last.channelName));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(children: [
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(children: [
          IconButton(key: const Key('channel-back'), tooltip: 'Back to channels', icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(header: true, child: Text(_title, key: const Key('channel-title'), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium)),
              // People look for a box to type in: say that this is a reader, and where the newest message is.
              if (!_private)
                Text('Read-only · newest at the bottom',
                    key: const Key('channel-readonly'), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
          if (!_private) ...[
            IconButton(
              key: const Key('channel-search'),
              tooltip: 'Search this channel',
              icon: const Icon(Icons.search),
              onPressed: () => openChannelSearch(context, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, channelId: widget.channelId, channelName: _title),
            ),
            IconButton(
              key: const Key('channel-refresh'),
              tooltip: 'Refresh',
              icon: _refreshing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
              onPressed: _refreshing ? null : _refresh,
            ),
          ],
        ]),
      ),
      Expanded(child: _body(context)),
    ]);
  }

  Widget _body(BuildContext context) {
    final t = Theme.of(context);
    if (_private) {
      return ListView(padding: const EdgeInsets.all(Gap.l), children: const [
        PacketNote('This is a private channel: its text cannot be read without its key, so there is nothing to show here.', key: Key('channel-private'), icon: Icons.lock_outline),
      ]);
    }
    if (_load == _Load.loading) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: Gap.m),
          Text('Loading messages…', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      );
    }
    if (_load == _Load.error) {
      final e = _error;
      if (e is V1Error && e.offline) return SingleChildScrollView(child: RegionOfflineEmpty(what: 'this channel', onRetry: _reload));
      final notFound = e is V1Error && (e.notFound || e.code == 'bad_param');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              notFound
                  ? 'This channel is not in this region.'
                  : (e is V1NotLive ? 'Channels are not available on this server yet.' : (e is V1Error ? e.message : 'The messages did not load.')),
              key: const Key('channel-error'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Gap.m),
            if (!notFound) FilledButton(key: const Key('channel-retry'), onPressed: _reload, child: const Text('Try again')),
            if (notFound) FilledButton(key: const Key('channel-error-back'), onPressed: widget.onBack, child: const Text('Back to channels')),
          ]),
        ),
      );
    }
    if (_rows.isEmpty) {
      return ListView(children: [
        if (!_feed.hasFeed)
          NoPacketFeedCard(regionName: _feed.scopeName ?? widget.regionSlug, reason: _feed.reason, what: 'channel messages')
        else
          Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(children: [
              Text(_emptyReason ?? 'No messages heard on this channel yet.', key: const Key('channel-empty'), textAlign: TextAlign.center),
              const SizedBox(height: Gap.m),
              OutlinedButton(key: const Key('channel-empty-refresh'), onPressed: _reload, child: const Text('Check again')),
            ]),
          ),
      ]);
    }
    final n = _rows.length;
    // "N new" while newer messages wait; plain "Latest" when the person has just scrolled far up.
    final pill = _pending.isNotEmpty ? '${_pending.length} new' : (_away ? 'Latest' : null);
    return Stack(children: [
      Column(children: [
        if (_asOf != null) Padding(padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, 0), child: RegionOfflineAsOf(asOf: _asOf!, onRetry: _reload)),
        Expanded(
          child: ListView.builder(
            key: const Key('channel-messages'),
            controller: _scroll,
            reverse: true,
            padding: const EdgeInsets.only(bottom: Gap.s),
            itemCount: n + 1,
            itemBuilder: (context, i) {
              if (i == n) {
                // the far (top) end
                return Padding(
                  padding: const EdgeInsets.all(Gap.m),
                  child: Center(
                    child: _next == null || _atCap
                        ? Text(_next == null ? 'The start of what is stored for this channel.' : 'Showing the latest ${groupInt(channelReaderCap)} messages. Use search to find older ones.',
                            key: Key(_next == null ? 'channel-start' : 'channel-cap'), textAlign: TextAlign.center, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))
                        : (_loadingOlder
                            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                            : TextButton(key: const Key('channel-older'), onPressed: _loadOlder, child: const Text('Load older messages'))),
                  ),
                );
              }
              final m = _rows[n - 1 - i];
              return ChannelMessageTile(key: ValueKey('msg-${m.id}'), message: m, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug);
            },
          ),
        ),
      ]),
      if (pill != null)
        Positioned(
          bottom: Gap.m,
          left: 0,
          right: 0,
          child: Center(
            child: FilledButton.tonalIcon(
              key: const Key('channel-new-pill'),
              style: FilledButton.styleFrom(minimumSize: const Size(44, 44)),
              onPressed: _jumpToLatest,
              icon: const Icon(Icons.arrow_downward, size: 18),
              label: Text(pill),
            ),
          ),
        ),
    ]);
  }
}
