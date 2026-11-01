// A list row for conversations, channels and contacts. Unlike ListTile it never fails when the text is huge: at large text
// sizes the time stamp is dropped (the unread badge stays) and the title and preview get all the width.
import 'package:flutter/material.dart';

import '../theme.dart';

class ChatRow extends StatelessWidget {
  final Widget leading;
  final Widget title;
  final Widget subtitle;
  final String? stamp;
  final Widget? badge;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? below;
  const ChatRow({super.key, required this.leading, required this.title, required this.subtitle, this.stamp, this.badge, this.onTap, this.onLongPress, this.below});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final big = MediaQuery.textScalerOf(context).scale(10) > 16;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              leading,
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DefaultTextStyle.merge(style: t.textTheme.titleMedium, child: title),
                    DefaultTextStyle.merge(style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant), child: subtitle),
                    ?below,
                  ],
                ),
              ),
              if ((stamp != null && stamp!.isNotEmpty && !big) || badge != null) ...[
                const SizedBox(width: Gap.s),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (stamp != null && stamp!.isNotEmpty && !big) Text(stamp!, style: t.textTheme.labelSmall),
                    if (badge != null) Padding(padding: const EdgeInsets.only(top: 2), child: badge),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
