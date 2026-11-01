// Channel info: share (QR, link, copy), notifications, pin, region, rename, put back on the radio, clear history, delete.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/chat_controller.dart';
import '../../chat/channel_admin.dart';
import '../../chat/models.dart';
import '../theme.dart';
import '../widgets.dart' show SectionLabel;
import 'qr_widgets.dart';

class ChannelDetailScreen extends StatefulWidget {
  final ChatController controller;
  final int channelId;
  const ChannelDetailScreen({super.key, required this.controller, required this.channelId});

  static Future<void> open(BuildContext context, {required ChatController controller, required int channelId}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChannelDetailScreen(controller: controller, channelId: channelId)));

  @override
  State<ChannelDetailScreen> createState() => _ChannelDetailScreenState();
}

class _ChannelDetailScreenState extends State<ChannelDetailScreen> {
  String? _link;
  String? _secretHex;
  bool _showSecret = false;
  bool _loadedKey = false;

  ChatController get c => widget.controller;
  Channel? get _channel => c.store.channels.getById(widget.channelId);

  @override
  void initState() {
    super.initState();
    c.addListener(_rebuild);
    _loadKey();
  }

  @override
  void dispose() {
    c.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _loadKey() async {
    final ch = _channel;
    if (ch == null) return;
    try {
      final link = await c.admin.shareLink(ch);
      final hex = await c.admin.secretHex(ch);
      if (mounted) {
        setState(() {
          _link = link;
          _secretHex = hex;
          _loadedKey = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadedKey = true);
    }
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } on ChannelAdminException catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('channel-error-dialog'),
          icon: const Icon(Icons.error_outline_rounded),
          title: const Text('Could not do that'),
          content: Text(e.message),
          actions: [FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    }
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.maybeOf(context)?..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text('$what copied')));
  }

  Future<void> _rename(Channel ch) async {
    final ctl = TextEditingController(text: ch.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename channel'),
        content: TextField(key: const Key('rename-field'), controller: ctl, autofocus: true, decoration: const InputDecoration(labelText: 'Channel name')),
        actions: [
          TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(key: const Key('rename-save'), style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;
    await _guard(() async {
      await c.admin.edit(ch, name: name);
      await _loadKey();
    });
  }

  Future<void> _editRegion(Channel ch) async {
    final ctl = TextEditingController(text: ch.regionScope ?? '');
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Region'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(_regionHelp),
          const SizedBox(height: Gap.m),
          TextField(key: const Key('region-field'), controller: ctl, autofocus: true, autocorrect: false, decoration: const InputDecoration(labelText: 'Region name', hintText: 'Leave empty for the whole mesh')),
        ]),
        actions: [
          TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(key: const Key('region-save'), style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (res == null) return;
    await _guard(() async {
      final v = res.trim();
      String? scope;
      if (v.isNotEmpty) scope = ChannelAdmin.normaliseHashtag(v).substring(1);
      await c.admin.edit(ch, regionScope: scope);
      await _loadKey();
    });
  }

  Future<void> _putBack(Channel ch) => _guard(() async {
        final secret = await c.store.channels.secretOf(ch);
        if (secret == null) {
          throw const ChannelAdminException(ChannelAdminError.notOnRadio, 'The secret of this channel is not on this phone, so it cannot be put back on the radio.');
        }
        await c.admin.joinPrivate(ch.radioId, ch.name, toHex(secret));
      });

  Future<void> _delete(Channel ch) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('delete-channel-dialog'),
        title: Text('Delete ${ch.name}?'),
        content: Text(ch.slot == null
            ? 'The channel and its messages are removed from this phone.'
            : 'The channel is removed from your radio and its messages from this phone. You can join it again later with its link, if you still have it.'),
        actions: [
          TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
            key: const Key('delete-channel-confirm'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48), backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _guard(() async {
      await c.admin.delete(ch);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst || r.settings.name == '/');
    });
  }

  Future<void> _clearHistory(Channel ch) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear the messages?'),
        content: const Text('The messages of this channel are removed from this phone. The channel stays.'),
        actions: [
          TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(key: const Key('clear-history-confirm'), style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      c.service.deleteHistory(ch.convKey);
      c.refresh();
    }
  }

  static const String _regionHelp =
      'A region limits how far your messages are repeated: only repeaters set up for that region pass them on. '
      'Leave it empty to use the whole mesh, which is what most channels do. Only set it if the people who run your local network tell you to, and use the name exactly as they write it.';

  @override
  Widget build(BuildContext context) {
    final ch = _channel;
    final t = Theme.of(context);
    if (ch == null) {
      return Scaffold(appBar: AppBar(title: const Text('Channel')), body: const Center(child: Text('This channel was deleted.')));
    }
    final summary = c.service.conversation(ch.convKey);
    final mode = summary?.notifyMode ?? NotifyMode.all;
    final pinned = summary?.pinned ?? false;
    final kindLabel = switch (ch.kind) {
      ChannelKind.public => 'Public channel',
      ChannelKind.hashtag => '# channel',
      ChannelKind.private => 'Private channel',
      ChannelKind.system => 'Wardrive channel',
    };
    return Scaffold(
      appBar: AppBar(title: Text(ch.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
          key: const Key('channel-detail'),
          padding: const EdgeInsets.only(bottom: Gap.xl),
          children: [
            ListTile(
              minTileHeight: 56,
              leading: Icon(switch (ch.kind) {
                ChannelKind.public => Icons.public_rounded,
                ChannelKind.hashtag => Icons.tag_rounded,
                ChannelKind.private => Icons.lock_outline_rounded,
                ChannelKind.system => Icons.sensors_rounded,
              }),
              title: Text(kindLabel),
              subtitle: Text(ch.slot == null ? 'Not on your radio right now' : 'On your radio, slot ${ch.slot}'),
            ),
            if (ch.slot == null && !ch.isSystem)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                child: Card(
                  color: t.colorScheme.tertiaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.m),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Messages cannot arrive or be sent until this channel is back on the radio. Another app may have replaced it.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onTertiaryContainer)),
                      const SizedBox(height: Gap.s),
                      FilledButton(key: const Key('put-back'), style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => _putBack(ch), child: const Text('Put it back on the radio')),
                    ]),
                  ),
                ),
              ),
            const SectionLabel('Share'),
            if (!_loadedKey)
              const Padding(padding: EdgeInsets.all(Gap.l), child: Center(child: CircularProgressIndicator()))
            else if (_link == null)
              const ListTile(title: Text('The secret of this channel is not on this phone, so it cannot be shared.'))
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                child: Column(children: [
                  Center(child: QrView(key: const Key('share-qr'), data: _link!, size: 220)),
                  const SizedBox(height: Gap.s),
                  Text(
                    ch.kind == ChannelKind.private
                        ? 'Anyone who scans this code or opens the link can read and write in this channel. Share it only with people you trust.'
                        : 'This is an open channel: anyone can also join it by typing its name.',
                    style: t.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: Gap.s),
                  Text(_link!, key: const Key('share-link'), style: t.textTheme.bodySmall),
                  const SizedBox(height: Gap.s),
                  Wrap(spacing: Gap.s, runSpacing: Gap.s, alignment: WrapAlignment.center, children: [
                    OutlinedButton.icon(
                      key: const Key('copy-link'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () => _copy(_link!, 'Link'),
                      icon: const Icon(Icons.link_rounded),
                      label: const Text('Copy link'),
                    ),
                    if (ch.kind == ChannelKind.private && _secretHex != null)
                      OutlinedButton.icon(
                        key: const Key('show-secret'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () => setState(() => _showSecret = !_showSecret),
                        icon: const Icon(Icons.key_rounded),
                        label: Text(_showSecret ? 'Hide secret' : 'Show secret'),
                      ),
                  ]),
                  if (_showSecret && _secretHex != null) ...[
                    const SizedBox(height: Gap.s),
                    Text(_secretHex!, key: const Key('secret-hex'), style: t.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    TextButton(key: const Key('copy-secret'), style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => _copy(_secretHex!, 'Secret'), child: const Text('Copy secret')),
                  ],
                ]),
              ),
            if (!ch.isSystem) ...[
              const SectionLabel('Notifications'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<NotifyMode>(
                    key: const Key('notify-mode'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: NotifyMode.all, label: Text('All')),
                      ButtonSegment(value: NotifyMode.mentionsOnly, label: Text('Mentions')),
                      ButtonSegment(value: NotifyMode.muted, label: Text('Muted')),
                    ],
                    selected: {mode},
                    onSelectionChanged: (v) {
                      c.service.setNotifyMode(ch.radioId, ch.convKey, v.first);
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, 0),
                child: Text(
                  switch (mode) {
                    NotifyMode.all => 'Every new message in this channel notifies you.',
                    NotifyMode.mentionsOnly => 'Only messages that mention you notify you.',
                    NotifyMode.muted => 'Nothing notifies you. Messages still arrive and the unread count stays.',
                  },
                  style: t.textTheme.bodySmall,
                ),
              ),
              SwitchListTile(
                key: const Key('pin-switch'),
                title: const Text('Pin to the top'),
                value: pinned,
                onChanged: (v) => c.service.setPinned(ch.radioId, ch.convKey, v),
              ),
              ListTile(
                key: const Key('region-row'),
                minTileHeight: 56,
                leading: const Icon(Icons.map_outlined),
                title: const Text('Region'),
                subtitle: Text(ch.regionScope == null ? 'None: the whole mesh' : ch.regionScope!),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _editRegion(ch),
              ),
              if (ch.kind == ChannelKind.private)
                ListTile(key: const Key('rename-row'), minTileHeight: 56, leading: const Icon(Icons.edit_outlined), title: const Text('Rename'), onTap: () => _rename(ch)),
              const Divider(),
              ListTile(key: const Key('clear-history'), minTileHeight: 56, leading: const Icon(Icons.cleaning_services_outlined), title: const Text('Clear messages on this phone'), onTap: () => _clearHistory(ch)),
              ListTile(
                key: const Key('delete-channel'),
                minTileHeight: 56,
                leading: Icon(Icons.delete_outline_rounded, color: t.colorScheme.error),
                title: Text('Delete channel', style: TextStyle(color: t.colorScheme.error)),
                onTap: () => _delete(ch),
              ),
            ],
          ],
        ),
          ),
        ),
      ),
    );
  }
}
