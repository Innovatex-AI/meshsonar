// Message search (build 71). Website twin: `/channels` > Search. `GET /v1/messages/search`: decoded text only, never
// hidden messages, the last 30 days. Nothing is sent under 2 characters; typing waits 300 ms before asking; 30 hits a
// page, more as the list is scrolled. A hit shows the match in bold; tap opens its packet, "..." has Open channel and
// Report. With [channelId] it searches that one channel.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/v1/channels_api.dart';
import '../../region/region_common.dart' show RegionOfflineEmpty;
import '../../theme.dart';
import 'channel_reader.dart';
import 'channel_ui.dart';

Future<void> openChannelSearch(BuildContext context, {required String baseUrl, required String? regionSlug, String? channelId, String? channelName}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ChannelSearchScreen(baseUrl: baseUrl, regionSlug: regionSlug, channelId: channelId, channelName: channelName)));

class ChannelSearchScreen extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;

  /// Null searches every readable channel of the scope.
  final String? channelId;
  final String? channelName;

  /// Tests shorten the typing delay.
  final Duration debounce;

  /// Text to search for straight away ("Search every channel" from a one-channel search).
  final String? initialQuery;
  const ChannelSearchScreen(
      {super.key, required this.baseUrl, required this.regionSlug, this.channelId, this.channelName, this.debounce = const Duration(milliseconds: 300), this.initialQuery});

  @override
  State<ChannelSearchScreen> createState() => _ChannelSearchScreenState();
}

class _ChannelSearchScreenState extends State<ChannelSearchScreen> {
  late final ChannelsApi _api = channelsApiFactory(widget.baseUrl);
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;
  String _q = '';
  List<ChannelMessage> _rows = const [];
  String? _next;
  bool _loading = false, _loadingMore = false;
  Object? _error;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) unawaited(_more());
    });
    final q = widget.initialQuery;
    if (q != null && q.isNotEmpty) {
      _text.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_run(q));
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _scroll.dispose();
    _api.close();
    super.dispose();
  }

  void _changed(String v) {
    setState(() {}); // the clear button shows with the first letter, not after the pause
    _debounce?.cancel();
    _debounce = Timer(widget.debounce, () => unawaited(_run(v)));
  }

  Future<void> _run(String raw) async {
    final q = raw.trim();
    final gen = ++_gen;
    if (q.length < messageSearchMinChars) {
      setState(() {
        _q = q;
        _rows = const [];
        _next = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() {
      _q = q;
      _loading = true;
      _error = null;
    });
    try {
      final p = await _api.search(q, channelId: widget.channelId);
      if (!mounted || gen != _gen) return;
      setState(() {
        _rows = p.rows;
        _next = p.next;
        _loading = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e;
        _rows = const [];
        _next = null;
        _loading = false;
      });
    }
  }

  Future<void> _more() async {
    if (_loadingMore || _loading || _next == null) return;
    final gen = _gen;
    setState(() => _loadingMore = true);
    try {
      final p = await _api.search(_q, channelId: widget.channelId, cursor: _next);
      if (!mounted || gen != _gen) return;
      final have = {for (final m in _rows) m.id};
      setState(() {
        _rows = [..._rows, ...p.rows.where((m) => !have.contains(m.id))];
        _next = p.next;
      });
    } catch (_) {
      // "Load more results" stays for another try
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final where = widget.channelId == null ? 'messages' : (widget.channelName ?? channelTitleOf(widget.channelId!));
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          key: const Key('channel-search-field'),
          controller: _text,
          autofocus: widget.initialQuery == null,
          maxLength: messageSearchMaxChars,
          textInputAction: TextInputAction.search,
          onChanged: _changed,
          onSubmitted: (v) {
            _debounce?.cancel();
            unawaited(_run(v));
          },
          autocorrect: false,
          decoration: InputDecoration(hintText: 'Search $where', border: InputBorder.none, counterText: ''),
        ),
        actions: [
          if (_text.text.isNotEmpty)
            IconButton(
              key: const Key('channel-search-clear'),
              tooltip: 'Clear the search',
              icon: const Icon(Icons.close),
              onPressed: () {
                _text.clear();
                _debounce?.cancel();
                unawaited(_run(''));
              },
            ),
        ],
      ),
      body: SafeArea(child: _body(t)),
    );
  }

  Widget _hint(String text, Key key, {List<Widget> actions = const []}) => ListView(keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, children: [
        Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(children: [
            Text(text, key: key, textAlign: TextAlign.center),
            if (actions.isNotEmpty) const SizedBox(height: Gap.m),
            ...actions,
          ]),
        ),
      ]);

  Widget _body(ThemeData t) {
    if (_loading) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: Gap.m),
          Text('Searching…', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      );
    }
    final e = _error;
    if (e != null) {
      if (e is V1Error && e.offline) return SingleChildScrollView(child: RegionOfflineEmpty(what: 'the search', onRetry: () => _run(_q)));
      return _hint(e is V1NotLive ? 'Message search is not available on this server yet.' : (e is V1Error ? e.message : 'The search did not work.'), const Key('channel-search-error'),
          actions: [if (e is! V1NotLive) FilledButton(key: const Key('channel-search-retry'), onPressed: () => _run(_q), child: const Text('Try again'))]);
    }
    if (_q.length < messageSearchMinChars) {
      return _hint('Type $messageSearchMinChars or more letters. The search covers readable channel messages from the last 30 days.', const Key('channel-search-hint'));
    }
    if (_rows.isEmpty) {
      return _hint('No messages match "$_q" in the last 30 days.${widget.channelId == null ? '' : ' Only this channel was searched.'}', const Key('channel-search-empty'), actions: [
        if (widget.channelId != null)
          OutlinedButton(
            key: const Key('channel-search-everywhere'),
            onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => ChannelSearchScreen(baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, initialQuery: _q))),
            child: const Text('Search every channel'),
          ),
      ]);
    }
    final count = '${_rows.length}${_next == null ? '' : '+'} ${_rows.length == 1 && _next == null ? 'result' : 'results'}';
    return ListView.builder(
      key: const Key('channel-search-results'),
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: _rows.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) {
          // The count first (it used to be under the last row), and what a tap does.
          return Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xs),
            child: Text('$count, newest first. Tap one to see how it travelled.', key: const Key('channel-search-count'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          );
        }
        i -= 1;
        if (i == _rows.length) {
          return Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Center(
              child: _next == null
                  ? Text('${_rows.length} ${_rows.length == 1 ? 'result' : 'results'}.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))
                  : (_loadingMore
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton(key: const Key('channel-search-more'), onPressed: _more, child: const Text('Load more results'))),
            ),
          );
        }
        final m = _rows[i];
        return ChannelMessageTile(
          key: ValueKey('hit-${m.id}'),
          message: m,
          baseUrl: widget.baseUrl,
          regionSlug: widget.regionSlug,
          showChannel: widget.channelId == null,
          onOpenChannel: widget.channelId != null || m.channelId.isEmpty
              ? null
              : () => openChannelReader(context, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, channelId: m.channelId, title: m.channelName),
        );
      },
    );
  }
}
