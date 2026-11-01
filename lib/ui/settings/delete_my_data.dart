// Settings > Privacy & data sharing > Delete my collected data (stream 7 WP5). One clearly worded action for the server
// ("Delete my data on the server": all drive context through `DELETE drive-context?category=all`, and the packet
// headers this phone shared) and, separately and never by default, one for the context saved on this phone. The
// drives themselves (ping positions and signal) are not touched here.
//
// Every state is said in words: no driver key, a server that cannot erase context, a key the server does not know
// (401/403), the hourly limit (429, "try again in an hour"), no connection (remembered and retried), and the server's
// own counts when it worked.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/context_upload_hook.dart';
import '../../app/messages.dart';
import '../app.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

/// What the screen tells a person before they press anything.
const String deleteMyDataLead = 'This deletes what MeshSonar collected alongside your driving: the drive context (air '
    'pressure, altitude and direction, phone and radio readings, phone and app details, the weather lookup for your '
    'drives) and the packet headers this phone shared. Your drives themselves (where each ping was sent and what '
    'it heard) are not touched here: delete a drive from its own screen. Collection continues as the switches in '
    'Privacy & data sharing say; turn a switch off to stop it.';

/// Account deletion (App Store guideline 5.1.1(v)) from inside the app: `DELETE driver-delete` removes this driver key and
/// everything tied to it on the server. A website account linked to the key (if you made one) is separate and is deleted
/// from the website. An older server without the endpoint keeps the website hand-off.
const String deleteAccountText = 'Delete my account removes your driver key and every drive, ping, weather lookup, packet '
    'header and problem report the server holds for it. It cannot be undone. A website account you may have linked to '
    'the key is separate: delete that one on the website. Drives on this phone stay unless you tick the box. '
    'You can make a new key afterwards.';

/// What the person is told before "Download my data".
const String exportText = 'Download my data saves everything the server holds for your account (your keys, every drive '
    'with each ping, and your reports) as one file you can keep or share.';

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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          key: const Key('delete-account-dialog'),
          title: const Text('Delete my account?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('This deletes your driver key and all your drives, pings and reports on the server. It cannot be undone.'),
            CheckboxListTile(
              key: const Key('delete-account-also-phone'),
              contentPadding: EdgeInsets.zero,
              value: alsoPhone,
              onChanged: (v) => set(() => alsoPhone = v ?? false),
              title: const Text('Also delete the drives on this phone'),
              subtitle: const Text('Ones not uploaded yet are lost.'),
            ),
          ]),
          actions: [
            TextButton(key: const Key('delete-account-cancel'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              key: const Key('delete-account-confirm'),
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error, foregroundColor: Theme.of(ctx).colorScheme.onError),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete my account'),
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
      body: 'The server deletes all the drive context it holds for your driver key (every drive) and every packet '
          'header this phone shared. This cannot be undone. Your drives and their pings stay. Collection continues '
          'as your switches say.',
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
      body: 'Removes the air pressure, altitude, battery, radio readings and phone details recorded with your drives '
          'from every drive on this phone, and from the drive reports. The drives themselves stay. This does not '
          'change the server.',
      confirmLabel: 'Delete on this phone',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _localBusy = true);
    final n = await s.deleteAllCollectedLocally();
    if (!mounted) return;
    setState(() {
      _localBusy = false;
      _localResult = n == 0
          ? 'Nothing of it was saved on this phone.'
          : 'Deleted the saved context from $n drive${n == 1 ? '' : 's'} on this phone.';
    });
  }

  /// Every drive on this phone, including ones not uploaded yet (the person is told so first). The drive being
  /// recorded is never touched.
  Future<void> _deleteAllDrives(AppState s) async {
    final ids = [for (final x in s.sessions) x.session.id];
    final recording = s.currentSession?.id;
    final n = ids.where((id) => id != recording).length;
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'delete-drives-dialog',
      title: 'Delete all drives on this phone?',
      body: n == 0
          ? 'There are no drives on this phone.'
          : 'Deletes $n drive${n == 1 ? '' : 's'} from this phone, including any that have not uploaded yet (those '
              'are lost: export them first if you want a copy). Drives already on the server stay there until you '
              'delete your account. This cannot be undone.',
      confirmLabel: 'Delete drives',
      destructive: true,
    );
    if (!ok || !mounted || n == 0) return;
    setState(() => _drivesBusy = true);
    var done = 0;
    for (final id in ids) {
      if (id == recording) continue;
      if (await s.deleteSession(id, quiet: true)) done++;
    }
    if (!mounted) return;
    setState(() {
      _drivesBusy = false;
      _drivesResult = 'Deleted $done drive${done == 1 ? '' : 's'} from this phone.';
    });
  }

  Future<void> _removeKey(AppState s) async {
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'delete-key-dialog',
      title: 'Remove the driver key from this phone?',
      body: 'This phone forgets the key and stops uploading. The key and your account stay on the server until you '
          'delete your account on the website. The app keeps no copy of the key.',
      confirmLabel: 'Remove key',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await s.forgetKey();
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
            ? '$serverCannotEraseText Packet headers can still be erased with "Erase shared packet headers" in Privacy & data sharing.'
            : null;

    return Scaffold(
      appBar: AppBar(title: Text(settingsEntry('delete-my-data').title)),
      body: SafeArea(
        child: ListView(
          key: const Key('delete-my-data-screen'),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            const Text(deleteMyDataLead, key: Key('delete-my-data-lead')),
            head('On the server'),
            if (serverWhyNot != null) SettingsWhyNot(serverWhyNot, key: const Key('delete-server-whynot')),
            if (s.contextErasePending && serverWhyNot == null)
              const Text('An erase is waiting to reach the server; it is retried automatically.', key: Key('delete-server-pending')),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('delete-server-data'),
              onPressed: (serverWhyNot != null || _serverBusy) ? null : () => _deleteOnServer(s),
              icon: _serverBusy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_off_outlined),
              label: const Text('Delete my data on the server'),
            ),
            if (_serverResult != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Column(
                  key: const Key('delete-server-result'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_serverFailed ? 'Not finished' : 'Done', style: t.textTheme.titleSmall),
                    for (final line in _serverResult!) Padding(padding: const EdgeInsets.only(top: 2), child: Text(line)),
                  ],
                ),
              ),
            ],
            head('On this phone'),
            const Text('The context saved with your drives on this phone is yours and stays unless you delete it here. '
                'Deleting it does not change the server.'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('delete-local-context'),
              onPressed: _localBusy ? null : () => _deleteLocal(s),
              icon: const Icon(Icons.phone_android_outlined),
              label: const Text('Delete context saved on this phone'),
            ),
            if (_localResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(liveRegion: true, child: Text(_localResult!, key: const Key('delete-local-result'))),
              ),
            head('Download my data'),
            const Text(exportText, key: Key('export-text')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('export-data'),
              onPressed: (!s.accountAvailable || _exportBusy) ? null : () => _export(s),
              icon: _exportBusy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download_outlined),
              label: const Text('Download my data'),
            ),
            if (!s.accountAvailable)
              const Padding(padding: EdgeInsets.only(top: 6), child: Text('Needs a confirmed driver key on a server that offers it.', key: Key('export-whynot'))),
            if (_exportResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(liveRegion: true, child: Text(_exportResult!, key: const Key('export-result'))),
              ),
            head('Your account and drives'),
            const Text(deleteAccountText, key: Key('delete-account-text')),
            const SizedBox(height: 8),
            if (s.serverCanDeleteDriver)
              FilledButton.icon(
                key: const Key('delete-account'),
                style: FilledButton.styleFrom(backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError),
                onPressed: _acctBusy ? null : () => _deleteAccount(s),
                icon: _acctBusy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.manage_accounts_outlined),
                label: const Text('Delete my account'),
              )
            else
              FilledButton.icon(
                key: const Key('delete-account-website'),
                style: FilledButton.styleFrom(backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError),
                onPressed: () => s.openWebPage('/me/privacy'),
                icon: const Icon(Icons.manage_accounts_outlined),
                label: const Text('Delete my account on the website'),
              ),
            if (_acctResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(liveRegion: true, child: Text(_acctResult!, key: const Key('delete-account-result'))),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('delete-all-drives'),
              onPressed: _drivesBusy ? null : () => _deleteAllDrives(s),
              icon: const Icon(Icons.route_outlined),
              label: const Text('Delete all drives on this phone'),
            ),
            if (_drivesResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(liveRegion: true, child: Text(_drivesResult!, key: const Key('delete-drives-result'))),
              ),
            if (s.hasKey) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('delete-remove-key'),
                onPressed: () => _removeKey(s),
                icon: const Icon(Icons.key_off_outlined),
                label: const Text('Remove the driver key from this phone'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
