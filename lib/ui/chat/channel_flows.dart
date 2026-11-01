import 'dart:async';

// Add-a-channel flows: join Public, join a #hashtag channel, scan a QR code, paste a link or secret, create a private
// channel; plus what happens when a meshcore:// link is tapped in a message. Every failure is a plain sentence that says
// what to do (ChannelAdminException.message).
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/channel_admin.dart';
import '../../chat/channel_secret.dart';
import '../../chat/mesh_links.dart';
import '../../chat/models.dart';
import '../alerts/permission_prompt.dart';
import '../theme.dart';
import 'channel_detail_screen.dart';
import 'conversation_screen.dart';
import 'qr_widgets.dart';

/// Replaceable in tests: the camera scanner.
abstract final class ChatUiHooks {
  static QrScanLauncher scanQr = defaultQrScan;
}

enum AddChannelChoice { public, hashtag, scan, paste, create }

Future<void> showAddChannelSheet(BuildContext context, ChatController controller) async {
  final choice = await showModalBottomSheet<AddChannelChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      Widget tile(IconData icon, String title, String sub, AddChannelChoice c, Key key) => ListTile(
            key: key,
            minTileHeight: 56,
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(sub),
            onTap: () => Navigator.pop(ctx, c),
          );
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
              child: Align(alignment: Alignment.centerLeft, child: Text('Add a channel', style: Theme.of(ctx).textTheme.titleLarge)),
            ),
            tile(Icons.public_rounded, 'Join Public', 'The open channel most MeshCore users share', AddChannelChoice.public, const Key('add-public')),
            tile(Icons.tag_rounded, 'Join a # channel', 'Type a name like #hamradio. Anyone who types the same name joins the same channel',
                AddChannelChoice.hashtag, const Key('add-hashtag')),
            tile(Icons.qr_code_scanner_rounded, 'Scan a QR code', 'Use the camera on a code from a friend', AddChannelChoice.scan, const Key('add-scan')),
            tile(Icons.link_rounded, 'Paste a link or secret', 'A meshcore:// link, or a channel name with its secret', AddChannelChoice.paste, const Key('add-paste')),
            tile(Icons.lock_outline_rounded, 'Create a private channel', 'Only people you give the QR code or link to can read it', AddChannelChoice.create,
                const Key('add-create')),
          ]),
        ),
      );
    },
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case AddChannelChoice.public:
      await runChannelAction(context, controller, () => controller.admin.joinPublic(controller.radioId ?? ''), what: 'Public');
    case AddChannelChoice.hashtag:
      await _form(context, controller, _FormMode.hashtag);
    case AddChannelChoice.paste:
      await _form(context, controller, _FormMode.paste);
    case AddChannelChoice.create:
      await _form(context, controller, _FormMode.create);
    case AddChannelChoice.scan:
      final link = await ChatUiHooks.scanQr(context);
      if (link != null && context.mounted) await handleMeshLink(context, controller, link);
  }
}

Future<void> _form(BuildContext context, ChatController controller, _FormMode mode) async {
  final join = await showDialog<ChannelJoin>(context: context, builder: (_) => _ChannelForm(controller: controller, mode: mode));
  if (join == null || !context.mounted) return;
  _announce(context, controller, join);
  if (mode == _FormMode.create) {
    // The next thing anyone does with a new private channel is share it.
    await ChannelDetailScreen.open(context, controller: controller, channelId: join.channel.id!);
  }
}

void _announce(BuildContext context, ChatController controller, ChannelJoin join) {
  // First channel joined: the right moment to explain alerts (once; never at launch).
  if (join.created) unawaited(offerAlertsAfterFirstAction(context));
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(join.created ? 'Joined ${join.channel.name}' : 'You already have ${join.channel.name}'),
      action: SnackBarAction(label: 'Open', onPressed: () => ConversationScreen.open(context, controller: controller, convKey: join.channel.convKey)),
    ));
}

/// Runs a join with a progress indicator and shows the plain-language error in a dialog when it fails.
Future<ChannelJoin?> runChannelAction(BuildContext context, ChatController controller, Future<ChannelJoin> Function() action, {String? what}) async {
  if (controller.radioId == null) {
    await _errorDialog(context, 'Connect your radio once first. Channels live in the radio, so MeshSonar needs to see it before it can add one.');
    return null;
  }
  try {
    final j = await action();
    if (context.mounted) _announce(context, controller, j);
    return j;
  } on ChannelAdminException catch (e) {
    if (context.mounted) await _errorDialog(context, e.message);
  } catch (e) {
    if (context.mounted) await _errorDialog(context, 'Something went wrong while changing the channel. Nothing was changed. Try again.');
  }
  return null;
}

Future<void> _errorDialog(BuildContext context, String message) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('channel-error-dialog'),
        icon: const Icon(Icons.error_outline_rounded),
        title: const Text('Could not do that'),
        content: Text(message),
        actions: [FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );

/// A tapped or scanned meshcore:// link. Channel: ask, then join. Contact or advert: add it to Contacts. Anything else: say what it is.
Future<void> handleMeshLink(BuildContext context, ChatController controller, String link) async {
  final p = MeshLinks.parse(link);
  switch (p) {
    case LinkParseError():
      await _errorDialog(context, ChannelAdmin.describeLinkError(p.error));
    case ChannelLink():
      final kind = classifyName(p);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('join-link-dialog'),
          title: Text('Join ${p.name}?'),
          content: Text(
            '${kind == ChannelKind.private ? 'This is a private channel. Everyone who has this link can read it.' : 'This is an open channel. Anyone who types the same name can read it.'}'
            '${p.regionScope != null ? '\n\nIt is limited to the region "${p.regionScope}".' : ''}'
            '\n\nIt uses one of your radio\'s channel slots.',
          ),
          actions: [
            TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
            FilledButton(key: const Key('join-link-confirm'), style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx, true), child: const Text('Join')),
          ],
        ),
      );
      if (ok == true && context.mounted) await runChannelAction(context, controller, () => controller.admin.joinFromLink(controller.radioId ?? '', link));
    case ContactLink() || AdvertLink():
      // The contact book (ContactManager) saves it on the phone and puts it on the radio when it can.
      final r = await controller.service.contacts.addFromLink(link);
      if (!context.mounted) return;
      controller.refresh();
      final text = r.ok ? '${r.created ? 'Added' : 'Already in Contacts:'} ${r.contact!.displayName}.${r.note == null ? '' : ' ${r.note}'}' : (r.error ?? 'That contact could not be added.');
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
  }
}

ChannelKind classifyName(ChannelLink p) => classifyChannel(p.name, p.secret);

enum _FormMode { hashtag, paste, create }

class _ChannelForm extends StatefulWidget {
  final ChatController controller;
  final _FormMode mode;
  const _ChannelForm({required this.controller, required this.mode});
  @override
  State<_ChannelForm> createState() => _ChannelFormState();
}

class _ChannelFormState extends State<_ChannelForm> {
  final _name = TextEditingController();
  final _link = TextEditingController();
  final _secret = TextEditingController();
  bool _byParts = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _link.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final id = widget.controller.radioId;
    if (id == null) {
      setState(() => _error = 'Connect your radio once first. Channels live in the radio, so MeshSonar needs to see it before it can add one.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final a = widget.controller.admin;
      final ChannelJoin j = switch (widget.mode) {
        _FormMode.hashtag => await a.joinHashtag(id, _name.text),
        _FormMode.create => await a.createPrivate(id, _name.text),
        _FormMode.paste => _byParts ? await a.joinPrivate(id, _name.text, _secret.text) : await a.joinFromLink(id, _link.text),
      };
      if (mounted) Navigator.pop(context, j);
    } on ChannelAdminException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Something went wrong while changing the channel. Nothing was changed. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (title, action) = switch (widget.mode) {
      _FormMode.hashtag => ('Join a # channel', 'Join'),
      _FormMode.paste => ('Paste a link or secret', 'Join'),
      _FormMode.create => ('Create a private channel', 'Create'),
    };
    return AlertDialog(
      key: const Key('channel-form'),
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.mode == _FormMode.hashtag) ...[
              Text('The key is made from the name, so anyone who types the same name lands in the same channel. Capitals are turned into lower case.', style: t.textTheme.bodyMedium),
              const SizedBox(height: Gap.m),
              TextField(key: const Key('form-name'), controller: _name, autofocus: true, autocorrect: false, decoration: const InputDecoration(labelText: 'Channel name', prefixText: '# ')),
            ],
            if (widget.mode == _FormMode.create) ...[
              Text('MeshSonar makes a random secret. Only people you give the QR code or link to can read this channel.', style: t.textTheme.bodyMedium),
              const SizedBox(height: Gap.m),
              TextField(key: const Key('form-name'), controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'Channel name')),
            ],
            if (widget.mode == _FormMode.paste) ...[
              if (!_byParts)
                TextField(
                  key: const Key('form-link'),
                  controller: _link,
                  autofocus: true,
                  autocorrect: false,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'meshcore:// link', hintText: 'meshcore://channel/add?name=...'),
                )
              else ...[
                TextField(key: const Key('form-name'), controller: _name, autocorrect: false, decoration: const InputDecoration(labelText: 'Channel name')),
                const SizedBox(height: Gap.s),
                TextField(key: const Key('form-secret'), controller: _secret, autocorrect: false, decoration: const InputDecoration(labelText: 'Secret (32 letters and numbers)')),
              ],
              const SizedBox(height: Gap.s),
              TextButton(
                key: const Key('form-toggle'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => setState(() {
                  _byParts = !_byParts;
                  _error = null;
                }),
                child: Text(_byParts ? 'I have a link instead' : 'I have a name and a secret instead'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: Gap.s),
              Text(_error!, key: const Key('form-error'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('form-submit'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : _submit,
          child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(action),
        ),
      ],
    );
  }
}
