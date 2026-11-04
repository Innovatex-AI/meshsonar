// The conversation subtitle of a direct message (chat plan 4.2): "Direct", "Via 2 repeaters", "Searching" or "No route yet",
// plus the signal word of the last message heard from them. Plain text, not a tap target. Replaces the 48-60 dp
// dm_route_header strip.
import 'package:flutter/material.dart';

import '../../chat/message_info.dart';
import '../../chat/models.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';

class DmRouteText extends StatelessWidget {
  final Contact? contact;

  /// SNR of the newest message heard from them (null = none yet).
  final double? lastSnr;
  const DmRouteText({super.key, required this.contact, this.lastSnr});

  static String textFor(Contact? contact, double? lastSnr) {
    final route = dmRouteText(contact);
    return lastSnr == null ? route : '$route · ${signalWord(lastSnr)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Text(textFor(contact, lastSnr), key: const Key('dm-route-text'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.footnote.copyWith(color: c.textMuted));
  }
}
