// Settings > Sharing & privacy > Delete my collected data (stream 7 WP5). One clearly worded action for the server
// ("Delete my data on the server": all drive context through `DELETE drive-context?category=all`, and the packet
// headers this phone shared) and, separately and never by default, one for the context saved on this phone. The
// drives themselves (ping positions and signal) are not touched here.
//
// Every state is said in words: no driver key, a server that cannot erase context, a key the server does not know
// (401/403), the hourly limit (429, "try again in an hour"), no connection (remembered and retried), and the server's
// own counts when it worked.
import '../design/app_surfaces.dart';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/context_upload_hook.dart';
import '../../app/messages.dart';
import '../app.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

/// What the screen tells a person before they press anything.
const String deleteMyDataLead =
    'This deletes what MeshSonar collected alongside your driving: the drive context (air '
    'pressure, altitude and direction, phone and radio readings, phone and app details, the weather lookup for your '
    'drives) and the observer packets this phone shared (with the positions they were shared with). Your drives themselves (where each ping was sent and what '
    'it heard) are not touched here: delete a drive from its own screen. Collection continues as the switches in '
    'Sharing & privacy say; turn a switch off to stop it.';

/// Account deletion (App Store guideline 5.1.1(v)) from inside the app: `DELETE driver-delete` removes this driver key and
/// everything tied to it on the server. A website account linked to the key (if you made one) is separate and is deleted
/// from the website. An older server without the endpoint keeps the website hand-off.
const String deleteAccountText =
    'Delete my account removes your driver key and every drive, ping, weather lookup, observer '
    'packet, observer position and problem report the server holds for it. It cannot be undone. A website account you may have linked to '
    'the key is separate: delete that one on the website. Drives on this phone stay unless you tick the box. '
    'You can make a new key afterwards.';

/// What the person is told before "Download my data".
const String exportText =
    'Download my data saves everything the server holds for your account (your keys, every drive '
    'with each ping, the packets this phone shared as an observer with the positions they were shared with, and your '
    'reports) as '
    'one file you can keep or share.';

/// The one line shown for each part of the screen (build 76). The full texts above are one tap away, under
/// "What this covers" ([deleteMyDataLead], [exportText]) and "What deleting my account covers" ([deleteAccountText]).
const String deleteMyDataShort = 'Download or delete what MeshSonar holds about you.';
const String exportShort = 'One file with everything the server holds for you. Do this first if you want a copy.';
const String deleteServerShort = 'Sensor readings, phone details and observer packets. Your drives stay.';
const String deleteLocalShort = 'The same readings saved with the drives on this phone. Your drives stay.';
const String deleteAccountShort = 'Removes your driver key and everything the server holds for it. This is permanent.';

class DeleteMyDataScreen extends StatefulWidget {
  const DeleteMyDataScreen({super.key});

  @override
  State<DeleteMyDataScreen> createState() => _DeleteMyDataScreenState();
}

class _DeleteMyDataScreenState extends State<DeleteMyDataScreen> {
  bool _serverBusy = false;
  bool _localBusy = false;
  List<String>? _serverResult;
  bool _serverFailed = false;
  String? _localResult;
  bool _drivesBusy = false;
  String? _drivesResult;
  bool _exportBusy = false;
  String? _exportResult;
  bool _acctBusy = false;
  String? _acctResult;

  Future<void> _export(AppState s) async {
    setState(() {
      _exportBusy = true;
      _exportResult = null;
    });
    String msg;
    try {
      await s.exportAccountData();
      msg = 'Done. Choose where to keep the file.';
    } catch (e) {
      msg = friendlyError(e, action: 'Downloading your data');
    }
    if (!mounted) return;
    setState(() {
      _exportBusy = false;
      _exportResult = msg;
    });
  }

  Future<void> _deleteAccount(AppState s) async {
    var alsoPhone = false;
    final onPhone = s.sessions.length;
    final ok = await showAppSheet<bool>(
      context,
      detents: const [0.55, 0.92], // can be pulled up: at large text the words did not fit the one height

      builder: (ctx, controller) => StatefulBuilder(
        builder: (ctx, set) => AppSheetScaffold(
          key: const Key('delete-account-dialog'),
          controller: controller,
          title: 'Delete my account?',

          primaryAction: FilledButton(
            key: const Key('delete-account-confirm'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete my account'),
          ),
          secondaryAction: TextButton(
            key: const Key('delete-account-cancel'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          children: [
            const Text('This deletes your driver key and all your drives, pings and reports on the server. It cannot be undone.'),
            // Nothing on the phone: no box to think about.
            if (onPhone > 0)
              CheckboxListTile(
                key: const Key('delete-account-also-phone'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: alsoPhone,
                onChanged: (v) => set(() => alsoPhone = v ?? false),
                title: Text('Also delete the $onPhone drive${onPhone == 1 ? '' : 's'} on this phone'),
                subtitle: const Text('Ones not uploaded yet are lost.'),
              ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _acctBusy = true;
      _acctResult = null;
    });
    String msg;
    try {
      final c = await s.deleteAccountOnServer(alsoOnPhone: alsoPhone);
      msg = c == null
          ? 'The server no longer knew this key, so there was nothing left to delete. This phone forgot it.'
          : 'Deleted: ${c.sessions} drive${c.sessions == 1 ? '' : 's'}, ${c.pings} pings, ${c.reports} report${c.reports == 1 ? '' : 's'}. This phone forgot the key.';
    } catch (e) {
      msg = '${friendlyError(e, action: 'Deleting the account')} Nothing was changed.';
    }
    if (!mounted) return;
    setState(() {
      _acctBusy = false;
      _acctResult = msg;
    });
  }

  Future<void> _deleteOnServer(AppState s) async {
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'delete-server-dialog',
      title: 'Delete my data on the server?',
      body:
          'Deletes the sensor readings and phone details of every drive, and the observer packets this phone shared. '
          'This cannot be undone. Your drives and their pings stay.',
      confirmLabel: 'Delete on the server',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      _serverBusy = true;
      _serverResult = null;
    });
    final r = await s.deleteMyDataOnServer();
    if (!mounted) return;
    final headers = r.headers;
    setState(() {
      _serverBusy = false;
      _serverFailed = !r.context.done;
      _serverResult = [
        'Drive context: ${r.context.message}',
        if (s.hasKey)
          headers != null
              ? 'Packet headers: the server erased $headers.'
              : 'Packet headers: could not reach the server. The erase is remembered and sent again by itself.',
      ];
    });
  }

  Future<void> _deleteLocal(AppState s) async {
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'delete-local-dialog',
      title: 'Delete the context saved on this phone?',
      body:
          'Removes the sensor readings and phone details saved with every drive on this phone. The drives stay. '
          '${s.meshTrack != null ? 'MeshTrack forgets your friends\' last positions and your group list; the channels stay in Chats. ' : ''}'
          'This does not change the server.',
      confirmLabel: 'Delete on this phone',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _localBusy = true);
    final n = await s.deleteAllCollectedLocally();
    final groups = await s.clearMeshTrackLocal(); // MeshTrack: last positions (meshtrack_last.json) and the group list
    if (!mounted) return;
    setState(() {
      _localBusy = false;
      final drives = n == 0
          ? 'Nothing of it was saved on this phone.'
          : 'Deleted the saved context from $n drive${n == 1 ? '' : 's'} on this phone.';
      _localResult = groups == 0 ? drives : '$drives MeshTrack forgot $groups group${groups == 1 ? '' : 's'} and your friends\' last positions.';
    });
  }

  /// Every drive on this phone, including ones not uploaded yet (the person is told so first). The drive being
  /// recorded is never touched.
  Future<void> _deleteAllDrives(AppState s) async {
    final ids = [for (final x in s.sessions) x.session.id];
    final recording = s.currentSession?.id;
    final n = ids.where((id) => id != recording).length;
    if (n == 0) {
      // Was a dialog with a red "Delete drives" button that then did nothing.
      setState(() => _drivesResult = recording == null ? 'There are no drives on this phone.' : 'Only the drive being recorded is on this phone, and it is kept.');
      return;
    }
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'delete-drives-dialog',
      title: 'Delete all drives on this phone?',
      body: 'Deletes $n drive${n == 1 ? '' : 's'} from this phone, including any not uploaded yet (export those first '
          'to keep a copy). Drives on the server stay. This cannot be undone.',
      confirmLabel: 'Delete drives',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _drivesBusy = true);
    var done = 0;
    for (final id in ids) {
      if (id == recording) continue;
      if (await s.deleteSession(id, quiet: true)) done++;
    }
    if (!mounted) return;
    setState(() {
      _drivesBusy = false;
      _drivesResult = 'Deleted $done drive${done == 1 ? '' : 's'} from this phone.'
          '${done < n ? ' ${n - done} could not be deleted; try again.' : ''}'
          '${recording != null ? ' The drive being recorded was kept.' : ''}';
    });
  }

  Future<void> _removeKey(AppState s) async {
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'delete-key-dialog',
      title: 'Remove the driver key from this phone?',
      body:
          'This phone forgets the key and stops uploading. Your account stays on the server. Save the key somewhere '
          'first if you want to use it again: the app keeps no copy.',
      confirmLabel: 'Remove key',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await s.forgetKey();
    if (mounted) showAppToast(context, 'Driver key removed from this phone.');
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    Widget head(String text) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6),
      child: Semantics(header: true, child: Text(text, style: t.textTheme.titleMedium)),
    );

    final caps = s.uploadSiteConfig;
    final String? serverWhyNot = !s.hasKey
        ? 'This phone has no driver key, so there is nothing of yours on the server to delete.'
        : (caps != null && !caps.driveContextErase)
        ? '$serverCannotEraseText Observer packets can still be erased with "Erase shared observer packets" in Settings > Sharing & privacy.'
        : null;

    const spinner = SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
    final tall = ButtonStyle(minimumSize: WidgetStateProperty.all(const Size.fromHeight(48)));
    final danger = FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError);
    Widget line(String text, {Key? key}) => Text(text, key: key, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant));
    // What happened, under the button that did it, in a box so it is not lost among the other text.
    Widget result(Key key, List<String> lines, {String? title}) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
          child: Column(
            key: lines.length == 1 && title == null ? null : key,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null) Text(title, style: t.textTheme.titleSmall),
              if (lines.length == 1 && title == null)
                Text(lines.single, key: key)
              else
                for (final l in lines) Padding(padding: const EdgeInsets.only(top: 2), child: Text(l)),
            ],
          ),
        ),
      ),
    );
    Widget more(String id, String title, List<Widget> children) => ExpansionTile(
      key: Key(id),
      dense: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      expandedAlignment: Alignment.centerLeft,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(title),
      children: children,
    );

    return Scaffold(
      appBar: AppBar(title: Text(settingsEntry('delete-my-data').title)),
      body: SafeArea(
        child: ListView(
          key: const Key('delete-my-data-screen'),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            const Text(deleteMyDataShort, key: Key('delete-my-data-short')),
            more('delete-details', 'What this covers', const [
              Text(deleteMyDataLead, key: Key('delete-my-data-lead')),
              SizedBox(height: 8),
              Text(exportText, key: Key('export-text')),
            ]),
            // Download comes first (build 76): it is the safe step, and the one to take before deleting.
            head('Download my data'),
            line(exportShort, key: const Key('export-short')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('export-data'),
              style: tall,
              onPressed: (!s.accountAvailable || _exportBusy) ? null : () => _export(s),
              icon: _exportBusy ? spinner : const Icon(Icons.download_outlined),
              label: Text(_exportBusy ? 'Preparing your file…' : 'Download my data'),
            ),
            if (!s.accountAvailable)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  s.hasKey ? 'Not available yet: the server has not confirmed your driver key.' : 'Needs a driver key. Add one in Settings > Account.',
                  key: const Key('export-whynot'),
                ),
              ),
            if (_exportResult != null) result(const Key('export-result'), [_exportResult!]),
            head('Delete collected data on the server'),
            line(deleteServerShort, key: const Key('delete-server-short')),
            if (serverWhyNot != null) Padding(padding: const EdgeInsets.only(top: 6), child: SettingsWhyNot(serverWhyNot, key: const Key('delete-server-whynot'))),
            if (s.contextErasePending && serverWhyNot == null)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('An earlier delete has not reached the server yet. It is sent again by itself.', key: Key('delete-server-pending')),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('delete-server-data'),
              style: tall,
              onPressed: (serverWhyNot != null || _serverBusy) ? null : () => _deleteOnServer(s),
              icon: _serverBusy ? spinner : const Icon(Icons.cloud_off_outlined),
              label: Text(_serverBusy ? 'Deleting…' : 'Delete my data on the server'),
            ),
            if (_serverResult != null) result(const Key('delete-server-result'), _serverResult!, title: _serverFailed ? 'Not finished' : 'Done'),
            head('Delete collected data on this phone'),
            line(deleteLocalShort, key: const Key('delete-local-short')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('delete-local-context'),
              style: tall,
              onPressed: _localBusy ? null : () => _deleteLocal(s),
              icon: _localBusy ? spinner : const Icon(Icons.phone_android_outlined),
              label: Text(_localBusy ? 'Deleting…' : 'Delete context saved on this phone'),
            ),
            if (_localResult != null) result(const Key('delete-local-result'), [_localResult!]),
            head('Your drives and driver key on this phone'),
            OutlinedButton.icon(
              key: const Key('delete-all-drives'),
              style: tall,
              onPressed: _drivesBusy ? null : () => _deleteAllDrives(s),
              icon: _drivesBusy ? spinner : const Icon(Icons.route_outlined),
              label: Text(_drivesBusy ? 'Deleting…' : 'Delete all drives on this phone'),
            ),
            if (_drivesResult != null) result(const Key('delete-drives-result'), [_drivesResult!]),
            if (s.hasKey) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('delete-remove-key'),
                style: tall,
                onPressed: () => _removeKey(s),
                icon: const Icon(Icons.key_off_outlined),
                label: const Text('Remove the driver key from this phone'),
              ),
            ],
            // The one that cannot be taken back is last, alone, and red.
            head('Delete my account'),
            line(deleteAccountShort, key: const Key('delete-account-short')),
            more('delete-account-details', 'What deleting my account covers', const [Text(deleteAccountText, key: Key('delete-account-text'))]),
            const SizedBox(height: 4),
            if (s.serverCanDeleteDriver)
              FilledButton.icon(
                key: const Key('delete-account'),
                style: danger,
                onPressed: _acctBusy ? null : () => _deleteAccount(s),
                icon: _acctBusy ? spinner : const Icon(Icons.manage_accounts_outlined),
                label: Text(_acctBusy ? 'Deleting…' : 'Delete my account'),
              )
            else
              FilledButton.icon(
                key: const Key('delete-account-website'),
                style: danger,
                onPressed: () => s.openWebPage('/me/privacy'),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Delete my account on the website'),
              ),
            if (_acctResult != null) result(const Key('delete-account-result'), [_acctResult!]),
          ],
        ),
      ),
    );
  }
}
