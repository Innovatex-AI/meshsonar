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
import '../design/app_surfaces.dart';
import 'person_devices_screen.dart';

const Duration keyRevealFor = Duration(seconds: 30);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "30 Oct 2026", in the phone's time zone.
String _day(DateTime t) {
  final l = t.toLocal();
  return '${l.day} ${_months[l.month - 1]} ${l.year}';
}

/// One line for a key row: what it is doing now first, then the dates, then how to recognise it.
String keyLine(DriverKeyStatus status, {DateTime? createdAt, DateTime? lastSeenAt, String? keyHint}) => [
      statusWords(status),
      lastSeenAt == null ? 'no uploads yet' : 'last upload ${_day(lastSeenAt)}',
      if (createdAt != null) 'made ${_day(createdAt)}',
      if (keyHint != null) 'ends in $keyHint',
    ].join(' · ');

/// What the person should do about this phone's key, or null when it simply works.
String? keyNextStep(DriverKeyStatus s) => switch (s) {
      DriverKeyStatus.pending => 'Pull down to check again.',
      DriverKeyStatus.rejected => 'The server turned this key down. Make a new key below.',
      DriverKeyStatus.revoked => 'This key was switched off. Make a new key below.',
      _ => null,
    };

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
    if (s.radioProofCapable) return; // ID step 3: PersonDevicesScreen is shown instead; no driver-devices call
    unawaited(s.settlePendingKey());
    _future = s.accountAvailable ? s.loadDriverDevices() : null;
  }

  void _load() {
    final s = AppScope.read(context);
    final f = s.accountAvailable ? (s.loadDriverDevices()..ignore()) : null; // the FutureBuilder shows a failure
    setState(() {
      _future = f;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    if (s.radioProofCapable) return const PersonDevicesScreen();
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
                'One key per phone. No account or sign-in needed.',
                key: const Key('devices-intro'),
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: Gap.m),
              _ThisPhone(onChanged: _load),
              const SizedBox(height: Gap.l),
              if (!s.hasKey)
                EmptyState(
                  key: const Key('devices-nokey'),
                  icon: Icons.key_off_outlined,
                  title: 'No driver key on this phone',
                  body: 'Go back to Account & driver key and create one.',
                  action: FilledButton.tonal(key: const Key('devices-nokey-back'), onPressed: () => Navigator.of(context).maybePop(), child: const Text('Back')),
                )
              else if (_future == null)
                const _Note(
                    key: Key('devices-unavailable'),
                    text: 'Your other phones cannot be listed on this server yet. The key above still works.')
              else
                FutureBuilder<DriverDevices>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Padding(
                        key: Key('devices-loading'),
                        padding: EdgeInsets.all(Gap.l),
                        child: Column(children: [CircularProgressIndicator(), SizedBox(height: Gap.s), Text('Loading your keys…')]),
                      );
                    }
                    if (snap.hasError) {
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        ErrorBanner(friendlyError(snap.error!, action: 'Loading your keys')),
                        FilledButton.tonalIcon(
                          key: const Key('devices-retry'),
                          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Try again'),
                        ),
                      ]);
                    }
                    return _Account(devices: snap.data!, onChanged: _load);
                  },
                ),
              const SizedBox(height: Gap.l),
              TextButton.icon(
                key: const Key('devices-website'),
                onPressed: () => s.openWebPage('/me/devices'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open on the website'),
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
  int _left = 0;
  Timer? _timer;
  bool _busy = false;
  String? _msg;
  bool _failed = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle(bool on) {
    _timer?.cancel();
    setState(() {
      _show = on;
      _left = keyRevealFor.inSeconds;
    });
    if (on) {
      // Ticks once a second so the card can say how long the key stays on screen.
      _timer = Timer.periodic(const Duration(seconds: 1), (tm) {
        if (!mounted) return tm.cancel();
        setState(() => _left--);
        if (_left <= 0) {
          tm.cancel();
          setState(() => _show = false);
        }
      });
    }
  }

  Future<void> _rotate(AppState s) async {
    final ok = await confirmSettingsChange(context,
        dialogKey: 'rotate-key-dialog',
        title: 'Make a new key for this phone?',
        body: 'The old key stops working at once. Your drives stay. '
            'Another phone using the old key stops uploading until you paste the new one into it.',
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
      _failed = err != null;
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
    final works = st.keyStatus == DriverKeyStatus.approved;
    final bad = st.keyStatus == DriverKeyStatus.rejected || st.keyStatus == DriverKeyStatus.revoked;
    final next = keyNextStep(st.keyStatus);
    final statusColor = works ? t.colorScheme.primary : (bad ? t.colorScheme.error : t.colorScheme.onSurfaceVariant);
    return Card(
      key: const Key('devices-this-phone'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('This phone', style: t.textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(works ? Icons.check_circle_outline : (bad ? Icons.error_outline : Icons.hourglass_empty), size: 20, color: statusColor),
            const SizedBox(width: Gap.s),
            Expanded(
              child: Text('${statusWords(st.keyStatus)}${st.display == null ? '' : ' · shown as ${st.display}'}', key: const Key('devices-this-status')),
            ),
          ]),
          if (next != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(next, key: const Key('devices-this-next'), style: t.textTheme.bodyMedium?.copyWith(color: bad ? t.colorScheme.error : null)),
            ),
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
            // Always there: copying does not need the key on screen first (one tap, not two).
            IconButton(
              key: const Key('devices-key-copy'),
              tooltip: 'Copy key',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: st.driverKey ?? ''));
                if (context.mounted) showAppToast(context, 'Key copied', kind: AppToastKind.success);
              },
            ),
          ]),
          Text(_show ? 'Hides in $_left s. Keep it private.' : 'Keep it private: anyone with the key can upload as you.',
              key: const Key('devices-key-note'), style: t.textTheme.bodySmall),
          if (st.pendingDriverKey != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.s),
              child: Text('A key change is being checked with the server.', key: const Key('devices-pending'), style: t.textTheme.bodySmall),
            ),
          if (_msg != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.s),
              child: Text(_msg!, key: const Key('devices-rotate-result'), style: TextStyle(color: _failed ? t.colorScheme.error : t.colorScheme.primary)),
            ),
          const SizedBox(height: Gap.s),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('devices-rotate'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: (!canRotate || _busy || s.keyBusy) ? null : () => _rotate(s),
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.autorenew),
              label: const Text('Make a new key'),
            ),
          ),
          if (!canRotate)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text('Not available yet: this server has not confirmed the key.', key: const Key('devices-rotate-why'), style: t.textTheme.bodySmall),
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
          'Only this phone is listed: the key has no website account. That is fine.',
          key: const Key('devices-unlinked'),
          style: t.textTheme.bodyMedium,
        ),
      Card(
        child: ListTile(
          key: const Key('devices-row-self'),
          leading: const Icon(Icons.smartphone),
          title: Text('${devices.driver.display} (this phone)'),
          subtitle: Text(keyLine(devices.driver.status, createdAt: devices.driver.createdAt, lastSeenAt: devices.driver.lastSeenAt, keyHint: devices.driver.keyHint)),
        ),
      ),
      for (final d in others) _OtherPhone(device: d),
      const SizedBox(height: Gap.l),
      Text('MeshMapper forwarding', style: t.textTheme.titleMedium),
      const SizedBox(height: Gap.xs),
      Text('Send drives from the MeshMapper app here too.', key: const Key('devices-mm-intro'), style: t.textTheme.bodyMedium),
      const SizedBox(height: Gap.s),
      if (!devices.linked)
        const _Note(
            key: Key('devices-mm-needs-account'),
            text: 'Needs a website account. Sign in on the website with your email once to link this key.')
      else if (devices.mmKeys.isEmpty)
        const _Note(key: Key('devices-mm-none'), text: 'No forward key yet. Make one on the website and it shows here.')
      else
        for (final k in devices.mmKeys) _MmKeyTile(k: k),
      if (!devices.linked || devices.mmKeys.isEmpty)
        _WebButton(key: const Key('devices-mm-website'), label: devices.linked ? 'Make a forward key on the website' : 'Sign in on the website'),
      if (devices.linked) ...[
        const SizedBox(height: Gap.l),
        Text('Your account', style: t.textTheme.titleMedium),
        const SizedBox(height: Gap.xs),
        const _Note(key: Key('devices-profile'), text: 'Your public name and the leaderboard choice are changed on the website.'),
        const _WebButton(key: Key('devices-profile-website'), label: 'Change on the website'),
      ],
    ]);
  }
}

/// Opens the website's devices page: the place for the things this page only describes (forward keys, name, leaderboard).
class _WebButton extends StatelessWidget {
  final String label;
  const _WebButton({super.key, required this.label});
  @override
  Widget build(BuildContext context) => Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => AppScope.read(context).openWebPage('/me/devices'),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text(label),
        ),
      );
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
          subtitle: Text(keyLine(device.status, createdAt: device.createdAt, lastSeenAt: device.lastSeenAt, keyHint: device.keyHint)),
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
          title: Text(k.label == null ? 'Forward key' : 'Forward key: ${k.label}'),
          subtitle: Text([
            k.active ? 'Works' : 'Switched off${k.revokedAt == null ? '' : ' ${_day(k.revokedAt!)}'}',
            k.lastBatchAt == null ? 'nothing received yet' : 'last received ${_day(k.lastBatchAt!)}',
            '${k.items24h} items in 24 h, ${k.items} in all',
            if (k.createdAt != null) 'made ${_day(k.createdAt!)}',
            'ends in ${k.keyHint}',
          ].join(' · ')),
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
      showAppToast(context, err ?? 'This older key cannot be shown. Make a new key instead.', kind: AppToastKind.error);
      return;
    }
    await showAppSheet<void>(
      context,
      detents: [MediaQuery.textScalerOf(context).scale(10) > 13 ? 0.92 : 0.5], // large text: the key, both buttons and the title need the room
      builder: (_, controller) => _RevealDialog(title: widget.label, revealed: r!, controller: controller),
    );
  }

  @override
  Widget build(BuildContext context) => IconButton(
        key: ValueKey('reveal-${widget.kind}-${widget.id}'),
        tooltip: widget.kind == 'mm' ? 'Show the MeshMapper link' : 'Show key',
        onPressed: _busy ? null : _go,
        icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.visibility_outlined),
      );
}

class _RevealDialog extends StatefulWidget {
  final String title;
  final RevealedKey revealed;
  final ScrollController controller;
  const _RevealDialog({required this.title, required this.revealed, required this.controller});
  @override
  State<_RevealDialog> createState() => _RevealDialogState();
}

class _RevealDialogState extends State<_RevealDialog> {
  Timer? _timer;
  int _left = keyRevealFor.inSeconds;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (tm) {
      if (!mounted) return tm.cancel();
      setState(() => _left--);
      if (_left <= 0) {
        tm.cancel();
        Navigator.of(context).maybePop();
      }
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
    final text = r.configLink ?? r.key ?? '';
    final small = Theme.of(context).textTheme.bodySmall;
    return AppSheetScaffold(
      key: const Key('reveal-dialog'),
      controller: widget.controller,
      title: widget.title,
      // Copy is what the person came for, so it is the big button; Close is the quiet one.
      primaryAction: FilledButton.icon(
        key: const Key('reveal-copy'),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: text));
          if (context.mounted) showAppToast(context, 'Copied', kind: AppToastKind.success);
        },
        icon: const Icon(Icons.copy_rounded),
        label: Text(r.configLink != null ? 'Copy link' : 'Copy key'),
      ),
      secondaryAction: TextButton(key: const Key('reveal-close'), onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      children: [
        SelectableText(text, key: const Key('reveal-text'), style: const TextStyle(fontFamily: 'monospace')),
        const SizedBox(height: Gap.s),
        if (r.configLink != null) Text('Paste it into MeshMapper > Custom API Endpoint.', key: const Key('reveal-how'), style: small),
        Text('Closes in $_left s. Keep it private.', key: const Key('reveal-countdown'), style: small),
      ],
    );
  }
}
