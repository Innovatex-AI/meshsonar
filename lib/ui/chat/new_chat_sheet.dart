// The New chat sheet (plan 4.13): opened from the New button and Cmd-N. One sheet (detents 0.5 / 0.92) with pages inside it:
// the start page (To: field, recent and favourite people, the list of things to start) and the channel forms as sheet pages
// (hashtag with a live key preview, paste a link or key, create a private channel and its success page with the secret and
// QR). Scan a QR code and Add a contact close the sheet first and then run on the page behind (the camera and the add screen
// are full pages). Every outcome is returned to [showNewChatSheet], which acts on it once the sheet is gone, so a toast
// with [Open] is never anchored to a closed sheet.
//
//   Cancel is on the leading side; on a form page the leading button reads Back and goes to the start page.
//   Failures are one plain sentence inline (ChannelAdminException.message); nothing is an alert on top of the keyboard.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/chat_controller.dart';
import '../../chat/channel_admin.dart';
import '../../chat/channel_secret.dart';
import '../../chat/conversation_row.dart';
import '../../chat/models.dart';
import '../contacts/add_contact_screen.dart';
import '../contacts/contact_widgets.dart';
import '../design/app_symbols.dart';
import '../design/app_surfaces.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import 'channel_flows.dart';
import 'conversation_tile.dart' show ConversationAvatar;
import 'chat_navigation.dart';
import 'qr_widgets.dart';

/// What the sheet hands back. Private on purpose: the only consumer is [showNewChatSheet].
sealed class _Outcome {
  const _Outcome();
}

class _Joined extends _Outcome {
  final ChannelJoin join;
  const _Joined(this.join);
}

class _OpenPerson extends _Outcome {
  final Contact contact;
  const _OpenPerson(this.contact);
}

class _PickPerson extends _Outcome {
  const _PickPerson();
}

class _Scan extends _Outcome {
  const _Scan();
}

class _AddContact extends _Outcome {
  const _AddContact();
}

/// The sentence shown when there is no radio identity to put a channel on.
const String noRadioForChannelText = 'Connect your radio once first. Channels live in the radio, so MeshSonar needs to see it before it can add one.';

Future<void> showNewChatSheet(
  BuildContext context,
  ChatController controller, {
  required ChatNavigator navigator,
  required VoidCallback showContacts,
}) async {
  final out = await showAppSheet<_Outcome>(
    context,
    detents: const [0.5, 0.92],
    builder: (ctx, scroll) => _NewChatBody(controller: controller, scroll: scroll),
  );
  if (out == null || !context.mounted) return;
  switch (out) {
    case _Joined(:final join):
      announceJoin(context, controller, join);
    case _OpenPerson(:final contact):
      navigator.openContact(context, contact);
    case _PickPerson():
      showContacts();
    case _Scan():
      final link = await ChatUiHooks.scanQr(context);
      if (link != null && context.mounted) await handleMeshLink(context, controller, link);
    case _AddContact():
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AddContactScreen(controller: navigator.contacts)));
  }
}

enum _Page { home, hashtag, paste, create, created }

class _NewChatBody extends StatefulWidget {
  final ChatController controller;
  final ScrollController scroll;
  const _NewChatBody({required this.controller, required this.scroll});
  @override
  State<_NewChatBody> createState() => _NewChatBodyState();
}

class _NewChatBodyState extends State<_NewChatBody> {
  final _to = TextEditingController();
  final _name = TextEditingController();
  final _link = TextEditingController();
  final _secret = TextEditingController();
  _Page _page = _Page.home;
  bool _byParts = false;
  bool _busy = false;
  bool _showSecret = false;
  String? _error;
  ChannelJoin? _created;
  String? _createdLink;
  String? _createdSecret;

  ChatController get _c => widget.controller;

  @override
  void dispose() {
    _to.dispose();
    _name.dispose();
    _link.dispose();
    _secret.dispose();
    super.dispose();
  }

  void _go(_Page p, {String name = '', String link = ''}) {
    setState(() {
      _page = p;
      _error = null;
      _byParts = false;
      _name.text = name;
      _link.text = link;
      _secret.clear();
    });
  }

  // ------------------------------------------------------------------ actions

  Future<void> _run(Future<ChannelJoin> Function(ChannelAdmin a, String radioId) action, {bool toCreated = false}) async {
    final id = _c.radioId;
    if (id == null) {
      setState(() => _error = noRadioForChannelText);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final j = await action(_c.admin, id);
      if (!mounted) return;
      if (toCreated) {
        final link = await _c.admin.shareLink(j.channel);
        final hex = await _c.admin.secretHex(j.channel);
        if (!mounted) return;
        setState(() {
          _busy = false;
          _page = _Page.created;
          _created = j;
          _createdLink = link;
          _createdSecret = hex;
        });
      } else {
        Navigator.pop(context, _Joined(j));
      }
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

  Future<void> _submit() => switch (_page) {
        _Page.hashtag => _run((a, id) => a.joinHashtag(id, _name.text)),
        _Page.create => _run((a, id) => a.createPrivate(id, _name.text), toCreated: true),
        _Page.paste => _run((a, id) => _byParts ? a.joinPrivate(id, _name.text, _secret.text) : a.joinFromLink(id, _link.text)),
        _ => Future<void>.value(),
      };

  Future<void> _pasteFromClipboard() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text?.trim();
    if (t == null || t.isEmpty || !mounted) return;
    setState(() {
      _link.text = t;
      _error = null;
    });
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showAppToast(context, '$what copied');
  }

  // ------------------------------------------------------------------ chrome

  String get _title => switch (_page) {
        _Page.home => 'New',
        _Page.hashtag => 'Join a # channel',
        _Page.paste => 'Paste a link or key',
        _Page.create => 'Create a private channel',
        _Page.created => 'Channel created',
      };

  Widget _header() {
    final t = AppType.headline;
    final home = _page == _Page.home;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.s, 0, Gap.s, Gap.xs),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Align(
              alignment: Alignment.centerLeft,
              child: CupertinoButton(
                key: Key(home ? 'new-cancel' : 'new-back'),
                padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                minimumSize: const Size(Hit.min, Hit.min),
                onPressed: _busy
                    ? null
                    : home
                        ? () => Navigator.pop(context)
                        : _page == _Page.created
                            ? () => Navigator.pop(context, _Joined(_created!))
                            : () => _go(_Page.home),
                child: Text(home ? 'Cancel' : (_page == _Page.created ? 'Done' : 'Back')),
              ),
            ),
          ),
          Expanded(child: Semantics(header: true, child: Text(_title, style: t, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis))),
          const SizedBox(width: 92),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _header(),
        Expanded(child: _body(context)),
      ],
    );
  }

  Widget _body(BuildContext context) => switch (_page) {
        _Page.home => _home(context),
        _Page.created => _createdPage(context),
        _ => _formPage(context),
      };

  // ------------------------------------------------------------------ home

  List<Contact> _people() {
    final id = _c.radioId;
    if (id == null) return const [];
    return _c.store.contacts.list(id, includeBlocked: false).where((x) => x.type == ContactType.companion || x.type == ContactType.room).toList();
  }

  /// Favourites first (by name), then people with the most recent conversation; capped.
  List<Contact> _recents(List<Contact> people) {
    final out = <Contact>[];
    final seen = <String>{};
    final fav = people.where((p) => p.favourite).toList()..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    for (final p in fav) {
      if (seen.add(p.publicKey)) out.add(p);
    }
    final byKey = {for (final p in people) p.publicKey: p};
    for (final r in _c.conversationRows()) {
      if (r.isChannel || r.isSystem || !r.hasHistory || r.contactKey == null) continue;
      final p = byKey[r.contactKey];
      if (p != null && seen.add(p.publicKey)) out.add(p);
    }
    return out.take(14).toList();
  }

  Widget _home(BuildContext context) {
    final q = _to.text.trim();
    final people = _people();
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.xs, Layout.screenMargin, Gap.s),
        child: CupertinoSearchTextField(
          key: const Key('new-to'),
          controller: _to,
          placeholder: 'To: name or key',
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) {
            final m = _matches(people, q);
            if (m.isNotEmpty) Navigator.pop(context, _OpenPerson(m.first));
          },
        ),
      ),
    ];
    if (q.isEmpty) {
      final recents = _recents(people);
      if (recents.isNotEmpty) {
        children.add(_sectionLabel('Recent & favourites'));
        children.add(SizedBox(
          height: 92,
          child: ListView.builder(
            key: const Key('new-recents'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.m),
            itemCount: recents.length,
            itemBuilder: (_, i) => _RecentPerson(contact: recents[i], onTap: () => Navigator.pop(context, _OpenPerson(recents[i]))),
          ),
        ));
      }
      if (_error != null) children.add(_inlineError(_error!));
      children.add(_sectionLabel('Start'));
      children.add(_entries(context));
    } else {
      children.addAll(_search(context, q, people));
    }
    return ListView(controller: widget.scroll, padding: EdgeInsets.zero, children: [...children, const SizedBox(height: Gap.xl)]);
  }

  static List<Contact> _matches(List<Contact> people, String q) {
    final s = q.toLowerCase();
    final key = s.replaceAll(RegExp(r'\s'), '');
    return people.where((p) => p.displayName.toLowerCase().contains(s) || (RegExp(r'^[0-9a-f]{2,}$').hasMatch(key) && p.publicKey.startsWith(key))).toList();
  }

  List<Widget> _search(BuildContext context, String q, List<Contact> people) {
    final c = AppColors.of(context);
    final hits = _matches(people, q);
    final lower = q.toLowerCase();
    final shortcuts = <Widget>[
      if (lower.startsWith('meshcore://'))
        _tile(AppSymbols.docOnDoc, 'Use this link', 'Join the channel or add the contact it holds', () => _go(_Page.paste, link: q), key: const Key('new-use-link')),
      if (q.startsWith('#') && q.length > 1)
        _tile(AppSymbols.message, 'Join $q', 'A # channel: anyone who types the same name joins the same channel', () => _go(_Page.hashtag, name: q.substring(1)),
            key: const Key('new-use-hashtag')),
    ];
    return [
      if (hits.isNotEmpty) ...[
        _sectionLabel('People'),
        _group([
          for (final p in hits.take(30))
            CupertinoListTile(
              key: Key('new-person-${p.prefix}'),
              backgroundColor: c.surfaceHigh,
              leading: ContactAvatar(p, size: 40),
              title: Text(p.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(p.type == ContactType.room ? 'Room' : 'Person', maxLines: 1),
              onTap: () => Navigator.pop(context, _OpenPerson(p)),
            ),
        ]),
      ] else if (shortcuts.isEmpty)
        Padding(
          key: const Key('new-no-people'),
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.l, Layout.screenMargin, Gap.m),
          child: Text('No one in Contacts matches "$q".', style: AppType.subhead.copyWith(color: c.textMuted), textAlign: TextAlign.center),
        ),
      if (shortcuts.isNotEmpty) _group(shortcuts),
      _sectionLabel('Or'),
      _group([
        _tile(AppSymbols.personBadgePlus, 'Add a contact', 'Add someone with their link, key or QR code', () => Navigator.pop(context, const _AddContact()), key: const Key('new-contact-search')),
      ]),
    ];
  }

  Widget _entries(BuildContext context) {
    return _group([
      _tile(AppSymbols.squareAndPencil, 'New message', 'Pick someone from Contacts', () => Navigator.pop(context, const _PickPerson()), key: const Key('new-message')),
      _tile(AppSymbols.numberSign, 'Join a hashtag channel', 'Type a name like #hamradio. Anyone who types the same name joins the same channel', () => _go(_Page.hashtag),
          key: const Key('add-hashtag')),
      _tile(AppSymbols.globe, 'Join Public channel', 'The open channel most MeshCore users share', _busy ? null : () => _run((a, id) => a.joinPublic(id)), key: const Key('add-public')),
      _tile(AppSymbols.lockFill, 'Create a private channel', 'Only people you give the QR code or link to can read it', () => _go(_Page.create), key: const Key('add-create')),
      _tile(AppSymbols.qrcode, 'Scan a QR code', 'Use the camera on a code from a friend', () => Navigator.pop(context, const _Scan()), key: const Key('add-scan')),
      _tile(AppSymbols.docOnDoc, 'Paste a link or key', 'A meshcore:// link, or a channel name with its secret', () => _go(_Page.paste), key: const Key('add-paste')),
      _tile(AppSymbols.personBadgePlus, 'Add a contact', 'Add someone with their link, key or QR code', () => Navigator.pop(context, const _AddContact()), key: const Key('new-contact')),
    ]);
  }

  Widget _tile(AppSymbol symbol, String title, String subtitle, VoidCallback? onTap, {required Key key}) {
    final c = AppColors.of(context);
    return CupertinoListTile(
      key: key,
      backgroundColor: c.surfaceHigh,
      leading: AppSymbolIcon(symbol, size: 22, color: c.accent),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const CupertinoListTileChevron(),
      onTap: onTap,
    );
  }

  Widget _group(List<Widget> rows) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Corners.chip),
        child: ColoredBox(
          color: c.surfaceHigh,
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Container(height: 0.5, margin: const EdgeInsets.only(left: 56), color: c.outline),
              rows[i],
            ],
          ]),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin + Gap.s, Gap.m, Layout.screenMargin, Gap.xs),
      child: Semantics(header: true, child: Text(text.toUpperCase(), style: AppType.footnote.copyWith(color: c.textMuted, letterSpacing: 0.4))),
    );
  }

  Widget _inlineError(String text) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, 0),
      child: Text(text, key: const Key('new-error'), style: AppType.subhead.copyWith(color: c.danger)),
    );
  }

  // ------------------------------------------------------------------ forms

  /// The live preview under the hashtag field: what the name becomes and the start of the key it makes.
  Widget _hashtagPreview(BuildContext context) {
    final c = AppColors.of(context);
    final raw = _name.text.trim();
    String line;
    var ok = false;
    if (raw.isEmpty) {
      line = 'Type a name to see its key.';
    } else {
      try {
        final n = ChannelAdmin.normaliseHashtag(raw);
        final key = hashtagSecret16(n);
        line = '$n  ->  key ${key.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}…';
        ok = true;
      } on ChannelAdminException catch (e) {
        line = e.message;
      }
    }
    return Semantics(
      liveRegion: true,
      child: Text(
        line,
        key: const Key('hashtag-preview'),
        style: ok ? AppType.mono.copyWith(color: c.textPrimary) : AppType.subhead.copyWith(color: c.textMuted),
      ),
    );
  }

  CupertinoTextField _field(Key key, TextEditingController ctl, String placeholder,
      {bool autofocus = false, bool autocorrect = false, int maxLines = 1, String? prefix}) {
    final c = AppColors.of(context);
    return CupertinoTextField(
      key: key,
      controller: ctl,
      placeholder: placeholder,
      autofocus: autofocus,
      autocorrect: autocorrect,
      enableSuggestions: false,
      minLines: 1,
      maxLines: maxLines,
      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.m),
      prefix: prefix == null ? null : Padding(padding: const EdgeInsets.only(left: Gap.m), child: Text(prefix, style: AppType.body.copyWith(color: c.textMuted))),
      style: AppType.body.copyWith(color: c.textPrimary),
      placeholderStyle: AppType.body.copyWith(color: c.textMuted),
      decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.chip)),
      onChanged: (_) => setState(() => _error = null),
    );
  }

  Widget _formPage(BuildContext context) {
    final c = AppColors.of(context);
    final action = _page == _Page.create ? 'Create' : 'Join';
    final intro = switch (_page) {
      _Page.hashtag =>
        'The key is made from the name, so anyone who types the same name lands in the same channel. It is the first 16 bytes of a hash of the name, in lower case. Capitals are turned into lower case.',
      _Page.create => 'MeshSonar makes a random secret. Only people you give the QR code or link to can read this channel.',
      _ => 'Paste a meshcore:// link, or type a channel name with its secret.',
    };
    return AppSheetScaffold(
      key: const Key('channel-form'),
      controller: widget.scroll,
      primaryAction: CupertinoButton.filled(
        key: const Key('form-submit'),
        minimumSize: const Size(Hit.min, Hit.min),
        onPressed: _busy ? null : _submit,
        child: _busy ? const CupertinoActivityIndicator() : Text(action),
      ),
      children: [
        Text(intro, style: AppType.subhead.copyWith(color: c.textMuted)),
        const SizedBox(height: Gap.m),
        if (_page == _Page.hashtag) ...[
          _field(const Key('form-name'), _name, 'hamradio', autofocus: true, prefix: '#'),
          const SizedBox(height: Gap.s),
          _hashtagPreview(context),
        ],
        if (_page == _Page.create) _field(const Key('form-name'), _name, 'Channel name', autofocus: true, autocorrect: true),
        if (_page == _Page.paste) ...[
          if (!_byParts) ...[
            _field(const Key('form-link'), _link, 'meshcore://channel/add?name=...', autofocus: true, maxLines: 3),
            Align(
              alignment: Alignment.centerLeft,
              child: CupertinoButton(
                key: const Key('form-clipboard'),
                padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                minimumSize: const Size(Hit.min, Hit.min),
                onPressed: _pasteFromClipboard,
                child: const Text('Paste from clipboard'),
              ),
            ),
          ] else ...[
            _field(const Key('form-name'), _name, 'Channel name'),
            const SizedBox(height: Gap.s),
            _field(const Key('form-secret'), _secret, 'Secret (32 letters and numbers)'),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoButton(
              key: const Key('form-toggle'),
              padding: const EdgeInsets.symmetric(horizontal: Gap.s),
              minimumSize: const Size(Hit.min, Hit.min),
              onPressed: () => setState(() {
                _byParts = !_byParts;
                _error = null;
              }),
              child: Text(_byParts ? 'I have a link instead' : 'I have a name and a secret instead'),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: Gap.s),
          Text(_error!, key: const Key('form-error'), style: AppType.subhead.copyWith(color: c.danger)),
        ],
        const SizedBox(height: Gap.l),
      ],
    );
  }

  // ------------------------------------------------------------------ created

  Widget _createdPage(BuildContext context) {
    final c = AppColors.of(context);
    final j = _created!;
    final link = _createdLink;
    return AppSheetScaffold(
      key: const Key('channel-created'),
      controller: widget.scroll,
      primaryAction: CupertinoButton.filled(
        key: const Key('created-done'),
        minimumSize: const Size(Hit.min, Hit.min),
        onPressed: () => Navigator.pop(context, _Joined(j)),
        child: const Text('Done'),
      ),
      children: [
        Text('${j.channel.name} is on your radio. Give the QR code or link to the people who should read it.', style: AppType.subhead.copyWith(color: c.textMuted)),
        const SizedBox(height: Gap.m),
        if (link == null)
          Text('The secret of this channel is not on this phone, so it cannot be shared.', style: AppType.subhead)
        else ...[
          Center(child: QrView(key: const Key('share-qr'), data: link, size: 220)),
          const SizedBox(height: Gap.s),
          Text('Anyone who scans this code or opens the link can read and write in this channel. Share it only with people you trust.',
              style: AppType.footnote.copyWith(color: c.textMuted), textAlign: TextAlign.center),
          const SizedBox(height: Gap.m),
          SelectableText(link, key: const Key('share-link'), style: AppType.mono.copyWith(color: c.textPrimary)),
          Wrap(children: [
            CupertinoButton(
              key: const Key('copy-link'),
              padding: const EdgeInsets.symmetric(horizontal: Gap.s),
              minimumSize: const Size(Hit.min, Hit.min),
              onPressed: () => _copy(link, 'Link'),
              child: const Text('Copy link'),
            ),
            if (_createdSecret != null)
              CupertinoButton(
                key: const Key('show-secret'),
                padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                minimumSize: const Size(Hit.min, Hit.min),
                onPressed: () => setState(() => _showSecret = !_showSecret),
                child: Text(_showSecret ? 'Hide secret' : 'Show secret'),
              ),
          ]),
          if (_showSecret && _createdSecret != null) ...[
            SelectableText(_createdSecret!, key: const Key('secret-hex'), style: AppType.mono.copyWith(color: c.textPrimary)),
            CupertinoButton(
              key: const Key('copy-secret'),
              padding: const EdgeInsets.symmetric(horizontal: Gap.s),
              minimumSize: const Size(Hit.min, Hit.min),
              onPressed: () => _copy(_createdSecret!, 'Secret'),
              child: const Text('Copy secret'),
            ),
          ],
        ],
        const SizedBox(height: Gap.l),
      ],
    );
  }
}

class _RecentPerson extends StatelessWidget {
  final Contact contact;
  final VoidCallback onTap;
  const _RecentPerson({required this.contact, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      button: true,
      label: 'Message ${contact.displayName}',
      excludeSemantics: true,
      child: GestureDetector(
        key: Key('new-recent-${contact.prefix}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 72,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: Gap.xs),
              ContactAvatar(contact, size: 52),
              const SizedBox(height: Gap.xs),
              Text(contact.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.caption.copyWith(color: c.textPrimary), textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Cmd-K quick switcher (iPad): type to filter every conversation, Return opens the first match.
Future<void> showQuickSwitcher(BuildContext context, ChatController controller, ChatNavigator navigator) async {
  final r = await showAppSheet<ConversationRow>(
    context,
    detents: const [0.6, 0.92],
    builder: (ctx, scroll) => _QuickSwitcher(controller: controller, scroll: scroll),
  );
  if (r == null || !context.mounted) return;
  navigator.openRow(context, r);
}

class _QuickSwitcher extends StatefulWidget {
  final ChatController controller;
  final ScrollController scroll;
  const _QuickSwitcher({required this.controller, required this.scroll});
  @override
  State<_QuickSwitcher> createState() => _QuickSwitcherState();
}

class _QuickSwitcherState extends State<_QuickSwitcher> {
  final _q = TextEditingController();
  late final List<ConversationRow> _all = widget.controller.conversationRows();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  List<ConversationRow> get _hits {
    final s = _q.text.trim().toLowerCase();
    if (s.isEmpty) return _all;
    bool m(ConversationRow r) => r.title.toLowerCase().contains(s) || (r.contactKey?.startsWith(s) ?? false);
    final hits = _all.where(m).toList();
    // Titles that start with the text first.
    hits.sort((a, b) {
      final pa = a.title.toLowerCase().startsWith(s), pb = b.title.toLowerCase().startsWith(s);
      return pa == pb ? 0 : (pa ? -1 : 1);
    });
    return hits;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final hits = _hits;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.xs, Layout.screenMargin, Gap.s),
          child: CupertinoSearchTextField(
            key: const Key('switcher-field'),
            controller: _q,
            autofocus: true,
            placeholder: 'Go to a conversation',
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (hits.isNotEmpty) Navigator.pop(context, hits.first);
            },
          ),
        ),
        Expanded(
          child: hits.isEmpty
              ? Center(child: Text('No conversation matches.', key: const Key('switcher-empty'), style: AppType.subhead.copyWith(color: c.textMuted)))
              : ListView.builder(
                  controller: widget.scroll,
                  itemCount: hits.length,
                  itemBuilder: (_, i) {
                    final r = hits[i];
                    return CupertinoListTile(
                      key: Key('switcher-${r.key}'),
                      leading: ConversationAvatarMini(row: r),
                      title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: r.preview.isEmpty ? null : Text(r.preview, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, r),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// A small avatar for the switcher rows (the shared [ConversationAvatar] at 36 pt).
class ConversationAvatarMini extends StatelessWidget {
  final ConversationRow row;
  const ConversationAvatarMini({super.key, required this.row});
  @override
  Widget build(BuildContext context) => ConversationAvatar(row: row, size: 36);
}
