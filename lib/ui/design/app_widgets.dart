// Small shared widgets of the redesigns: AppSwitchTile, ChatStatusBanner, TipCard.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_haptics.dart';
import 'app_symbols.dart';
import 'tokens.dart';

bool _isApple(BuildContext context) {
  final p = Theme.of(context).platform;
  return p == TargetPlatform.iOS || p == TargetPlatform.macOS;
}

/// A settings row with a switch: title, optional subtitle, optional leading symbol, minimum height 44. The whole row
/// toggles. Cupertino switch on Apple platforms, Material switch elsewhere; a selection haptic on change.
class AppSwitchTile extends StatelessWidget {
  final AppSymbol? symbol;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Key? switchKey;
  const AppSwitchTile({
    super.key,
    this.symbol,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.switchKey,
  });

  void _set(bool v) {
    AppHaptics.selection();
    onChanged?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final enabled = onChanged != null;
    final sw = _isApple(context)
        ? CupertinoSwitch(key: switchKey, value: value, onChanged: enabled ? _set : null, activeTrackColor: t.colorScheme.primary)
        : Switch(key: switchKey, value: value, onChanged: enabled ? _set : null);
    return Semantics(
      container: true,
      toggled: value,
      enabled: enabled,
      onTap: enabled ? () => _set(!value) : null,
      label: subtitle == null ? title : '$title. $subtitle',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: enabled ? () => _set(!value) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Hit.min),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
              child: Row(
                children: [
                  if (symbol != null) ...[
                    AppSymbolIcon(symbol!, size: 22, color: t.colorScheme.primary),
                    const SizedBox(width: Gap.m),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: t.textTheme.bodyLarge),
                        if (subtitle != null)
                          Text(subtitle!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  const SizedBox(width: Gap.m),
                  sw,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum StatusBannerKind { info, warning, error }

/// The thin status strip at the top of Chat ("Radio not connected", "Reconnecting...", "Sending is paused while you
/// drive"). Minimum height 44 (grows with text), live region, optional action button. Colour is never the only cue:
/// each kind has its own symbol.
class ChatStatusBanner extends StatelessWidget {
  final StatusBannerKind kind;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  const ChatStatusBanner({super.key, this.kind = StatusBannerKind.info, required this.message, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context);
    final (sym, tint) = switch (kind) {
      StatusBannerKind.info => (AppSymbols.infoCircle, c.accent),
      StatusBannerKind.warning => (AppSymbols.exclamationTriangle, c.warning),
      StatusBannerKind.error => (AppSymbols.exclamationCircle, c.danger),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      label: message,
      child: Container(
        constraints: const BoxConstraints(minHeight: Hit.min),
        padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
        color: Color.alphaBlend(tint.withValues(alpha: 0.14), c.surface),
        child: Row(
          children: [
            AppSymbolIcon(sym, size: 20, color: tint),
            const SizedBox(width: Gap.s),
            Expanded(child: Text(message, style: t.textTheme.bodyMedium)),
            if (actionLabel != null)
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                minimumSize: const Size(Hit.min, Hit.min),
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
          ],
        ),
      ),
    );
  }
}

/// Where seen tips are remembered. The default keeps them for the session; the app can swap in a persistent one.
abstract class TipStore {
  bool seen(String id);
  void markSeen(String id);
}

class MemoryTipStore implements TipStore {
  final Set<String> _seen = {};
  @override
  bool seen(String id) => _seen.contains(id);
  @override
  void markSeen(String id) => _seen.add(id);
}

TipStore appTipStore = MemoryTipStore();

/// A one-time inline tip (D49: no overlay coach marks). Shows until dismissed, then never again for [tipId].
class TipCard extends StatefulWidget {
  final String tipId;
  final String title;
  final String message;
  final AppSymbol symbol;
  final VoidCallback? onDismissed;
  const TipCard({
    super.key,
    required this.tipId,
    required this.title,
    required this.message,
    this.symbol = AppSymbols.infoCircle,
    this.onDismissed,
  });

  @override
  State<TipCard> createState() => _TipCardState();
}

class _TipCardState extends State<TipCard> {
  late bool _hidden = appTipStore.seen(widget.tipId);

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final c = AppColors.of(context);
    final t = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
      padding: const EdgeInsets.fromLTRB(Gap.m, Gap.m, Gap.xs, Gap.m),
      decoration: BoxDecoration(
        color: c.surfaceHigh,
        borderRadius: BorderRadius.circular(Corners.card),
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: AppSymbolIcon(widget.symbol, size: 22, color: c.accent)),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title, style: t.textTheme.titleMedium),
                const SizedBox(height: Gap.xs),
                Text(widget.message, style: t.textTheme.bodyMedium),
              ],
            ),
          ),
          CupertinoButton(
            key: const Key('tip-dismiss'),
            padding: EdgeInsets.zero,
            minimumSize: const Size(Hit.min, Hit.min),
            onPressed: () {
              appTipStore.markSeen(widget.tipId);
              setState(() => _hidden = true);
              widget.onDismissed?.call();
            },
            child: Semantics(label: 'Dismiss tip', child: AppSymbolIcon(AppSymbols.xmark, size: 18, color: c.textMuted)),
          ),
        ],
      ),
    );
  }
}
