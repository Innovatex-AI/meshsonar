// Location state in plain language (Stream 4): permission not asked / denied / denied for good / restricted /
// approximate / services off, each with its one action, plus "Choose region" so the app is usable without location.
// The app still opens on the last region in every one of these states. Nothing here prompts on its own: the system
// question only appears after the person taps "Allow location".
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import 'region/region_switcher.dart';
import 'theme.dart';

class LocationNoteBanner extends StatelessWidget {
  final AppState state;
  const LocationNoteBanner({super.key = const Key('location-note'), required this.state});

  @override
  Widget build(BuildContext context) {
    final note = state.locationNote;
    if (note == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(Corners.small),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.s, Gap.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.location_off_outlined, size: 20, color: t.colorScheme.onSurfaceVariant),
                const SizedBox(width: Gap.s),
                Expanded(child: Text(note.message, key: const Key('location-note-text'), style: t.textTheme.bodyMedium)),
              ],
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Gap.xs,
              children: [
                if (note.offerRegionPicker && state.regionIndex.isNotEmpty)
                  TextButton(
                    key: const Key('location-note-pick-region'),
                    onPressed: () => unawaited(showRegionSwitcher(context)),
                    child: const Text('Choose region'),
                  ),
                if (note.actionLabel != null)
                  TextButton(
                    key: const Key('location-note-action'),
                    onPressed: () => unawaited(state.resolveLocationNote()),
                    child: Text(note.actionLabel!),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "Last known location, 2 d ago": shown on a map while the position it opened on is not a live fix.
class PhoneFixNoteChip extends StatelessWidget {
  final AppState state;
  const PhoneFixNoteChip({super.key = const Key('phone-fix-note'), required this.state});

  @override
  Widget build(BuildContext context) {
    final text = state.phoneFixNote;
    if (text == null || state.driving) return const SizedBox.shrink();
    return Chip(
      avatar: const Icon(Icons.history, size: 16),
      label: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      visualDensity: VisualDensity.compact,
    );
  }
}
