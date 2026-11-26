// MeshTrack in the Drive panel (build 69; it replaces the small map pill): Andy, Nov 16 2026 - "it was supposed to be on the
// drive panel. who is going to notice that pill?"
//   MeshTrackPanelRow    Medium: a full-width row near the Antenna / Ping chips. People icon, "MeshTrack", the state line
//                        (mtPanelLine: "Share your position with friends", "Sharing: Family, Club" with the accent dot,
//                        "Sharing paused: privacy zone", "Waiting for GPS", "2 friends nearby", "Connect your radio to
//                        share"). Tap opens the Group sheet. With exactly one group a Share switch sits at the end, so
//                        sharing is one tap (the intro first, the group's last duration, Undo on stop). A "New" tag shows
//                        from the first drive after the update until MeshTrack is opened once.
//   MeshTrackDockButton  Dock (always visible): a compact 56 x 52 button, people icon over "MeshTrack". While sharing it
//                        is tinted with the accent dot (warning dot when paused), so the person always knows positions go out.
//   MeshTrackEvents      The MeshTrack toasts ("Sam asked where you are" + Send my position, "Stopped sharing: radio
//                        disconnected" + Share again, "the hour is up"), mounted once around the Drive screen so none is
//                        lost while the panel is hidden or collapsed.
// All three are nothing when MeshTrack is off in this build (no binding).
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';

import '../../design/app_surfaces.dart';
import '../../design/tokens.dart';
import '../../meshtrack/group_sheet.dart' show setGroupShare, showGroupSheet;
import '../../meshtrack/meshtrack_binding.dart';
import '../../meshtrack/meshtrack_copy.dart';
import '../../meshtrack/meshtrack_intro.dart' show ensureMeshTrackIntro;

/// Rebuilds [builder] on every MeshTrack change (the service's state and the group operations' settings).
class _MtListen extends StatefulWidget {
  final Widget Function(BuildContext context, MeshTrackBinding b) builder;
  const _MtListen({required this.builder});
  @override
  State<_MtListen> createState() => _MtListenState();
}

class _MtListenState extends State<_MtListen> {
  MeshTrackBinding? _b;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final b = MeshTrackUi.of(context);
    if (identical(b?.service, _b?.service) && identical(b?.ops, _b?.ops)) {
      _b = b;
      return;
    }
    _unhook();
    _b = b;
    b?.service.addListener(_changed);
    b?.ops.addListener(_changed);
  }

  void _unhook() {
    _b?.service.removeListener(_changed);
    _b?.ops.removeListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _unhook();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    return b == null ? const SizedBox.shrink() : widget.builder(context, b);
  }
}

Color? _toneColor(MtChipTone tone, AppColors c) => switch (tone) {
      MtChipTone.sharing => c.accent,
      MtChipTone.paused => c.warning,
      MtChipTone.idle => null,
    };

// ------------------------------------------------------------------------------------------------ Medium row

class MeshTrackPanelRow extends StatelessWidget {
  const MeshTrackPanelRow({super.key = const Key('mt-panel')});

  @override
  Widget build(BuildContext context) => _MtListen(builder: _build);

  Widget _build(BuildContext context, MeshTrackBinding b) {
    final c = AppColors.fromTheme(Theme.of(context));
    final st = b.service.state;
    final line = mtPanelLine(st);
    final tone = _toneColor(line.tone, c);
    final isNew = b.ops.panelNew;
    final one = st.groups.length == 1 ? st.groups.first : null;

    final icon = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: (tone ?? c.accent).withValues(alpha: 0.16), shape: BoxShape.circle),
      child: Icon(Icons.people_alt_rounded, size: 22, color: tone ?? c.accent),
    );
    final texts = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Flexible(child: Text(mtFeatureName, key: Key('mt-panel-title'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
          if (isNew) ...[const SizedBox(width: 8), _NewTag(color: c.accent, onColor: c.onAccent)],
        ]),
        const SizedBox(height: 2),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (tone != null) ...[
            Container(key: const Key('mt-panel-dot'), width: 8, height: 8, decoration: BoxDecoration(color: tone, shape: BoxShape.circle)),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(line.text,
                key: const Key('mt-panel-subtitle'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: tone == null ? c.textMuted : c.textPrimary)),
          ),
        ]),
      ],
    );

    void open() => unawaited(showGroupSheet(context));
    final main = Semantics(
      button: true,
      label: mtPanelSemantics(st, isNew: isNew),
      excludeSemantics: true,
      onTap: open,
      child: GestureDetector(
        key: const Key('mt-panel-row'),
        behavior: HitTestBehavior.opaque,
        onTap: open,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(children: [
              icon,
              const SizedBox(width: 12),
              Expanded(child: texts),
              if (one == null) Icon(Icons.chevron_right_rounded, color: c.textMuted),
            ]),
          ),
        ),
      ),
    );

    Widget? trailing;
    if (one != null) {
      final share = one.config.share;
      final notOnRadio = !one.config.onRadio || b.ops.notOnRadio(one.channelId);
      final enabled = share || (!notOnRadio && st.radioConnected && st.canShareMore);
      trailing = Semantics(
        label: mtPanelShareLabel(one),
        child: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kMtHit, minWidth: kMtHit),
            child: Center(
              widthFactor: 1,
              child: CupertinoSwitch(
                key: const Key('mt-panel-share'),
                value: share,
                onChanged: !enabled
                    ? null
                    : (v) {
                        unawaited(b.ops.markPanelSeen());
                        unawaited(setGroupShare(context, b, one, v, duration: one.config.duration));
                      },
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surfaceHigh,
          borderRadius: BorderRadius.circular(Corners.chip),
          border: Border.all(color: tone?.withValues(alpha: 0.6) ?? c.outline.withValues(alpha: 0.5)),
        ),
        child: Row(children: [Expanded(child: main), ?trailing]),
      ),
    );
  }
}

class _NewTag extends StatelessWidget {
  final Color color, onColor;
  const _NewTag({required this.color, required this.onColor});
  @override
  Widget build(BuildContext context) => Container(
        key: const Key('mt-panel-new'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
        child: Text(mtPanelNewTag, textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: onColor)),
      );
}

// ------------------------------------------------------------------------------------------------ Dock button

/// The Dock's MeshTrack button: 56 x 52 (the Start button's height). [gap] is the space before it, left out with the
/// button when MeshTrack is off in this build.
class MeshTrackDockButton extends StatelessWidget {
  final double gap;
  const MeshTrackDockButton({super.key = const Key('mt-dock'), this.gap = 8});

  static const double width = 56;

  /// Icon only, on a Dock narrower than 400 pt (iPhone SE to iPhone 17, build 76): the 10 pt "MeshTrack" caption was hard
  /// to read and its 56 pt square squeezed the status words beside it. VoiceOver still says MeshTrack.
  static const double compactWidth = 48;
  static bool compactFor(BuildContext context) => MediaQuery.sizeOf(context).width < 400;

  @override
  Widget build(BuildContext context) => _MtListen(builder: _build);

  Widget _build(BuildContext context, MeshTrackBinding b) {
    final c = AppColors.fromTheme(Theme.of(context));
    final st = b.service.state;
    final tone = _toneColor(mtPanelLine(st).tone, c);
    void open() => unawaited(showGroupSheet(context));
    final compact = compactFor(context);
    final label = MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2)),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(mtFeatureName,
            key: const Key('mt-dock-label'), maxLines: 1, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: tone ?? c.textMuted)),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(left: gap),
      child: Semantics(
        button: true,
        label: mtPanelSemantics(st),
        excludeSemantics: true,
        onTap: open,
        child: GestureDetector(
          key: const Key('mt-dock-hit'),
          behavior: HitTestBehavior.opaque,
          onTap: open,
          child: Container(
            width: compact ? compactWidth : width,
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: tone?.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: tone ?? c.outline, width: 1.5),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(
                width: 28,
                height: 22,
                child: Stack(clipBehavior: Clip.none, children: [
                  Center(child: Icon(Icons.people_alt_rounded, size: compact ? 24 : 21, color: tone ?? c.textPrimary)),
                  if (tone != null)
                    Positioned(
                      right: -1,
                      top: -1,
                      child: Container(
                        key: const Key('mt-dock-dot'),
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(color: tone, shape: BoxShape.circle, border: Border.all(color: c.surface, width: 1.5)),
                      ),
                    ),
                ]),
              ),
              if (!compact) ...[const SizedBox(height: 2), label],
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ toasts

/// The MeshTrack toasts, listened to once for the whole Drive screen (moved from the old map pill).
class MeshTrackEvents extends StatefulWidget {
  final Widget child;
  const MeshTrackEvents({super.key, required this.child});
  @override
  State<MeshTrackEvents> createState() => _MeshTrackEventsState();
}

class _MeshTrackEventsState extends State<MeshTrackEvents> {
  MeshTrackService? _svc;
  StreamSubscription<MtEvent>? _events;

  /// Each group's last share duration, for Share again after the radio went away.
  final Map<int, MtShareDuration> _durations = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final svc = MeshTrackUi.of(context)?.service;
    if (!identical(svc, _svc)) {
      _svc?.removeListener(_changed);
      unawaited(_events?.cancel());
      _svc = svc;
      svc?.addListener(_changed);
      _events = svc?.events.listen(_onEvent);
      _changed();
    }
  }

  @override
  void dispose() {
    _svc?.removeListener(_changed);
    unawaited(_events?.cancel());
    super.dispose();
  }

  void _changed() {
    final st = _svc?.state;
    if (st == null) return;
    for (final g in st.groups) {
      if (g.config.share) _durations[g.channelId] = g.config.duration;
    }
  }

  void _onEvent(MtEvent e) {
    if (!mounted) return;
    final svc = _svc;
    if (svc == null) return;
    switch (e) {
      case MtAskedWhileNotSharing(:final channelId, :final name):
        showAppToast(context, mtAskedToast(name), actionLabel: 'Send my position', onAction: () async {
          // A one-shot share: the intro comes first, as for the Share switch.
          if (!mounted) return;
          final ops = MeshTrackUi.read(context)?.ops;
          if (ops == null || !await ensureMeshTrackIntro(context, ops)) return;
          if (!mounted) return;
          final r = svc.sendMyPosition(channelId);
          final t = mtResultText(r);
          if (mounted) showAppToast(context, t ?? 'Your position is on its way.', kind: t == null ? AppToastKind.success : AppToastKind.error);
        });
      case MtSharingStopped(:final channelId, cause: MtStopCause.radioDisconnected):
        final d = _durations[channelId] ?? MtShareDuration.thisDrive;
        showAppToast(context, mtRadioDisconnectedStop, kind: AppToastKind.error, actionLabel: mtShareAgain, onAction: () {
          final t = mtResultText(svc.setShare(channelId, true, duration: d));
          if (t != null && mounted) showAppToast(context, t, kind: AppToastKind.error);
        });
      case MtSharingStopped(:final channelId, cause: MtStopCause.durationEnded):
        final name = svc.state.group(channelId)?.name;
        if (name != null) showAppToast(context, 'Stopped sharing with $name: the hour is up.');
      case MtSharingStopped():
        break; // the person's own stop has its Undo toast; drive end, Leave and removal need no message
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
