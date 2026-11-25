// Network > Channels (build 71). Website twin: `/channels`. The channel list of the region (or, on the hub, of every
// region): name, 24 h message and sender counts, last sender and when. Tap a readable channel for the reader
// (channel_reader.dart), shown INSIDE this section with a back arrow to the list, so the Network strip stays and a
// link to another section is never hidden under a pushed page. The search field on top opens message search
// (channel_search.dart). A private channel (no
// key on the server) is listed, visibly disabled, with the reason inline: it does not navigate.
// A region no packet feed covers says so plainly (NoPacketFeedCard) instead of an empty list.
// No polling here: the list loads when shown and on pull to refresh (battery rules).
// The constructor is FIXED (stream A builds the section strip against it).
import 'package:flutter/material.dart';

import '../../../core/v1/channels_api.dart';
import '../../region/region_common.dart' show RegionOfflineAsOf, RegionOfflineEmpty, agoText, groupInt;
import '../../theme.dart';
import '../packets/packet_ui.dart' show NoPacketFeedCard, PacketNote, WebTwinLine, plainServerText;
import 'channel_reader.dart';
import 'channel_search.dart';

class ChannelsSection extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;

  /// A channel to open straight away (from a `/channels/<id>` link); null shows the list.
  final String? initialChannelId;
  const ChannelsSection({super.key, required this.baseUrl, required this.regionSlug, this.initialChannelId});

  @override
  State<ChannelsSection> createState() => _ChannelsSectionState();
}

class _ChannelsData {
  final ChannelListPage page;
  final PacketFeedProbe feed;
  const _ChannelsData(this.page, this.feed);
}

class _ChannelsSectionState extends State<ChannelsSection> {
  late Future<_ChannelsData> _f = _fetch();

  /// The channel being read (id, name when known); null shows the list.
  (String, String?)? _open;

  @override
  void initState() {
    super.initState();
    final id = widget.initialChannelId;
    if (id != null && id.isNotEmpty) _open = (id, null);
  }

  @override
  void didUpdateWidget(ChannelsSection old) {
    super.didUpdateWidget(old);
    final moved = old.baseUrl != widget.baseUrl;
    if (moved) _f = _fetch();
    if (moved || old.initialChannelId != widget.initialChannelId) {
      // a new link opens its channel; a link taken away (or another region) goes back to the list
      final id = widget.initialChannelId;
      _open = id != null && id.isNotEmpty ? (id, null) : null;
    }
  }

  Future<_ChannelsData> _fetch() async {
    final api = channelsApiFactory(widget.baseUrl);
    try {
      final page = await api.list();
      // An empty list has two meanings: nothing said in 24 h, or no packet feed at all. One cached probe tells them
      // apart. The hub (every region) always has a feed.
      final feed = page.rows.isEmpty && widget.regionSlug != null ? await api.packetFeed() : PacketFeedProbe.unknown;
      return _ChannelsData(page, feed);
    } finally {
      api.close();
    }
  }

  Future<void> _reload() async {
    resetPacketFeedProbes(widget.baseUrl);
    final f = _fetch();
    setState(() {
      _f = f;
    });
    try {
      await f;
    } catch (_) {}
  }

  void _search() => openChannelSearch(context, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug);

  Uri get _web => Uri(scheme: 'https', host: widget.regionSlug == null ? Uri.parse(widget.baseUrl).host : '${widget.regionSlug}.meshsonar.com', path: '/channels');

  void _close() => setState(() => _open = null);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final open = _open;
    if (open != null) {
      return ChannelReaderView(
          key: ValueKey('channel-reader-${widget.baseUrl}-${open.$1}'), baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, channelId: open.$1, title: open.$2, onBack: _close);
    }
    return FutureBuilder<_ChannelsData>(
      future: _f,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(
            key: const Key('channels-loading'),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              const SizedBox(height: Gap.m),
              Text('Loading the channels…', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          );
        }
        if (snap.hasError) return _error(snap.error);
        final d = snap.data!;
        final p = d.page;
        // readable channels first (busiest first, as the server sent them), private ones last
        final readable = p.rows.where((r) => !r.private).toList(), private = p.rows.where((r) => r.private).toList();
        final rows = [...readable, ...private];
        final noFeed = rows.isEmpty && !d.feed.hasFeed;
        final storeOff = rows.isEmpty && !noFeed && p.statusCode == 'channel_store_off';
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            key: const Key('channels-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (p.offlineAsOf != null) Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.l), child: RegionOfflineAsOf(asOf: p.offlineAsOf!, onRetry: _reload)),
              if (!noFeed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.s),
                  child: Semantics(
                    button: true,
                    label: 'Search messages',
                    child: InkWell(
                      key: const Key('channels-search'),
                      borderRadius: BorderRadius.circular(Corners.chip),
                      onTap: _search,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 44),
                        padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                        decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
                        child: Row(children: [
                          Icon(Icons.search, size: 20, color: t.colorScheme.onSurfaceVariant),
                          const SizedBox(width: Gap.s),
                          Expanded(child: Text('Search messages', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant))),
                        ]),
                      ),
                    ),
                  ),
                ),
              if (noFeed)
                NoPacketFeedCard(regionName: d.feed.scopeName ?? p.scopeName ?? widget.regionSlug, reason: d.feed.reason, what: 'channel messages')
              else if (storeOff)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                  child: PacketNote(plainServerText(p.status.reason) ?? 'Channel messages are not being stored on this server yet.', key: const Key('channels-store-off')),
                )
              else if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Column(children: [
                    const Text('No channel messages heard here in the last 24 hours.', key: Key('channels-empty'), textAlign: TextAlign.center),
                    const SizedBox(height: Gap.m),
                    OutlinedButton(key: const Key('channels-empty-retry'), onPressed: _reload, child: const Text('Check again')),
                  ]),
                ),
              if (readable.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xs),
                  child: Text('Public radio conversations, read-only. Tap a channel to read it.',
                      key: const Key('channels-intro'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ),
              for (final r in readable) _ChannelTile(row: r, onTap: () => setState(() => _open = (r.id, r.label))),
              // Private channels cannot be opened: one closed row holds them, so the readable ones are not pushed apart.
              if (private.isNotEmpty && readable.length + private.length <= 3)
                for (final r in private) _ChannelTile(row: r)
              else if (private.isNotEmpty)
                Theme(
                  data: t.copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    key: const PageStorageKey('channels-private'),
                    leading: Icon(Icons.lock_outline, color: t.colorScheme.onSurfaceVariant),
                    title: Text('Private channels (${private.length})'),
                    subtitle: Text('Listed only: their text cannot be read without the key', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    children: [for (final r in private) _ChannelTile(row: r)],
                  ),
                ),
              Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m), child: WebTwinLine(_web)),
            ],
          ),
        );
      },
    );
  }

  Widget _error(Object? e) {
    if (e is V1Error && e.offline) return SingleChildScrollView(child: RegionOfflineEmpty(what: 'the channels', onRetry: _reload));
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            e is V1NotLive ? 'Channels are not available on this server yet.' : (e is V1Error ? e.message : 'The channels did not load.'),
            key: const Key('channels-error'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.m),
          FilledButton(key: const Key('channels-retry'), onPressed: _reload, child: const Text('Try again')),
        ]),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final ChannelRow row;

  /// Null on a private channel: the row is shown disabled and does not navigate.
  final VoidCallback? onTap;
  const _ChannelTile({required this.row, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final r = row;
    final muted = t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant);
    final counts = [
      '${groupInt(r.messages24h)} ${r.messages24h == 1 ? 'message' : 'messages'}',
      if (r.senders24h != null) '${groupInt(r.senders24h!)} ${r.senders24h == 1 ? 'sender' : 'senders'}',
    ].join(' · ');
    final last = [
      if (r.lastSender != null) r.lastSender!,
      if (r.lastMessageAt != null) agoText(r.lastMessageAt),
    ].join(' · ');
    final heardIn = r.regions.isEmpty ? null : 'Heard in ${r.regions.take(3).join(', ')}${r.regions.length > 3 ? ' +${r.regions.length - 3}' : ''}';
    return Opacity(
      opacity: r.private ? 0.55 : 1,
      child: ListTile(
        key: Key('channel-row-${r.id}'),
        enabled: !r.private,
        minTileHeight: 56,
        leading: Icon(r.private ? Icons.lock_outline : (r.kind == 'public' ? Icons.public : Icons.tag), color: c.onSurfaceVariant),
        title: Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('$counts in 24 h', style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (r.private)
            Text('Private: the text cannot be read without its key.', key: Key('channel-private-${r.id}'), style: muted)
          else if (last.isNotEmpty || heardIn != null)
            // One line: who spoke last and when, then where it is heard (the hub).
            Text([if (last.isNotEmpty) 'Last: $last', ?heardIn].join(' · '), style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
        trailing: r.private ? null : Icon(Icons.chevron_right, color: c.onSurfaceVariant),
        onTap: onTap,
      ),
    );
  }
}
