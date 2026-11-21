// A thin strip above the tab bar for the two honest states of M3: "Reconnecting to <radio>…" after the app was started
// again, and the warning that the radio's waiting-message queue was (nearly) full. Shows nothing when neither applies.
//
// The radio row's icon, spinner and first words are the shared ones (lib/ui/drive/radio_link_status.dart, rule 7 of the map
// panel rules): "Reconnecting…" with the spinner while it works, "Not connected" with the Dock's glyph when it gave up. The
// radio's name, or the sentence that says why, follows as the detail.
import 'package:flutter/material.dart';

import '../../alerts/alerts_runtime.dart';
import '../drive/radio_link_status.dart';
import '../theme.dart';

class AlertsStatusStrip extends StatelessWidget {
  /// Space kept under the strip when it shows (the Drive tab runs behind the tab bar, so the strip clears it).
  final double bottomInset;
  const AlertsStatusStrip({super.key, this.bottomInset = 0});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AlertsRuntime?>(
      valueListenable: AlertsHost.runtime,
      builder: (context, rt, _) {
        if (rt == null) return const SizedBox.shrink();
        final reconnect = rt.reconnect;
        return ListenableBuilder(
          listenable: Listenable.merge([rt.queue, ?reconnect]),
          builder: (context, _) {
            final rows = <Widget>[];
            final status = reconnect?.statusText;
            if (reconnect != null && status != null) {
              final active = reconnect.active;
              final link = RadioLinkStatus(active ? RadioLink.reconnecting : RadioLink.notConnected);
              rows.add(_Row(
                key: const Key('reconnect-strip'),
                icon: link.icon,
                title: link.statusLabel,
                text: active ? (reconnect.radioName ?? 'your radio') : status,
                semantics: status,
                action: active
                    ? null
                    : TextButton(key: const Key('reconnect-now'), onPressed: () => reconnect.run(reason: 'button'), child: const Text('Reconnect')),
              ));
            }
            final q = rt.queue.message;
            if (q != null) {
              rows.add(_Row(
                key: const Key('queue-strip'),
                icon: Icons.warning_amber_rounded,
                text: q,
                action: TextButton(key: const Key('queue-dismiss'), onPressed: rt.queue.dismiss, child: const Text('Dismiss')),
              ));
            }
            if (rows.isEmpty) return const SizedBox.shrink();
            return Padding(padding: EdgeInsets.only(bottom: bottomInset), child: Column(mainAxisSize: MainAxisSize.min, children: rows));
          },
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  /// null = the spinner (a working state).
  final IconData? icon;

  /// The shared status words, shown first and bold; null = [text] alone.
  final String? title;
  final String text;

  /// What VoiceOver reads instead of title + text.
  final String? semantics;
  final Widget? action;
  const _Row({super.key, required this.icon, required this.text, this.title, this.semantics, this.action});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.secondaryContainer,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
          child: Row(
            children: [
              if (icon == null)
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(icon, size: 20, color: cs.onSecondaryContainer),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  label: semantics,
                  excludeSemantics: semantics != null,
                  child: Text.rich(
                    TextSpan(children: [
                      if (title != null) TextSpan(text: '$title  ', style: const TextStyle(fontWeight: FontWeight.w700)),
                      TextSpan(text: text),
                    ]),
                    style: TextStyle(color: cs.onSecondaryContainer),
                  ),
                ),
              ),
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}
