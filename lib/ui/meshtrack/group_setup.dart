// MeshTrack group setup (plan 5.2, 5.3, 5.5, 7 "Setup"): New group (one name field, then the Invite screen), Join (scan
// the QR or paste the link), Use a private channel you already have, the Invite screen (big QR, Share link, Done) and
// Make room (the channels on the radio, where the person removes one when the radio is full). No other questions.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../chat/channel_admin.dart';
import '../../chat/mesh_links.dart';
import '../../chat/models.dart' show Channel, ChannelKind;
import '../chat/channel_detail_screen.dart';
import '../chat/channel_flows.dart' show ChatUiHooks;
import '../chat/qr_widgets.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../radio/inset_list.dart';
import 'meshtrack_binding.dart';
import 'meshtrack_copy.dart';

/// Test seams: the share sheet and the clipboard (null = the real platform).
abstract final class MtSetupSeams {
  static Future<void> Function(String text)? shareText;
  static Future<String?> Function()? paste;
  static void reset() {
    shareText = null;
    paste = null;
  }
}

Future<void> _share(String link, String name) =>
    MtSetupSeams.shareText?.call(link) ??
    SharePlus.instance.share(ShareParams(text: 'Join my MeshTrack group "$name" in MeshSonar or the MeshCore app: $link', subject: name)).then((_) {});

Future<String?> _paste() async => MtSetupSeams.paste != null ? MtSetupSeams.paste!() : (await Clipboard.getData(Clipboard.kTextPlain))?.text;

Route<T> _page<T>(Widget w) => MaterialPageRoute<T>(builder: (_) => w);

Future<void> openNewGroup(BuildContext context) => Navigator.of(context, rootNavigator: true).push(_page(const NewGroupScreen()));
Future<void> openJoinGroup(BuildContext context) => Navigator.of(context, rootNavigator: true).push(_page(const JoinGroupScreen()));
Future<void> openUseExisting(BuildContext context) => Navigator.of(context, rootNavigator: true).push(_page(const UseExistingScreen()));
Future<void> openInvite(BuildContext context, int channelId, String name, {bool fresh = false}) =>
    Navigator.of(context, rootNavigator: true).push(_page(InviteScreen(channelId: channelId, name: name, fresh: fresh)));
Future<void> openMakeRoom(BuildContext context) => Navigator.of(context, rootNavigator: true).push(_page(const MakeRoomScreen()));

/// The bar and background every setup page shares.
class _SetupPage extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Key? listKey;
  const _SetupPage({required this.title, required this.children, this.listKey});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      appBar: CupertinoNavigationBar(backgroundColor: c.bg, border: null, middle: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(key: listKey, padding: const EdgeInsets.fromLTRB(0, Gap.m, 0, Gap.xl), children: children),
          ),
        ),
      ),
    );
  }
}

/// A full-width primary button with a busy state.
class _Primary extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  const _Primary({super.key, required this.label, required this.onPressed, this.busy = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
        child: SizedBox(
          width: double.infinity,
          child: CupertinoButton.filled(
            minimumSize: const Size.square(kMtHit),
            onPressed: busy ? null : onPressed,
            child: busy ? const CupertinoActivityIndicator(color: Colors.white) : Text(label, textAlign: TextAlign.center),
          ),
        ),
      );
}

/// The plain sentence a failed operation shows, plus Make room when the radio is full.
class _OpError extends StatelessWidget {
  final MtGroupOpResult result;
  const _OpError(this.result);

  static String text(MtGroupOpResult r) =>
      r.message ??
      switch (r.status) {
        MtGroupOpStatus.radioFull => mtNotOnRadio,
        MtGroupOpStatus.notConnected => 'Connect your radio first. A group lives on your radio, like any channel.',
        MtGroupOpStatus.invalidLink => 'That is not a group link. Ask your friend to share the group again.',
        MtGroupOpStatus.notEligible => 'That is an open channel. A group needs a private channel, so only people with the link can read it.',
        MtGroupOpStatus.nameInvalid => 'That name does not work for a channel. Keep it short, letters and numbers.',
        MtGroupOpStatus.failed || MtGroupOpStatus.ok => 'Something went wrong. Nothing was changed. Try again.',
      };

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.m, Layout.screenMargin, 0),
      child: Semantics(
        liveRegion: true,
        child: Container(
          key: const Key('mt-op-error'),
          padding: const EdgeInsets.all(Gap.m),
          decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.card)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppSymbolIcon(AppSymbols.exclamationTriangle, size: 20, color: c.warning),
              const SizedBox(width: Gap.s),
              Expanded(child: Text(text(result), style: AppType.subhead.copyWith(color: c.textPrimary))),
            ]),
            if (result.status == MtGroupOpStatus.radioFull) ...[
              const SizedBox(height: Gap.s),
              CupertinoButton(
                key: const Key('mt-make-room'),
                minimumSize: const Size.square(kMtHit),
                padding: EdgeInsets.zero,
                onPressed: () => openMakeRoom(context),
                child: const Text(mtMakeRoom),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ New group

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});
  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  TextEditingController? _name;
  String? _fieldError;
  MtGroupOpResult? _error;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _name ??= TextEditingController(text: mtDefaultGroupName(MeshTrackUi.read(context)?.selfName()));
  }

  @override
  void dispose() {
    _name?.dispose();
    super.dispose();
  }

  /// Same rules as any private channel, and no leading # (that would make an open channel).
  static String? validate(String raw) {
    final n = raw.trim();
    if (n.startsWith('#')) return 'A group name cannot start with #. That would make an open channel anyone can read.';
    try {
      ChannelAdmin.checkPrivateName(n);
    } on ChannelAdminException catch (e) {
      return e.message;
    }
    return null;
  }

  Future<void> _create() async {
    final b = MeshTrackUi.read(context);
    if (b == null) return;
    final name = _name!.text.trim();
    final bad = validate(name);
    setState(() {
      _fieldError = bad;
      _error = null;
    });
    if (bad != null) return;
    setState(() => _busy = true);
    final r = await b.ops.createGroup(name);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!r.ok || r.channelId == null) {
      setState(() => _error = r);
      return;
    }
    await Navigator.of(context).pushReplacement(_page(InviteScreen(channelId: r.channelId!, name: name)));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return _SetupPage(
      title: 'New group',
      listKey: const Key('mt-new-group'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          child: Text('Name your group. Friends see this name when they join.', style: AppType.subhead.copyWith(color: c.textMuted)),
        ),
        const SizedBox(height: Gap.m),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          child: Semantics(
            label: 'Group name',
            textField: true,
            child: CupertinoTextField(
              key: const Key('mt-group-name'),
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              placeholder: 'Group name',
              padding: const EdgeInsets.all(Gap.m),
              style: AppType.body.copyWith(color: c.textPrimary),
              decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.chip)),
              onChanged: (_) {
                if (_fieldError != null) setState(() => _fieldError = null);
              },
              onSubmitted: (_) => _create(),
            ),
          ),
        ),
        if (_fieldError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, 0),
            child: Semantics(liveRegion: true, child: Text(_fieldError!, key: const Key('mt-name-error'), style: AppType.footnote.copyWith(color: c.danger))),
          ),
        if (_error != null) _OpError(_error!),
        const SizedBox(height: Gap.l),
        _Primary(key: const Key('mt-create'), label: 'Create', busy: _busy, onPressed: _create),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ Invite

class InviteScreen extends StatelessWidget {
  final int channelId;
  final String name;

  /// Shown after Start fresh: says why the people have to join again.
  final bool fresh;
  const InviteScreen({super.key, required this.channelId, required this.name, this.fresh = false});

  @override
  Widget build(BuildContext context) {
    final b = MeshTrackUi.of(context);
    final c = AppColors.of(context);
    String? link;
    try {
      link = b?.ops.inviteLink(channelId);
    } catch (_) {
      link = null;
    }
    final side = (MediaQuery.sizeOf(context).shortestSide - 2 * Layout.screenMargin).clamp(200.0, 320.0);
    return _SetupPage(
      title: 'Invite friends',
      listKey: const Key('mt-invite'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          child: Text(name, key: const Key('mt-invite-name'), textAlign: TextAlign.center, style: AppType.title2.copyWith(color: c.textPrimary)),
        ),
        const SizedBox(height: Gap.xs),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          child: Text(
            fresh
                ? 'This is a new group link. The old one stops working for MeshTrack, so invite the people you want again.'
                : 'Friends scan this code in MeshSonar or the MeshCore app, or open the link you send them.',
            textAlign: TextAlign.center,
            style: AppType.subhead.copyWith(color: c.textMuted),
          ),
        ),
        const SizedBox(height: Gap.l),
        if (link == null || link.isEmpty)
          const SizedBox(
            height: 240,
            child: AppErrorView(title: 'No invite for this group', message: 'Its key is not on this phone, so it cannot be shared.'),
          )
        else ...[
          Center(
            child: QrView(
              key: const Key('mt-invite-qr'),
              data: link,
              size: side,
              semanticLabel: 'QR code for the group $name. Friends scan it with MeshSonar or the MeshCore app to join.',
            ),
          ),
          const SizedBox(height: Gap.l),
          _Primary(key: const Key('mt-share-link'), label: 'Share link', onPressed: () => unawaited(_share(link!, name))),
        ],
        const SizedBox(height: Gap.s),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          child: SizedBox(
            width: double.infinity,
            child: CupertinoButton(
              key: const Key('mt-invite-done'),
              minimumSize: const Size.square(kMtHit),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
        ),
        const SizedBox(height: Gap.m),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          child: Text(mtRosterFooter, textAlign: TextAlign.center, style: AppType.footnote.copyWith(color: c.textMuted)),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ Join

class JoinGroupScreen extends StatefulWidget {
  const JoinGroupScreen({super.key});
  @override
  State<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends State<JoinGroupScreen> {
  final _link = TextEditingController();
  MtGroupOpResult? _error;
  bool _busy = false;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final read = await ChatUiHooks.scanQr(context);
    if (read == null || !mounted) return;
    _link.text = read;
    await _join(read);
  }

  Future<void> _pasteLink() async {
    final t = await _paste();
    if (t == null || !mounted) return;
    setState(() => _link.text = t.trim());
  }

  Future<void> _join(String raw) async {
    final b = MeshTrackUi.read(context);
    if (b == null) return;
    final link = raw.trim();
    if (link.isEmpty) {
      setState(() => _error = const MtGroupOpResult(MtGroupOpStatus.invalidLink, message: 'Scan the group\'s QR code or paste its link first.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await b.ops.joinFromLink(link);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!r.ok) {
      setState(() => _error = r);
      return;
    }
    final parsed = MeshLinks.parse(link);
    final id = r.channelId;
    final name = (id == null ? null : b.service.state.group(id)?.name) ?? (parsed is ChannelLink ? parsed.name : 'the group');
    showAppToast(context, mtJoinedBanner(name), kind: AppToastKind.success);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return _SetupPage(
      title: 'Join a group',
      listKey: const Key('mt-join'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          child: Text('Scan the QR code on your friend\'s phone, or paste the link they sent you.', style: AppType.subhead.copyWith(color: c.textMuted)),
        ),
        const SizedBox(height: Gap.l),
        _Primary(key: const Key('mt-scan'), label: 'Scan QR code', onPressed: _busy ? null : _scan),
        const SizedBox(height: Gap.l),
        InsetGroup(
          header: 'Or paste the link',
          rows: [
            Padding(
              padding: const EdgeInsets.all(Gap.s),
              child: Semantics(
                label: 'Group link',
                textField: true,
                child: CupertinoTextField(
                  key: const Key('mt-join-link'),
                  controller: _link,
                  autocorrect: false,
                  placeholder: 'meshcore://channel/add?…',
                  padding: const EdgeInsets.all(Gap.m),
                  style: AppType.body.copyWith(color: c.textPrimary),
                  decoration: const BoxDecoration(),
                  maxLines: 3,
                  minLines: 1,
                ),
              ),
            ),
            InsetRow(key: const Key('mt-paste'), title: 'Paste from clipboard', chevron: false, onTap: _busy ? null : _pasteLink),
          ],
        ),
        if (_error != null) _OpError(_error!),
        const SizedBox(height: Gap.m),
        _Primary(key: const Key('mt-join-go'), label: 'Join', busy: _busy, onPressed: () => _join(_link.text)),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ Use an existing channel

class UseExistingScreen extends StatefulWidget {
  const UseExistingScreen({super.key});
  @override
  State<UseExistingScreen> createState() => _UseExistingScreenState();
}

class _UseExistingScreenState extends State<UseExistingScreen> {
  MtGroupOpResult? _error;
  int? _busy;

  Future<void> _use(MeshTrackBinding b, Channel ch) async {
    setState(() {
      _busy = ch.id;
      _error = null;
    });
    final r = await b.ops.useExistingChannel(ch.id!);
    if (!mounted) return;
    setState(() => _busy = null);
    if (!r.ok) {
      setState(() => _error = r);
      return;
    }
    showAppToast(context, '${ch.name} is now a MeshTrack group.', kind: AppToastKind.success);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final b = MeshTrackUi.of(context);
    final c = AppColors.of(context);
    final list = b == null ? const <Channel>[] : b.ops.eligibleChannels().where((ch) => ch.id != null && !b.ops.isGroup(ch.id!)).toList();
    return _SetupPage(
      title: 'Use a private channel',
      listKey: const Key('mt-use-existing'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          child: Text('Already share a private channel with these people? Use it for MeshTrack. The chat in it stays as it is.',
              style: AppType.subhead.copyWith(color: c.textMuted)),
        ),
        const SizedBox(height: Gap.l),
        if (list.isEmpty)
          const SizedBox(
            height: 260,
            child: AppEmptyView(
              symbol: AppSymbols.lock,
              title: 'No private channels to use',
              message: 'Only private channels can be groups. Open and # channels can be read by anyone, so they are not offered.',
            ),
          )
        else
          InsetGroup(rows: [
            for (final ch in list)
              InsetRow(
                key: Key('mt-use-${ch.id}'),
                title: ch.name,
                subtitle: 'Private channel',
                trailing: _busy == ch.id ? const CupertinoActivityIndicator() : null,
                onTap: _busy != null ? null : () => _use(b!, ch),
              ),
          ]),
        if (_error != null) _OpError(_error!),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ Make room

/// The channels on the radio. Tapping one opens its page, where Delete channel frees the room a group needs.
class MakeRoomScreen extends StatelessWidget {
  const MakeRoomScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final b = MeshTrackUi.of(context);
    final chat = b?.chat();
    final c = AppColors.of(context);
    final radio = chat?.radioId;
    final list = chat == null || radio == null
        ? const <Channel>[]
        : chat.store.channels.list(radio, includeSystem: false).where((ch) => ch.slot != null && ch.kind != ChannelKind.public).toList();
    return _SetupPage(
      title: mtMakeRoom,
      listKey: const Key('mt-make-room-screen'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          child: Text('Your radio holds a fixed number of channels and it is full. Open one you no longer need and delete it, then come back.',
              style: AppType.subhead.copyWith(color: c.textMuted)),
        ),
        const SizedBox(height: Gap.l),
        if (chat == null)
          const SizedBox(height: 240, child: AppEmptyView(symbol: AppSymbols.antenna, title: 'Radio not connected', message: 'Connect your radio to see its channels.'))
        else if (list.isEmpty)
          const SizedBox(height: 240, child: AppEmptyView(symbol: AppSymbols.numberSign, title: 'No channels to remove', message: 'Only Public is on this radio.'))
        else
          InsetGroup(header: 'On your radio', rows: [
            for (final ch in list)
              InsetRow(
                key: Key('mt-room-${ch.id}'),
                title: ch.name,
                subtitle: b!.ops.isGroup(ch.id!) ? 'MeshTrack group' : switch (ch.kind) {
                  ChannelKind.hashtag => 'Hashtag channel',
                  _ => 'Private channel',
                },
                onTap: () => ChannelDetailScreen.open(context, controller: chat, channelId: ch.id!),
              ),
          ]),
      ],
    );
  }
}
