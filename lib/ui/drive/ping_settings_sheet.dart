// Quick access to the ping settings from the Map tab: a chip that says what the drive is doing ("Ping 30 s / 100 m") and a
// sheet with the same three sliders as More > Settings > Wardriving (interval, minimum distance, listen window). Changes
// save at once and, mid-drive, reach the engine at once (AppState._applyPingCadence).
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../app.dart';
import '../settings/wardriving_section.dart' show pingCadenceTiles;
import '../settings_screen.dart' show SettingsScreen;

/// "Ping 30 s / 100 m": what the next drive (or this one) pings by. Opens [showPingSettingsSheet].
class PingSettingsChip extends StatelessWidget {
  final AppState state;
  const PingSettingsChip({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final st = s.settings;
    final String text;
    if (st.discoveryMode) {
      text = 'Listen only';
    } else if (s.pingsPaused) {
      text = 'Pings paused';
    } else {
      text = 'Ping ${st.intervalSec} s / ${s.units.shortLength(st.minDistanceM.toDouble())}';
    }
    return ActionChip(
      key: const Key('ping-settings-chip'),
      tooltip: 'Ping interval, distance and listen window',
      avatar: Icon(Icons.tune_rounded, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
      label: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      onPressed: () => showPingSettingsSheet(context),
    );
  }
}

Future<void> showPingSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const _PingSettingsSheet(),
  );
}

class _PingSettingsSheet extends StatelessWidget {
  const _PingSettingsSheet();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = AppScope.of(context);
    return SingleChildScrollView(
      key: const Key('ping-settings-sheet'),
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('Ping settings', style: t.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              s.driving
                  ? 'An auto-ping goes out when both the time has passed and you have moved the distance. Changes apply to this drive straight away.'
                  : 'An auto-ping goes out when both the time has passed and you have moved the distance. Saved for every drive.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
          ...pingCadenceTiles(context, prefix: 'quick-'),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('ping-settings-all'),
                icon: const Icon(Icons.settings_outlined),
                label: const Text('All wardriving settings'),
                onPressed: () {
                  final shell = ShellScope.maybeRead(context);
                  Navigator.of(context).pop();
                  if (shell != null) {
                    shell.openMore(MoreItem.wardriving);
                  } else {
                    Navigator.of(
                      context,
                    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen(initialSection: 'wardriving')));
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
