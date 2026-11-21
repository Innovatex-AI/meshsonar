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
  const ChannelSearchScreen({super.key, required this.baseUrl, required this.regionSlug, this.channelId, this.channelName, this.debounce = const Duration(milliseconds: 300)});

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
          autofocus: true,
          maxLength: messageSearchMaxChars,
          textInputAction: TextInputAction.search,
          onChanged: _changed,
          onSubmitted: (v) {
            _debounce?.cancel();
            unawaited(_run(v));
          },
          decoration: InputDecoration(hintText: 'Search $where', border: InputBorder.none, counterText: ''),
        ),
        actions: [
          if (_text.text.isNotEmpty)
            IconButton(
              key: const Key('channel-search-clear'),
              tooltip: 'Clear',
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

  Widget _hint(String text, Key key) =>
      ListView(children: [Padding(padding: const EdgeInsets.all(Gap.xl), child: Text(text, key: key, textAlign: TextAlign.center))]);

  Widget _body(ThemeData t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final e = _error;
    if (e != null) {
      if (e is V1Error && e.offline) return SingleChildScrollView(child: RegionOfflineEmpty(what: 'the search', onRetry: () => _run(_q)));
      return _hint(e is V1NotLive ? 'Message search is not available on this server yet.' : (e is V1Error ? e.message : 'The search did not work.'), const Key('channel-search-error'));
    }
    if (_q.length < messageSearchMinChars) {
      return _hint('Type at least $messageSearchMinChars characters. Search covers readable channel text from the last 30 days.', const Key('channel-search-hint'));
    }
    if (_rows.isEmpty) return _hint('No messages match "$_q".', const Key('channel-search-empty'));
    return ListView.builder(
      key: const Key('channel-search-results'),
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: _rows.length + 1,
      itemBuilder: (context, i) {
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
