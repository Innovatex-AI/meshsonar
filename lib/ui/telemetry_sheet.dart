// First-run disclosure of everything MeshSonar collects (version 2, stream 7): one block per category with its own
// switch, all on unless the person turns them off (opt-out, Andy Oct 2026), and two equally weighted choices,
// "Continue" (keeps the switches as set) and "Turn all off". Every existing user sees it once; nothing of the
// drive-context categories is collected before it has been seen (AppState.collectionOn).
// Every word comes from lib/ui/settings/data_sharing.dart (and its core list, lib/core/data_categories.dart), the same
// source Settings > Privacy & data sharing uses.
import 'package:flutter/material.dart';

import '../core/data_categories.dart' show savedWithDriveNote;
import '../core/phone_sensors.dart' show phoneTemperatureNote;
import 'app.dart';
import 'onboarding/ui_prefs.dart';
import 'settings/data_sharing.dart';

export 'settings/data_sharing.dart' show telemetryHelp;

/// Sheet heading.
const String disclosureHeading = 'What MeshSonar collects';

/// Under the heading.
const String disclosureLead = 'Everything below is on unless you turn it off here or later. No message text, no '
    'private messages, and nothing about other apps, ever.';

Future<void> showTelemetryDisclosure(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    builder: (_) => const _CollectionSheet(),
  );
}

class _CollectionSheet extends StatefulWidget {
  const _CollectionSheet();

  @override
  State<_CollectionSheet> createState() => _CollectionSheetState();
}

class _CollectionSheetState extends State<_CollectionSheet> {
  Map<String, bool>? _on;

  Map<String, bool> _state(BuildContext context) {
    final s = AppScope.read(context);
    return _on ??= {for (final c in dataCategories) c.id: c.isOn(s.settings)};
  }

  Future<void> _choose(BuildContext context, {required bool allOff}) async {
    final s = AppScope.read(context);
    final prefs = uiPrefsFor(s);
    final chosen = _state(context);
    Navigator.of(context).pop();
    var next = s.settings;
    for (final c in dataCategories) {
      final want = allOff ? false : (chosen[c.id] ?? true);
      if (c.isOn(next) != want) next = c.set(next, want);
    }
    if (!identical(next, s.settings)) await s.updateSettings(next);
    await prefs.markTelemetryDisclosed();
    s.noteCollectionDisclosed();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final on = _state(context);
    Widget bullet(IconData i, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(i, size: 18, color: t.colorScheme.primary),
              const SizedBox(width: Gap.m),
              Expanded(child: Text(text, style: t.textTheme.bodyMedium)),
            ],
          ),
        );
    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(top: Gap.s, bottom: 2),
          child: Text(text, style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
        );
    Widget block(DataCategory c) {
      final full = c.eraseFromServer != null; // shared off the phone today: every item listed here
      return Padding(
        padding: const EdgeInsets.only(top: Gap.m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          MergeSemantics(
            child: Row(children: [
              Expanded(child: Text(c.title, style: t.textTheme.titleMedium)),
              Switch(
                key: Key('disclosure-switch-${c.id}'),
                value: on[c.id] ?? true,
                onChanged: (v) => setState(() => on[c.id] = v),
              ),
            ]),
          ),
          if (full) ...[
            Text(c.disclosureLead, style: t.textTheme.bodyMedium),
            label('Shared'),
            for (final x in c.shared) bullet(Icons.check, x),
            label('Never shared'),
            for (final x in c.neverShared) bullet(Icons.block, x),
            const SizedBox(height: Gap.xs),
            Text(c.destination, style: t.textTheme.bodySmall),
          ] else
            Text(c.summary, style: t.textTheme.bodyMedium),
        ]),
      );
    }

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
                Semantics(header: true, child: Text(disclosureHeading, style: t.textTheme.headlineSmall)),
                const SizedBox(height: Gap.s),
                Text(disclosureLead, style: t.textTheme.bodyLarge),
                for (final c in dataCategories) block(c),
                const SizedBox(height: Gap.m),
                Text(savedWithDriveNote, key: const Key('disclosure-saved-note'), style: t.textTheme.bodySmall),
                const SizedBox(height: Gap.s),
                Text(phoneTemperatureNote, style: t.textTheme.bodySmall),
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
                onPressed: () => _choose(context, allOff: false),
                child: const Text('Continue'),
              ),
              const SizedBox(height: Gap.s),
              OutlinedButton(
                key: const Key('telemetry-off'),
                onPressed: () => _choose(context, allOff: true),
                child: const Text('Turn all off'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
