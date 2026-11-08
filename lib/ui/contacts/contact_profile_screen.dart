// Contact profile (chat plan 4.6; replaces contact_detail_screen.dart): who it is, how messages reach them, and the quick
// actions for that kind of contact. Inset-grouped cards, share and Edit in the nav bar, everything that changes the
// contact (name, notes, favourite, keep on radio, block, remove) in the Edit sheet. Reactive: a route learned, a favourite
// toggled or a contact removed shows at once.
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoButton, CupertinoNavigationBar;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../chat/contact_manager.dart';
import '../../chat/contact_port.dart';
import '../../chat/models.dart';
import '../../radio/caps.dart';
import '../claims/claim_widgets.dart' show ClaimRepeaterAction;
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/app_widgets.dart';
import '../design/tokens.dart';
import '../shell/shell_controller.dart';
import '../tools/ping_result_sheet.dart';
import 'contact_edit_sheet.dart';
import 'contact_map.dart';
import 'contact_widgets.dart';
import 'contacts_controller.dart';
import 'path_manager_screen.dart';
import 'profile_sheets.dart';
import 'profile_tiles.dart';
import 'radio_caps_of.dart';
import 'profile_widgets.dart';
import 'user_stats_sheet.dart';

typedef ShareText = Future<void> Function(String text, {String? subject});
typedef ShareFile = Future<void> Function(String fileName, String text);
typedef ClaimBuilder = Widget Function(BuildContext context, Contact contact);

Future<void> _defaultShare(String text, {String? subject}) async {
  await SharePlus.instance.share(ShareParams(text: text, subject: subject));
}

Future<void> _defaultShareFile(String fileName, String text) async {
  final dir = await Directory.systemTemp.createTemp('meshsonar_contact');
  final f = File('${dir.path}${Platform.pathSeparator}$fileName');
  await f.writeAsString(text);
  await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
}

Widget _defaultClaim(BuildContext context, Contact c) =>
    ClaimRepeaterAction(keyHex: c.publicKey, name: c.displayName, isRoom: c.type == ContactType.room);

class ContactProfileScreen extends StatefulWidget {
  final ContactsController controller;
  final String publicKey;

  /// Test and offline seams: the mini map, the share sheets and the claim button.
  final ContactMapBuilder mapBuilder;
  final ShareText shareText;
  final ShareFile shareFile;
  final ClaimBuilder claimBuilder;

  /// The radio's firmware capabilities (null = baseline). The real app wires this when WP7 exposes it on the session.
  final RadioCaps Function()? radioCaps;

  const ContactProfileScreen({
    super.key,
    required this.controller,
    required this.publicKey,
    this.mapBuilder = defaultContactMap,
    this.shareText = _defaultShare,
    this.shareFile = _defaultShareFile,
    this.claimBuilder = _defaultClaim,
    this.radioCaps,
  });

  @override
  State<ContactProfileScreen> createState() => _ContactProfileScreenState();
}

class _ContactProfileScreenState extends State<ContactProfileScreen> {
  bool _popped = false;

  ContactsController get _c => widget.controller;
  ContactManager get _m => _c.manager;

  void _say(String msg, {AppToastKind kind = AppToastKind.info}) {
    if (!mounted) return;
    showAppToast(context, msg, kind: kind);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final c = _c.contact(widget.publicKey);
        if (c == null) return _gone(context);
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
    final col = AppColors.of(context);
    return Scaffold(
      backgroundColor: col.bg,
      appBar: CupertinoNavigationBar(backgroundColor: col.bg, border: null),
      body: Center(
        key: const Key('contact-gone'),
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Text('This contact was removed.', textAlign: TextAlign.center, style: AppType.body.copyWith(color: col.textMuted)),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ build

  Widget _body(BuildContext context, Contact c) {
    final col = AppColors.of(context);
    final now = _c.nowMs();
    final connected = _m.connected;
    // Rooms need a login before the server takes a post; until it exists there is no button to a conversation that cannot work.
    final canMessage = _c.openConversation != null && (c.type == ContactType.companion || (c.type == ContactType.room && _c.canOpenRooms));
    final canAdmin = _c.openAdmin != null && (c.type == ContactType.repeater || c.type == ContactType.room);
    final tiles = profileTiles(c,
        connected: connected,
        caps: widget.radioCaps?.call() ?? radioCapsOf(context),
        canMessage: canMessage,
        canAdmin: canAdmin);
    final disabled = [for (final t in tiles) if (!t.enabled && t.reason != null) t.reason!];
    final conv = c.type == ContactType.room ? ConvKey.room(c.prefix) : ConvKey.dm(c.prefix);
    final summary = _c.conversationOf(c);
    final muted = summary?.isMutedAt(now) ?? false;
    final loose = !c.onRadio;
    final delivery = c.type == ContactType.companion ? _lastDelivery(conv, now) : null;
    final adv = c.lastAdvertTs;

    return Scaffold(
      backgroundColor: col.bg,
      appBar: CupertinoNavigationBar(
        backgroundColor: col.bg,
        border: null,
        transitionBetweenRoutes: false,
        automaticallyImplyLeading: false,
        leading: Semantics(
          button: true,
          label: 'Back',
          excludeSemantics: true,
          child: CupertinoButton(
            key: const Key('contact-back'),
            minimumSize: const Size(Hit.minAndroid, Hit.minAndroid),
            padding: const EdgeInsets.only(left: Gap.xs),
            onPressed: () => Navigator.of(context).maybePop(),
            child: AppSymbolIcon(AppSymbols.chevronLeft, size: 22, color: col.accent),
          ),
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Semantics(
            button: true,
            label: 'Share contact',
            excludeSemantics: true,
            child: CupertinoButton(
              key: const Key('contact-share-nav'),
              minimumSize: const Size(Hit.minAndroid, Hit.minAndroid),
              padding: EdgeInsets.zero,
              onPressed: () => _share(c),
              child: AppSymbolIcon(AppSymbols.squareAndArrowUp, size: 22, color: col.accent),
            ),
          ),
          CupertinoButton(
            key: const Key('contact-edit'),
            minimumSize: const Size(Hit.minAndroid, Hit.minAndroid),
            padding: const EdgeInsets.only(left: Gap.xs, right: Gap.xs),
            onPressed: () => _edit(c),
            child: Text('Edit', style: AppType.body.copyWith(color: col.accent)),
          ),
        ]),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Layout.sheetMaxWidth + 80),
            child: ListView(
              key: const Key('contact-profile'),
              padding: const EdgeInsets.only(bottom: Gap.xl),
              children: [
                _header(context, c, now),
                ProfileTileGrid(tiles: tiles, onTap: (t) => _tapTile(c, t), onOptions: (t) => _pingOptions(c)),
                if (disabled.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Layout.screenMargin + Gap.xs, 0, Layout.screenMargin, Gap.m),
                    child: Text(disabled.first, key: const Key('tile-reason'), style: AppType.footnote.copyWith(color: col.textMuted)),
                  ),
                if (c.type == ContactType.repeater)
                  Padding(padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.l), child: widget.claimBuilder(context, c)),
                ProfileGroup(rows: [
                  ProfileRow(
                    key: const Key('contact-route-row'),
                    label: 'Route',
                    value: routeCaption(c),
                    chevron: true,
                    onTap: () => _route(c),
                  ),
                  if (delivery != null) ProfileRow(key: const Key('contact-last-delivery'), label: 'Last delivery', value: delivery),
                  ProfileRow(
                    key: const Key('contact-radio-row'),
                    label: 'Radio',
                    value: c.onRadio ? 'On your radio' : 'Saved on your phone only',
                  ),
                  if (loose && (c.favourite || _c.conversationOf(c) != null))
                    ProfileRow(key: const Key('contact-put-on-radio'), label: 'Put on radio now', onTap: () => _putOnRadio(c)),
                ]),
                ProfileGroup(rows: [
                  ProfileRow(
                    key: const Key('contact-key-row'),
                    label: 'Public key',
                    semanticsLabel: 'Public key, ${middleEllipsis(c.publicKey)}. Tap to copy',
                    valueWidget: Text(middleEllipsis(c.publicKey),
                        key: const Key('contact-key'), maxLines: 1, overflow: TextOverflow.fade, softWrap: false, style: monoStyle.copyWith(color: col.textMuted)),
                    onTap: () => _copyKey(c),
                  ),
                  _location(context, c, adv, now),
                  _notesRow(c),
                  if (c.type == ContactType.room && canAdmin)
                    ProfileRow(key: const Key('contact-admin'), label: 'Administer room', chevron: true, onTap: () => _c.openAdmin!(context, c)),
                ]),
                ProfileGroup(rows: [
                  if (c.type == ContactType.companion || c.type == ContactType.room)
                    AppSwitchTile(
                      switchKey: const Key('contact-mute'),
                      title: 'Mute notifications',
                      value: muted,
                      onChanged: (v) => _c.chat.setNotifyMode(c.radioId, conv, v ? NotifyMode.muted : NotifyMode.all),
                    ),
                  ProfileRow(key: const Key('contact-share'), label: 'Share contact', chevron: true, onTap: () => _share(c)),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, Contact c, int now) {
    final col = AppColors.of(context);
    final custom = c.customName != null && c.customName!.trim().isNotEmpty && c.customName != c.name;
    final heard = heardText(c.lastHeardMs ?? (c.lastAdvertTs == null ? null : c.lastAdvertTs! * 1000), now);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, Gap.l),
      child: Column(children: [
        ContactAvatar(c, size: 88),
        const SizedBox(height: Gap.m),
        Semantics(header: true, child: Text(c.displayName, key: const Key('contact-name'), textAlign: TextAlign.center, style: AppType.title2.copyWith(color: col.textPrimary))),
        if (custom) Text('Advertises as ${c.name}', textAlign: TextAlign.center, style: AppType.footnote.copyWith(color: col.textMuted)),
        const SizedBox(height: 2),
        Text('${contactTypeLabel(c.type)} · ${routeCaption(c)}',
            key: const Key('contact-type-route'), textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: col.textMuted)),
        Text(heard, key: const Key('contact-heard'), textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: col.textMuted)),
        if (c.blocked) Text('Blocked', key: const Key('contact-blocked'), style: AppType.subhead.copyWith(color: col.danger)),
      ]),
    );
  }

  Widget _location(BuildContext context, Contact c, int? adv, int now) {
    final col = AppColors.of(context);
    if (!c.hasPosition) {
      return ProfileRow(key: const Key('contact-no-position'), label: 'Location', value: 'Not shared');
    }
    final coords = '${c.lat!.toStringAsFixed(5)}, ${c.lon!.toStringAsFixed(5)}';
    final when = adv == null ? 'when they last announced themselves' : 'when they last announced themselves, ${_ago(now - adv * 1000)}';
    return Semantics(
      button: true,
      label: 'Location on map. Opens the Map tab. Position from $when',
      onTap: () => _openMap(),
      onLongPress: () => _copyCoords(coords),
      child: ExcludeSemantics(
        child: GestureDetector(
          key: const Key('contact-location'),
          behavior: HitTestBehavior.opaque,
          onTap: _openMap,
          onLongPress: () => _copyCoords(coords),
          child: Padding(
            padding: const EdgeInsets.all(Layout.screenMargin),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Location', style: AppType.body.copyWith(color: col.textPrimary)),
              const SizedBox(height: Gap.s),
              IgnorePointer(child: widget.mapBuilder(context, c.lat!, c.lon!)),
              const SizedBox(height: Gap.s),
              Text(coords, key: const Key('contact-coords'), style: monoStyle.copyWith(color: col.textMuted)),
              Text('From $when. Hold to copy.', style: AppType.footnote.copyWith(color: col.textMuted)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _notesRow(Contact c) {
    final col = AppColors.of(context);
    return ProfileRow(
      key: const Key('contact-notes'),
      label: 'Notes',
      semanticsLabel: c.notes.isEmpty ? 'Notes, none. Add them in Edit' : 'Notes, ${c.notes}',
      valueWidget: Text(c.notes.isEmpty ? 'None' : c.notes,
          textAlign: TextAlign.end, maxLines: 4, overflow: TextOverflow.ellipsis, style: AppType.body.copyWith(color: col.textMuted)),
    );
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

  /// "2 min ago · 1.8 s" for the newest message to them that was acknowledged, else null.
  String? _lastDelivery(String conv, int now) {
    ChatMessage? best;
    for (final m in _c.chat.page(conv, limit: 50).messages) {
      if (m.direction == Direction.outgoing && m.state == MessageState.acked && (best == null || m.tsLocalMs > best.tsLocalMs)) best = m;
    }
    if (best == null) return null;
    final ack = best.ackMs;
    final took = ack == null ? '' : ' · ${ack < 950 ? '$ack ms' : '${(ack / 1000).toStringAsFixed(1)} s'}';
    return '${_ago(now - best.tsLocalMs)}$took';
  }

  // ------------------------------------------------------------------ actions

  Future<void> _tapTile(Contact c, ProfileTile t) async {
    if (!t.enabled) {
      _say(t.reason ?? 'Not available right now.');
      return;
    }
    switch (t.id) {
      case ProfileTileId.message:
      case ProfileTileId.openRoom:
        _c.openConversation!(context, c);
      case ProfileTileId.dashboard:
        _c.openAdmin!(context, c);
      case ProfileTileId.route:
        await _route(c);
      case ProfileTileId.ping:
        await showPingSheet(context, contact: c, manager: _m, onUseRoute: (r) => offerUseRoute(context, _m, c, r));
      case ProfileTileId.stats:
        await showUserStatsSheet(context, contact: c);
      case ProfileTileId.telemetry:
        await showUserStatsSheet(context, contact: c);
    }
  }

  Future<void> _pingOptions(Contact c) =>
      showPingOptions(context, contact: c, manager: _m, onUseRoute: (r) => offerUseRoute(context, _m, c, r));

  Future<void> _route(Contact c) => PathManagerScreen.open(context, manager: _m, publicKey: c.publicKey, changes: _c);

  Future<void> _edit(Contact c) async {
    final r = await showContactEditSheet(context, controller: _c, publicKey: c.publicKey);
    if (r == ContactEditOutcome.removed && mounted) {
      _popped = true;
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    }
  }

  Future<void> _copyKey(Contact c) async {
    AppHaptics.selection();
    await Clipboard.setData(ClipboardData(text: c.publicKey));
    _say('Key copied');
  }

  Future<void> _copyCoords(String coords) async {
    AppHaptics.selection();
    await Clipboard.setData(ClipboardData(text: coords));
    _say('Position copied');
  }

  void _openMap() {
    final shell = ShellScope.maybeOf(context);
    if (shell == null) return;
    shell.select(AppTab.drive);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _share(Contact c) {
    final link = _m.linkFor(c);
    return showContactShareSheet(
      context,
      contact: c,
      link: link,
      connected: _m.connected,
      onCopyLink: () async {
        await Clipboard.setData(ClipboardData(text: link));
        _say('Link copied');
      },
      onCopyKey: () => _copyKey(c),
      onShare: () => widget.shareText(link, subject: 'MeshCore contact ${c.displayName}'),
      onNearby: () => _shareNearby(c),
      onExportFile: () => widget.shareFile('${c.displayName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.meshcore.txt', link),
    );
  }

  Future<void> _shareNearby(Contact c) async {
    try {
      final ok = await _m.shareToNearbyRadios(c.publicKey);
      _say(ok
          ? 'Sent. Only radios within direct range can hear it.'
          : 'Your radio has no stored announcement from this contact, so it cannot send it. Share the link or QR code instead.');
    } on RadioUnavailable {
      _say('The radio is not connected. Connect it and try again.');
    } catch (_) {
      _say('The radio did not answer. Try again in a moment.');
    }
  }

  Future<void> _putOnRadio(Contact c) async {
    try {
      await _m.ensureOnRadio(c.publicKey);
      _say('${c.displayName} is on the radio now.');
    } on ContactTableFull {
      _say('The radio\'s contact list is full and every contact on it is a favourite or in use. Free some room in Contacts first.');
    } on RadioUnavailable {
      _say('The radio is not connected. Connect it and try again.');
    } catch (_) {
      _say('The radio did not take it. Try again in a moment.');
    }
  }
}
