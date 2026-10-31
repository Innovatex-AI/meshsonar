// Contact detail: who it is, where it was last heard, how messages get there, and every action on one screen. Reactive: a
// route learned, a favourite toggled or a contact removed shows at once.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../chat/contact_manager.dart';
import '../../chat/contact_port.dart';
import '../../chat/delivery_text.dart';
import '../../chat/models.dart';
import '../claims/claim_widgets.dart' show ClaimRepeaterAction;
import '../theme.dart';
import 'contact_map.dart';
import 'contact_widgets.dart';
import 'contacts_controller.dart';
import 'qr_view.dart';

typedef ShareText = Future<void> Function(String text, {String? subject});
typedef ClaimBuilder = Widget Function(BuildContext context, Contact contact);

Future<void> _defaultShare(String text, {String? subject}) async {
  await SharePlus.instance.share(ShareParams(text: text, subject: subject));
}

Widget _defaultClaim(BuildContext context, Contact c) =>
    ClaimRepeaterAction(keyHex: c.publicKey, name: c.displayName, isRoom: c.type == ContactType.room);

class ContactDetailScreen extends StatefulWidget {
  final ContactsController controller;
  final String publicKey;

  /// Test and offline seams: the mini map, the share sheet and the claim button.
  final ContactMapBuilder mapBuilder;
  final ShareText shareText;
  final ClaimBuilder claimBuilder;

  const ContactDetailScreen({
    super.key,
    required this.controller,
    required this.publicKey,
    this.mapBuilder = defaultContactMap,
    this.shareText = _defaultShare,
    this.claimBuilder = _defaultClaim,
  });

  @override
  State<ContactDetailScreen> createState() => _ContactDetailScreenState();
}

class _ContactDetailScreenState extends State<ContactDetailScreen> {
  final _notes = TextEditingController();
  final _notesFocus = FocusNode();
  String? _notesFor;
  bool _popped = false;

  ContactsController get _c => widget.controller;
  ContactManager get _m => _c.manager;

  @override
  void initState() {
    super.initState();
    _notesFocus.addListener(() {
      if (!_notesFocus.hasFocus) _saveNotes();
    });
  }

  @override
  void dispose() {
    _saveNotes();
    _notes.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  void _saveNotes() {
    final c = _c.contact(widget.publicKey);
    if (c != null && _notesFor == c.publicKey && _notes.text != c.notes) _m.setNotes(c.publicKey, _notes.text);
  }

  void _say(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final c = _c.contact(widget.publicKey);
        if (c == null) return _gone(context);
        if (_notesFor != c.publicKey) {
          _notesFor = c.publicKey;
          _notes.text = c.notes;
        }
        return _body(context, c);
      },
    );
  }

  Widget _gone(BuildContext context) {
    if (!_popped) {
      _popped = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
      });
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Contact')),
      body: const Center(
        key: Key('contact-gone'),
        child: Padding(padding: EdgeInsets.all(Gap.xl), child: Text('This contact was removed.', textAlign: TextAlign.center)),
      ),
    );
  }

  Widget _body(BuildContext context, Contact c) {
    final t = Theme.of(context);
    final now = _c.nowMs();
    final connected = _m.connected;
    final canMessage = _c.openConversation != null && (c.type == ContactType.companion || c.type == ContactType.room);
    final canAdmin = _c.openAdmin != null && (c.type == ContactType.repeater || c.type == ContactType.room);
    final canClaim = c.type == ContactType.repeater;
    return Scaffold(
      appBar: AppBar(
        title: Text(c.displayName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const Key('contact-favourite'),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: c.favourite ? 'Remove favourite' : 'Favourite',
            icon: Icon(c.favourite ? Icons.star_rounded : Icons.star_outline_rounded, color: c.favourite ? Colors.amber.shade700 : null),
            onPressed: () => _m.setFavourite(c.publicKey, !c.favourite),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              key: const Key('contact-detail'),
              padding: const EdgeInsets.all(Gap.l),
              children: [
                _header(context, c),
                const SizedBox(height: Gap.l),
                if (canMessage || canAdmin || canClaim) ...[
                  Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
                    if (canMessage)
                      FilledButton.icon(
                        key: const Key('contact-message'),
                        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                        icon: Icon(c.type == ContactType.room ? Icons.forum_rounded : Icons.chat_bubble_rounded),
                        label: Text(c.type == ContactType.room ? 'Open room' : 'Message'),
                        onPressed: () => _c.openConversation!(context, c),
                      ),
                    if (canAdmin)
                      OutlinedButton.icon(
                        key: const Key('contact-admin'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                        icon: const Icon(Icons.admin_panel_settings_outlined),
                        label: const Text('Admin'),
                        onPressed: () => _c.openAdmin!(context, c),
                      ),
                    if (canClaim) widget.claimBuilder(context, c),
                  ]),
                  const SizedBox(height: Gap.l),
                ],
                _card(context, 'Identity', [
                  _identity(context, c),
                ]),
                _card(context, 'Location', [_location(context, c, now)]),
                _card(context, 'Route', [_route(context, c, now)]),
                _card(context, 'Notes', [
                  TextField(
                    key: const Key('contact-notes'),
                    controller: _notes,
                    focusNode: _notesFocus,
                    minLines: 2,
                    maxLines: 6,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(hintText: 'Add a note', border: OutlineInputBorder()),
                    onTapOutside: (_) => _notesFocus.unfocus(),
                  ),
                  const SizedBox(height: 4),
                  Text('Notes stay on this phone.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ]),
                _card(context, 'Share and manage', [
                  _fullButton(const Key('contact-share'), Icons.ios_share_rounded, 'Share contact', () => _share(c)),
                  if (connected)
                    _fullButton(const Key('contact-share-nearby'), Icons.cell_tower_rounded, 'Send to radios nearby', () => _shareNearby(c)),
                  _fullButton(const Key('contact-block'), c.blocked ? Icons.check_circle_outline : Icons.block_rounded,
                      c.blocked ? 'Unblock' : 'Block', () => _block(c)),
                  _fullButton(const Key('contact-remove'), Icons.delete_outline_rounded, 'Remove contact', () => _remove(c), destructive: true),
                ]),
                const SizedBox(height: Gap.xl),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fullButton(Key key, IconData icon, String label, VoidCallback onTap, {bool destructive = false}) {
    final err = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          key: key,
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: destructive ? err : null,
              side: destructive ? BorderSide(color: err) : null,
              alignment: Alignment.centerLeft),
          icon: Icon(icon),
          label: Text(label),
          onPressed: onTap,
        ),
      ),
    );
  }

  Widget _card(BuildContext context, String title, List<Widget> children) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.l),
      child: Container(
        padding: const EdgeInsets.all(Gap.l),
        decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.card)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(header: true, child: Text(title, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
          const SizedBox(height: Gap.s),
          ...children,
        ]),
      ),
    );
  }

  // ------------------------------------------------------------------ header

  Widget _header(BuildContext context, Contact c) {
    final t = Theme.of(context);
    final loose = !c.onRadio;
    final why = c.onRadio
        ? 'Your radio has this contact, so messages can go out and arrive.'
        : (c.favourite || _c.conversationOf(c) != null)
            ? 'The radio let this contact go to make room. It goes back on the radio when you message them, or you can put it on now.'
            : 'Kept in your phone\'s contact book. It goes onto the radio when you message them.';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        ContactAvatar(c, size: 64),
        const SizedBox(width: Gap.l),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.displayName, style: t.textTheme.titleLarge, key: const Key('contact-name')),
            if (c.customName != null && c.customName!.trim().isNotEmpty && c.customName != c.name)
              Text('Advertises as ${c.name}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Wrap(spacing: Gap.s, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(contactTypeLabel(c.type), style: t.textTheme.bodyMedium),
              Chip(
                key: const Key('contact-radio-chip'),
                visualDensity: VisualDensity.compact,
                avatar: Icon(c.onRadio ? Icons.check_circle_outline : Icons.smartphone_rounded, size: 18),
                label: Text(c.onRadio ? 'On your radio' : 'Saved on your phone only'),
              ),
              if (c.blocked) const Chip(visualDensity: VisualDensity.compact, label: Text('Blocked')),
            ]),
          ]),
        ),
      ]),
      const SizedBox(height: Gap.s),
      Text(why, key: const Key('contact-radio-why'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      if (loose && (c.favourite || _c.conversationOf(c) != null))
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: OutlinedButton.icon(
            key: const Key('contact-put-on-radio'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.upload_rounded),
            label: const Text('Put on radio now'),
            onPressed: () => _putOnRadio(c),
          ),
        ),
    ]);
  }

  Future<void> _putOnRadio(Contact c) async {
    try {
      await _m.ensureOnRadio(c.publicKey);
      _say('${c.displayName} is on the radio now.');
    } on ContactTableFull {
      _say('The radio\'s contact list is full and every contact on it is a favourite or in use. Free a slot in Contacts first.');
    } on RadioUnavailable {
      _say('The radio is not connected. Connect it and try again.');
    } catch (_) {
      _say('The radio did not take it. Try again in a moment.');
    }
  }

  // ------------------------------------------------------------------ identity

  Widget _identity(BuildContext context, Contact c) {
    final t = Theme.of(context);
    final groups = [for (var i = 0; i < 64; i += 8) c.publicKey.substring(i, i + 8)];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Public key', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 4),
      Semantics(
        label: 'Public key, ${groups.join(' ')}',
        excludeSemantics: true,
        child: Wrap(spacing: 10, runSpacing: 2, children: [
          for (final g in groups) Text(g, style: const TextStyle(fontFamily: 'monospace', fontSize: 15, fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      ),
      const SizedBox(height: Gap.s),
      Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
        OutlinedButton.icon(
          key: const Key('contact-copy-key'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy key'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: c.publicKey));
            _say('Key copied');
          },
        ),
        OutlinedButton.icon(
          key: const Key('contact-show-qr'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.qr_code_2_rounded),
          label: const Text('Show QR code'),
          onPressed: () => _showQr(c),
        ),
        OutlinedButton.icon(
          key: const Key('contact-rename'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Rename'),
          onPressed: () => _rename(c),
        ),
      ]),
    ]);
  }

  Future<void> _rename(Contact c) async {
    final ctl = TextEditingController(text: c.customName ?? c.name);
    final hasCustom = c.customName != null && c.customName!.trim().isNotEmpty;
    final res = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename contact'),
        content: TextField(
          key: const Key('rename-field'),
          controller: ctl,
          autofocus: true,
          maxLength: 31,
          decoration: InputDecoration(helperText: 'Only changes the name on this phone. They still advertise as ${c.name}.'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          if (hasCustom)
            TextButton(
                key: const Key('rename-reset'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.pop(ctx, ''),
                child: const Text('Reset name')),
          FilledButton(
              key: const Key('rename-save'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    ctl.dispose();
    if (res != null) _m.rename(c.publicKey, res);
  }

  Future<void> _showQr(Contact c) {
    final link = _m.linkFor(c);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(c.displayName, style: Theme.of(ctx).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: Gap.s),
            Text('Scan this with MeshSonar or the MeshCore app to add ${c.displayName}.',
                textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.bodyMedium),
            const SizedBox(height: Gap.l),
            QrView(data: link, size: 240, semanticLabel: 'QR code for contact ${c.displayName}'),
            const SizedBox(height: Gap.l),
            Wrap(spacing: Gap.s, runSpacing: Gap.s, alignment: WrapAlignment.center, children: [
              OutlinedButton.icon(
                key: const Key('qr-copy-link'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.link_rounded),
                label: const Text('Copy link'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link));
                  _say('Link copied');
                },
              ),
              FilledButton.icon(
                key: const Key('qr-share-link'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.ios_share_rounded),
                label: const Text('Share'),
                onPressed: () => widget.shareText(link, subject: 'MeshCore contact ${c.displayName}'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ location

  Widget _location(BuildContext context, Contact c, int now) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    if (!c.hasPosition) {
      return Text('No position advertised. Repeaters and people choose whether to share where they are.', key: const Key('contact-no-position'), style: t.textTheme.bodyMedium);
    }
    final adv = c.lastAdvertTs;
    final when = adv == null ? 'their last advert' : 'their last advert, ${_ago(now - adv * 1000)}';
    final coords = '${c.lat!.toStringAsFixed(5)}, ${c.lon!.toStringAsFixed(5)}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ExcludeSemantics(child: widget.mapBuilder(context, c.lat!, c.lon!)),
      const SizedBox(height: Gap.s),
      Text('Position from $when', style: muted),
      Row(children: [
        Expanded(child: SelectableText(coords, key: const Key('contact-coords'), style: const TextStyle(fontFamily: 'monospace'))),
        IconButton(
          key: const Key('contact-copy-coords'),
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: 'Copy position',
          icon: const Icon(Icons.copy_rounded),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: coords));
            _say('Position copied');
          },
        ),
      ]),
    ]);
  }

  static String _ago(int ms) {
    if (ms < 90000) return 'just now';
    final m = ms ~/ 60000;
    if (m < 60) return '$m min ago';
    final h = ms ~/ 3600000;
    if (h < 24) return '$h h ago';
    final d = ms ~/ 86400000;
    return d == 1 ? 'yesterday' : '$d days ago';
  }

  // ------------------------------------------------------------------ route

  Widget _route(BuildContext context, Contact c, int now) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final adv = c.lastAdvertTs;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(heardText(c.lastHeardMs, now), key: const Key('contact-heard'), style: t.textTheme.bodyLarge),
      Text(adv == null ? 'No advert received yet' : 'Last advert ${_ago(now - adv * 1000)}', style: muted),
      const SizedBox(height: Gap.s),
      Text(describeRoute(c), key: const Key('contact-route'), style: t.textTheme.bodyMedium),
      if (c.hasPath) Text('${c.pathHops} ${c.pathHops == 1 ? 'hop' : 'hops'} saved', key: const Key('contact-hops'), style: muted),
      if (c.routeIds.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final id in c.routeIds)
              Chip(key: Key('hop-$id'), visualDensity: VisualDensity.compact, label: Text(id, style: const TextStyle(fontFamily: 'monospace'))),
          ]),
        ),
      const SizedBox(height: Gap.s),
      SwitchListTile(
        key: const Key('contact-force-flood'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Always send by flood (ignore the saved route)'),
        subtitle: const Text('Slower and uses more airtime, but works when repeaters on the saved route move or go off.'),
        value: c.forceFlood,
        onChanged: (v) => _m.setForceFlood(c.publicKey, v),
      ),
      OutlinedButton.icon(
        key: const Key('contact-reset-route'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        icon: const Icon(Icons.route_rounded),
        label: const Text('Reset route'),
        onPressed: c.hasPath
            ? () async {
                await _m.resetPath(c.publicKey);
                _say('Route forgotten. The next message floods and finds a new one.');
              }
            : null,
      ),
      if (!c.hasPath) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Nothing to reset: no route is saved yet.', style: muted)),
    ]);
  }

  // ------------------------------------------------------------------ share / block / remove

  Future<void> _share(Contact c) => widget.shareText(_m.linkFor(c), subject: 'MeshCore contact ${c.displayName}');

  Future<void> _shareNearby(Contact c) async {
    try {
      final ok = await _m.shareToNearbyRadios(c.publicKey);
      _say(ok
          ? 'Sent. Only radios within direct range can hear it.'
          : 'Your radio has no stored advert for this contact, so it cannot send it. Share the link or QR code instead.');
    } on RadioUnavailable {
      _say('The radio is not connected. Connect it and try again.');
    } catch (_) {
      _say('The radio did not answer. Try again in a moment.');
    }
  }

  void _block(Contact c) {
    final to = !c.blocked;
    _m.setBlocked(c.publicKey, to);
    if (to) {
      final conv = c.type == ContactType.room ? ConvKey.room(c.prefix) : ConvKey.dm(c.prefix);
      _c.chat.markRead(conv);
    }
    _say(to ? '${c.displayName} is blocked. Their messages no longer alert you.' : '${c.displayName} is unblocked.');
  }

  Future<void> _remove(Contact c) async {
    var deleteMessages = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Remove ${c.displayName}?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('This removes the contact from this phone and from your radio. If you meet them on air again, the radio may offer them as a new node.'),
            CheckboxListTile(
              key: const Key('remove-delete-messages'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: deleteMessages,
              onChanged: (v) => set(() => deleteMessages = v ?? false),
              title: const Text('Also delete the messages with them'),
            ),
          ]),
          actions: [
            TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              key: const Key('remove-confirm'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48), backgroundColor: Theme.of(ctx).colorScheme.error, foregroundColor: Theme.of(ctx).colorScheme.onError),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if (deleteMessages) {
      _c.chat.deleteHistory(c.type == ContactType.room ? ConvKey.room(c.prefix) : ConvKey.dm(c.prefix));
    }
    _popped = true;
    final nav = Navigator.of(context);
    unawaited(_m.remove(c.publicKey));
    if (nav.canPop()) nav.pop();
  }
}
