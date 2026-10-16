// Settings, grouped: Driver & server, Wardriving, Antenna, Sync, About.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/api.dart';
import '../core/model.dart';
import 'about_screen.dart';
import 'onboarding/onboarding_screen.dart';
import 'app.dart';
import 'widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final st = s.settings;
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          key: const Key('settings-list'),
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
          children: [
            _Section(
              id: 'driver',
              title: 'Driver & server',
              icon: Icons.badge_outlined,
              help: 'Your driver key lets this phone upload drives to the coverage map. Without one, drives stay on '
                  'this phone (you can still export them).',
              children: [
                const _DriverKeySection(),
                ListTile(
                  key: const Key('server-url'),
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Server URL'),
                  subtitle: Text(st.serverUrl),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final v = await _editText(context,
                        title: 'Server URL',
                        initial: st.serverUrl,
                        hint: 'https://cmh-meshcore.lovable.app',
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
                    if (v != null) await s.updateSettings(st.copyWith(serverUrl: v.trim().replaceAll(RegExp(r'/+$'), '')));
                  },
                ),
              ],
            ),
            _Section(
              id: 'wardriving',
              title: 'Wardriving',
              icon: Icons.radar,
              help: 'How often MeshSonar pings while you drive, and on which channel. Changes apply to the next drive.',
              children: [
                ListTile(
                  key: const Key('channel'),
                  leading: const Icon(Icons.tag),
                  title: const Text('Channel'),
                  subtitle: Text(st.channel),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final v = await _editText(context,
                        title: 'Channel',
                        initial: st.channel,
                        hint: '#wardriving',
                        help: 'The channel pings are sent on. Use the one your mesh community wardrives on.',
                        validate: (v) => v.trim().isEmpty ? 'Enter a channel name' : null);
                    if (v != null) {
                      var c = v.trim();
                      if (!c.startsWith('#')) c = '#$c';
                      await s.updateSettings(st.copyWith(channel: c));
                    }
                  },
                ),
                ListTile(
                  key: const Key('interval'),
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('Auto-ping every'),
                  subtitle: Text(st.intervalSec == 0 ? 'Off (manual pings only)' : '${st.intervalSec} seconds'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final v = await _editInt(context,
                        title: 'Auto-ping interval (seconds)', initial: st.intervalSec, min: 0, max: 3600,
                        help: '0 turns auto-ping off. 30 to 60 seconds suits most drives.');
                    if (v != null) await s.updateSettings(st.copyWith(intervalSec: v));
                  },
                ),
                ListTile(
                  key: const Key('min-distance'),
                  leading: const Icon(Icons.straighten),
                  title: const Text('Minimum distance between auto-pings'),
                  subtitle: Text('${st.minDistanceM} m · skips pings while you\'re stopped'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final v = await _editInt(context,
                        title: 'Minimum distance (metres)', initial: st.minDistanceM, min: 0, max: 10000,
                        help: 'Skip an auto-ping if you haven\'t moved this far. Saves airtime at red lights.');
                    if (v != null) await s.updateSettings(st.copyWith(minDistanceM: v));
                  },
                ),
              ],
            ),
            _Section(
              id: 'antenna',
              title: 'Antenna',
              icon: Icons.settings_input_antenna,
              help: 'Recorded with each drive so coverage maps can compare like with like. Leave blank if unsure.',
              children: [
                ListTile(
                  key: const Key('antenna-type'),
                  leading: const Icon(Icons.settings_input_antenna),
                  title: const Text('Antenna type'),
                  subtitle: Text(st.antenna.type ?? 'Not set'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final v = await _editText(context,
                        title: 'Antenna type', initial: st.antenna.type ?? '', hint: 'stock, mag-mount, external…', allowEmpty: true);
                    if (v != null) {
                      await s.updateSettings(st.copyWith(
                          antenna: Antenna(
                              type: v.trim().isEmpty ? null : v.trim(), gainDbi: st.antenna.gainDbi, heightM: st.antenna.heightM)));
                    }
                  },
                ),
                ListTile(
                  key: const Key('antenna-gain'),
                  leading: const Icon(Icons.signal_cellular_alt),
                  title: const Text('Antenna gain'),
                  subtitle: Text(st.antenna.gainDbi == null ? 'Not set' : '${st.antenna.gainDbi} dBi'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final v = await _editDouble(context, title: 'Antenna gain (dBi)', initial: st.antenna.gainDbi);
                    if (v != null) {
                      await s.updateSettings(st.copyWith(
                          antenna: Antenna(type: st.antenna.type, gainDbi: v.value, heightM: st.antenna.heightM)));
                    }
                  },
                ),
                ListTile(
                  key: const Key('antenna-height'),
                  leading: const Icon(Icons.height),
                  title: const Text('Antenna height above ground'),
                  subtitle: Text(st.antenna.heightM == null ? 'Not set' : '${st.antenna.heightM} m'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final v = await _editDouble(context, title: 'Antenna height (metres)', initial: st.antenna.heightM);
                    if (v != null) {
                      await s.updateSettings(st.copyWith(
                          antenna: Antenna(type: st.antenna.type, gainDbi: st.antenna.gainDbi, heightM: v.value)));
                    }
                  },
                ),
              ],
            ),
            _Section(
              id: 'sync',
              title: 'Sync',
              icon: Icons.cloud_sync_outlined,
              help: 'Drives are always saved on this phone first. Uploads are safe to retry; nothing is sent twice.',
              children: [
                SwitchListTile(
                  key: const Key('auto-sync'),
                  secondary: const Icon(Icons.cloud_sync),
                  title: const Text('Upload automatically when a drive stops'),
                  subtitle: const Text('Needs an approved driver key.'),
                  value: st.autoSync,
                  onChanged: (v) => s.updateSettings(st.copyWith(autoSync: v)),
                ),
                ListTile(
                  key: const Key('refresh-repeaters'),
                  leading: const Icon(Icons.cell_tower),
                  title: const Text('Repeater names'),
                  subtitle: Text(s.repeaters.isEmpty
                      ? 'None saved yet. Names download once your key is approved.'
                      : '${s.repeaters.length} saved for offline use'),
                  trailing: const Icon(Icons.refresh),
                  onTap: s.hasKey ? () => s.refreshRepeaters() : null,
                ),
              ],
            ),
            _Section(
              id: 'about-section',
              title: 'About',
              icon: Icons.info_outline,
              children: [
                ListTile(
                  key: const Key('about'),
                  leading: const Icon(Icons.info_outline),
                  title: const Text('About MeshSonar'),
                  subtitle: Text('Version ${s.services.appInfo.version ?? ''} · MIT licence'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
                ),
                ListTile(
                  key: const Key('show-intro'),
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: const Text('Show the welcome tour'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    fullscreenDialog: true,
                    builder: (ctx) => OnboardingScreen(onFinish: (_) => Navigator.of(ctx).pop()),
                  )),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Settings are saved on this phone as you change them.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A titled group of settings in one rounded card.
class _Section extends StatelessWidget {
  final String id;
  final String? title;
  final IconData? icon;
  final String? help;
  final List<Widget> children;
  const _Section({required this.id, this.title, this.icon, this.help, required this.children});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    return Padding(
      key: Key('section-$id'),
      padding: EdgeInsets.fromLTRB(12, title == null ? 0 : 14, 12, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Row(children: [
              if (icon != null) ...[Icon(icon, size: 18, color: c.primary), const SizedBox(width: 8)],
              Text(title!.toUpperCase(),
                  style: t.textTheme.labelLarge?.copyWith(color: c.primary, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
            ]),
          ),
        if (help != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(help!, style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
          ),
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: 56, color: c.outlineVariant.withValues(alpha: 0.5)),
              children[i],
            ],
          ]),
        ),
      ]),
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

class _DriverKeySection extends StatefulWidget {
  const _DriverKeySection();
  @override
  State<_DriverKeySection> createState() => _DriverKeySectionState();
}

class _DriverKeySectionState extends State<_DriverKeySection> {
  final _name = TextEditingController();
  final _callsign = TextEditingController();
  final _email = TextEditingController();
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    _callsign.dispose();
    _email.dispose();
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
          Row(children: [
            Flexible(child: KeyStatusBadge(status: st.keyStatus)),
            const Spacer(),
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
          Text('Driver key: ${s.maskedKey}', key: const Key('masked-key'), style: t.textTheme.bodyMedium),
          const SizedBox(height: 6),
          Text(keyStatusHelp(st.keyStatus), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          if (s.keyError != null) ...[const SizedBox(height: 8), ErrorBanner(s.keyError!)],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('forget-key'),
              style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Remove this driver key?'),
                    content: const Text(
                        'The key is shown only once by the server. If you remove it you\'ll need to request a new one.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
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
                if (s.keyError != null) ErrorBanner(s.keyError!),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- edit dialogs ----------

Future<String?> _editText(
  BuildContext context, {
  required String title,
  required String initial,
  String? hint,
  String? help,
  TextInputType? keyboard,
  bool allowEmpty = false,
  String? Function(String)? validate,
}) {
  final c = TextEditingController(text: initial);
  final formKey = GlobalKey<FormState>();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Form(
        key: formKey,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextFormField(
            key: const Key('edit-field'),
            controller: c,
            autofocus: true,
            keyboardType: keyboard,
            decoration: InputDecoration(hintText: hint),
            validator: (v) {
              final s = v ?? '';
              if (!allowEmpty && s.trim().isEmpty && validate == null) return 'Enter a value';
              return validate?.call(s);
            },
          ),
          if (help != null) ...[const SizedBox(height: 8), Text(help, style: Theme.of(ctx).textTheme.bodySmall)],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          key: const Key('edit-save'),
          onPressed: () {
            if (formKey.currentState?.validate() ?? false) Navigator.pop(ctx, c.text);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<int?> _editInt(BuildContext context,
    {required String title, required int initial, required int min, required int max, String? help}) async {
  final v = await _editText(context,
      title: title,
      initial: '$initial',
      help: help,
      keyboard: TextInputType.number,
      validate: (v) {
        final n = int.tryParse(v.trim());
        if (n == null || n < min || n > max) return 'Enter a whole number from $min to $max';
        return null;
      });
  return v == null ? null : int.parse(v.trim());
}

/// Returns null if cancelled; a box holding null if cleared.
Future<({double? value})?> _editDouble(BuildContext context, {required String title, double? initial}) async {
  final v = await _editText(context,
      title: title,
      initial: initial?.toString() ?? '',
      help: 'Leave empty if you don\'t know.',
      allowEmpty: true,
      keyboard: const TextInputType.numberWithOptions(decimal: true, signed: true),
      validate: (v) => v.trim().isEmpty || double.tryParse(v.trim()) != null ? null : 'Enter a number, or leave empty');
  if (v == null) return null;
  return (value: v.trim().isEmpty ? null : double.parse(v.trim()));
}
