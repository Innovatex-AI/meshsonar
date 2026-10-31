// Settings > Account & driver key: the driver key (request, paste, reveal, remove), the server it works on, and the
// website links for the account. DriverKeyScreen shows the key part on its own over screens that need a key.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../core/api.dart';
import '../../core/server_url.dart';
import '../app.dart';
import '../widgets.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String driverHelp =
    'Your driver key lets this phone upload drives to the coverage map. Without one, drives stay on this phone (you '
    'can still export them).';

/// The section's rows, for the Settings shell.
List<Widget> accountSectionRows(BuildContext context) => const [
      SettingsAnchor(id: 'driver-key', child: DriverKeySection()),
      SettingsAnchor(id: 'server-url', child: ServerUrlTile()),
    ];

class ServerUrlTile extends StatelessWidget {
  const ServerUrlTile({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final st = s.settings;
    final e = settingsEntry('server-url');
    return ListTile(
      key: const Key('server-url'),
      leading: const Icon(Icons.dns_outlined),
      title: Text(e.title),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(st.serverUrl), Text(e.summary)]),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final v = await editSettingText(context,
            title: 'Server URL',
            initial: st.serverUrl,
            hint: defaultServerUrl,
            keyboard: TextInputType.url,
            help: 'Any server that speaks the MeshSonar Drive Format works. A key from one server '
                'doesn\'t work on another.',
            validate: (v) {
              final u = Uri.tryParse(v.trim());
              if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) {
                return 'Enter a full address starting with https://';
              }
              return null;
            });
        if (v == null || !context.mounted) return;
        final url = v.trim().replaceAll(RegExp(r'/+$'), '');
        if (url == s.settings.serverUrl) return;
        // Another address of the same server (old Lovable host, meshsonar.com, cmh.meshsonar.com) keeps
        // the key, so there is nothing to ask.
        final sameServer = isSameServer(url, s.settings.serverUrl);
        if (s.hasKey && !sameServer && !await confirmServerChange(context, url)) return;
        await s.updateSettings(s.settings.copyWith(serverUrl: url));
      },
    );
  }
}

/// The driver key part of Settings on a screen of its own, opened over screens that need a key (Report a problem);
/// Back returns there with nothing lost.
class DriverKeyScreen extends StatelessWidget {
  const DriverKeyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Driver key')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
          children: const [
            SettingsSection(
              id: 'driver',
              title: 'Driver key',
              icon: Icons.badge_outlined,
              help: driverHelp,
              children: [DriverKeySection()],
            ),
          ],
        ),
      ),
    );
  }
}

/// Coloured pill for the driver-key status.
class KeyStatusBadge extends StatelessWidget {
  final DriverKeyStatus status;
  const KeyStatusBadge({super.key, required this.status});

  static Color colorFor(BuildContext context, DriverKeyStatus st) {
    final c = Theme.of(context).colorScheme;
    final m = MeshSonarColors.of(context);
    return switch (st) {
      DriverKeyStatus.approved => m.snrStrong,
      DriverKeyStatus.pending => m.beacon,
      DriverKeyStatus.none => c.outline,
      _ => c.error,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(context, status);
    final icon = switch (status) {
      DriverKeyStatus.approved => Icons.verified,
      DriverKeyStatus.pending => Icons.hourglass_top,
      DriverKeyStatus.none => Icons.key_off,
      _ => Icons.block,
    };
    return Container(
      key: const Key('key-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(keyStatusLabel(status),
              key: const Key('key-status'),
              style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 14)),
        ),
      ]),
    );
  }
}

String keyStatusLabel(DriverKeyStatus s) => switch (s) {
      DriverKeyStatus.none => 'No key',
      DriverKeyStatus.pending => 'Pending approval',
      DriverKeyStatus.approved => 'Approved',
      DriverKeyStatus.rejected => 'Rejected',
      DriverKeyStatus.revoked => 'Revoked',
      DriverKeyStatus.unknown => 'Not recognised by this server',
    };

String keyStatusHelp(DriverKeyStatus s) => switch (s) {
      DriverKeyStatus.none => 'Request a key to upload your drives.',
      DriverKeyStatus.pending =>
        'An admin needs to approve your key. You can drive now; your drives upload once it\'s approved. Tap Refresh to check.',
      DriverKeyStatus.approved => 'Your drives can upload.',
      DriverKeyStatus.rejected => 'This key was rejected. Contact the server admin, or request a new key.',
      DriverKeyStatus.revoked => 'This key was revoked. Contact the server admin, or request a new key.',
      DriverKeyStatus.unknown => 'The server doesn\'t know this key (maybe a different server). Request a new key.',
    };

/// Asks before switching servers when this phone has a driver key: keys only work on the server that issued them,
/// so the key is removed. Returns true to go ahead.
Future<bool> confirmServerChange(BuildContext context, String newUrl) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('server-change-dialog'),
      title: const Text('Change server and remove your key?'),
      content: Text('A driver key only works on the server that issued it, so your current key will be removed. '
          'Request a new key from $newUrl afterwards.\n\n'
          'Drives already uploaded stay on the old server. Drives not yet uploaded stay on this phone and will upload '
          'to the new server once you have a key there.'),
      actions: [
        TextButton(key: const Key('server-change-cancel'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
            key: const Key('server-change-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Change server')),
      ],
    ),
  );
  return ok == true;
}

/// Where to manage drives on the website, and a button to get a key there. (Privacy zones moved to Settings >
/// Privacy & data sharing.)
class AccountLinks extends StatelessWidget {
  const AccountLinks({super.key});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(
        'Manage your drives and privacy at ${s.webPage('/me')} — sign in with the same email you registered with',
        key: const Key('account-hint'),
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('key-website'),
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 0)),
          onPressed: () => s.openWebPage('/me/devices'),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Get a key on the website'),
        ),
      ),
    ]);
  }
}

class DriverKeySection extends StatefulWidget {
  const DriverKeySection({super.key});
  @override
  State<DriverKeySection> createState() => _DriverKeySectionState();
}

class _DriverKeySectionState extends State<DriverKeySection> {
  final _name = TextEditingController();
  final _callsign = TextEditingController();
  final _email = TextEditingController();
  final _pasted = TextEditingController();

  // Tap-to-reveal: the full key is on screen only while the person asks for it (hides itself after 30 s).
  bool _revealKey = false;
  Timer? _hideTimer;

  void _setReveal(bool on) {
    _hideTimer?.cancel();
    setState(() => _revealKey = on);
    if (on) {
      _hideTimer = Timer(const Duration(seconds: 30), () {
        if (mounted) setState(() => _revealKey = false);
      });
    }
  }
  bool _showPaste = false;
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    _callsign.dispose();
    _email.dispose();
    _pasted.dispose();
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final st = s.settings;
    if (s.hasKey) return _status(context, s, st);
    return _requestForm(context, s);
  }

  Widget _status(BuildContext context, AppState s, Settings st) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A Wrap, not a Row: with large text the Refresh button moves under the badge instead of squeezing it.
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
            KeyStatusBadge(status: st.keyStatus),
            if (s.keyBusy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              TextButton.icon(
                key: const Key('key-refresh'),
                onPressed: () => s.refreshKeyStatus(),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
          ]),
          const SizedBox(height: 10),
          if (st.display != null)
            Text('Shown on the map as: ${st.display}', style: t.textTheme.titleSmall),
          Row(children: [
            Expanded(
              child: _revealKey
                  ? SelectableText(st.driverKey ?? '',
                      key: const Key('revealed-key'), style: t.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'))
                  : Text('Driver key: ${s.maskedKey}', key: const Key('masked-key'), style: t.textTheme.bodyMedium),
            ),
            IconButton(
              key: const Key('key-reveal'),
              tooltip: _revealKey ? 'Hide key' : 'Show key',
              icon: Icon(_revealKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => _setReveal(!_revealKey),
            ),
            if (_revealKey)
              IconButton(
                key: const Key('key-copy'),
                tooltip: 'Copy key',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: st.driverKey ?? ''));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Key copied')));
                  }
                },
              ),
          ]),
          Text('Works on ${st.serverUrl}. Keep it private: anyone with it can upload drives as you.',
              key: const Key('key-info'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Text(keyStatusHelp(st.keyStatus), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          if (s.keyError != null) ...[const SizedBox(height: 8), ErrorBanner(s.keyError!)],
          const SizedBox(height: 8),
          const AccountLinks(),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('forget-key'),
              style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    key: const Key('forget-key-dialog'),
                    title: const Text('Remove this driver key?'),
                    content: const Text(
                        'Make sure you can get it again before you remove it: the website\'s Devices page shows keys made after it was updated, otherwise you\'ll need a new one.\n\n'
                        'Without a key, drives stay on this phone and nothing uploads; packet headers stop being collected. '
                        'The app keeps no copy: to undo, paste the same key again with "I already have a key".'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(
                          key: const Key('forget-key-confirm'),
                          style: FilledButton.styleFrom(
                              backgroundColor: Theme.of(ctx).colorScheme.error, foregroundColor: Theme.of(ctx).colorScheme.onError),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Remove')),
                    ],
                  ),
                );
                if (ok == true) await s.forgetKey();
              },
              child: const Text('Remove key'),
            ),
          ),
        ],
      ),
    );
  }

  /// Saves the pasted key; on success the field is wiped and folded away so the full key never shows again.
  Future<void> _usePasted(AppState s) async {
    final ok = await s.useExistingKey(_pasted.text);
    if (ok && mounted) {
      setState(() {
        _pasted.clear();
        _showPaste = false;
      });
    }
  }

  Widget _requestForm(BuildContext context, AppState s) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: SizedBox(
        width: double.infinity,
        child: Material(
          type: MaterialType.transparency,
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Text('Driver key', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  const KeyStatusBadge(status: DriverKeyStatus.none),
                ]),
                const SizedBox(height: 6),
                Text(
                  'To upload drives, ask the server for a driver key. Your callsign (or "Driver N") is shown publicly; '
                  'your name and email are only seen by the server admin.',
                  style: t.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: const Key('key-name'),
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name (required)'),
                  textInputAction: TextInputAction.next,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your name' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  key: const Key('key-callsign'),
                  controller: _callsign,
                  decoration: const InputDecoration(labelText: 'Callsign (optional)'),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  key: const Key('key-email'),
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Email (optional)'),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) =>
                      (v != null && v.trim().isNotEmpty && !v.contains('@')) ? 'That doesn\'t look like an email' : null,
                ),
                const SizedBox(height: 16),
                if (s.keyError != null && !_showPaste) ErrorBanner(s.keyError!),
                FilledButton.icon(
                  key: const Key('key-request'),
                  onPressed: s.keyBusy
                      ? null
                      : () {
                          if (!(_form.currentState?.validate() ?? false)) return;
                          FocusScope.of(context).unfocus();
                          s.requestKey(name: _name.text, callsign: _callsign.text, email: _email.text);
                        },
                  icon: s.keyBusy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.vpn_key),
                  label: const Text('Request key'),
                ),
                const SizedBox(height: 12),
                const AccountLinks(),
                if (!_showPaste)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('key-have'),
                      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 0)),
                      onPressed: () => setState(() => _showPaste = true),
                      icon: const Icon(Icons.key, size: 18),
                      label: const Text('I already have a key'),
                    ),
                  )
                else ...[
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('key-paste'),
                    controller: _pasted,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Paste your driver key'),
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!s.keyBusy) _usePasted(s);
                    },
                  ),
                  if (s.keyError != null) ...[const SizedBox(height: 8), ErrorBanner(s.keyError!, key: const Key('key-paste-error'))],
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: const Key('key-use'),
                    onPressed: s.keyBusy
                        ? null
                        : () {
                            FocusScope.of(context).unfocus();
                            _usePasted(s);
                          },
                    icon: const Icon(Icons.key),
                    label: const Text('Use this key'),
                  ),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('key-privacy-policy'),
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 0)),
                    onPressed: () => s.services.openUrl(Uri.parse(privacyPolicyUrl)),
                    icon: const Icon(Icons.policy_outlined, size: 18),
                    label: const Text('Privacy policy'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
