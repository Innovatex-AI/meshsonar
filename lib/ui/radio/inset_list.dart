// Grouped inset list pieces for the Device settings screen (chat plan 4.14): a small uppercase header, a rounded surface
// holding rows separated by hairlines, an optional footer line. Rows are at least 44 pt tall, the whole row is the target.
import 'package:flutter/material.dart';

import '../design/app_symbols.dart';
import '../design/tokens.dart';

class InsetGroup extends StatelessWidget {
  final String? header;
  final String? footer;
  final List<Widget> rows;
  final Key? groupKey;
  const InsetGroup({super.key, this.header, this.footer, required this.rows, this.groupKey});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    if (rows.isEmpty) return const SizedBox.shrink();
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) children.add(Container(height: 0.5, margin: const EdgeInsets.only(left: Layout.screenMargin), color: c.outlineVariant));
      children.add(rows[i]);
    }
    return Padding(
      key: groupKey,
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Layout.sectionGap - 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xs + 2),
            child: Semantics(
              header: true,
              child: Text(header!.toUpperCase(), style: t.textTheme.labelMedium?.copyWith(color: c.onSurfaceVariant, letterSpacing: 0.4)),
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(Corners.chip),
          child: Material(color: c.surfaceContainerHigh, child: Column(children: children)),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs + 2, Gap.l, 0),
            child: Text(footer!, style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
          ),
      ]),
    );
  }
}

class InsetRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? value;
  final VoidCallback? onTap;
  final bool destructive;
  final bool chevron;
  final Widget? trailing;
  const InsetRow({super.key, required this.title, this.subtitle, this.value, this.onTap, this.destructive = false, this.chevron = true, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final color = destructive ? c.error : c.onSurface;
    final body = ConstrainedBox(
      constraints: BoxConstraints(minHeight: Hit.of(context)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s + 2),
        child: Row(children: [
          Expanded(
            flex: 3,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.textTheme.bodyLarge?.copyWith(color: color)),
              if (subtitle != null) Text(subtitle!, style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
            ]),
          ),
          if (value != null) ...[
            const SizedBox(width: Gap.m),
            Flexible(flex: 2, child: Text(value!, textAlign: TextAlign.end, style: t.textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant))),
          ],
          ?trailing,
          if (onTap != null && chevron && trailing == null) ...[
            const SizedBox(width: Gap.xs),
            AppSymbolIcon(AppSymbols.chevronRight, size: 16, color: c.onSurfaceVariant),
          ],
        ]),
      ),
    );
    if (onTap == null) return Semantics(container: true, child: body);
    return Semantics(button: true, label: value == null ? title : '$title, $value', excludeSemantics: true, onTap: onTap, child: InkWell(onTap: onTap, child: body));
  }
}
