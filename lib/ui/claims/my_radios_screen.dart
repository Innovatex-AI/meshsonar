// Settings > My radios: the radios this driver key manages. List, give up a radio, change its name / whether its
// position is public / notes; start "Claim my radio" or "Claim a repeater"; finish a name restore still owed. The full
// same list is on the website (/me/radios). Observer claims show their health (hearing, quiet, deaf, offline) and battery.
// Nothing here decides whether a radio's data counts.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../core/api.dart';
import '../../core/claim_flow.dart';
import '../../core/node_claim.dart';
import '../app.dart';
import '../settings/settings_kit.dart' show confirmSettingsChange;
import 'claim_radio_screen.dart';
import 'claim_repeater_screen.dart';
import 'claim_widgets.dart';

class MyRadiosScreen extends StatefulWidget {
  const MyRadiosScreen({super.key});
  @override
  State<MyRadiosScreen> createState() => _MyRadiosScreenState();
}

class _MyRadiosScreenState extends State<MyRadiosScreen> {
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final c = AppScope.read(context).claims;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      c.refresh();
      c.loadPending();
    });
  }

  String _typeWord(ClaimNodeType t) => switch (t) {
        ClaimNodeType.repeater => 'Repeater',
        ClaimNodeType.room => 'Room server',
        ClaimNodeType.observer => 'Observer',
        ClaimNodeType.companion => 'Companion radio',
        ClaimNodeType.unknown => 'Radio',
      };

  String _how(ClaimMethod m) => switch (m) {
        ClaimMethod.signature => 'Verified by the radio\'s signature',
        ClaimMethod.advert => 'Verified by an observer hearing the code',
        ClaimMethod.login => 'Logged in as admin from your app',
        ClaimMethod.other => 'Verified',
      };

  Future<void> _release(AppState s, NodeClaim c) async {
    final ok = await confirmSettingsChange(context,
        dialogKey: 'release-radio',
        title: 'Give up ${c.label}?',
        body: 'You stop managing this radio. Its data stays and keeps counting exactly as before. You can claim it again later.',
        confirmLabel: 'Give up',
        destructive: true);
    if (!ok || !mounted) return;
    try {
      await s.claims.release(c.pubkey);
    } on CmatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not give it up: ${e.message}')));
    }
  }

  Future<void> _edit(AppState s, NodeClaim c) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => EditRadioSheet(claim: c, state: s),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = s.claims;
    final t = Theme.of(context);
    final enabled = s.nodeClaimsEnabled;
    return Scaffold(
      appBar: AppBar(title: const Text('My radios')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: c.refresh,
          child: ListView(
            key: const Key('my-radios-screen'),
            padding: const EdgeInsets.all(Gap.l),
            children: [
              Text(claimNeverGates, key: const Key('my-radios-intro')),
              const SizedBox(height: Gap.m),
              if (!enabled)
                Card(
                  key: const Key('my-radios-unavailable'),
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.m),
                    child: Text(s.hasKey
                        ? 'Radio claims need a server that offers them and a driver key it accepts.'
                        : 'Radio claims need a driver key. Add one under Account & driver key.'),
                  ),
                ),
              if (enabled) ...[
                Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
                  FilledButton.icon(
                    key: const Key('my-radios-claim-radio'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.settings_input_antenna),
                    label: const Text('Claim my radio'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ClaimRadioScreen())),
                  ),
                  OutlinedButton.icon(
                    key: const Key('my-radios-claim-repeater'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.cell_tower),
                    label: const Text('Claim a repeater'),
                    onPressed: s.repeaterClaimEnabled
                        ? () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ClaimRepeaterScreen()))
                        : null,
                  ),
                ]),
                if (!s.repeaterClaimEnabled)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.s),
                    child: Text('Claiming a repeater needs a newer server (it is being updated). Claiming your own radio works now.',
                        key: const Key('my-radios-repeater-soon'), style: t.textTheme.bodySmall),
                  ),
                const SizedBox(height: Gap.l),
                for (final p in c.pending) _PendingRestoreCard(pending: p),
                Text('Your radios', style: t.textTheme.titleMedium),
                const SizedBox(height: Gap.s),
                if (c.loading && !c.loadedOnce) const Center(child: Padding(padding: EdgeInsets.all(Gap.l), child: CircularProgressIndicator())),
                if (c.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.s),
                    child: Text(c.error!, key: const Key('my-radios-error'), style: TextStyle(color: t.colorScheme.error)),
                  ),
                if (c.loadedOnce && c.active.isEmpty && c.past.isEmpty && c.error == null)
                  Text('You have not claimed a radio yet. Claim your own radio, or a repeater you run.', key: const Key('my-radios-empty'), style: t.textTheme.bodyMedium),
                for (final claim in c.active)
                  Card(
                    key: ValueKey('radio-${claim.pubkey}'),
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.m),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(claim.label, style: t.textTheme.titleMedium),
                        const SizedBox(height: Gap.xs),
                        Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
                          _Chip(_typeWord(claim.nodeType), Icons.cell_tower),
                          _Chip(_how(claim.method), Icons.verified_outlined),
                          if (claim.health != null) _Chip(claim.health!.words, _healthIcon(claim.health!)),
                          if (claim.health?.batteryMv != null)
                            _Chip(
                                'Battery ${(claim.health!.batteryMv! / 1000).toStringAsFixed(2)} V${claim.health!.batteryLow ? ' (low)' : ''}'
                                '${claim.health!.batteryTrend == null || claim.health!.batteryTrend == 'unknown' ? '' : ', ${claim.health!.batteryTrend}'}',
                                claim.health!.batteryLow ? Icons.battery_alert : Icons.battery_full),
                          _Chip(
                            claim.positionPublic == null
                                ? 'Position: server default'
                                : (claim.positionPublic! ? 'Position public' : 'Position hidden'),
                            claim.positionPublic == true ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                          ),
                        ]),
                        const SizedBox(height: Gap.xs),
                        Text(claim.pubkey.substring(0, 16), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                        if (claim.verifiedAt != null) Text('Claimed ${claim.verifiedAt!.toLocal().toIso8601String().substring(0, 10)}', style: t.textTheme.bodySmall),
                        if (claim.notes != null) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(claim.notes!, style: t.textTheme.bodySmall)),
                        const SizedBox(height: Gap.xs),
                        Wrap(spacing: Gap.s, children: [
                          TextButton.icon(
                            key: ValueKey('edit-${claim.pubkey}'),
                            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Edit'),
                            onPressed: () => _edit(s, claim),
                          ),
                          TextButton.icon(
                            key: ValueKey('release-${claim.pubkey}'),
                            style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: t.colorScheme.error),
                            icon: const Icon(Icons.link_off),
                            label: const Text('Give up'),
                            onPressed: () => _release(s, claim),
                          ),
                        ]),
                      ]),
                    ),
                  ),
                if (c.past.isNotEmpty)
                  ExpansionTile(
                    key: const Key('past-radios'),
                    tilePadding: EdgeInsets.zero,
                    title: Text('Past radios (${c.past.length})', style: t.textTheme.titleMedium),
                    children: [
                      for (final p in c.past)
                        ListTile(
                          key: ValueKey('past-${p.pubkey}'),
                          contentPadding: EdgeInsets.zero,
                          minVerticalPadding: Gap.s,
                          leading: const Icon(Icons.history),
                          title: Text(p.label),
                          subtitle: Text(claimEndText(p.endReason ?? ClaimEndReason.unknown) +
                              (p.releasedAt == null ? '' : ' · ${p.releasedAt!.toIso8601String().substring(0, 10)}')),
                        ),
                    ],
                  ),
                const SizedBox(height: Gap.l),
                ListTile(
                  key: const Key('my-radios-website'),
                  minVerticalPadding: Gap.s,
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('View your radios on the website'),
                  subtitle: Text('The same list, optional: ${s.webPage('/me/radios')}'),
                  onTap: () => s.openWebPage('/me/radios'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

IconData _healthIcon(ObserverHealth h) => switch (h.state) {
      'ok' => Icons.hearing,
      'deaf' => Icons.hearing_disabled,
      'offline' => Icons.cloud_off_outlined,
      _ => Icons.volume_mute_outlined,
    };

class _Chip extends StatelessWidget {
  final String text;
  final IconData icon;
  const _Chip(this.text, this.icon);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 4),
        decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16),
          const SizedBox(width: 4),
          Flexible(child: Text(text, style: t.textTheme.labelMedium)),
        ]),
      ),
    );
  }
}

class _PendingRestoreCard extends StatelessWidget {
  final PendingRestore pending;
  const _PendingRestoreCard({required this.pending});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: ValueKey('pending-${pending.pubkey}'),
      color: t.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('A repeater\'s name still needs to be put back', style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onErrorContainer)),
          const SizedBox(height: Gap.xs),
          Text('Its name was "${pending.originalName}" before the claim code was added. Log in again to restore it, or type these in the MeshCore app: ${restoreCommands(pending.originalName).join('  then  ')}',
              style: TextStyle(color: t.colorScheme.onErrorContainer)),
          const SizedBox(height: Gap.s),
          Wrap(spacing: Gap.s, children: [
            FilledButton(
              key: ValueKey('restore-${pending.pubkey}'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ClaimRepeaterScreen(restore: pending))),
              child: const Text('Put the name back'),
            ),
            TextButton(
              key: ValueKey('restore-dismiss-${pending.pubkey}'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => AppScope.read(context).claims.dismissPending(pending.pubkey),
              child: const Text('I fixed it myself'),
            ),
            TextButton(
              key: ValueKey('restore-copy-${pending.pubkey}'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Clipboard.setData(ClipboardData(text: restoreCommands(pending.originalName).join('\n'))),
              child: const Text('Copy commands'),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Edit the owner's name for a radio, whether its position is public, and notes. Sends only what changed.
class EditRadioSheet extends StatefulWidget {
  final NodeClaim claim;
  final AppState state;
  const EditRadioSheet({super.key, required this.claim, required this.state});
  @override
  State<EditRadioSheet> createState() => _EditRadioSheetState();
}

class _EditRadioSheetState extends State<EditRadioSheet> {
  late final _name = TextEditingController(text: widget.claim.displayName ?? '');
  late final _notes = TextEditingController(text: widget.claim.notes ?? '');
  late bool? _pos = widget.claim.positionPublic;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c = widget.claim;
    final changes = <String, Object?>{};
    final name = _name.text.trim(), notes = _notes.text.trim();
    if (name != (c.displayName ?? '')) changes['displayName'] = name.isEmpty ? null : name;
    if (notes != (c.notes ?? '')) changes['notes'] = notes.isEmpty ? null : notes;
    if (_pos != c.positionPublic) changes['positionPublic'] = _pos;
    if (changes.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.state.claims.update(c.pubkey, changes);
      if (mounted) Navigator.of(context).pop();
    } on CmatException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save: ${e.message}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, MediaQuery.viewInsetsOf(context).bottom + Gap.l),
      child: SingleChildScrollView(
        child: Column(
          key: const Key('edit-radio-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Edit ${widget.claim.label}', style: t.textTheme.titleLarge),
            const SizedBox(height: Gap.m),
            TextField(
              key: const Key('edit-radio-name'),
              controller: _name,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Name to show', helperText: 'Your name for this radio. Empty uses the name it advertises.'),
            ),
            const SizedBox(height: Gap.s),
            Text('Position on the public map', style: t.textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            SegmentedButton<int>(
              key: const Key('edit-radio-position'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('Default')),
                ButtonSegment(value: 1, label: Text('Public')),
                ButtonSegment(value: 2, label: Text('Hidden')),
              ],
              selected: {_pos == null ? 0 : (_pos! ? 1 : 2)},
              onSelectionChanged: (v) => setState(() => _pos = v.first == 0 ? null : v.first == 1),
            ),
            const SizedBox(height: Gap.s),
            TextField(
              key: const Key('edit-radio-notes'),
              controller: _notes,
              maxLength: 500,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Notes (only you see them)'),
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(bottom: Gap.s), child: Text(_error!, key: const Key('edit-radio-error'), style: TextStyle(color: t.colorScheme.error))),
            FilledButton(
              key: const Key('edit-radio-save'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
