// Devices and keys, native (the website's /me/devices). The app is an anonymous driver by default, so this works with the
// phone's own key and no sign-in: this phone's key (show it for 30 s, make a new one), the account's other phones and the
// MeshMapper forward key when the key belongs to a website account, and what is public about the account.
// A key is shown only while the person asks (30 s), is never logged and never stored by this screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/messages.dart';
import '../../core/api.dart';
import '../../core/driver_account.dart';
import '../app.dart';
import '../settings/settings_kit.dart' show confirmSettingsChange;
import '../widgets.dart';

const Duration keyRevealFor = Duration(seconds: 30);

String _day(DateTime? t) => t == null ? 'never' : t.toLocal().toIso8601String().substring(0, 10);

String statusWords(DriverKeyStatus s) => switch (s) {
      DriverKeyStatus.approved => 'Works',
      DriverKeyStatus.pending => 'Waiting for the server',
      DriverKeyStatus.rejected => 'Turned down',
      DriverKeyStatus.revoked => 'Switched off',
      _ => 'Unknown',
    };

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  Future<DriverDevices>? _future;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final s = AppScope.read(context);
    unawaited(s.settlePendingKey());
    _future = s.accountAvailable ? s.loadDriverDevices() : null;
  }

  void _load() {
    final s = AppScope.read(context);
    final f = s.accountAvailable ? s.loadDriverDevices() : null;
    setState(() {
      _future = f;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Devices and keys')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => _load(),
          child: ListView(
            key: const Key('devices-screen'),
            padding: const EdgeInsets.all(Gap.l),
            children: [
              Text(
                'A driver key links MeshSonar on a phone to its drives. Use one key per phone. The key works the moment it is made; '
                'no account or sign-in is needed.',
                key: const Key('devices-intro'),
                style: t.textTheme.bodyMedium,
              ),
              const SizedBox(height: Gap.m),
              _ThisPhone(onChanged: _load),
              const SizedBox(height: Gap.l),
              if (!s.hasKey)
                const Text('This phone has no driver key. Create one under Account & driver key.', key: Key('devices-nokey'))
              else if (_future == null)
                const _Note(
                    key: Key('devices-unavailable'),
                    text: 'This server does not offer the account lists yet, or the key is not confirmed. Your key above still works.')
              else
                FutureBuilder<DriverDevices>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(child: Padding(padding: EdgeInsets.all(Gap.l), child: CircularProgressIndicator()));
                    }
                    if (snap.hasError) {
                      return Column(children: [
                        ErrorBanner(friendlyError(snap.error!, action: 'Loading your devices')),
                        TextButton(key: const Key('devices-retry'), onPressed: _load, child: const Text('Try again')),
                      ]);
                    }
                    return _Account(devices: snap.data!, onChanged: _load);
                  },
                ),
              const SizedBox(height: Gap.l),
              TextButton.icon(
                key: const Key('devices-website'),
                onPressed: () => s.openWebPage('/me/devices'),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('View this page on the website'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note({super.key, required this.text});
  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant));
}

/// This phone's key: the local copy is shown from the phone, so it works offline and before the server lists anything.
class _ThisPhone extends StatefulWidget {
  final VoidCallback onChanged;
  const _ThisPhone({required this.onChanged});
  @override
  State<_ThisPhone> createState() => _ThisPhoneState();
}

class _ThisPhoneState extends State<_ThisPhone> {
  bool _show = false;
  Timer? _timer;
  bool _busy = false;
  String? _msg;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle(bool on) {
    _timer?.cancel();
    setState(() => _show = on);
    if (on) {
      _timer = Timer(keyRevealFor, () {
        if (mounted) setState(() => _show = false);
      });
    }
  }

  Future<void> _rotate(AppState s) async {
    final ok = await confirmSettingsChange(context,
        dialogKey: 'rotate-key-dialog',
        title: 'Make a new key for this phone?',
        body: 'This phone gets a new key and the old one stops working at once. Your drives stay and keep their history. '
            'Anything else using the old key, such as the same key pasted into another phone, stops uploading until you paste the new one.',
        confirmLabel: 'Make a new key',
        destructive: true);
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _msg = null;
      _show = false;
    });
    final err = await s.rotateDriverKey();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _msg = err ?? 'Done. This phone now uses the new key.';
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final st = s.settings;
    final t = Theme.of(context);
    if (!s.hasKey) return const SizedBox.shrink();
    final canRotate = s.accountAvailable;
    return Card(
      key: const Key('devices-this-phone'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('This phone', style: t.textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Text('${statusWords(st.keyStatus)}${st.display == null ? '' : ' · shown as ${st.display}'}', key: const Key('devices-this-status')),
          const SizedBox(height: Gap.s),
          Row(children: [
            Expanded(
              child: _show
                  ? SelectableText(st.driverKey ?? '', key: const Key('devices-key-shown'), style: const TextStyle(fontFamily: 'monospace'))
                  : Text('Driver key: ${s.maskedKey}', key: const Key('devices-key-hidden')),
            ),
            IconButton(
              key: const Key('devices-key-toggle'),
              tooltip: _show ? 'Hide key' : 'Show key',
              icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => _toggle(!_show),
            ),
            if (_show)
              IconButton(
                key: const Key('devices-key-copy'),
                tooltip: 'Copy key',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: st.driverKey ?? ''));
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Key copied')));
                },
              ),
          ]),
          Text('Hides itself after 30 seconds. Anyone with the key can upload drives as you.', style: t.textTheme.bodySmall),
          if (st.pendingDriverKey != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.s),
              child: Text('A key change is being checked with the server.', key: const Key('devices-pending'), style: t.textTheme.bodySmall),
            ),
          if (_msg != null) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text(_msg!, key: const Key('devices-rotate-result'))),
          const SizedBox(height: Gap.s),
          OutlinedButton.icon(
            key: const Key('devices-rotate'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: (!canRotate || _busy || s.keyBusy) ? null : () => _rotate(s),
            icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.autorenew),
            label: const Text('Make a new key for this phone'),
          ),
          if (!canRotate)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text('Needs a server that offers it and a confirmed key.', style: t.textTheme.bodySmall),
            ),
        ]),
      ),
    );
  }
}

class _Account extends StatelessWidget {
  final DriverDevices devices;
  final VoidCallback onChanged;
  const _Account({required this.devices, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final others = devices.devices.where((d) => d.id != devices.driver.id).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, key: const Key('devices-account'), children: [
      Text('Your keys', style: t.textTheme.titleMedium),
      const SizedBox(height: Gap.xs),
      if (!devices.linked)
        Text(
          'This key is not linked to a website account, so it is the only one listed. That is normal: MeshSonar needs no account.',
          key: const Key('devices-unlinked'),
          style: t.textTheme.bodyMedium,
        ),
      Card(
        child: ListTile(
          key: const Key('devices-row-self'),
          leading: const Icon(Icons.smartphone),
          title: Text('${devices.driver.display} (this phone)'),
          subtitle: Text('${statusWords(devices.driver.status)} · created ${_day(devices.driver.createdAt)} · last upload ${_day(devices.driver.lastSeenAt)}'
              '${devices.driver.keyHint == null ? '' : ' · ends in ${devices.driver.keyHint}'}'),
        ),
      ),
      for (final d in others) _OtherPhone(device: d),
      const SizedBox(height: Gap.l),
      Text('MeshMapper forwarding', style: t.textTheme.titleMedium),
      const SizedBox(height: Gap.xs),
      Text(
        'Drive with the MeshMapper app and have each batch also sent here: MeshMapper\'s Custom API Endpoint takes a link made from a forward key. '
        'Those drives join the coverage map, marked as MeshMapper.',
        style: t.textTheme.bodyMedium,
      ),
      const SizedBox(height: Gap.s),
      if (!devices.linked)
        const _Note(
            key: Key('devices-mm-needs-account'),
            text: 'A forward key belongs to a website account, and this key has none. Sign in on the website with your email once, '
                'and keys made in the app with that email can be linked to it.')
      else if (devices.mmKeys.isEmpty)
        const _Note(key: Key('devices-mm-none'), text: 'No forward key yet. Make one on the website; it then shows here.')
      else
        for (final k in devices.mmKeys) _MmKeyTile(k: k),
      if (devices.linked) ...[
        const SizedBox(height: Gap.l),
        Text('Your account', style: t.textTheme.titleMedium),
        const SizedBox(height: Gap.xs),
        const _Note(key: Key('devices-profile'), text: 'The name on your drives and whether you are on the leaderboard are account settings. Change them on the website.'),
      ],
    ]);
  }
}

class _OtherPhone extends StatelessWidget {
  final AccountDevice device;
  const _OtherPhone({required this.device});
  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          key: ValueKey('devices-row-${device.id}'),
          leading: const Icon(Icons.phone_iphone_outlined),
          title: Text(device.display),
          subtitle: Text('${statusWords(device.status)} · created ${_day(device.createdAt)} · last upload ${_day(device.lastSeenAt)}'
              '${device.keyHint == null ? '' : ' · ends in ${device.keyHint}'}'),
          trailing: device.status == DriverKeyStatus.approved && device.revealable ? _RevealButton(kind: 'driver', id: device.id, label: 'Driver key for ${device.display}') : null,
        ),
      );
}

class _MmKeyTile extends StatelessWidget {
  final MmForwardKey k;
  const _MmKeyTile({required this.k});
  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          key: ValueKey('devices-mm-${k.id}'),
          leading: const Icon(Icons.send_outlined),
          title: Text('MeshMapper forward key${k.label == null ? '' : ': ${k.label}'}'),
          subtitle: Text('${k.active ? 'Active' : 'Switched off ${_day(k.revokedAt)}'} · created ${_day(k.createdAt)} · last batch ${_day(k.lastBatchAt)} · '
              '${k.items24h} items in 24 h, ${k.items} in all · ends in ${k.keyHint}'),
          isThreeLine: true,
          trailing: k.active && k.revealable ? _RevealButton(kind: 'mm', id: k.id, label: 'MeshMapper link') : null,
        ),
      );
}

/// Shows a key (or the MeshMapper import link) from the server for 30 s in a dialog; the text lives in this widget only.
class _RevealButton extends StatefulWidget {
  final String kind, id, label;
  const _RevealButton({required this.kind, required this.id, required this.label});
  @override
  State<_RevealButton> createState() => _RevealButtonState();
}

class _RevealButtonState extends State<_RevealButton> {
  bool _busy = false;

  Future<void> _go() async {
    final s = AppScope.read(context);
    setState(() => _busy = true);
    RevealedKey? r;
    String? err;
    try {
      r = await s.revealKeyOnServer(widget.kind, widget.id);
    } catch (e) {
      err = e is CmatException && e.status == 429 ? 'You have looked at keys a lot this hour. Try again later.' : friendlyError(e, action: 'Showing the key');
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null || r == null || !r.revealable) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'This key was made before keys could be viewed, so it cannot be shown. Make a new key.')));
      return;
    }
    await showDialog<void>(context: context, builder: (_) => _RevealDialog(title: widget.label, revealed: r!));
  }

  @override
  Widget build(BuildContext context) => IconButton(
        key: ValueKey('reveal-${widget.kind}-${widget.id}'),
        tooltip: 'Show key',
        onPressed: _busy ? null : _go,
        icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.visibility_outlined),
      );
}

class _RevealDialog extends StatefulWidget {
  final String title;
  final RevealedKey revealed;
  const _RevealDialog({required this.title, required this.revealed});
  @override
  State<_RevealDialog> createState() => _RevealDialogState();
}

class _RevealDialogState extends State<_RevealDialog> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer(keyRevealFor, () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.revealed;
    final text = r.configLink ?? r.key!;
    return AlertDialog(
      key: const Key('reveal-dialog'),
      title: Text(widget.title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        SelectableText(text, key: const Key('reveal-text'), style: const TextStyle(fontFamily: 'monospace')),
        const SizedBox(height: Gap.s),
        Text(r.configLink != null ? 'Copy the link, then paste it into MeshMapper\'s Custom API Endpoint. ' : '', style: Theme.of(context).textTheme.bodySmall),
        Text('This closes by itself after 30 seconds.', style: Theme.of(context).textTheme.bodySmall),
      ]),
      actions: [
        TextButton(
          key: const Key('reveal-copy'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
          },
          child: const Text('Copy'),
        ),
        TextButton(key: const Key('reveal-close'), onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}
