// Map chips (Drive plan WP2, step 1; build 77 Round 1 F4, Round 4 section 3).
import 'package:flutter/material.dart';

import '../../design/app_symbols.dart';
import '../../design/tokens.dart' show AppColors, Hit;
import '../../theme.dart';

/// The ONE chip style on a map (build 77, Round 1 F4 and Round 4 section 3): the region chip's shape on Drive, the legend chip
/// on every map, the plan chip on Plan. 36 pt tall stadium on the surface with the outline, an optional leading icon, the label
/// and, when it opens something, a small chevron so it looks tappable. The tap area is 44 pt tall, the drawn size stays 36.
/// Key [tapKey] is on the drawn chip.
class MapChip extends StatelessWidget {
  final Widget? leading;
  final Widget label;
  final VoidCallback? onTap;
  final bool chevron;
  final Key? tapKey;
  final String? semanticsLabel;
  final bool? expanded;
  const MapChip({super.key, this.leading, required this.label, this.onTap, this.chevron = true, this.tapKey, this.semanticsLabel, this.expanded});

  static const double height = 36;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.fromTheme(Theme.of(context));
    final t = Theme.of(context);
    final chip = Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(height / 2), border: Border.all(color: c.outline)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 6)],
          Flexible(child: DefaultTextStyle.merge(style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis, child: label)),
          if (onTap != null && chevron) ...[
            const SizedBox(width: 4),
            AppSymbolIcon(AppSymbols.chevronDown, size: 11, color: c.textMuted),
          ],
        ],
      ),
    );
    if (onTap == null) return Semantics(label: semanticsLabel, child: chip);
    // The 44 pt target is real layout (4 pt above and below the drawn chip), so it works inside any slot; [tapKey] marks the
    // drawn 36 pt chip.
    return Semantics(
      button: true,
      expanded: expanded,
      label: semanticsLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: (Hit.min - height) / 2),
          child: KeyedSubtree(key: tapKey, child: ExcludeSemantics(excluding: semanticsLabel != null, child: chip)),
        ),
      ),
    );
  }
}

/// A small text pill drawn on the map (distance on a link, a heard repeater's name).
class MapTag extends StatelessWidget {
  final String text;
  final Color color;
  final bool strong;
  const MapTag({super.key, required this.text, required this.color, this.strong = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: strong ? 0.9 : 0.5), width: strong ? 1.4 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: numberStyle(
            context,
            size: 12.5,
            weight: FontWeight.w600,
            color: strong ? t.colorScheme.onSurface : t.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class MapPill extends StatelessWidget {
  final Widget child;
  const MapPill({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        // An outline and a little more room (build 76): the pill stays readable on any map colour.
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), child: child),
    );
  }
}
