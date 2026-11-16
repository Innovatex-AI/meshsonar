// The MeshTrack Group sheet (plan 5.4, 5.5, 7, 8). Opened from the Drive chip, Settings > MeshTrack > Groups and the
// friends layer. Two pages in one sheet:
//   * Groups: one card per group (name, "3 heard in the last 30 min", See and Share switches, the inline This drive /
//     1 hour / Until I stop control while Share is on, the group menu: Invite, Start fresh, Leave, Share on every drive).
//     Header: New group, Join; the sharing status line; empty state with New group / Join / Use a private channel.
//   * People in one group: name, last heard, distance + compass point, direct / via N repeaters + SNR, speed if moving;
//     tap = centre the Drive map; Message and Where are you? on each row; header Send my position, Meet here, Invite
//     friends; the meet-up point with Clear (Undo); the footer about removing someone; the empty state.
// A phone gets a resizable bottom sheet; a screen 700 or more wide (iPad) gets a side panel on the right.
// Reversible actions never ask first: stopping a share, leaving a group, Start fresh and clearing the meet-up point all
// happen at once with Undo.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/units.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/app_widgets.dart' show AppSwitchTile;
import '../design/avatar_style.dart';
import '../design/sheet_detents.dart' show formSheetDetents;
import '../design/tokens.dart';
import '../settings/settings_kit.dart' show runWithUndo;
import 'group_setup.dart';
import 'meshtrack_binding.dart';
import 'meshtrack_copy.dart';
import 'meshtrack_intro.dart';
import 'mt_message.dart';

/// Width from which the sheet is a side panel instead of a bottom sheet.
const double kMtSidePanelWidth = 700;

/// Opens the Group sheet ([channelId] = straight to that group's people).
Future<void> showGroupSheet(BuildContext context, {int? channelId}) async {
  final b = MeshTrackUi.read(context);
  if (b == null) return;
  Widget content(BuildContext ctx, ScrollController sc) => MeshTrackScope(binding: b, child: GroupSheet(controller: sc, initialGroup: channelId));
  if (MediaQuery.sizeOf(context).width >= kMtSidePanelWidth) {
    AppHaptics.light();
    await Navigator.of(context, rootNavigator: true).push(_SidePanelRoute(theme: Theme.of(context), builder: content));
    return;
  }
  await showAppSheet<void>(context, detents: formSheetDetents(context), builder: content);
}

/// The iPad side panel: slides in from the right edge, the map stays visible on the left.
class _SidePanelRoute extends PopupRoute<void> {
  final ThemeData theme;
  final Widget Function(BuildContext, ScrollController) builder;
  _SidePanelRoute({required this.theme, required this.builder});

  @override
  Color? get barrierColor => Colors.black26;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Close MeshTrack';
  @override
  Duration get transitionDuration => Motion.sheet;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    return Theme(
      data: theme,
      child: _SidePanel(builder: builder),
    );
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    if (Motion.reduced(context)) return FadeTransition(opacity: animation, child: child);
    return SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    );
  }
}

class _SidePanel extends StatefulWidget {
  final Widget Function(BuildContext, ScrollController) builder;
  const _SidePanel({required this.builder});
  @override
  State<_SidePanel> createState() => _SidePanelState();
}

class _SidePanelState extends State<_SidePanel> {
  final _sc = ScrollController();
  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        key: const Key('mt-side-panel'),
        width: 420,
        height: double.infinity,
        child: Material(
          color: c.surface,
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(Corners.card)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(left: false, child: widget.builder(context, _sc)),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ the sheet

class GroupSheet extends StatefulWidget {
  final ScrollController controller;
  final int? initialGroup;
  const GroupSheet({super.key, required this.controller, this.initialGroup});
  @override
  State<GroupSheet> createState() => _GroupSheetState();
}

class _GroupSheetState extends State<GroupSheet> {
  MeshTrackBinding? _b;
  int? _open;
  Timer? _askedTimer;

  @override
  void initState() {
    super.initState();
    _open = widget.initialGroup;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final b = MeshTrackUi.of(context);
    if (!identical(b?.service, _b?.service) || !identical(b?.ops, _b?.ops)) {
      _b?.service.removeListener(_changed);
      _b?.ops.removeListener(_changed);
      b?.service.addListener(_changed);
      b?.ops.addListener(_changed);
    }
    _b = b;
  }

  @override
  void dispose() {
    _askedTimer?.cancel();
    _b?.service.removeListener(_changed);
    _b?.ops.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Rebuild when an "Asked" label runs out (the 15 s state tick may be later).
  void _wakeAt(DateTime? t, DateTime now) {
    _askedTimer?.cancel();
    if (t == null) return;
    final d = t.difference(now);
    _askedTimer = Timer(d.isNegative ? Duration.zero : d + const Duration(milliseconds: 50), _changed);
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    if (b == null) return const SizedBox.shrink();
    final st = b.service.state;
    final open = _open == null ? null : st.group(_open!);
    if (_open != null && open == null) _open = null; // left or removed meanwhile
    return Column(children: [
      if (open == null) _groupsHeader(context, b, st) else _peopleHeader(context, b, open),
      Expanded(
        child: ListView(
          key: Key(open == null ? 'mt-groups' : 'mt-people'),
          controller: widget.controller,
          padding: EdgeInsets.fromLTRB(0, 0, 0, Gap.xl + MediaQuery.viewPaddingOf(context).bottom),
          children: open == null ? _groups(context, b, st) : _people(context, b, st, open),
        ),
      ),
    ]);
  }

  // ---------------------------------------------------------------- groups page

  Widget _groupsHeader(BuildContext context, MeshTrackBinding b, MeshTrackState st) {
    final c = AppColors.of(context);
    // Full width, so the title sits on the screen margin and the buttons on the right edge (a bare Wrap in the sheet's
    // Column shrank to its content and was centred). The empty state has its own New group / Join buttons, so the
    // header shows them only once there is a group.
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.xs, Layout.screenMargin, Gap.s),
      child: SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: Gap.xs,
          children: [
            Semantics(header: true, child: Text(mtFeatureName, style: AppType.title2.copyWith(color: c.textPrimary))),
            if (st.groups.isNotEmpty)
              Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
                _HeaderButton(key: const Key('mt-new'), symbol: AppSymbols.plus, label: 'New group', onPressed: () => openNewGroup(context)),
                _HeaderButton(key: const Key('mt-join-open'), symbol: AppSymbols.qrcode, label: 'Join', onPressed: () => openJoinGroup(context)),
              ]),
          ],
        ),
      ),
    );
  }

  List<Widget> _groups(BuildContext context, MeshTrackBinding b, MeshTrackState st) {
    final c = AppColors.of(context);
    final status = mtStatusLine(st);
    if (st.groups.isEmpty) {
      return [
        const SizedBox(height: Gap.l),
        Center(child: AppSymbolIcon(AppSymbols.person2, size: 44, color: c.textMuted)),
        const SizedBox(height: Gap.m),
        Text(mtNoGroupsTitle, key: const Key('mt-empty'), textAlign: TextAlign.center, style: AppType.headline.copyWith(color: c.textPrimary)),
        const SizedBox(height: Gap.xs),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin * 2),
          child: Text(mtNoGroupsBody, textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: c.textMuted)),
        ),
        const SizedBox(height: Gap.l),
        _WideButton(key: const Key('mt-empty-new'), label: 'New group', filled: true, onPressed: () => openNewGroup(context)),
        const SizedBox(height: Gap.s),
        _WideButton(key: const Key('mt-empty-join'), label: 'Join a group', onPressed: () => openJoinGroup(context)),
        _WideButton(key: const Key('mt-empty-existing'), label: 'Use a private channel you have', onPressed: () => openUseExisting(context)),
      ];
    }
    return [
      if (status != null) _StatusBanner(text: status, warn: st.reason != MtShareReason.sharing),
      for (final g in st.groups) _GroupCard(
        key: Key('mt-group-${g.channelId}'),
        group: g,
        state: st,
        notOnRadio: !g.config.onRadio || b.ops.notOnRadio(g.channelId),
        onOpen: () => setState(() => _open = g.channelId),
        onSee: (v) => b.service.setSee(g.channelId, v),
        onShare: (v) => _setShare(context, b, g, v),
        now: b.now(),
        onDuration: (d) => _toast(context, b.service.setShare(g.channelId, true, duration: d)),
        onMenu: () => _menu(context, b, g),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.s),
        child: Text(mtGroupsFooter, key: const Key('mt-groups-footer'), style: AppType.footnote.copyWith(color: c.textMuted)),
      ),
      _WideButton(key: const Key('mt-existing'), label: 'Use a private channel you have', onPressed: () => openUseExisting(context)),
    ];
  }

  Future<void> _setShare(BuildContext context, MeshTrackBinding b, MtGroupView g, bool on) async {
    if (on) {
      if (!await ensureMeshTrackIntro(context, b.ops)) return;
      if (!context.mounted) return;
      _toast(context, b.service.setShare(g.channelId, true));
      return;
    }
    final before = g.config.duration;
    b.service.setShare(g.channelId, false);
    runWithUndo(context, mtStoppedSharingWith(g.name), commit: () async {}, onUndo: () => b.service.setShare(g.channelId, true, duration: before));
  }

  void _toast(BuildContext context, MtResult r) {
    final t = mtResultText(r);
    if (t != null) showAppToast(context, t, kind: AppToastKind.error);
  }

  Future<void> _menu(BuildContext context, MeshTrackBinding b, MtGroupView g) async {
    final every = g.config.shareEveryDrive;
    final pick = await showAppActionSheet<String>(
      context,
      title: g.name,
      sheetKey: const Key('mt-group-menu'),
      actions: [
        const AppAction('Invite', 'invite', symbol: AppSymbols.qrcode, key: Key('mt-menu-invite')),
        AppAction('Share on every drive', 'every', symbol: AppSymbols.car, checked: every, key: const Key('mt-menu-every')),
        const AppAction('Start fresh', 'fresh', symbol: AppSymbols.squareAndPencil, key: Key('mt-menu-fresh')),
        const AppAction('Leave', 'leave', destructive: true, key: Key('mt-menu-leave')),
      ],
    );
    if (pick == null || !context.mounted) return;
    switch (pick) {
      case 'invite':
        await openInvite(context, g.channelId, g.name);
      case 'every':
        b.service.setShareEveryDrive(g.channelId, !every);
        showAppToast(context, !every ? '${g.name}: Share turns on when you start a drive.' : '${g.name}: Share stays off until you turn it on.');
      case 'fresh':
        final r = await b.ops.startFresh(g.channelId);
        if (!context.mounted) return;
        if (!r.ok || r.channelId == null) {
          showAppToast(context, r.message ?? (r.status == MtGroupOpStatus.radioFull ? mtNotOnRadio : 'Could not start fresh. Nothing was changed.'), kind: AppToastKind.error);
          return;
        }
        final fresh = r.channelId!;
        runWithUndo(context, 'New link for ${g.name}. Invite people again.', commit: () async {}, onUndo: () => unawaited(b.ops.undoStartFresh(fresh)));
        await openInvite(context, fresh, g.name, fresh: true);
      case 'leave':
        final saved = await b.ops.stopUsingChannel(g.channelId);
        if (!context.mounted) return;
        runWithUndo(context, 'Left ${g.name}. The channel and its chat stay.', commit: () async {}, onUndo: () {
          if (saved != null) unawaited(b.ops.undoStopUsing(saved));
        });
    }
  }

  // ---------------------------------------------------------------- people page

  Widget _peopleHeader(BuildContext context, MeshTrackBinding b, MtGroupView g) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Layout.screenMargin, Gap.s),
      child: Row(children: [
        Hit.pad(
          size: kMtHit,
          semanticsLabel: 'Back to groups',
          onTap: () => setState(() => _open = null),
          child: KeyedSubtree(key: const Key('mt-back'), child: AppSymbolIcon(AppSymbols.chevronLeft, size: 22, color: c.accent)),
        ),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(g.name, key: const Key('mt-people-title'), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.title2.copyWith(color: c.textPrimary)),
          ),
        ),
      ]),
    );
  }

  List<Widget> _people(BuildContext context, MeshTrackBinding b, MeshTrackState st, MtGroupView g) {
    final c = AppColors.of(context);
    final now = b.now();
    final me = b.here();
    final status = mtStatusLine(st);
    final notOnRadio = !g.config.onRadio || b.ops.notOnRadio(g.channelId);
    final inZone = st.reason == MtShareReason.privacyZone;
    final asked = g.askedUntil != null && now.isBefore(g.askedUntil!);
    _wakeAt(asked ? g.askedUntil : null, now);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.m),
        child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
          _HeaderButton(
            key: const Key('mt-send-position'),
            symbol: AppSymbols.locationFill,
            label: inZone ? 'In a privacy zone' : 'Send my position',
            onPressed: notOnRadio || inZone ? null : () => _sendMine(context, b, g),
          ),
          _HeaderButton(key: const Key('mt-meet-here'), symbol: AppSymbols.flag, label: 'Meet here', onPressed: notOnRadio ? null : () => _meetHere(context, b, g)),
          _HeaderButton(key: const Key('mt-invite-open'), symbol: AppSymbols.personBadgePlus, label: 'Invite friends', onPressed: () => openInvite(context, g.channelId, g.name)),
        ]),
      ),
      if (status != null) _StatusBanner(text: status, warn: st.reason != MtShareReason.sharing),
      if (notOnRadio) _NotOnRadio(onRemove: () => _leaveFromPeople(context, b, g)),
      if (g.meet != null) _MeetRow(meet: g.meet!, me: me, units: b.units, now: now, onClear: () => _clearMeet(context, b, g)),
      if (g.friends.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.l, Layout.screenMargin, Gap.l),
          child: Column(children: [
            AppSymbolIcon(AppSymbols.mapFill, size: 40, color: c.textMuted),
            const SizedBox(height: Gap.s),
            Text(g.config.see ? mtPeopleEmpty : 'See is off for this group, so their positions are not shown. Turn See on to show them.',
                key: const Key('mt-people-empty'), textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: c.textMuted)),
            const SizedBox(height: Gap.m),
            CupertinoButton(
              key: const Key('mt-people-empty-invite'),
              minimumSize: const Size.square(kMtHit),
              onPressed: () => openInvite(context, g.channelId, g.name),
              child: const Text('Invite friends'),
            ),
          ]),
        )
      else
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Corners.chip),
            child: ColoredBox(
              color: c.surfaceHigh,
              child: Column(children: [
                for (final (i, f) in g.friends.indexed) ...[
                  if (i > 0) Container(height: 0.5, margin: const EdgeInsets.only(left: 64), color: c.outline.withValues(alpha: 0.35)),
                  FriendRow(
                    key: Key('mt-friend-${f.name}'),
                    friend: f,
                    me: me,
                    units: b.units,
                    now: now,
                    asked: asked && (g.askedName == null || g.askedName!.toLowerCase() == f.name.toLowerCase()),
                    askBlocked: asked,
                    onTap: () => _centre(context, b, f),
                    onMessage: () => openMtMessage(context, b.chat(), g.channelId, f.name),
                    onAsk: notOnRadio ? null : () => _toast(context, b.service.askWhereAreYou(g.channelId, name: f.name)),
                  ),
                ],
              ]),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.m, Layout.screenMargin, 0),
        child: Text(mtRosterFooter, key: const Key('mt-roster-footer'), style: AppType.footnote.copyWith(color: c.textMuted)),
      ),
    ];
  }

  void _sendMine(BuildContext context, MeshTrackBinding b, MtGroupView g) {
    final r = b.service.sendMyPosition(g.channelId);
    if (r == MtResult.ok) {
      showAppToast(context, 'Your position is on its way to ${g.name}.', kind: AppToastKind.success);
    } else {
      _toast(context, r);
    }
  }

  void _meetHere(BuildContext context, MeshTrackBinding b, MtGroupView g) {
    final at = b.here();
    if (at == null) {
      _toast(context, MtResult.waitingForGps);
      return;
    }
    final old = g.meet;
    final r = b.service.meetHere(g.channelId, at.lat, at.lon);
    if (r != MtResult.ok) {
      _toast(context, r);
      return;
    }
    runWithUndo(context, 'Meet-up point set where you are.', commit: () async {}, onUndo: () {
      if (old == null) {
        b.service.clearMeet(g.channelId);
      } else {
        b.service.meetHere(g.channelId, old.lat, old.lon, label: old.label);
      }
    });
  }

  void _clearMeet(BuildContext context, MeshTrackBinding b, MtGroupView g) {
    final old = g.meet;
    if (old == null) return;
    b.service.clearMeet(g.channelId);
    runWithUndo(context, 'Meet-up point cleared.', commit: () async {}, onUndo: () => b.service.meetHere(g.channelId, old.lat, old.lon, label: old.label));
  }

  Future<void> _leaveFromPeople(BuildContext context, MeshTrackBinding b, MtGroupView g) async {
    final saved = await b.ops.stopUsingChannel(g.channelId);
    if (!context.mounted) return;
    setState(() => _open = null);
    runWithUndo(context, 'Removed ${g.name} from MeshTrack.', commit: () async {}, onUndo: () {
      if (saved != null) unawaited(b.ops.undoStopUsing(saved));
    });
  }

  void _centre(BuildContext context, MeshTrackBinding b, MtFriend f) {
    if (!f.onMap) {
      showAppToast(context, '${f.name} was last heard over 2 h ago, so they are not on the map.');
      return;
    }
    (b.onCentre ?? centreDriveMap)(context, f.lat, f.lon);
  }
}

// ------------------------------------------------------------------------------------------------ pieces

class _HeaderButton extends StatelessWidget {
  final AppSymbol symbol;
  final String label;
  final VoidCallback? onPressed;
  const _HeaderButton({super.key, required this.symbol, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final on = onPressed != null;
    return Semantics(
      button: true,
      enabled: on,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          constraints: const BoxConstraints(minHeight: kMtHit, minWidth: kMtHit),
          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.xs),
          decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(kMtHit / 2)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AppSymbolIcon(symbol, size: 18, color: on ? c.accent : c.textMuted),
            const SizedBox(width: Gap.xs),
            Flexible(child: Text(label, style: AppType.subhead.copyWith(color: on ? c.textPrimary : c.textMuted, fontWeight: FontWeight.w600))),
          ]),
        ),
      ),
    );
  }
}

class _WideButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool filled;
  const _WideButton({super.key, required this.label, required this.onPressed, this.filled = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
        child: SizedBox(
          width: double.infinity,
          child: filled
              ? CupertinoButton.filled(minimumSize: const Size.square(kMtHit), onPressed: onPressed, child: Text(label, textAlign: TextAlign.center))
              : CupertinoButton(minimumSize: const Size.square(kMtHit), onPressed: onPressed, child: Text(label, textAlign: TextAlign.center)),
        ),
      );
}

class _StatusBanner extends StatelessWidget {
  final String text;
  final bool warn;
  const _StatusBanner({required this.text, required this.warn});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.m),
      child: Semantics(
        liveRegion: true,
        child: Container(
          key: const Key('mt-status'),
          padding: const EdgeInsets.all(Gap.m),
          decoration: BoxDecoration(
            color: (warn ? c.warning : c.accent).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(Corners.chip),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppSymbolIcon(warn ? AppSymbols.exclamationTriangle : AppSymbols.locationFill, size: 18, color: warn ? c.warning : c.accent),
            const SizedBox(width: Gap.s),
            Expanded(child: Text(text, style: AppType.subhead.copyWith(color: c.textPrimary))),
          ]),
        ),
      ),
    );
  }
}

class _NotOnRadio extends StatelessWidget {
  final VoidCallback onRemove;
  const _NotOnRadio({required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.m),
      child: Container(
        key: const Key('mt-not-on-radio'),
        padding: const EdgeInsets.all(Gap.m),
        decoration: BoxDecoration(color: c.warning.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(Corners.chip)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(mtNotOnRadio, style: AppType.subhead.copyWith(color: c.textPrimary)),
          Wrap(spacing: Gap.m, children: [
            CupertinoButton(key: const Key('mt-make-room'), minimumSize: const Size.square(kMtHit), padding: EdgeInsets.zero, onPressed: () => openMakeRoom(context), child: const Text(mtMakeRoom)),
            CupertinoButton(key: const Key('mt-remove'), minimumSize: const Size.square(kMtHit), padding: EdgeInsets.zero, onPressed: onRemove, child: Text('Remove', style: TextStyle(color: c.danger))),
          ]),
        ]),
      ),
    );
  }
}

class _MeetRow extends StatelessWidget {
  final MtMeetPin meet;
  final MtLatLon? me;
  final Units units;
  final DateTime now;
  final VoidCallback onClear;
  const _MeetRow({required this.meet, required this.me, required this.units, required this.now, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final where = mtDistanceAndPoint(me, meet.lat, meet.lon, units);
    final title = meet.label == null || meet.label!.isEmpty ? 'Meet-up point' : 'Meet-up point: ${meet.label}';
    final sub = [if (meet.setBy != null) 'set by ${meet.setBy}', mtAgo(meet.at, now), ?where].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.m),
      child: Container(
        key: const Key('mt-meet'),
        padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.xs, Gap.s),
        decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.chip)),
        child: Row(children: [
          AppSymbolIcon(AppSymbols.flag, size: 20, color: c.accent),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Semantics(
              container: true,
              label: '$title, $sub',
              child: ExcludeSemantics(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: AppType.body.copyWith(color: c.textPrimary)),
                  Text(sub, style: AppType.footnote.copyWith(color: c.textMuted)),
                ]),
              ),
            ),
          ),
          CupertinoButton(key: const Key('mt-meet-clear'), minimumSize: const Size.square(kMtHit), onPressed: onClear, child: const Text('Clear')),
        ]),
      ),
    );
  }
}

/// One friend in a group's people list.
class FriendRow extends StatelessWidget {
  final MtFriend friend;
  final MtLatLon? me;
  final Units units;
  final DateTime now;
  /// This person was asked "Where are you?" (the button says Asked).
  final bool asked;

  /// Someone in the group was asked less than a minute ago, so the button is off (it says Where are you?, muted).
  final bool askBlocked;
  final VoidCallback onTap;
  final VoidCallback onMessage;
  final VoidCallback? onAsk;
  const FriendRow({
    super.key,
    required this.friend,
    required this.me,
    required this.units,
    required this.now,
    required this.asked,
    this.askBlocked = false,
    required this.onTap,
    required this.onMessage,
    required this.onAsk,
  });

  String get _initials {
    final w = friend.name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (w.isEmpty) return '?';
    String first(String s) => s.characters.first.toUpperCase();
    return w.length > 1 ? first(w.first) + first(w.last) : first(w.first);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final f = friend;
    final lines = mtFriendLines(f, me: me, units: units, now: now);
    final faded = f.staleness != MtStaleness.fresh;
    final style = avatarStyle('mt:${f.name}', c);
    final off = asked || askBlocked || onAsk == null;
    final actions = [
      Hit.pad(
        size: kMtHit,
        semanticsLabel: 'Message ${f.name}',
        onTap: onMessage,
        child: KeyedSubtree(key: Key('mt-message-${f.name}'), child: AppSymbolIcon(AppSymbols.message, size: 22, color: c.accent)),
      ),
      Semantics(
        button: true,
        enabled: !off,
        label: asked ? '$mtAsked. You asked where they are' : '$mtWhereAreYou Ask ${f.name}',
        excludeSemantics: true,
        child: CupertinoButton(
          key: Key('mt-ask-${f.name}'),
          minimumSize: const Size.square(kMtHit),
          padding: const EdgeInsets.symmetric(horizontal: Gap.s),
          onPressed: off ? null : onAsk,
          child: Text(asked ? mtAsked : mtWhereAreYou, style: AppType.subhead.copyWith(fontWeight: FontWeight.w600, color: off ? c.textMuted : c.accent)),
        ),
      ),
    ];
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.headline.copyWith(color: faded ? c.textMuted : c.textPrimary)),
      Text(mtKeepTogether(lines.line1), style: AppType.subhead.copyWith(color: c.textMuted)),
      if (lines.line2 != null) Text(mtKeepTogether(lines.line2!), style: AppType.footnote.copyWith(color: f.jumped ? c.warning : c.textMuted)),
    ]);
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.xs, Gap.s),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(
              child: Semantics(
                button: true,
                label: lines.semantics,
                hint: f.onMap ? 'Shows them on the map' : null,
                excludeSemantics: true,
                onTap: onTap,
                child: GestureDetector(
                  key: Key('mt-friend-tap-${f.name}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: kMtHit),
                    child: Row(children: [
                      Opacity(
                        opacity: faded ? 0.55 : 1,
                        child: Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: f.staleness == MtStaleness.fresh || f.staleness == MtStaleness.faded ? style.fill : c.outline, shape: BoxShape.circle),
                          child: Text(_initials, textScaler: TextScaler.noScaling, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(width: Gap.m),
                      Expanded(child: text),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
          // The actions sit under the text (aligned with it), so the name and the two lines get the full width: beside
          // them, "Where are you?" squeezed the lines into "0.7 mi / W" and "25 / mph" on a phone.
          Padding(padding: const EdgeInsets.only(left: 52), child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: actions)),
        ]),
      ),
    );
  }
}

/// One group on the groups page.
class _GroupCard extends StatelessWidget {
  final MtGroupView group;
  final MeshTrackState state;
  final bool notOnRadio;
  final DateTime now;
  final VoidCallback onOpen;
  final ValueChanged<bool> onSee;
  final ValueChanged<bool> onShare;
  final ValueChanged<MtShareDuration> onDuration;
  final VoidCallback onMenu;
  const _GroupCard({
    super.key,
    required this.group,
    required this.state,
    required this.notOnRadio,
    required this.now,
    required this.onOpen,
    required this.onSee,
    required this.onShare,
    required this.onDuration,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final g = group;
    final share = g.config.share;
    final capped = !share && !state.canShareMore;
    final line = mtHeardLine(g);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.m),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Corners.chip),
        child: Material(
          color: c.surfaceHigh,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: '${g.name}, $line. Shows the people in this group',
                  excludeSemantics: true,
                  onTap: onOpen,
                  child: InkWell(
                    key: Key('mt-open-${g.channelId}'),
                    onTap: onOpen,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: kMtHit),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Gap.xs, Gap.s),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                if (g.sharingNow) ...[
                                  Container(width: 8, height: 8, decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle)),
                                  const SizedBox(width: Gap.xs),
                                ],
                                Flexible(child: Text(g.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.headline.copyWith(color: c.textPrimary))),
                              ]),
                              Text(line, key: Key('mt-heard-${g.channelId}'), style: AppType.subhead.copyWith(color: c.textMuted)),
                            ]),
                          ),
                          AppSymbolIcon(AppSymbols.chevronRight, size: 16, color: c.textMuted),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
              Hit.pad(
                size: kMtHit,
                semanticsLabel: '${g.name} options',
                onTap: onMenu,
                child: KeyedSubtree(key: Key('mt-menu-${g.channelId}'), child: AppSymbolIcon(AppSymbols.ellipsisCircle, size: 24, color: c.accent)),
              ),
              const SizedBox(width: Gap.xs),
            ]),
            if (notOnRadio)
              Padding(
                padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.s),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(mtNotOnRadio, key: Key('mt-not-on-radio-${g.channelId}'), style: AppType.footnote.copyWith(color: c.warning)),
                  CupertinoButton(
                    key: Key('mt-make-room-${g.channelId}'),
                    minimumSize: const Size.square(kMtHit),
                    padding: EdgeInsets.zero,
                    onPressed: () => openMakeRoom(context),
                    child: const Text(mtMakeRoom),
                  ),
                ]),
              ),
            Container(height: 0.5, color: c.outline.withValues(alpha: 0.35)),
            AppSwitchTile(
              switchKey: Key('mt-see-${g.channelId}'),
              title: 'See',
              subtitle: 'Their positions on your map',
              value: g.config.see,
              onChanged: onSee,
            ),
            AppSwitchTile(
              switchKey: Key('mt-share-${g.channelId}'),
              title: 'Share',
              subtitle: notOnRadio ? 'Not on this radio' : (capped ? mtUpToThree : mtShareDetail(g, now)),
              value: share,
              onChanged: notOnRadio || capped ? null : onShare,
            ),
            if (share)
              Padding(
                padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.m),
                child: SizedBox(
                  width: double.infinity,
                  child: CupertinoSlidingSegmentedControl<MtShareDuration>(
                    key: Key('mt-duration-${g.channelId}'),
                    groupValue: g.config.duration,
                    children: {for (final d in MtShareDuration.values) d: _Seg(mtDurationLabel(d), key: Key('mt-dur-${d.name}'))},
                    onValueChanged: (v) {
                      if (v == null || v == g.config.duration) return;
                      AppHaptics.selection();
                      onDuration(v);
                    },
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Seg extends StatelessWidget {
  final String label;
  const _Seg(this.label, {super.key});
  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Center(child: Text(label, textAlign: TextAlign.center, maxLines: 2)),
      );
}
