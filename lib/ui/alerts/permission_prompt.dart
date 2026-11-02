// Our own explanation before the system's notification prompt. The system prompt can be shown only once on iOS, so it is
// never fired cold: it follows a Continue here, at a moment the person chose (first message sent, first channel joined,
// the switch in Settings). Never at launch.
import 'package:flutter/material.dart';

import '../../alerts/alert_coordinator.dart';
import '../../alerts/alerts_runtime.dart';
import '../design/app_surfaces.dart' show showAppSheet;
import '../design/sheet_detents.dart';
import '../theme.dart' show Gap;

const String alertsPrePromptTitle = 'Get an alert when a message arrives?';
const String alertsPrePromptBody = 'MeshSonar can show a notification when your radio receives a message. Messages stay on this phone: '
    'there is no server and nothing is sent to anyone.\n\n'
    'Alerts only come while your radio is connected, and iOS may pause MeshSonar in the background. '
    'The next screen is the system\'s own question.';

/// Shows the explanation, then (on Continue) the system prompt. Returns what happened, or null when alerts are not
/// available in this build.
Future<PermissionOutcome?> askForNotifications(BuildContext context, {bool force = false, bool userInitiated = true}) async {
  final rt = AlertsHost.runtime.value;
  if (rt == null) return null;
  return rt.coordinator.requestIfNeeded(
    force: force,
    prePrompt: () async {
      if (!context.mounted) return false;
      final yes = await showAppSheet<bool>(
        context,
        detents: formSheetDetents(context),
        userInitiated: userInitiated,
        builder: (c, controller) => Column(
          key: const Key('alerts-preprompt'),
          children: [
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, Gap.m),
                children: [
                  Semantics(header: true, child: Text(alertsPrePromptTitle, style: Theme.of(c).textTheme.titleLarge)),
                  const SizedBox(height: Gap.m),
                  const Text(alertsPrePromptBody),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l + MediaQuery.viewPaddingOf(c).bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(key: const Key('alerts-preprompt-yes'), onPressed: () => Navigator.pop(c, true), child: const Text('Continue')),
                  const SizedBox(height: Gap.xs),
                  TextButton(key: const Key('alerts-preprompt-no'), onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
                ],
              ),
            ),
          ],
        ),
      );
      return yes == true;
    },
  );
}

/// For the chat composer and the join-channel flow: call after the person's first send / first join. Does nothing unless
/// it is the right moment (alerts on, never asked, explanation not yet waved away).
Future<void> offerAlertsAfterFirstAction(BuildContext context) async {
  final rt = AlertsHost.runtime.value;
  if (rt == null || !rt.coordinator.shouldOfferPrePrompt) return;
  // Raised by the app after the person's first send / join, not by a tap on this prompt: held while driving.
  await askForNotifications(context, userInitiated: false);
}
