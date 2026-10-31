// Settings > Drives & uploads: when drives go to the server. Drives are always saved on this phone first.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../app.dart';
import '../widgets.dart';
import 'settings_kit.dart';

const String drivesHelp = 'Drives are always saved on this phone first. Uploads need a driver key the server accepts, are safe to '
    'retry, and never send a ping twice.';

List<Widget> drivesSectionRows(BuildContext context) {
  final s = AppScope.of(context);
  final st = s.settings;
  return [
    SettingsAnchor(
      id: 'auto-sync',
      child: SwitchListTile(
        key: const Key('auto-sync'),
        secondary: const Icon(Icons.cloud_upload_outlined),
        title: const Text('Upload at end of drive'),
        subtitle: const Text('Sends the drive when you press Stop. Off: drives wait on this phone until you upload them from Drives.'),
        value: st.autoSync,
        onChanged: (v) => s.updateSettings(s.settings.copyWith(autoSync: v)),
      ),
    ),
    SettingsAnchor(
      id: 'sync-during-drive',
      child: SwitchListTile(
        key: const Key('sync-during-drive'),
        secondary: const Icon(Icons.sync),
        title: const Text('Upload during the drive'),
        subtitle: st.autoSync
            ? const Text('Sends new pings while you drive, so nothing waits for Stop.')
            : const SettingsWhyNot('Off while "Upload at end of drive" is off. Turn that on first.'),
        value: st.autoSync && st.syncDuringDrive,
        onChanged: st.autoSync ? (v) => s.updateSettings(s.settings.copyWith(syncDuringDrive: v)) : null,
      ),
    ),
    SettingsAnchor(
      id: 'sync-every',
      child: SliderTile(
        key: const Key('sync-every'),
        sliderKey: const Key('sync-every-slider'),
        icon: Icons.schedule,
        title: 'Upload interval',
        stops: syncEveryStops,
        value: st.syncEveryMin,
        label: (v) => 'Every $v min',
        minLabel: '1 min',
        maxLabel: '30 min',
        caption: 'Shorter means the map is fresher; longer saves battery and data.',
        disabledReason: st.autoSync
            ? 'Only used while "Upload during the drive" is on. Turn it on to choose the interval.'
            : 'Only used while "Upload at end of drive" and "Upload during the drive" are on. Turn them on first.',
        enabled: st.autoSync && st.syncDuringDrive,
        onChanged: (v) => s.updateSettings(s.settings.copyWith(syncEveryMin: v)),
      ),
    ),
    SettingsAnchor(id: 'last-upload', child: LastUpload(state: s)),
  ];
}

/// "Last upload 14:05 · OK" / the reason it failed / "Uploading…".
class LastUpload extends StatelessWidget {
  final AppState state;
  const LastUpload({super.key, required this.state});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final s = state;
    final (IconData icon, Color color, String text) = s.uploading
        ? (Icons.sync, t.colorScheme.primary, 'Uploading…')
        : s.lastUploadError != null
            ? (Icons.cloud_off, t.colorScheme.error, 'Last upload failed: ${s.lastUploadError}')
            : s.lastUploadAt != null
                ? (Icons.cloud_done, m.snrStrong, 'Last upload ${formatTime(s.lastUploadAt!)} · OK')
                : (Icons.cloud_queue, t.colorScheme.onSurfaceVariant,
                    s.keyApproved ? 'No uploads yet.' : 'No uploads yet. Uploads start once your key is ready.');
    return Padding(
      key: const Key('last-upload'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 18),
        Expanded(child: Text(text, style: t.textTheme.bodyMedium?.copyWith(color: color, fontWeight: FontWeight.w600))),
      ]),
    );
  }
}
