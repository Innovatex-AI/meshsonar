// Where people find MeshTrack outside the Drive panel (build 69): the card at the top of Chat > Channels and in the empty
// Chats list. Title "MeshTrack", "See friends on the map. Make a group or join one." (the groups and the sharing state once
// there are groups); a tap opens the Group sheet. Nothing when MeshTrack is off in this build. Positions never show in chat.
import 'dart:async';

import 'package:flutter/material.dart';

import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import 'group_sheet.dart' show showGroupSheet;
import 'meshtrack_binding.dart';
import 'meshtrack_copy.dart';

class MeshTrackChatCard extends StatefulWidget {
  /// Around the card; the Channels list gives it the screen margins.
  final EdgeInsets padding;
  const MeshTrackChatCard({super.key = const Key('mt-chat-card'), this.padding = const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, Gap.xs)});
  @override
  State<MeshTrackChatCard> createState() => _MeshTrackChatCardState();
}

class _MeshTrackChatCardState extends State<MeshTrackChatCard> {
  MeshTrackService? _svc;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final svc = MeshTrackUi.of(context)?.service;
    if (!identical(svc, _svc)) {
      _svc?.removeListener(_changed);
      _svc = svc;
      svc?.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _svc?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = _svc;
    if (svc == null) return const SizedBox.shrink();
    final c = AppColors.of(context);
    final st = svc.state;
    final line = mtChatCardLine(st);
    void open() => unawaited(showGroupSheet(context));
    return Padding(
      padding: widget.padding,
      child: Semantics(
        button: true,
        label: '$mtChatCardTitle. $line. Opens your groups',
        excludeSemantics: true,
        onTap: open,
        child: Material(
          color: c.surfaceHigh,
          borderRadius: BorderRadius.circular(Corners.chip),
          child: InkWell(
            key: const Key('mt-chat-card-hit'),
            borderRadius: BorderRadius.circular(Corners.chip),
            onTap: open,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.s, Gap.s),
                child: Row(children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.16), shape: BoxShape.circle),
                    child: Center(child: AppSymbolIcon(AppSymbols.person2Fill, size: 20, color: c.accent)),
                  ),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(mtChatCardTitle, style: AppType.headline.copyWith(color: c.textPrimary)),
                      const SizedBox(height: 2),
                      Text(line, key: const Key('mt-chat-card-line'), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.subhead.copyWith(color: c.textMuted)),
                    ]),
                  ),
                  AppSymbolIcon(AppSymbols.chevronRight, size: 16, color: c.textMuted),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
