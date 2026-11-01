// A thin strip above the tab bar for the two honest states of M3: "Reconnecting to <radio>…" after the app was started
// again, and the warning that the radio's waiting-message queue was (nearly) full. Shows nothing when neither applies.
import 'package:flutter/material.dart';

import '../../alerts/alerts_runtime.dart';
import '../theme.dart';

class AlertsStatusStrip extends StatelessWidget {
  const AlertsStatusStrip({super.key});

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
              rows.add(_Row(
                key: const Key('reconnect-strip'),
                icon: active ? null : Icons.bluetooth_disabled,
                text: status,
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
            return Column(mainAxisSize: MainAxisSize.min, children: rows);
          },
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  final IconData? icon;
  final String text;
  final Widget? action;
  const _Row({super.key, required this.icon, required this.text, this.action});

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
              Expanded(child: Semantics(liveRegion: true, child: Text(text, style: TextStyle(color: cs.onSecondaryContainer)))),
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}
