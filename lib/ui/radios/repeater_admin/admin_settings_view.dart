// Settings form, grouped. Every row shows the value read from the repeater; a tap opens the editor sheet, which is the only
// way anything is written. Radio settings are compared with the region's preset; the observer uplink is read-only.
import 'package:flutter/material.dart';

import '../../../radio/repeater_admin.dart';
import '../../../radio/repeater_settings.dart';
import '../../theme.dart';
import 'admin_common.dart';
import 'admin_controller.dart';
import 'setting_editor_sheet.dart';

class AdminSettingsView extends StatefulWidget {
  final RepeaterAdminController controller;
  const AdminSettingsView({super.key, required this.controller});

  @override
  State<AdminSettingsView> createState() => _AdminSettingsViewState();
}

class _AdminSettingsViewState extends State<AdminSettingsView> {
  RepeaterAdminController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) c.loadSettings();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.isAdmin) {
          return const Padding(
            padding: EdgeInsets.all(Gap.xl),
            child: Center(child: Text('Settings need the admin password. You are logged in as a guest.', key: Key('settings-guest'), textAlign: TextAlign.center)),
          );
        }
        final p = c.settingsProgress;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: RefreshIndicator(
              onRefresh: () => c.loadSettings(force: true),
              child: ListView(
                key: const Key('admin-settings'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
                children: [
                  if (c.notices['settings'] != null) NoticeBanner(c.notices['settings']!, bannerKey: const Key('settings-notice')),
                  if (c.loadingSettings)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.m),
                      child: Column(children: [
                        LinearProgressIndicator(key: const Key('settings-progress'), value: p == null || p.total == 0 ? null : p.done / p.total),
                        const SizedBox(height: 6),
                        Text(p == null ? 'Reading settings...' : 'Reading ${p.done} of ${p.total}. Each takes about a second.', textAlign: TextAlign.center),
                      ]),
                    ),
                  if (c.session.pendingReboot.isNotEmpty) _rebootBanner(context),
                  _group(context, 'Identity', SettingGroup.identity, icon: Icons.badge_outlined),
                  _radioGroup(context),
                  if (!c.isRoom) _group(context, 'Routing', SettingGroup.routing, icon: Icons.alt_route),
                  if (c.isObserverBuild) _observer(context),
                  _advanced(context),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _rebootBanner(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      key: const Key('reboot-banner'),
      margin: const EdgeInsets.only(bottom: Gap.s),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: t.colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.restart_alt, color: t.colorScheme.onTertiaryContainer),
        const SizedBox(width: Gap.s),
        Expanded(
            child: Text('Saved but not used yet: ${c.session.pendingReboot.join(', ')}. The repeater uses it after it reboots (see Advanced).',
                style: TextStyle(color: t.colorScheme.onTertiaryContainer, height: 1.3))),
      ]),
    );
  }

  List<SettingDef> _defs(SettingGroup g, {bool expert = false}) => [
        for (final d in c.visibleSettings)
          if (d.group == g && d.expert == expert && !d.secret && d.key != 'radio' && d.key != 'allow.read.only') d,
      ];

  Widget _group(BuildContext context, String title, SettingGroup g, {required IconData icon}) {
    final defs = _defs(g);
    if (defs.isEmpty) return const SizedBox.shrink();
    return AdminCard(cardKey: Key('group-${g.name}'), title: title, icon: icon, child: Column(children: [for (final d in defs) _row(context, d)]));
  }

  Widget _radioGroup(BuildContext context) {
    final t = Theme.of(context);
    final radio = settingFor('radio')!;
    final tx = settingFor('tx')!;
    final cur = c.settings['radio']?.value;
    final params = cur == null ? null : parseRadioParams(cur);
    final preset = c.regionPreset;
    String? presetLine;
    var matches = false;
    if (params != null && preset != null) {
      matches = (params.freqMhz - preset.freqMhz).abs() <= 0.0011 && (params.bwKhz - preset.bwKhz).abs() <= 0.051 && params.sf == preset.sf && params.cr == preset.cr;
      presetLine = matches
          ? 'Matches the region preset (${preset.name}).'
          : 'Differs from the region preset (${preset.name}: ${preset.freqMhz} MHz, ${preset.bwKhz} kHz, SF${preset.sf}, CR${preset.cr}).';
    }
    return AdminCard(
      cardKey: const Key('group-radio'),
      title: 'Radio',
      icon: Icons.settings_input_antenna,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _row(context, radio, subtitleOverride: params?.toString()),
        if (presetLine != null)
          Padding(
            padding: const EdgeInsets.only(left: Gap.xs, bottom: Gap.s),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(matches ? Icons.check_circle_outline : Icons.warning_amber_rounded, size: 18, color: matches ? t.colorScheme.primary : const Color(0xFFB26A00)),
              const SizedBox(width: 6),
              Expanded(child: Text(presetLine, key: const Key('radio-compare'), style: t.textTheme.bodyMedium)),
            ]),
          ),
        if (preset == null && params != null) Padding(padding: const EdgeInsets.only(left: Gap.xs, bottom: Gap.s), child: Text('This region has no preset on file to compare with.', style: t.textTheme.bodySmall)),
        Padding(
          padding: const EdgeInsets.only(left: Gap.xs, bottom: Gap.s),
          child: Text('Changing these can take the repeater off the air. It needs a typed confirmation and a reboot.', style: t.textTheme.bodySmall),
        ),
        _row(context, tx),
      ]),
    );
  }

  Widget _advanced(BuildContext context) {
    final t = Theme.of(context);
    final expert = [for (final d in c.visibleSettings) if (d.expert && !d.secret && d.key != 'allow.read.only') d];
    return AdminCard(
      cardKey: const Key('group-advanced'),
      title: 'Advanced',
      icon: Icons.build_outlined,
      child: Theme(
        data: t.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('advanced-tile'),
          tilePadding: EdgeInsets.zero,
          title: const Text('Expert settings and reboot'),
          subtitle: const Text('Most people never need these.'),
          children: [
            for (final d in expert) _row(context, d),
            const Divider(),
            ListTile(
              key: const Key('reboot-tile'),
              contentPadding: EdgeInsets.zero,
              minVerticalPadding: Gap.s,
              leading: Icon(Icons.restart_alt, color: t.colorScheme.error),
              title: const Text('Reboot the repeater'),
              subtitle: const Text('It is off the air for a few seconds and does not answer the reboot command. Needed after changing radio parameters.'),
              onTap: () => _reboot(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _reboot(BuildContext context) async {
    final typed = await typedConfirm(context,
        title: 'Reboot this repeater?',
        body: 'It stops repeating for the time it takes to restart. If its radio settings were changed they take effect now, and any mistake in them leaves it off the air.',
        phrase: 'REBOOT',
        confirmLabel: 'Reboot');
    if (typed == null || !context.mounted) return;
    try {
      final before = c.snapshot?.stats?.upTimeSecs ?? 1 << 30;
      final r = await c.reboot(typed);
      if (!context.mounted) return;
      showSnack(context, r.message);
      final back = await c.session.waitForReturn(uptimeBeforeSecs: before);
      if (!context.mounted) return;
      showSnack(context, back == null ? 'It has not answered yet. Give it a minute, then refresh.' : 'It is back (${back.inSeconds}s).');
      c.loadSettings(force: true);
    } on AdminException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }

  Widget _row(BuildContext context, SettingDef d, {String? subtitleOverride}) {
    final t = Theme.of(context);
    final v = c.settings[d.key];
    final applied = c.lastApplied[d.key];
    String sub;
    var enabled = true;
    if (v == null) {
      sub = c.loadingSettings ? 'Reading...' : 'Not read yet';
    } else {
      switch (v.state) {
        case ReadState.ok:
          sub = subtitleOverride ?? d.display(v.value);
        case ReadState.unsupported:
          sub = 'Not on this firmware';
          enabled = false;
        case ReadState.silent:
          sub = 'No answer. Pull down to read again.';
        case ReadState.error:
          sub = 'Could not read';
      }
    }
    Widget? badge;
    if (applied != null) {
      badge = switch (applied.outcome) {
        ApplyOutcome.verified => const _Badge('Verified', Icons.check_circle, key: Key('badge-verified')),
        ApplyOutcome.unverified => const _Badge('Could not verify', Icons.help_outline, key: Key('badge-unverified')),
        ApplyOutcome.mismatch => const _Badge('Different', Icons.error_outline, key: Key('badge-mismatch')),
        _ => null,
      };
    }
    return Semantics(
      container: true,
      label: '${d.label}: $sub',
      button: enabled,
      excludeSemantics: true,
      child: ListTile(
        key: Key('setting-${d.key}'),
        contentPadding: EdgeInsets.zero,
        minVerticalPadding: Gap.s,
        enabled: enabled && c.stage == AdminStage.ready,
        title: Text(d.label),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(sub, style: t.textTheme.bodyMedium), ?badge]),
        trailing: Icon(d.danger.index >= Danger.disruptive.index ? Icons.warning_amber_rounded : Icons.chevron_right, color: d.danger.index >= Danger.disruptive.index ? const Color(0xFFB26A00) : null),
        onTap: enabled ? () => showSettingEditor(context, c, d) : null,
      ),
    );
  }

  Widget _observer(BuildContext context) {
    final t = Theme.of(context);
    final o = c.observer;
    return AdminCard(
      cardKey: const Key('group-uplink'),
      title: 'Observer uplink (read only)',
      icon: Icons.cloud_upload_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Where this observer sends what it hears. Passwords and tokens are never read or shown. MeshSonar does not change the uplink from here.', style: t.textTheme.bodyMedium?.copyWith(height: 1.3)),
        const SizedBox(height: Gap.s),
        if (o == null)
          FilledButton.tonalIcon(
            key: const Key('load-uplink'),
            style: FilledButton.styleFrom(minimumSize: kTarget),
            onPressed: c.loadingObserver ? null : c.loadObserver,
            icon: c.loadingObserver ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_sync_outlined),
            label: Text(c.loadingObserver ? 'Reading the uplink...' : 'Read the uplink status'),
          )
        else ...[
          for (final s in o.slots) KeyValueRow('Slot ${s.number}: ${s.name}', s.ok ? 'Connected' : s.state, valueColor: s.ok ? null : t.colorScheme.error),
          if (o.slots.isEmpty) const Text('No slot reported.'),
          KeyValueRow('Waiting to send', '${o.queueLen} of ${o.queueMax}'),
          KeyValueRow('Dropped / failed', '${o.drops} / ${o.failed}'),
          KeyValueRow('Reconnects since start', '${o.disconnects}'),
          if (o.ntpOk != null) KeyValueRow('Network time', o.ntpOk! ? 'Working' : 'Not answering'),
          TextButton(key: const Key('reload-uplink'), style: TextButton.styleFrom(minimumSize: kTarget), onPressed: c.loadObserver, child: const Text('Read again')),
        ],
      ]),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final IconData icon;
  const _Badge(this.text, this.icon, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: t.colorScheme.primary),
        const SizedBox(width: 4),
        Text(text, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary)),
      ]),
    );
  }
}
