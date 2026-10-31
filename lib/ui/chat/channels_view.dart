// Chat > Channels: your channels with the last message, unread count, pin and mute marks; the pinned System section with
// the wardrive channel (ping count, last ping, "paused by the airtime budget", read-only View traffic); Add a channel.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/models.dart';
import '../theme.dart';
import '../widgets.dart' show EmptyState, SectionLabel;
import 'channel_detail_screen.dart';
import 'channel_flows.dart';
import 'conversation_screen.dart';
import 'message_bubble.dart';
import 'message_format.dart';

class ChannelsView extends StatelessWidget {
  final ChatController controller;
  const ChannelsView({super.key, required this.controller});

  IconData _icon(ChannelKind k) => switch (k) {
        ChannelKind.public => Icons.public_rounded,
        ChannelKind.hashtag => Icons.tag_rounded,
        ChannelKind.private => Icons.lock_outline_rounded,
        ChannelKind.system => Icons.sensors_rounded,
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final id = controller.radioId;
        final channels = id == null ? <Channel>[] : controller.store.channels.list(id, includeSystem: false);
        final entries = [
          for (final ch in channels) (ch, controller.service.conversation(ch.convKey)),
        ]..sort((a, b) {
            final pa = a.$2?.pinned ?? false, pb = b.$2?.pinned ?? false;
            if (pa != pb) return pa ? -1 : 1;
            final ta = a.$2?.lastTsMs ?? 0, tb = b.$2?.lastTsMs ?? 0;
            if (ta != tb) return tb.compareTo(ta);
            return (a.$1.slot ?? 999).compareTo(b.$1.slot ?? 999);
          });
        final children = <Widget>[
          if (!controller.radioConnected) _OfflineNote(hasHistory: entries.isNotEmpty),
          _SystemSection(controller: controller),
          const SectionLabel('Channels'),
          if (entries.isEmpty)
            _NoChannels(controller: controller)
          else
            for (final e in entries) _ChannelRow(controller: controller, channel: e.$1, summary: e.$2, icon: _icon(e.$1.kind)),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.xl),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const Key('add-channel'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => showAddChannelSheet(context, controller),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add a channel'),
              ),
            ),
          ),
        ];
        return RefreshIndicator(
          onRefresh: controller.refreshFromRadio,
          child: ListView(key: const Key('channels-list'), physics: const AlwaysScrollableScrollPhysics(), children: children),
        );
      },
    );
  }
}

class _OfflineNote extends StatelessWidget {
  final bool hasHistory;
  const _OfflineNote({required this.hasHistory});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      key: const Key('channels-offline'),
      margin: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.card)),
      child: Row(children: [
        const Icon(Icons.bluetooth_disabled_rounded),
        const SizedBox(width: Gap.m),
        Expanded(
          child: Text(
            hasHistory
                ? 'Radio not connected. You can read what is saved on this phone; new messages arrive when the radio is back.'
                : 'Radio not connected. Connect it to add channels and to receive messages.',
            style: t.textTheme.bodyMedium,
          ),
        ),
      ]),
    );
  }
}

class _NoChannels extends StatelessWidget {
  final ChatController controller;
  const _NoChannels({required this.controller});
  @override
  Widget build(BuildContext context) {
    final connected = controller.radioConnected;
    return Column(
      key: const Key('channels-empty'),
      children: [
        EmptyState(
          icon: Icons.tag_rounded,
          title: 'No channels yet',
          body: connected
              ? 'A channel is a group chat on the mesh. Join Public to talk with everyone nearby, or add a # channel your local group uses.'
              : 'Channels come from your radio. Connect it and they appear here, or add one once it is connected.',
          action: connected
              ? FilledButton.icon(
                  key: const Key('join-public-empty'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => runChannelAction(context, controller, () => controller.admin.joinPublic(controller.radioId ?? ''), what: 'Public'),
                  icon: const Icon(Icons.public_rounded),
                  label: const Text('Join Public'),
                )
              : null,
        ),
      ],
    );
  }
}

class _ChannelRow extends StatelessWidget {
  final ChatController controller;
  final Channel channel;
  final ConversationSummary? summary;
  final IconData icon;
  const _ChannelRow({required this.controller, required this.channel, required this.summary, required this.icon});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = summary;
    final unread = s?.unread ?? 0;
    final muted = s?.isMutedAt(controller.now().millisecondsSinceEpoch) ?? false;
    final offRadio = channel.slot == null;
    final sub = offRadio && s?.lastPreview == null ? 'Not on your radio right now' : (s?.lastPreview ?? 'No messages yet');
    final stamp = listStamp(context, s?.lastTsMs, now: controller.now());
    final semantics = StringBuffer(channel.name);
    if (unread > 0) semantics.write(', $unread unread');
    if (s?.pinned ?? false) semantics.write(', pinned');
    if (muted) semantics.write(', muted');
    if (offRadio) semantics.write(', not on the radio');
    semantics.write('. $sub');
    return Semantics(
      container: true,
      label: semantics.toString(),
      button: true,
      child: ExcludeSemantics(
        child: ListTile(
          key: Key('channel-row-${channel.id}'),
          minTileHeight: 64,
          leading: CircleAvatar(backgroundColor: t.colorScheme.secondaryContainer, child: Icon(icon, color: t.colorScheme.onSecondaryContainer)),
          title: Row(children: [
            Flexible(child: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: unread > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null)),
            if (s?.pinned ?? false) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.push_pin_rounded, size: 14)),
            if (muted) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.notifications_off_outlined, size: 14)),
          ]),
          subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: offRadio ? TextStyle(color: t.colorScheme.error) : null),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(stamp, style: t.textTheme.labelSmall),
              if (unread > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Badge(key: Key('unread-${channel.id}'), label: Text(unread > 99 ? '99+' : '$unread'), backgroundColor: muted ? t.colorScheme.outline : t.colorScheme.primary),
                ),
            ],
          ),
          onTap: () => ConversationScreen.open(context, controller: controller, convKey: channel.convKey, title: channel.name),
          onLongPress: () => ChannelDetailScreen.open(context, controller: controller, channelId: channel.id!),
        ),
      ),
    );
  }
}

/// The pinned System section: the wardrive channel is not a chat. It shows what MeshSonar has done on it.
class _SystemSection extends StatelessWidget {
  final ChatController controller;
  const _SystemSection({required this.controller});

  @override
  Widget build(BuildContext context) {
    final id = controller.radioId;
    final systems = id == null ? const <SystemChannelStats>[] : controller.service.systemChannels(id);
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('System'),
        if (systems.isEmpty)
          ListTile(
            key: const Key('system-empty'),
            minTileHeight: 64,
            leading: const CircleAvatar(child: Icon(Icons.sensors_rounded)),
            title: const Text('Wardrive channel'),
            subtitle: const Text('Appears after your first drive: the channel your pings are sent on. It is never mixed into your chats.'),
          )
        else
          for (final s in systems) _systemTile(context, t, s),
      ],
    );
  }

  Widget _systemTile(BuildContext context, ThemeData t, SystemChannelStats s) {
    final last = s.lastPingTsMs == null ? 'no pings yet' : 'last ping ${_ago(controller.now().millisecondsSinceEpoch - s.lastPingTsMs!)} ago';
    final paused = controller.pingsPausedByBudget;
    return Semantics(
      container: true,
      label: 'System. ${s.channel.name}. ${s.pingsSent} pings sent, $last.${paused ? ' Pings paused by the airtime budget.' : ''}',
      child: ExcludeSemantics(
        child: ListTile(
          key: Key('system-row-${s.channel.id}'),
          minTileHeight: 72,
          isThreeLine: paused,
          leading: CircleAvatar(backgroundColor: t.colorScheme.tertiaryContainer, child: Icon(Icons.sensors_rounded, color: t.colorScheme.onTertiaryContainer)),
          title: Text(s.channel.name),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s.pingsSent} ${s.pingsSent == 1 ? 'ping' : 'pings'} sent, $last'),
            if (paused)
              Text('Paused by the airtime budget: pings resume by themselves.', key: const Key('system-paused'), style: TextStyle(color: t.colorScheme.error, fontWeight: FontWeight.w600)),
          ]),
          trailing: TextButton(
            key: const Key('view-traffic'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SystemTrafficScreen(controller: controller, channel: s.channel))),
            child: const Text('View traffic'),
          ),
        ),
      ),
    );
  }

  static String _ago(int ms) {
    final s = ms ~/ 1000;
    if (s < 90) return '${s < 0 ? 0 : s} s';
    if (s < 5400) return '${(s / 60).round()} min';
    return '${(s / 3600).round()} h';
  }
}

/// Read-only list of what others posted on the wardrive channel (pings from other MeshSonar and MeshMapper users).
class SystemTrafficScreen extends StatefulWidget {
  final ChatController controller;
  final Channel channel;
  const SystemTrafficScreen({super.key, required this.controller, required this.channel});
  @override
  State<SystemTrafficScreen> createState() => _SystemTrafficScreenState();
}

class _SystemTrafficScreenState extends State<SystemTrafficScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_r);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_r);
    super.dispose();
  }

  void _r() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.controller.service.systemTraffic(widget.channel.id!, limit: 100);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('${widget.channel.name} traffic')),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Text(
              'This is the wardrive channel: other people\'s pings land here. It is read-only and kept only on this phone, the newest ${page.messages.length}.',
              style: t.textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child: page.messages.isEmpty
                ? const EmptyState(icon: Icons.sensors_rounded, title: 'Nothing heard yet', body: 'Pings from other drivers on this channel will show up here while your radio is connected.')
                : ListView.builder(
                    key: const Key('traffic-list'),
                    itemCount: page.messages.length,
                    itemBuilder: (context, i) => MessageBubble(message: page.messages[i], showSender: true),
                  ),
          ),
        ]),
      ),
    );
  }
}
