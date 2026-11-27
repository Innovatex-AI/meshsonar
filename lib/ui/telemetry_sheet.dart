// First-run disclosure of everything MeshSonar collects (version 3, release 0.38: the phone is an observer whenever a radio
// is connected and the app is open; version 2 was stream 7's): one block per category with its own
// switch, all on unless the person turns them off (opt-out, Andy Oct 2026), and two equally weighted choices,
// "Continue" (keeps the switches as set) and "Turn all off". Every existing user sees it once; nothing of the
// drive-context categories is collected before it has been seen (AppState.collectionOn).
// Every word comes from lib/ui/settings/data_sharing.dart (and its core list, lib/core/data_categories.dart), the same
// source Settings > Privacy & data sharing uses.
// Build 77 (round 5 O1): on a first run it is the last page of the intro ([CollectionDisclosure] with onDone), answered
// before the intro closes, so Connect radio no longer opens it, the Connect screen and the Bluetooth question at once.
// The sheet stays for a phone that saw the intro in an older build and never answered it.
import 'package:flutter/material.dart';

import '../core/data_categories.dart' show savedWithDriveNote;
import '../core/phone_sensors.dart' show phoneTemperatureNote;
import 'app.dart';
import 'design/app_surfaces.dart' show showAppSheet;
import 'design/sheet_detents.dart' show kFormSheetFull;
import 'onboarding/ui_prefs.dart';
import 'settings/data_sharing.dart';

export 'settings/data_sharing.dart' show telemetryHelp;

/// Sheet heading.
const String disclosureHeading = 'What MeshSonar collects';

/// Under the heading.
const String disclosureLead = 'Everything below is on unless you turn it off here or later. No direct messages, no '
    'private channels, never your exact position outside a drive, and nothing about other apps, ever.';

Future<void> showTelemetryDisclosure(BuildContext context) {
  // Raised by the phone on first run: the drive guard holds it while a drive is active. Only the two buttons close it.
  return showAppSheet<void>(
    context,
    detents: const [kFormSheetFull],
    dismissible: false,
    grabber: false,
    userInitiated: false,
    builder: (_, _) => const CollectionDisclosure(),
  );
}

/// The disclosure itself: the categories with their switches and the two choices. In the sheet ([onDone] null) a choice
/// closes the sheet; as the intro's last page, [onDone] runs once the choice is saved.
class CollectionDisclosure extends StatefulWidget {
  final VoidCallback? onDone;
  const CollectionDisclosure({super.key, this.onDone});

  @override
  State<CollectionDisclosure> createState() => _CollectionDisclosureState();
}

class _CollectionDisclosureState extends State<CollectionDisclosure> {
  Map<String, bool>? _on;
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Map<String, bool> _state(BuildContext context) {
    final s = AppScope.read(context);
    return _on ??= {for (final c in dataCategories) c.id: c.isOn(s.settings)};
  }

  Future<void> _choose(BuildContext context, {required bool allOff}) async {
    final s = AppScope.read(context);
    final prefs = uiPrefsFor(s);
    final chosen = _state(context);
    final done = widget.onDone;
    if (done == null) Navigator.of(context).pop();
    var next = s.settings;
    for (final c in dataCategories) {
      final want = allOff ? false : (chosen[c.id] ?? true);
      if (c.isOn(next) != want) next = c.set(next, want);
    }
    if (!identical(next, s.settings)) await s.updateSettings(next);
    await prefs.markTelemetryDisclosed();
    s.noteCollectionDisclosed();
    done?.call();
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
      // Build 76 (layout only, every word unchanged): each category is its own card, and the whole title row flips its
      // switch (it was the 51 pt switch alone).
      return Container(
        margin: const EdgeInsets.only(top: Gap.m),
        padding: const EdgeInsets.fromLTRB(Gap.m, Gap.xs, Gap.m, Gap.m),
        decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          MergeSemantics(
            child: InkWell(
              key: Key('disclosure-row-${c.id}'),
              borderRadius: BorderRadius.circular(Corners.small),
              onTap: () => setState(() => on[c.id] = !(on[c.id] ?? true)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(children: [
                  Expanded(child: Text(c.title, style: t.textTheme.titleMedium)),
                  Switch(
                    key: Key('disclosure-switch-${c.id}'),
                    value: on[c.id] ?? true,
                    onChanged: (v) => setState(() => on[c.id] = v),
                  ),
                ]),
              ),
            ),
          ),
          if (full) ...[
            Text(c.disclosureLead, style: t.textTheme.bodyMedium),
            label('Shared'),
            for (final x in c.shared) bullet(Icons.check, x),
            label('Never shared'),
            for (final x in c.neverShared) bullet(Icons.block, x),
            const SizedBox(height: Gap.xs),
            Text(c.destination, style: t.textTheme.bodySmall),
          ] else ...[
            Text(c.summary, style: t.textTheme.bodyMedium),
            // Where it goes with the server the app uploads to right now (or that this is not known yet).
            if (c.isDriveContext)
              Text(contextDestinationLine(AppScope.read(context)),
                  key: Key('disclosure-destination-${c.id}'), style: t.textTheme.bodySmall),
          ],
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
          // A scrollbar that is always there says the text goes on below the fold (build 76).
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
            controller: _scroll,
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
        ),
        // A line between the text and the two pinned choices, both 52 pt tall and equal in weight.
        Divider(height: 1, color: t.colorScheme.outlineVariant),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                key: const Key('telemetry-keep'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: () => _choose(context, allOff: false),
                child: const Text('Continue'),
              ),
              const SizedBox(height: Gap.s),
              OutlinedButton(
                key: const Key('telemetry-off'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
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
