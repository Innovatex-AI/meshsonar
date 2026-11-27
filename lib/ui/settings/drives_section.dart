// Settings > Driving > Uploads: when drives go to the server (one choice since build 77), the interval while driving,
// and the last upload. Drives are always saved on this phone first.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/api.dart' show Settings;
import '../../core/power_profile.dart';
import '../../core/time_format.dart' as tf;
import '../app.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String drivesHelp = 'Drives are saved on this phone first. Uploads need a driver key.';

/// The one Upload choice (build 77, redesign round 5 decision 3). It is kept in the two settings it always was
/// (Settings.autoSync, Settings.syncDuringDrive), so files from older builds read the same: both on = while driving,
/// only autoSync = when the drive ends, autoSync off = only when you tap Upload.
enum UploadWhen {
  whileDriving('While driving', 'Sends new pings while you drive, and the rest when you press Stop.'),
  atEnd('When the drive ends', 'Sends the drive when you press Stop.'),
  manual('Only when I tap Upload', 'Upload each drive yourself from Drives.');

  final String label;
  final String summary;
  const UploadWhen(this.label, this.summary);

  static UploadWhen of(Settings st) => !st.autoSync ? manual : (st.syncDuringDrive ? whileDriving : atEnd);

  Settings apply(Settings st) => switch (this) {
    whileDriving => st.copyWith(autoSync: true, syncDuringDrive: true),
    atEnd => st.copyWith(autoSync: true, syncDuringDrive: false),
    manual => st.copyWith(autoSync: false),
  };
}

/// Upload while driving is chosen, but the battery mode holds drive uploads until Stop (Saver).
bool batteryHoldsUploads(Settings st) => UploadWhen.of(st) == UploadWhen.whileDriving && !PowerProfile.current.uploadDuringDrive;

/// "While driving, every 5 min · last 2:05 PM": the Uploads row on the first level of Driving.
String uploadsCaption(AppState s) {
  final st = s.settings;
  final when = switch (UploadWhen.of(st)) {
    UploadWhen.manual => 'Only when you tap Upload',
    UploadWhen.atEnd => 'When the drive ends',
    UploadWhen.whileDriving => 'While driving, every ${st.syncEveryMin} min',
  };
  final last = s.uploading
      ? 'uploading now'
      : s.lastUploadError != null
      ? 'last upload failed'
      : s.lastUploadAt != null
      ? 'last ${tf.timeOrShortDateTime(s.lastUploadAt)}'
      : null;
  return last == null ? '$when.' : '$when · $last.';
}

/// Words for a phone with no driver key yet that will make one by itself (release builds; the first try failed, for
/// example with no network at first launch): drives wait on the phone (round 5 O5). Null when uploads are not waiting on
/// that. For the Drives list header and the Drive tab's "Drive saved" row.
String? uploadSetupNote(AppState s) =>
    !s.hasKey && s.settings.autoKey && s.services.mayAutoCreateKey(s.settings.serverUrl) ? 'Will upload when this phone is set up.' : null;

List<Widget> drivesSectionRows(BuildContext context) {
  final s = AppScope.of(context);
  final st = s.settings;
  final when = UploadWhen.of(st);
  final held = batteryHoldsUploads(st);
  return [
    SettingsAnchor(
      id: 'auto-sync',
      // "Upload during the drive" (until build 77) is part of this choice: its id lands here.
      child: SettingsAnchor(
        id: 'sync-during-drive',
        child: ListTile(
          key: const Key('auto-sync'),
          leading: const Icon(Icons.cloud_upload_outlined),
          title: Text(settingsEntry('auto-sync').title),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 6),
                child: SegmentedButton<UploadWhen>(
                  key: const Key('upload-when'),
                  showSelectedIcon: false,
                  direction: Axis.vertical,
                  segments: [
                    for (final w in UploadWhen.values)
                      ButtonSegment(
                        value: w,
                        label: segmentLabel(w.label, key: Key('upload-when-${w.name}')),
                      ),
                  ],
                  selected: {when},
                  onSelectionChanged: (v) => s.updateSettings(v.first.apply(s.settings)),
                ),
              ),
              Text(when.summary, key: const Key('upload-when-summary')),
              if (held) ...[
                const SizedBox(height: 4),
                const SettingsWhyNot('Your battery mode holds uploads until the drive ends.', key: Key('sync-during-drive-battery')),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('upload-while-driving-anyway'),
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48), padding: EdgeInsets.zero),
                    onPressed: () => unawaited(PowerProfile.set(PowerProfile.chosen.tweak((p) => p.copyWith(uploadDuringDrive: true)))),
                    child: const Text('Upload while driving anyway'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    SettingsAnchor(
      id: 'sync-every',
      child: SliderTile(
        key: const Key('sync-every'),
        sliderKey: const Key('sync-every-slider'),
        icon: Icons.schedule,
        title: settingsEntry('sync-every').title,
        stops: syncEveryStops,
        value: st.syncEveryMin,
        label: (v) => 'Every $v min',
        minLabel: '1 min',
        maxLabel: '30 min',
        caption: 'Shorter: fresher map. Longer: saves battery and data.',
        disabledReason: 'Only used while Upload is "While driving". Choose it to set the interval.',
        enabled: when == UploadWhen.whileDriving,
        onChanged: (v) => s.updateSettings(s.settings.copyWith(syncEveryMin: v)),
      ),
    ),
    SettingsAnchor(
      id: 'last-upload',
      child: LastUpload(state: s),
    ),
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
        ? (Icons.cloud_done, m.snrStrong, 'Last upload ${tf.timeOrShortDateTime(s.lastUploadAt)} · OK')
        : (
            Icons.cloud_queue,
            t.colorScheme.onSurfaceVariant,
            s.keyApproved
                ? 'No uploads yet.'
                : (uploadSetupNote(s) == null
                      ? 'No uploads yet. Uploads start once your key is ready.'
                      : 'No uploads yet. ${uploadSetupNote(s)}'),
          );
    return Padding(
      key: const Key('last-upload'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 18),
          Expanded(
            child: Text(
              text,
              style: t.textTheme.bodyMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
