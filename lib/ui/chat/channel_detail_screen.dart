// Channel info: share (QR, link, copy), notifications, pin, region, rename, put back on the radio, clear history, delete.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/chat_controller.dart';
import '../../chat/channel_admin.dart';
import '../../chat/models.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/app_widgets.dart' show AppSwitchTile;
import '../design/avatar_style.dart';
import '../design/tokens.dart';
import '../radio/inset_list.dart';
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
  bool _details = false;

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
      await showAppAlert(
        context,
        title: 'Could not do that',
        message: e.message,
        confirmLabel: 'OK',
        cancelLabel: 'Close',
        dialogKey: const Key('channel-error-dialog'),
      );
    }
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showAppToast(context, '$what copied', kind: AppToastKind.success);
  }

  /// A small form sheet: [fields] above a Save button; returns [value] on Save, null on dismiss.
  Future<String?> _textSheet({required String title, required Key saveKey, required List<Widget> fields, required String Function() value}) {
    return showAppSheet<String>(
      context,
      detents: const [0.5, 0.92],
      builder: (ctx, controller) => AppSheetScaffold(
        controller: controller,
        title: title,
        primaryAction: CupertinoButton.filled(key: saveKey, onPressed: () => Navigator.pop(ctx, value()), child: const Text('Save')),
        secondaryAction: CupertinoButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        children: fields,
      ),
    );
  }

  Future<void> _rename(Channel ch) async {
    final ctl = TextEditingController(text: ch.name);
    final name = await _textSheet(
      title: 'Rename channel',
      saveKey: const Key('rename-save'),
      fields: [CupertinoTextField(key: const Key('rename-field'), controller: ctl, autofocus: true, placeholder: 'Channel name')],
      value: () => ctl.text,
    );
    if (name == null) return;
    await _guard(() async {
      await c.admin.edit(ch, name: name);
      await _loadKey();
    });
  }

  Future<void> _editRegion(Channel ch) async {
    final ctl = TextEditingController(text: ch.regionScope ?? '');
    final res = await _textSheet(
      title: 'Region',
      saveKey: const Key('region-save'),
      fields: [
        const Text(_regionHelp),
        const SizedBox(height: Gap.m),
        CupertinoTextField(key: const Key('region-field'), controller: ctl, autofocus: true, autocorrect: false, placeholder: 'Region name. Leave empty for the whole mesh'),
      ],
      value: () => ctl.text,
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
    final ok = await showAppAlert(
      context,
      title: 'Delete ${ch.name}?',
      message: ch.slot == null
          ? 'The channel and its messages are removed from this phone.'
          : 'The channel is removed from your radio and its messages from this phone. You can join it again later with its link, if you still have it.',
      confirmLabel: 'Delete',
      cancelLabel: 'Keep',
      destructive: true,
      dialogKey: const Key('delete-channel-dialog'),
      confirmKey: const Key('delete-channel-confirm'),
    );
    if (ok != true) return;
    await _guard(() async {
      await c.admin.delete(ch);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst || r.settings.name == '/');
    });
  }

  Future<void> _clearHistory(Channel ch) async {
    final ok = await showAppAlert(
      context,
      title: 'Clear the messages?',
      message: 'The messages of this channel are removed from this phone. The channel stays.',
      confirmLabel: 'Clear',
      cancelLabel: 'Keep',
      destructive: true,
      confirmKey: const Key('clear-history-confirm'),
    );
    if (ok == true) {
      c.service.deleteHistory(ch.convKey);
      c.refresh();
    }
  }

  static const String _regionHelp =
      'A region limits how far your messages are repeated: only repeaters set up for that region pass them on. '
      'Leave it empty to use the whole mesh, which is what most channels do. Only set it if the people who run your local network tell you to, and use the name exactly as they write it.';

  /// Messages heard in this channel since local midnight.
  int _heardToday(Channel ch) {
    final now = c.now();
    final midnight = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    var n = 0;
    for (final m in c.store.messages.page(ch.convKey, limit: 300).messages) {
      if (m.tsLocalMs < midnight) break;
      if (!m.isOutgoing) n++;
    }
    return n;
  }

  Future<void> _muteFor(Channel ch) async {
    final d = await showAppActionSheet<Duration?>(
      context,
      title: 'Mute ${ch.name}',
      sheetKey: const Key('mute-for-sheet'),
      actions: const [
        AppAction('For 1 hour', Duration(hours: 1), key: Key('mute-1h')),
        AppAction('For 8 hours', Duration(hours: 8), key: Key('mute-8h')),
        AppAction('For 24 hours', Duration(hours: 24), key: Key('mute-24h')),
        AppAction('Until I turn it back on', Duration.zero, key: Key('mute-forever')),
      ],
    );
    if (d == null) return;
    c.service.setNotifyMode(ch.radioId, ch.convKey, NotifyMode.muted, muteFor: d == Duration.zero ? null : d);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ch = _channel;
    final col = AppColors.of(context);
    if (ch == null) {
      return Scaffold(
        backgroundColor: col.bg,
        appBar: CupertinoNavigationBar(backgroundColor: col.bg, border: null, middle: const Text('Channel')),
        body: Center(child: Text('This channel was deleted.', style: AppType.body.copyWith(color: col.textMuted))),
      );
    }
    final summary = c.service.conversation(ch.convKey);
    final mode = summary?.notifyMode ?? NotifyMode.all;
    final pinned = summary?.pinned ?? false;
    final kindLabel = switch (ch.kind) {
      ChannelKind.public => 'Public channel',
      ChannelKind.hashtag => 'Hashtag channel',
      ChannelKind.private => 'Private channel',
      ChannelKind.system => 'Wardrive channel',
    };
    final heard = _heardToday(ch);
    final style = avatarStyle(ch.convKey, col);
    final letters = ch.name.replaceAll('#', '').trim();
    final initial = letters.isEmpty ? '#' : letters.substring(0, 1).toUpperCase();
    final regionSub = ch.regionScope == null ? 'None: the whole mesh' : ch.regionScope!;
    return Scaffold(
      backgroundColor: col.bg,
      appBar: CupertinoNavigationBar(backgroundColor: col.bg, border: null, middle: Text(ch.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              key: const Key('channel-detail'),
              padding: const EdgeInsets.only(top: Gap.s, bottom: Gap.xl),
              children: [
                Semantics(
                  container: true,
                  header: true,
                  label: '${ch.name}, $kindLabel, heard $heard ${heard == 1 ? 'time' : 'times'} today',
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.m),
                      child: Column(children: [
                        Container(
                          width: 72,
                          height: 72,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: style.fill, borderRadius: BorderRadius.circular(72 * 0.28)),
                          child: Text(initial, textScaler: TextScaler.noScaling, style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w600)),
                        ),
                        const SizedBox(height: Gap.s),
                        Text(ch.name, key: const Key('channel-title'), textAlign: TextAlign.center, style: AppType.title2.copyWith(color: col.textPrimary)),
                        Text(kindLabel, style: AppType.subhead.copyWith(color: col.textMuted)),
                        Text('Heard $heard ${heard == 1 ? 'time' : 'times'} today', key: const Key('channel-heard'), style: AppType.footnote.copyWith(color: col.textMuted)),
                      ]),
                    ),
                  ),
                ),
                if (ch.slot == null && !ch.isSystem)
                  Container(
                    key: const Key('off-radio-card'),
                    margin: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Layout.sectionGap - 8),
                    padding: const EdgeInsets.all(Gap.m),
                    decoration: BoxDecoration(color: col.surfaceHigh, borderRadius: BorderRadius.circular(Corners.card)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text('Messages cannot arrive or be sent until this channel is back on the radio. Another app may have replaced it.',
                          style: AppType.subhead.copyWith(color: col.textPrimary)),
                      const SizedBox(height: Gap.s),
                      CupertinoButton.filled(
                        key: const Key('put-back'),
                        minimumSize: Size.square(Hit.min),
                        onPressed: () => _putBack(ch),
                        child: const Text('Put it back on the radio'),
                      ),
                    ]),
                  ),
                InsetGroup(
                  header: 'Share',
                  rows: [
                    if (!_loadedKey)
                      const Padding(padding: EdgeInsets.all(Gap.l), child: Center(child: CupertinoActivityIndicator()))
                    else if (_link == null)
                      const Padding(padding: EdgeInsets.all(Gap.l), child: Text('The secret of this channel is not on this phone, so it cannot be shared.'))
                    else
                      Padding(
                        padding: const EdgeInsets.all(Gap.l),
                        child: Column(children: [
                          Center(child: QrView(key: const Key('share-qr'), data: _link!, size: 220)),
                          const SizedBox(height: Gap.s),
                          Text(
                            ch.kind == ChannelKind.private
                                ? 'Anyone who scans this code or opens the link can read and write in this channel. Share it only with people you trust.'
                                : 'This is an open channel: anyone can also join it by typing its name.',
                            style: AppType.footnote.copyWith(color: col.textMuted),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: Gap.s),
                          Text(_link!, key: const Key('share-link'), style: AppType.footnote.copyWith(color: col.textPrimary)),
                          if (_showSecret && _secretHex != null) ...[
                            const SizedBox(height: Gap.s),
                            Text(_secretHex!, key: const Key('secret-hex'), style: AppType.num(15).copyWith(color: col.textPrimary)),
                          ],
                        ]),
                      ),
                    if (_loadedKey && _link != null)
                      InsetRow(key: const Key('copy-link'), title: 'Copy link', chevron: false, onTap: () => _copy(_link!, 'Link')),
                    if (_loadedKey && ch.kind == ChannelKind.private && _secretHex != null) ...[
                      InsetRow(
                        key: const Key('show-secret'),
                        title: _showSecret ? 'Hide secret' : 'Show secret',
                        chevron: false,
                        onTap: () => setState(() => _showSecret = !_showSecret),
                      ),
                      if (_showSecret) InsetRow(key: const Key('copy-secret'), title: 'Copy secret', chevron: false, onTap: () => _copy(_secretHex!, 'Secret')),
                    ],
                  ],
                ),
                if (!ch.isSystem) ...[
                  InsetGroup(
                    header: 'Notifications',
                    footer: switch (mode) {
                      NotifyMode.all => 'Every new message in this channel notifies you.',
                      NotifyMode.mentionsOnly => 'Only messages that mention you notify you.',
                      NotifyMode.muted => 'Nothing notifies you. Messages still arrive and the unread count stays.',
                    },
                    rows: [
                      Padding(
                        padding: const EdgeInsets.all(Gap.m),
                        child: SizedBox(
                          width: double.infinity,
                          child: CupertinoSlidingSegmentedControl<NotifyMode>(
                            key: const Key('notify-mode'),
                            groupValue: mode,
                            children: const {
                              NotifyMode.all: Padding(padding: EdgeInsets.symmetric(vertical: Gap.s), child: Text('All')),
                              NotifyMode.mentionsOnly: Padding(padding: EdgeInsets.symmetric(vertical: Gap.s), child: Text('Mentions')),
                              NotifyMode.muted: Padding(padding: EdgeInsets.symmetric(vertical: Gap.s), child: Text('Muted')),
                            },
                            onValueChanged: (v) {
                              if (v == null) return;
                              AppHaptics.selection();
                              c.service.setNotifyMode(ch.radioId, ch.convKey, v);
                            },
                          ),
                        ),
                      ),
                      InsetRow(key: const Key('mute-for'), title: 'Mute for a while', onTap: () => _muteFor(ch)),
                    ],
                  ),
                  InsetGroup(rows: [
                    AppSwitchTile(
                      switchKey: const Key('pin-switch'),
                      symbol: AppSymbols.pin,
                      title: 'Pin to the top',
                      value: pinned,
                      onChanged: (v) => c.service.setPinned(ch.radioId, ch.convKey, v),
                    ),
                  ]),
                  InsetGroup(
                    header: 'Region',
                    footer: 'Limits how far your messages are repeated. Most channels leave it empty.',
                    rows: [
                      InsetRow(key: const Key('region-row'), title: 'Region', value: regionSub, onTap: () => _editRegion(ch)),
                    ],
                  ),
                  InsetGroup(
                    header: 'Name',
                    footer: ch.kind == ChannelKind.hashtag ? 'The name is the key. A hashtag channel cannot be renamed.' : null,
                    rows: [
                      if (ch.kind == ChannelKind.private)
                        InsetRow(key: const Key('rename-row'), title: 'Rename', value: ch.name, onTap: () => _rename(ch))
                      else
                        InsetRow(key: const Key('rename-locked'), title: 'Rename', value: ch.kind == ChannelKind.hashtag ? 'The name is the key' : 'Fixed', chevron: false),
                    ],
                  ),
                ],
                InsetGroup(rows: [
                  if (!ch.isSystem) InsetRow(key: const Key('clear-history'), title: 'Clear messages on this phone', chevron: false, onTap: () => _clearHistory(ch)),
                  if (!ch.isSystem) InsetRow(key: const Key('delete-channel'), title: 'Delete channel', destructive: true, chevron: false, onTap: () => _delete(ch)),
                  InsetRow(
                    key: const Key('channel-details'),
                    title: 'Details',
                    value: _details ? 'Hide' : null,
                    onTap: () => setState(() => _details = !_details),
                  ),
                  if (_details)
                    InsetRow(
                      key: const Key('details-slot'),
                      title: 'On your radio',
                      value: ch.slot == null ? 'Not on your radio right now' : 'Slot ${ch.slot}',
                      chevron: false,
                    ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
