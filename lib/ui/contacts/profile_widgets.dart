// Building blocks of the contact profile: the inset-grouped card, its rows, the quick-action tile grid and the middle
// ellipsis for keys. No Material list widgets (the chat lint bans them); everything is plain layout over the shared tokens.
import 'package:flutter/material.dart';

import '../design/app_haptics.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import 'profile_tiles.dart';

/// "a1b2c3d4…9f12ab34": the start and end of [key], so two keys can be told apart without 64 characters of noise.
String middleEllipsis(String key, {int head = 8, int tail = 8}) =>
    key.length <= head + tail + 1 ? key : '${key.substring(0, head)}…${key.substring(key.length - tail)}';

/// Monospace for keys and coordinates (SF Mono on Apple platforms through Menlo's family fallback).
const TextStyle monoStyle = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['SF Mono', 'Courier', 'monospace'], fontSize: 15);

/// One inset-grouped card: rounded 20, `surfaceHigh`, hairline between rows.
class ProfileGroup extends StatelessWidget {
  final List<Widget> rows;
  final String? footer;
  const ProfileGroup({super.key, required this.rows, this.footer});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final kids = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) kids.add(Container(height: 0.5, margin: const EdgeInsets.only(left: Layout.screenMargin), color: c.outline.withValues(alpha: 0.35)));
      kids.add(rows[i]);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Corners.card),
          child: ColoredBox(color: c.surfaceHigh, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: kids)),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, 0),
            child: Text(footer!, style: AppType.footnote.copyWith(color: c.textMuted)),
          ),
      ]),
    );
  }
}

/// A label with a value; tappable rows get a chevron. Wraps instead of truncating at large text.
class ProfileRow extends StatelessWidget {
  final String label;
  final String? value;
  final Widget? valueWidget;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool chevron;
  final bool destructive;
  final String? semanticsLabel;
  const ProfileRow({
    super.key,
    required this.label,
    this.value,
    this.valueWidget,
    this.onTap,
    this.onLongPress,
    this.chevron = false,
    this.destructive = false,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Hit.minAndroid),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s + 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (value == null && valueWidget == null)
            Expanded(child: Text(label, style: AppType.body.copyWith(color: destructive ? c.danger : c.textPrimary)))
          else ...[
            Flexible(child: Text(label, style: AppType.body.copyWith(color: destructive ? c.danger : c.textPrimary))),
            const SizedBox(width: Gap.m),
            Flexible(
              flex: 2,
              child: Align(
                alignment: Alignment.centerRight,
                child: valueWidget ?? Text(value!, textAlign: TextAlign.end, style: AppType.body.copyWith(color: c.textMuted)),
              ),
            ),
          ],
          if (chevron) ...[const SizedBox(width: Gap.xs), AppSymbolIcon(AppSymbols.chevronRight, size: 14, color: c.textMuted)],
        ]),
      ),
    );
    if (onTap == null && onLongPress == null) {
      return Semantics(container: true, label: semanticsLabel ?? (value == null ? label : '$label, $value'), child: ExcludeSemantics(child: body));
    }
    return Semantics(
      button: true,
      label: semanticsLabel ?? (value == null ? label : '$label, $value'),
      onTap: onTap,
      onLongPress: onLongPress,
      child: ExcludeSemantics(
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, onLongPress: onLongPress, child: body),
      ),
    );
  }
}

/// The quick-action tile row. Width = (available - gaps) / count, never below 72, so four tiles fit 375 pt; from 1.5x text
/// (or when 72 does not fit) the tiles wrap into rows of two. Each tile is at least 72 high and grows with its label.
class ProfileTileGrid extends StatelessWidget {
  final List<ProfileTile> tiles;
  final void Function(ProfileTile) onTap;
  const ProfileTileGrid({super.key, required this.tiles, required this.onTap});

  static const double minTile = 72;
  static const double gap = Gap.s;

  /// Tiles per row for [available] width, [count] tiles and text scale [scale].
  static int columnsFor(double available, int count, double scale) {
    if (count == 0) return 1;
    var cols = scale >= 1.5 ? (count < 2 ? count : 2) : count;
    while (cols > 1 && (available - gap * (cols - 1)) / cols < minTile) {
      cols--;
    }
    return cols;
  }

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();
    final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.m),
      child: LayoutBuilder(builder: (context, box) {
        final cols = columnsFor(box.maxWidth, tiles.length, scale);
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          key: const Key('profile-tiles'),
          spacing: gap,
          runSpacing: gap,
          children: [for (final t in tiles) SizedBox(width: w, child: _TileButton(tile: t, onTap: () => onTap(t)))],
        );
      }),
    );
  }
}

class _TileButton extends StatefulWidget {
  final ProfileTile tile;
  final VoidCallback onTap;
  const _TileButton({required this.tile, required this.onTap});
  @override
  State<_TileButton> createState() => _TileButtonState();
}

class _TileButtonState extends State<_TileButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = widget.tile;
    final label = t.enabled ? t.label : '${t.label}, unavailable. ${t.reason ?? ''}';
    return Semantics(
      button: true,
      enabled: t.enabled,
      label: label,
      onTap: widget.onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          key: Key('tile-${t.id.name}'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: () {
            AppHaptics.selection();
            widget.onTap();
          },
          child: Opacity(
            opacity: !t.enabled ? 0.4 : (_down ? 0.6 : 1),
            child: Container(
              constraints: const BoxConstraints(minHeight: ProfileTileGrid.minTile),
              padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.s),
              decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(16)),
              child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                AppSymbolIcon(t.symbol, size: 24, color: c.accent, scaleWithText: false),
                const SizedBox(height: 4),
                Text(t.label, textAlign: TextAlign.center, softWrap: true, style: AppType.footnote.copyWith(color: c.textPrimary)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
