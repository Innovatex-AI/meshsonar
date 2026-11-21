// Small shared pieces of the native Network tools (Path Inspector, Trace Viewer, Prefix Tool): the page padding, the
// error line for a `/v1` failure, a node row that opens the node page, and the SNR bar. One column, 44 pt targets.
import 'package:flutter/material.dart';

import '../../../core/v1/tools_api.dart';
import '../../design/tokens.dart';
import '../../theme.dart';
import '../nodes/node_routes.dart';
import '../packets/packet_ui.dart' show snrColor;

const EdgeInsets kToolPagePadding = EdgeInsets.fromLTRB(Layout.screenMargin, Gap.m, Layout.screenMargin, Gap.xl);

/// What went wrong, as one plain sentence.
String toolErrorText(Object e) {
  if (e is V1Error) {
    if (e.offline) return 'No connection. Check your signal and try again.';
    if (e.rateLimited) return 'Too many requests just now. Wait a moment and try again.';
    return e.message;
  }
  if (e is V1NotLive) return 'This server does not have this tool yet.';
  return 'Something went wrong. Try again.';
}

/// An inline error under a form (icon and words; colour is not the only signal).
class ToolErrorLine extends StatelessWidget {
  final String text;
  const ToolErrorLine(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.s),
      child: Semantics(
        liveRegion: true,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.error_outline, size: 18, color: t.colorScheme.error),
          const SizedBox(width: Gap.xs),
          Expanded(child: Text(text, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error))),
        ]),
      ),
    );
  }
}

/// A tinted, rounded block.
class ToolCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const ToolCard({super.key, required this.child, this.padding = const EdgeInsets.all(Gap.m)});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: Gap.s),
        padding: padding,
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
        child: child,
      );
}

/// A small label in a pill ("Speculative", "Free", "Taken").
class ToolPill extends StatelessWidget {
  final String text;
  final Color? background, foreground;
  const ToolPill(this.text, {super.key, this.background, this.foreground});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: background ?? cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: foreground ?? cs.onSurfaceVariant)),
    );
  }
}

/// One hop or conflict: a leading label (the prefix), the node's name, and a trailing widget. With a node the whole
/// row opens the node page.
class ToolNodeRow extends StatelessWidget {
  final String baseUrl;
  final String? regionSlug;
  final String leading;
  final ToolNode? node;

  /// Shown instead of a name when [node] is null.
  final String missing;
  final String? detail;
  final Widget? trailing;
  const ToolNodeRow({super.key, required this.baseUrl, required this.regionSlug, required this.leading, required this.node, this.missing = 'Unknown node', this.detail, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final n = node;
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: Hit.of(context)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Row(children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44),
            child: Text(leading, style: t.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace', color: t.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(n?.label ?? missing, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge?.copyWith(color: n == null ? t.colorScheme.onSurfaceVariant : null)),
              if (detail != null) Text(detail!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: Gap.s), trailing!],
          if (n != null) Icon(Icons.chevron_right, size: 18, color: t.colorScheme.onSurfaceVariant),
        ]),
      ),
    );
    if (n == null) return Semantics(container: true, child: row);
    return Semantics(
      button: true,
      label: 'Hop $leading, ${n.label}${detail == null ? '' : ', $detail'}. Opens the node.',
      excludeSemantics: true,
      child: InkWell(onTap: () => openNetworkNode(context, baseUrl: baseUrl, regionSlug: regionSlug ?? '', nodeKey: n.key), child: row),
    );
  }
}

/// SNR as words and a short bar (-20 dB empty, +12 dB full). Null reads "No SNR".
class SnrBar extends StatelessWidget {
  final double? snrDb;
  const SnrBar(this.snrDb, {super.key});

  static String text(double? v) => v == null ? 'No SNR' : '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(1)} dB';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final v = snrDb;
    return SizedBox(
      width: 84,
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        Text(text(v), style: t.textTheme.bodyMedium),
        if (v != null) ...[
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: ((v + 20) / 32).clamp(0.04, 1.0), minHeight: 4, color: snrColor(context, v), backgroundColor: MeshSonarColors.of(context).snrWeak.withValues(alpha: 0.15)),
          ),
        ],
      ]),
    );
  }
}

/// Kilometres as the tools print them.
String kmText(double km) => km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
