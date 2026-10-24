// First-run disclosure for data sharing (on by default, opt-out). Plain language; both choices are equally visible.
// Every word comes from lib/ui/settings/data_sharing.dart, the same source Settings > Privacy & data sharing uses.
import 'package:flutter/material.dart';

import 'app.dart';
import 'onboarding/ui_prefs.dart';
import 'settings/data_sharing.dart';

export 'settings/data_sharing.dart' show telemetryHelp;

Future<void> showTelemetryDisclosure(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    builder: (_) => const _TelemetrySheet(),
  );
}

class _TelemetrySheet extends StatelessWidget {
  const _TelemetrySheet();

  Future<void> _choose(BuildContext context, bool share) async {
    final s = AppScope.read(context);
    final prefs = uiPrefsFor(s);
    Navigator.of(context).pop();
    var next = s.settings;
    for (final c in dataCategories) {
      if (c.isOn(next) != share) next = c.set(next, share);
    }
    if (!identical(next, s.settings)) await s.updateSettings(next);
    await prefs.markTelemetryDisclosed();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final single = dataCategories.length == 1 ? dataCategories.single : null;
    Widget bullet(IconData i, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(i, size: 20, color: t.colorScheme.primary),
          const SizedBox(width: Gap.m),
          Expanded(child: Text(text, style: t.textTheme.bodyLarge)),
        ],
      ),
    );
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: Gap.m, bottom: Gap.xs),
      child: Text(text, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
    );
    // The two choices stay pinned under the scrolling text, so both are always on screen whatever the text size.
    return Column(
      key: const Key('telemetry-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(single?.disclosureTitle ?? 'What MeshSonar shares', style: t.textTheme.headlineSmall),
                for (final c in dataCategories) ...[
                  if (single == null) label(c.title),
                  const SizedBox(height: Gap.s),
                  Text(c.disclosureLead, style: t.textTheme.bodyLarge),
                  label('Shared'),
                  for (final x in c.shared) bullet(Icons.check, x),
                  label('Never shared'),
                  for (final x in c.neverShared) bullet(Icons.block, x),
                  const SizedBox(height: Gap.s),
                  Text(c.destination, style: t.textTheme.bodyMedium),
                ],
                const SizedBox(height: Gap.s),
                bullet(Icons.toggle_on_outlined, changeYourMindLine),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                key: const Key('telemetry-keep'),
                onPressed: () => _choose(context, true),
                child: Text(single?.keepLabel ?? 'Keep sharing on'),
              ),
              const SizedBox(height: Gap.s),
              OutlinedButton(
                key: const Key('telemetry-off'),
                onPressed: () => _choose(context, false),
                child: Text(single?.offLabel ?? 'Turn all off'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
