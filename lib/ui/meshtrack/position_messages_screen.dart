// "Position messages" (plan 5.8, 6): the MeshTrack updates heard and sent in one group's channel, opened from channel
// detail while "Show position messages" is on. Display only: the list comes from the service's memory
// (MeshTrackService.positionMessages, last 24 h), so these messages are never stored as chat, never notified or counted
// unread, and never in a backup, export or search. Leave, Start fresh, the channel's delete and Delete my data clear it.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/units.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import 'meshtrack_binding.dart';
import 'meshtrack_copy.dart';

Future<void> openPositionMessages(BuildContext context, int channelId, String name) {
  final b = MeshTrackUi.read(context);
  if (b == null) return Future.value();
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => MeshTrackScope(binding: b, child: PositionMessagesScreen(channelId: channelId, name: name)),
  ));
}

class PositionMessagesScreen extends StatefulWidget {
  final int channelId;
  final String name;
  const PositionMessagesScreen({super.key, required this.channelId, required this.name});
  @override
  State<PositionMessagesScreen> createState() => _PositionMessagesScreenState();
}

class _PositionMessagesScreenState extends State<PositionMessagesScreen> {
  MeshTrackBinding? _b;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final b = MeshTrackUi.of(context);
    if (!identical(b?.service, _b?.service)) {
      _b?.service.removeListener(_changed);
      b?.service.addListener(_changed);
    }
    _b = b;
  }

  @override
  void dispose() {
    _b?.service.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final b = _b;
    final list = b == null ? const <MtLoggedMessage>[] : b.service.positionMessages(widget.channelId);
    final now = b?.now() ?? DateTime.now();
    return Scaffold(
      backgroundColor: c.bg,
      appBar: CupertinoNavigationBar(backgroundColor: c.bg, border: null, middle: const Text('Position messages')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              key: const Key('mt-position-messages'),
              padding: const EdgeInsets.only(top: Gap.s, bottom: Gap.xl),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.m),
                  child: Text(mtPositionMessagesNote, key: const Key('mt-position-messages-note'), style: AppType.footnote.copyWith(color: c.textMuted)),
                ),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.l, Layout.screenMargin, Gap.l),
                    child: Column(children: [
                      AppSymbolIcon(AppSymbols.locationFill, size: 36, color: c.textMuted),
                      const SizedBox(height: Gap.s),
                      Text('No MeshTrack updates in ${widget.name} in the last 24 hours.',
                          key: const Key('mt-position-messages-empty'), textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: c.textMuted)),
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
                          for (final (i, m) in list.indexed) ...[
                            if (i > 0) Container(height: 0.5, margin: const EdgeInsets.only(left: Layout.screenMargin), color: c.outline.withValues(alpha: 0.35)),
                            _Row(key: Key('mt-position-message-$i'), message: m, units: b!.units, now: now),
                          ],
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final MtLoggedMessage message;
  final Units units;
  final DateTime now;
  const _Row({super.key, required this.message, required this.units, required this.now});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final who = message.name ?? 'You';
    final what = mtMessageSummary(message, units);
    final ago = mtAgo(message.at, now);
    return Semantics(
      container: true,
      label: '$who, $what, $ago',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
            child: Row(children: [
              AppSymbolIcon(message.mine ? AppSymbols.locationFill : AppSymbols.person2, size: 18, color: c.accent),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(who, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.subhead.copyWith(color: c.textPrimary, fontWeight: FontWeight.w600)),
                  Text(what, style: AppType.footnote.copyWith(color: c.textMuted)),
                ]),
              ),
              const SizedBox(width: Gap.s),
              Text(ago, style: AppType.caption.copyWith(color: c.textMuted)),
            ]),
          ),
        ),
      ),
    );
  }
}
