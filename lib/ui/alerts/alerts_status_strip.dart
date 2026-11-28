// A thin strip above the tab bar for the two honest states of M3: "Reconnecting to <radio>…" after the app was started
// again, and the warning that the radio's waiting-message queue was (nearly) full. Shows nothing when neither applies.
//
// The radio row's icon, spinner and first words are the shared ones (lib/ui/drive/radio_link_status.dart, rule 7 of the map
// panel rules): "Reconnecting…" with the spinner while it works, "Not connected" with the Dock's glyph when it gave up. The
// radio's name, or the sentence that says why, follows as the detail.
//
// The Drive tab (build 76): its Dock already says Reconnecting… / Not connected with the one action, so the radio row is not
// shown there ([AlertsStatusStrip.radioRow] false): one message, not two. The waiting-message warning still shows there, and
// [AlertsStripSeat] makes the Drive page end at the top of the strip, so the Drive panel rests on it. Before that the page
// kept the tab bar's height as bottom padding while the strip took that room away from it: the panel hung a tab bar's height
// above the strip with the map showing underneath ("the floating panel", iPhone bug report).
//
// Build 77 (round 5 R1): the radio row never shows while a radio is connected (connecting by hand used to leave "Not
// connected" up), and "Not connected" has Dismiss beside Reconnect.
import 'package:flutter/material.dart';

import '../../alerts/alerts_runtime.dart';
import '../app.dart' show AppScope;
import '../drive/radio_link_status.dart';
import '../theme.dart';

/// The strip's buttons are full 44 pt targets (a bare TextButton is 36 pt tall here).
final ButtonStyle _actionStyle = TextButton.styleFrom(minimumSize: const Size(64, 44), tapTargetSize: MaterialTapTargetSize.padded);

class AlertsStatusStrip extends StatelessWidget {
  /// Space kept under the strip when it shows (the Drive tab runs behind the tab bar, so the strip clears it).
  final double bottomInset;

  /// Show the radio row ("Reconnecting…" / "Not connected … Reconnect"). False on the Drive tab, whose Dock says it.
  final bool radioRow;
  const AlertsStatusStrip({super.key, this.bottomInset = 0, this.radioRow = true});

  /// True when the strip shows something on the Drive tab (only the waiting-message warning does).
  static bool showsOnDrive(AlertsRuntime? rt) => rt?.queue.message != null;

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
            final connected = AppScope.maybeOf(context)?.connected ?? false;
            if (radioRow && reconnect != null && status != null && !connected) {
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
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        TextButton(key: const Key('reconnect-now'), style: _actionStyle, onPressed: () => reconnect.run(reason: 'button'), child: const Text('Reconnect')),
                        // An X, not a second word button: the reason keeps its room on a narrow phone.
                        IconButton(
                          key: const Key('reconnect-dismiss'),
                          tooltip: 'Dismiss',
                          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                          color: Theme.of(context).colorScheme.onSecondaryContainer,
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: reconnect.dismiss,
                        ),
                      ]),
              ));
            }
            final q = rt.queue.message;
            if (q != null) {
              rows.add(_Row(
                key: const Key('queue-strip'),
                icon: Icons.warning_amber_rounded,
                warning: true,
                text: q,
                action: TextButton(key: const Key('queue-dismiss'), style: _actionStyle, onPressed: rt.queue.dismiss, child: const Text('Dismiss')),
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

/// Wraps the Drive page. While the strip shows on the Drive tab the page no longer runs behind the tab bar (the strip sits
/// between them), so the page is told it has no bottom inset: the Drive panel then rests directly on the strip. The widget
/// tree keeps one shape in both cases, so the page's state is never rebuilt.
class AlertsStripSeat extends StatelessWidget {
  final Widget child;
  const AlertsStripSeat({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AlertsRuntime?>(
      valueListenable: AlertsHost.runtime,
      child: child,
      builder: (context, rt, child) => ListenableBuilder(
        listenable: Listenable.merge([rt?.queue]),
        child: child,
        builder: (context, child) {
          final mq = MediaQuery.of(context);
          final seated = AlertsStatusStrip.showsOnDrive(rt);
          return MediaQuery(
            data: seated ? mq.copyWith(padding: mq.padding.copyWith(bottom: 0), viewPadding: mq.viewPadding.copyWith(bottom: 0)) : mq,
            child: child!,
          );
        },
      ),
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

  /// A warning row: its icon takes the warning colour so it does not read as one more status line.
  final bool warning;
  const _Row({super.key, required this.icon, required this.text, this.title, this.semantics, this.action, this.warning = false});

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
                Icon(icon, size: 20, color: warning ? cs.error : cs.onSecondaryContainer),
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
                    // Two lines at most: a long reason must not push the tab bar's neighbours up the screen.
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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
