// Small pieces the repeater admin screens share.
import 'package:flutter/material.dart';

import '../../../radio/repeater_health.dart';
import '../../../radio/repeater_settings.dart';
import '../../design/app_surfaces.dart';
import '../../theme.dart';
import 'admin_controller.dart';

/// "5 min ago", "2 h ago", "3 days ago" for [secs] seconds.
String agoText(int secs) {
  if (secs < 0) secs = 0;
  if (secs < 90) return '${secs}s ago';
  if (secs < 5400) return '${(secs / 60).round()} min ago';
  if (secs < 172800) return '${(secs / 3600).round()} h ago';
  return '${(secs / 86400).round()} days ago';
}

/// 149365 -> "1 d 17 h", 3600 -> "1 h 0 min".
String uptimeText(int secs) {
  final d = secs ~/ 86400, h = (secs % 86400) ~/ 3600, m = (secs % 3600) ~/ 60;
  if (d > 0) return '$d d $h h';
  if (h > 0) return '$h h $m min';
  if (m > 0) return '$m min';
  return '${secs}s';
}

String secondsText(int secs) {
  if (secs < 120) return '${secs}s';
  if (secs < 7200) return '${(secs / 60).toStringAsFixed(0)} min';
  return '${(secs / 3600).toStringAsFixed(1)} h';
}

/// "Using airtime" while a request is on the air. Always in the tree (so the layout does not jump); live region for
/// screen readers.
class AirtimeChip extends StatelessWidget {
  final bool active;
  const AirtimeChip({super.key, required this.active});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final big = MediaQuery.textScalerOf(context).scale(16) > 24;
    // Takes no room when idle (a hidden chip would still push the title around at large text sizes).
    return Semantics(
      liveRegion: true,
      label: active ? 'Using airtime' : 'Radio idle',
      excludeSemantics: true,
      child: !active
          ? const SizedBox(key: Key('airtime-chip'), width: 0, height: 0)
          : Container(
              key: const Key('airtime-chip'),
              margin: const EdgeInsets.only(right: Gap.s),
              padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 4),
              decoration: BoxDecoration(color: t.colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(Corners.chip)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.cell_tower, size: 16, color: t.colorScheme.onTertiaryContainer),
                if (!big) ...[
                  const SizedBox(width: 4),
                  Text('Using airtime', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onTertiaryContainer)),
                ],
              ]),
            ),
    );
  }
}

/// A titled card. [child] is the body.
class AdminCard extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;
  final Key? cardKey;
  const AdminCard({super.key, required this.title, required this.child, this.icon, this.trailing, this.cardKey});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: cardKey,
      margin: const EdgeInsets.symmetric(vertical: Gap.s),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (icon != null) ...[Icon(icon, size: 20, color: t.colorScheme.primary), const SizedBox(width: Gap.s)],
            Expanded(child: Semantics(header: true, child: Text(title, style: t.textTheme.titleMedium))),
            ?trailing,
          ]),
          const SizedBox(height: Gap.s),
          child,
        ]),
      ),
    );
  }
}

/// Label on one side, value on the other; stacks when there is no room (large text).
class KeyValueRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final Key? valueKey;
  const KeyValueRow(this.label, this.value, {super.key, this.valueColor, this.valueKey});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final big = MediaQuery.textScalerOf(context).scale(16) > 26;
    final l = Text(label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant));
    final v = Text(value, key: valueKey, style: t.textTheme.bodyLarge?.copyWith(color: valueColor, fontWeight: FontWeight.w600), textAlign: big ? TextAlign.start : TextAlign.end);
    return Semantics(
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: big
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [l, v])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 4, child: l), const SizedBox(width: Gap.s), Expanded(flex: 5, child: v)]),
      ),
    );
  }
}

/// A notice for one tab (an error, or a note).
class NoticeBanner extends StatelessWidget {
  final AdminNotice notice;
  final Key? bannerKey;
  const NoticeBanner(this.notice, {super.key, this.bannerKey});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final bg = notice.error ? c.errorContainer : c.secondaryContainer;
    final fg = notice.error ? c.onErrorContainer : c.onSecondaryContainer;
    return Container(
      key: bannerKey,
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(notice.error ? Icons.warning_amber_rounded : Icons.info_outline, color: fg),
        const SizedBox(width: 10),
        Expanded(child: Text(notice.text, style: TextStyle(color: fg, height: 1.3))),
      ]),
    );
  }
}

/// Severity colour + icon for a finding.
({IconData icon, Color color, String word}) severityLook(BuildContext context, Severity s) {
  final c = Theme.of(context).colorScheme;
  return switch (s) {
    Severity.ok => (icon: Icons.check_circle_outline, color: c.primary, word: 'Fine'),
    Severity.info => (icon: Icons.info_outline, color: c.onSurfaceVariant, word: 'Note'),
    Severity.warn => (icon: Icons.warning_amber_rounded, color: const Color(0xFFB26A00), word: 'Warning'),
    Severity.fail => (icon: Icons.error_outline, color: c.error, word: 'Problem'),
  };
}

String dangerWords(Danger d) => switch (d) {
      Danger.safe => 'Safe',
      Danger.reversible => 'Can be changed back',
      Danger.disruptive => 'Can cut this repeater off or hurt the mesh',
      Danger.bricking => 'Can lock you out until someone is at the repeater',
    };

IconData dangerIcon(Danger d) => switch (d) {
      Danger.safe => Icons.check_circle_outline,
      Danger.reversible => Icons.undo,
      Danger.disruptive => Icons.warning_amber_rounded,
      Danger.bricking => Icons.dangerous_outlined,
    };

Color dangerColor(BuildContext context, Danger d) {
  final c = Theme.of(context).colorScheme;
  return switch (d) {
    Danger.safe || Danger.reversible => c.onSurfaceVariant,
    Danger.disruptive => const Color(0xFFB26A00),
    Danger.bricking => c.error,
  };
}

/// Min 48 x 48 target for tappable rows and buttons.
const Size kTarget = Size(48, 48);

/// A plain "are you sure" alert that says what will happen. True when confirmed.
Future<bool> confirmAction(BuildContext context, {required String title, required String body, required String confirmLabel, bool danger = false, Key? confirmKey}) async {
  final r = await showAppAlert(
    context,
    title: title,
    message: body,
    confirmLabel: confirmLabel,
    destructive: danger,
    cancelKey: const Key('confirm-cancel'),
    confirmKey: confirmKey ?? const Key('confirm-ok'),
  );
  return r ?? false;
}

/// A sheet that asks for [phrase] to be typed before it can be confirmed. Returns the typed phrase, or null when cancelled.
Future<String?> typedConfirm(BuildContext context, {required String title, required String body, required String phrase, required String confirmLabel}) {
  return showAppSheet<String>(
    context,
    detents: const [0.6, 0.92],
    builder: (ctx, scroll) => _TypedConfirmBody(controller: scroll, title: title, body: body, phrase: phrase, confirmLabel: confirmLabel),
  );
}

class _TypedConfirmBody extends StatefulWidget {
  final ScrollController controller;
  final String title, body, phrase, confirmLabel;
  const _TypedConfirmBody({required this.controller, required this.title, required this.body, required this.phrase, required this.confirmLabel});

  @override
  State<_TypedConfirmBody> createState() => _TypedConfirmBodyState();
}

class _TypedConfirmBodyState extends State<_TypedConfirmBody> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      controller: widget.controller,
      title: widget.title,
      primaryAction: FilledButton(
        key: const Key('confirm-ok'),
        style: FilledButton.styleFrom(minimumSize: kTarget, backgroundColor: Theme.of(context).colorScheme.error),
        onPressed: _ctl.text.trim() == widget.phrase ? () => Navigator.of(context).pop(_ctl.text.trim()) : null,
        child: Text(widget.confirmLabel),
      ),
      secondaryAction: TextButton(key: const Key('confirm-cancel'), style: TextButton.styleFrom(minimumSize: kTarget), onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      children: [
        Text(widget.body),
        const SizedBox(height: Gap.m),
        Text('Type ${widget.phrase} to go on', style: const TextStyle(fontWeight: FontWeight.w700)),
        TextField(key: const Key('typed-confirm'), controller: _ctl, autocorrect: false, enableSuggestions: false, textCapitalization: TextCapitalization.characters, onChanged: (_) => setState(() {})),
      ],
    );
  }
}

void showSnack(BuildContext context, String text) => showAppToast(context, text);
