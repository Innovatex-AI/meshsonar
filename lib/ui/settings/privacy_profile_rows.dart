// Settings > Privacy & data sharing > "How you appear": callsign, display name, anonymous drives and the leaderboard opt-in.
// The same four settings as the website's /me/privacy "How you appear" (callsign, display name, Stay anonymous, List me on
// the leaderboard), edited here first and mirrored on the server (lib/app/driver_settings_controller.dart). Shown only when
// the server has `driverSettings` and this phone has a driver key; an older server keeps today's behaviour.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/driver_settings_controller.dart';
import '../../core/driver_settings.dart';
import '../app.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

/// The searchable rows (spread into [privacySettingsEntries]); each id is a SettingsAnchor in [PrivacyProfileRows].
const List<SettingsEntry> privacyProfileEntries = [
  SettingsEntry('profile-callsign', 'privacy', 'Callsign',
      'Your public name on drives and the leaderboard. Leave it empty and you show as "Driver N".',
      keywords: ['callsign', 'name', 'call sign', 'public name', 'ke4bfi', 'driver'], available: profileRowsAvailable),
  SettingsEntry('profile-display', 'privacy', 'Display name',
      'An optional longer name shown next to your callsign.',
      keywords: ['display name', 'name', 'nickname', 'how you appear'], available: profileRowsAvailable),
  SettingsEntry('profile-anonymous', 'privacy', 'Stay anonymous',
      'Public pages say "anonymous" instead of your callsign. Your drives still count toward coverage.',
      keywords: ['anonymous', 'hide my name', 'private', 'callsign', 'drives'], available: profileRowsAvailable),
  SettingsEntry('profile-leaderboard', 'privacy', 'List me on the leaderboard',
      'Shows your callsign with your distance, drives and squares covered. Off by default.',
      keywords: ['leaderboard', 'rank', 'ranking', 'opt in', 'public', 'stats'], available: profileRowsAvailable),
];

/// The server takes `driverSettings` and this phone has a driver key.
bool profileRowsAvailable(AppState s) => s.hasKey && s.driverSettings.supported;

class PrivacyProfileRows extends StatefulWidget {
  const PrivacyProfileRows({super.key});

  @override
  State<PrivacyProfileRows> createState() => _PrivacyProfileRowsState();
}

class _PrivacyProfileRowsState extends State<PrivacyProfileRows> {
  DriverSettingsController? _c;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c == null) {
      final c = AppScope.read(context).driverSettings;
      _c = c..addListener(_changed);
      c.load().then((_) => c.sync());
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c?.removeListener(_changed);
    super.dispose();
  }

  Future<void> _editText(String title, String? current, SettingField f, {String? Function(String)? problem, int maxLength = 40, TextCapitalization caps = TextCapitalization.none}) async {
    final r = await showDialog<String>(
      context: context,
      builder: (_) => _TextDialog(title: title, initial: current ?? '', fieldKey: Key('profile-${f.name}-field'), problem: problem, maxLength: maxLength, caps: caps),
    );
    if (r != null) await _c!.set(f, r);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = _c;
    if (c == null || !profileRowsAvailable(s)) return const SizedBox.shrink();
    final t = Theme.of(context);
    final leaderboardNeedsAccount = !c.leaderboardAvailable;
    String? status;
    if (c.hasPending) {
      status = c.status == SettingsSyncStatus.waitingForKey ? 'Saved on this phone. Sent as soon as there is a driver key.' : 'Saved on this phone. Sent when the server can be reached.';
    } else if (c.status == SettingsSyncStatus.rejected && c.error != null) {
      status = c.error;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SettingsAnchor(
        id: 'profile-callsign',
        child: ListTile(
          key: const Key('profile-callsign'),
          leading: const Icon(Icons.badge_outlined),
          title: Text(settingsEntry('profile-callsign').title),
          subtitle: Text(c.callsign ?? 'Not set: you show as "Driver N"'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editText('Callsign', c.callsign, SettingField.callsign,
              problem: callsignProblem, maxLength: kCallsignMax, caps: TextCapitalization.characters),
        ),
      ),
      SettingsAnchor(
        id: 'profile-display',
        child: ListTile(
          key: const Key('profile-display'),
          leading: const Icon(Icons.person_outline),
          title: Text(settingsEntry('profile-display').title),
          subtitle: Text(c.display ?? 'Optional'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editText('Display name', c.display, SettingField.display, maxLength: kDisplayNameMax),
        ),
      ),
      SettingsAnchor(
        id: 'profile-anonymous',
        child: SwitchListTile(
          key: const Key('profile-anonymous'),
          secondary: const Icon(Icons.visibility_off_outlined),
          title: Text(settingsEntry('profile-anonymous').title),
          subtitle: Text(settingsEntry('profile-anonymous').summary),
          value: c.anonymous,
          onChanged: (v) => c.set(SettingField.anonymous, v),
        ),
      ),
      SettingsAnchor(
        id: 'profile-leaderboard',
        child: SwitchListTile(
          key: const Key('profile-leaderboard'),
          secondary: const Icon(Icons.leaderboard_outlined),
          title: Text(settingsEntry('profile-leaderboard').title),
          subtitle: leaderboardNeedsAccount
              ? const SettingsWhyNot('Sign in on the website to join the leaderboard: it needs an account.')
              : Text(settingsEntry('profile-leaderboard').summary),
          value: !leaderboardNeedsAccount && c.leaderboardOptIn,
          onChanged: leaderboardNeedsAccount ? null : (v) => c.set(SettingField.leaderboardOptIn, v),
        ),
      ),
      if (status != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(status, key: const Key('profile-status'), style: t.textTheme.bodySmall),
        ),
    ]);
  }
}


/// The edit dialog; it owns its text controller, so the controller outlives the dialog's closing animation.
class _TextDialog extends StatefulWidget {
  final String title;
  final String initial;
  final Key fieldKey;
  final String? Function(String)? problem;
  final int maxLength;
  final TextCapitalization caps;
  const _TextDialog({required this.title, required this.initial, required this.fieldKey, this.problem, required this.maxLength, required this.caps});

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bad = widget.problem?.call(_ctl.text);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: widget.fieldKey,
        controller: _ctl,
        autofocus: true,
        maxLength: widget.maxLength,
        textCapitalization: widget.caps,
        decoration: InputDecoration(errorText: bad),
        onChanged: (_) => setState(() {}),
        onSubmitted: (v) {
          if (widget.problem?.call(v) == null) Navigator.pop(context, v);
        },
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('profile-save'), onPressed: bad == null ? () => Navigator.pop(context, _ctl.text) : null, child: const Text('Save')),
      ],
    );
  }
}
