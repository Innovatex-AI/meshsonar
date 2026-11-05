// Pieces of the repeater dashboard (chat plan 4.10): inset-grouped lists, the glance cards, and the remote request strip with its
// "What the radio is doing" sheet. Cupertino-style, no Material list widgets.
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator, CupertinoButton;
import 'package:flutter/material.dart';

import '../../../radio/remote_request_queue.dart';
import '../../design/app_surfaces.dart';
import '../../design/app_symbols.dart';
import '../../design/app_type.dart';
import '../../design/sparkline.dart';
import '../../design/tokens.dart';

/// Number with thousands separators: 8214 -> "8,214".
String groupedInt(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// "Updated 40 s ago" / "Updated 3 min ago".
String updatedText(DateTime? at, DateTime now) {
  if (at == null) return 'Not updated yet';
  final s = now.difference(at).inSeconds.clamp(0, 1 << 30);
  if (s < 60) return 'Updated $s s ago';
  if (s < 3600) return 'Updated ${s ~/ 60} min ago';
  return 'Updated ${s ~/ 3600} h ago';
}

/// The big number's uptime: "12 d", "5 h", "7 min".
String shortUptime(int secs) {
  final d = secs ~/ 86400, h = secs ~/ 3600, m = secs ~/ 60;
  if (d > 0) return '$d d';
  if (h > 0) return '$h h';
  if (m > 0) return '$m min';
  return '$secs s';
}

/// An inset-grouped section: small caps header above, rounded block of rows, optional footer below.
class InsetGroup extends StatelessWidget {
  final String? header;
  final String? footer;
  final List<Widget> rows;
  final Key? groupKey;
  const InsetGroup({super.key, this.header, this.footer, required this.rows, this.groupKey});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xs),
            child: Semantics(header: true, child: Text(header!.toUpperCase(), style: AppType.footnote.copyWith(color: c.textMuted))),
          ),
        Container(
          key: groupKey,
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(10)),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Container(height: 0.5, margin: const EdgeInsets.only(left: Gap.l), color: c.outline.withValues(alpha: 0.35)),
              rows[i],
            ],
          ]),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, 0),
            child: Text(footer!, key: const Key('group-footer'), style: (t.bodySmall ?? AppType.footnote).copyWith(color: c.textMuted)),
          ),
      ]),
    );
  }
}

/// One row of an [InsetGroup]: title left, value right (stacks when the text is large), chevron when [onTap] is set.
class GroupRow extends StatelessWidget {
  final String title;
  final String? value;
  final VoidCallback? onTap;
  final Key? rowKey;
  final Key? valueKey;
  const GroupRow({super.key, required this.title, this.value, this.onTap, this.rowKey, this.valueKey});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final big = MediaQuery.textScalerOf(context).scale(17) > 17 * 1.5;
    final titleW = Text(title, style: AppType.body.copyWith(color: c.textPrimary));
    final valueW = value == null
        ? null
        : Text(value!, key: valueKey, style: AppType.num(17, weight: FontWeight.w400).copyWith(color: c.textMuted), textAlign: big ? TextAlign.start : TextAlign.end);
    final chevron = onTap == null ? null : AppSymbolIcon(AppSymbols.chevronRight, size: 14, color: c.textMuted);
    final body = Container(
      constraints: const BoxConstraints(minHeight: Hit.min),
      padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
      child: big
          ? Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [titleW, ?valueW])),
              if (chevron != null) Padding(padding: const EdgeInsets.only(left: Gap.s), child: chevron),
            ])
          : Row(children: [
              Flexible(flex: 5, child: titleW),
              if (valueW != null) ...[const SizedBox(width: Gap.s), Flexible(flex: 6, child: valueW)],
              if (chevron != null) Padding(padding: const EdgeInsets.only(left: Gap.s), child: chevron),
            ]),
    );
    return Semantics(
      key: rowKey,
      container: true,
      button: onTap != null,
      label: value == null ? title : '$title: $value',
      excludeSemantics: true,
      onTap: onTap,
      child: onTap == null ? body : GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: body),
    );
  }
}

/// One of the four glance cards: label, big tabular number with its unit, a 60 x 24 sparkline. Tap opens the chart page.
class GlanceCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final List<double> series;
  final String summary;
  final VoidCallback onTap;
  final Key cardKey;
  final Key valueKey;
  const GlanceCard({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.series,
    required this.summary,
    required this.onTap,
    required this.cardKey,
    required this.valueKey,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      key: cardKey,
      container: true,
      button: true,
      label: '$label ${value == '—' ? 'not read yet' : '$value $unit'}. $summary Opens the chart.',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 84),
          padding: const EdgeInsets.all(Gap.m),
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: AppType.footnote.copyWith(color: c.textMuted)),
            const SizedBox(height: Gap.xs),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, mainAxisSize: MainAxisSize.min, children: [
                    Text(value, key: valueKey, style: AppType.num(28).copyWith(color: c.textPrimary)),
                    if (unit.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 4), child: Text(unit, style: AppType.footnote.copyWith(color: c.textMuted))),
                  ]),
                ),
              ),
              const SizedBox(width: Gap.s),
              Sparkline(values: series, semanticLabel: summary, color: c.accent),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------- remote request queue

/// "Asking Hill for neighbours" for one request, in plain words.
String requestPhrase(RemoteRequest r, String Function(String target) nameFor) {
  final who = nameFor(r.target);
  final what = switch (r.kind) {
    RemoteKind.login => 'to log in',
    RemoteKind.status => 'for its status',
    RemoteKind.telemetry => 'for its readings',
    RemoteKind.neighbours => 'for neighbours',
    RemoteKind.acl => 'for the access list',
    RemoteKind.ownerInfo => 'for its owner info',
    RemoteKind.anon => 'for its clock',
    RemoteKind.cli => 'to run a command',
    RemoteKind.pathDiscovery => 'for a route',
    RemoteKind.trace => 'for a trace',
    RemoteKind.contact => 'for its contact details',
  };
  return 'Asking $who $what';
}

String requestStateWord(RemoteState s) => switch (s) {
      RemoteState.queued => 'Waiting',
      RemoteState.sending || RemoteState.waitingForReply => 'Running',
      RemoteState.done => 'Done',
      RemoteState.noReply => 'No answer',
      RemoteState.refused => 'Refused',
      RemoteState.cancelled => 'Cancelled',
      RemoteState.dropped => 'Skipped (radio busy)',
      RemoteState.failed => 'Failed',
    };

/// Follows the queue and remembers the last few requests (the queue itself forgets a request when it ends).
class RemoteQueueWatch extends ChangeNotifier {
  final RemoteRequestQueue queue;
  final List<RemoteRequest> _seen = [];
  RemoteQueueWatch(this.queue) {
    _take();
    queue.requests.addListener(_onChange);
  }

  static const int keep = 8;

  void _take() {
    for (final r in queue.requests.value) {
      if (!_seen.contains(r)) _seen.add(r);
    }
    while (_seen.length > keep) {
      final i = _seen.indexWhere((r) => r.isFinished);
      _seen.removeAt(i < 0 ? 0 : i);
    }
  }

  void _onChange() {
    _take();
    // A finished request leaves the live list; give listeners a second look once its state has settled.
    notifyListeners();
    scheduleMicrotask(notifyListeners);
  }

  /// Requests that are waiting or running now.
  List<RemoteRequest> get active => [for (final r in queue.requests.value) if (!r.isFinished) r];

  /// Everything remembered, newest first.
  List<RemoteRequest> get recent => _seen.reversed.toList();

  @override
  void dispose() {
    queue.requests.removeListener(_onChange);
    super.dispose();
  }
}

/// The 28 pt strip above the bottom edge (44 pt hit area) while a remote request waits or runs.
class RemoteQueueStrip extends StatelessWidget {
  final RemoteQueueWatch watch;
  final String Function(String target) nameFor;
  const RemoteQueueStrip({super.key, required this.watch, required this.nameFor});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: watch,
      builder: (context, _) {
        final a = watch.active;
        if (a.isEmpty) return const SizedBox.shrink(key: Key('queue-strip-idle'));
        final c = AppColors.of(context);
        final text = '${requestPhrase(a.first, nameFor)}…${a.length > 1 ? ' (${a.length - 1} waiting)' : ''}';
        return Semantics(
          key: const Key('queue-strip'),
          liveRegion: true,
          button: true,
          label: '$text. Opens what the radio is doing.',
          excludeSemantics: true,
          onTap: () => showRadioActivitySheet(context, watch: watch, nameFor: nameFor),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showRadioActivitySheet(context, watch: watch, nameFor: nameFor),
            child: Container(
              constraints: const BoxConstraints(minHeight: Hit.min),
              color: Color.alphaBlend(c.accent.withValues(alpha: 0.12), c.surface),
              padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
              child: Row(children: [
                const CupertinoActivityIndicator(radius: 8),
                const SizedBox(width: Gap.s),
                Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.footnote.copyWith(color: c.textPrimary))),
                AppSymbolIcon(AppSymbols.chevronUp, size: 12, color: c.textMuted),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// "What the radio is doing": queued, running and finished requests, each waiting or running one cancellable.
Future<void> showRadioActivitySheet(BuildContext context, {required RemoteQueueWatch watch, required String Function(String target) nameFor}) {
  return showAppSheet<void>(
    context,
    detents: const [0.5, 0.92],
    builder: (ctx, scroll) => ListenableBuilder(
      listenable: watch,
      builder: (ctx, _) {
        final c = AppColors.of(ctx);
        final items = watch.recent;
        return AppSheetScaffold(
          controller: scroll,
          title: 'What the radio is doing',
          children: [
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.l),
                child: Text('Nothing right now. Requests to repeaters show up here while they wait for the radio.', key: const Key('activity-empty'), style: AppType.body.copyWith(color: c.textMuted)),
              )
            else
              InsetGroup(groupKey: const Key('activity-list'), rows: [for (final r in items) _ActivityRow(request: r, nameFor: nameFor, onCancel: () => watch.queue.cancel(r.id))]),
          ],
        );
      },
    ),
  );
}

class _ActivityRow extends StatelessWidget {
  final RemoteRequest request;
  final String Function(String target) nameFor;
  final VoidCallback onCancel;
  const _ActivityRow({required this.request, required this.nameFor, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final r = request;
    final secs = DateTime.now().difference(r.createdAt).inSeconds.clamp(0, 1 << 30);
    final est = r.estTimeout;
    final detail = '${requestStateWord(r.state)} · ${secs}s${est == null ? '' : ' · up to ${est.inSeconds}s'}';
    final live = !r.isFinished;
    return Container(
      key: Key('activity-${r.id}'),
      constraints: const BoxConstraints(minHeight: Hit.min),
      padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
      child: Row(children: [
        Expanded(
          child: Semantics(
            container: true,
            label: '${requestPhrase(r, nameFor)}. $detail',
            excludeSemantics: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(requestPhrase(r, nameFor), style: AppType.body.copyWith(color: c.textPrimary)),
              Text(detail, style: AppType.footnote.copyWith(color: c.textMuted)),
            ]),
          ),
        ),
        if (live)
          CupertinoButton(
            key: Key('activity-cancel-${r.id}'),
            minimumSize: const Size(Hit.min, Hit.min),
            padding: const EdgeInsets.only(left: Gap.s),
            onPressed: onCancel,
            child: Text('Cancel', style: TextStyle(color: c.danger)),
          ),
      ]),
    );
  }
}
