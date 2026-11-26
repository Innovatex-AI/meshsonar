// "Claim several repeaters" (ID step 6): prove and claim one repeater after another without leaving the screen. Each row says
// where it is (not started, proving, claimed, failed and why); "Claim another" keeps the session and its rows. The proof for a
// repeater is the admin login over your own radio (the server's `login` method); nothing on a repeater is changed, and each
// repeater's admin password is typed per row, held by the running flow only and never stored.
//
// Plain public constructor: Claimed radios opens it (button "Claim several repeaters", shown while AppState.repeaterBatchEnabled).
import 'package:flutter/material.dart';
import '../drive/drive_controls.dart' show openConnect;

import '../../app/app_state.dart';
import '../../app/repeater_batch.dart';
import '../../core/model.dart';
import '../../core/node_claim.dart';
import '../app.dart';
import '../design/app_surfaces.dart';
import 'claim_proof_label.dart';
import 'claim_widgets.dart';
import 'my_radios_screen.dart' show releaseRadioClaim;

class ClaimRepeatersScreen extends StatefulWidget {
  const ClaimRepeatersScreen({super.key});
  @override
  State<ClaimRepeatersScreen> createState() => _ClaimRepeatersScreenState();
}

class _ClaimRepeatersScreenState extends State<ClaimRepeatersScreen> {
  final _search = TextEditingController();
  final _paste = TextEditingController();
  final Map<String, TextEditingController> _pw = {};
  String? _pasteError;

  /// The picker is open at the start (nothing to show yet) and after "Claim another".
  bool _adding = false;
  bool _firstBuild = true;

  @override
  void dispose() {
    _search.dispose();
    _paste.dispose();
    for (final c in _pw.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _pwFor(String key) => _pw.putIfAbsent(key, TextEditingController.new);

  void _prove(RepeaterBatchController b, String key) {
    final c = _pwFor(key);
    if (c.text.isEmpty) return;
    final ok = b.prove(key, c.text);
    if (ok) c.clear(); // the flow holds it now; nothing on screen does
    setState(() {});
  }

  List<RepeaterRef> _matches(AppState s, RepeaterBatchController b) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return s.repeaters
        .where((r) => !r.isRoom && b.row(r.key) == null && !s.ownsRadio(r.key) && (r.name.toLowerCase().contains(q) || r.key.startsWith(q)))
        .take(8)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final b = s.repeaterBatch;
    if (_firstBuild) {
      _firstBuild = false;
      _adding = b.rows.isEmpty;
    }
    return PopScope(
      canPop: !b.busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && b.busy) {
          showAppToast(context, 'A claim is running. Press Cancel first.');
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Claim several repeaters')),
        body: SafeArea(
          child: ListView(
            key: const Key('claim-several-screen'),
            padding: const EdgeInsets.all(Gap.l),
            children: !s.repeaterBatchEnabled ? _unavailable(t) : _body(context, s, b, t),
          ),
        ),
      ),
    );
  }

  List<Widget> _unavailable(ThemeData t) => [
    Card(
      key: const Key('claim-several-unavailable'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Text(
          'Claiming several repeaters needs a server that offers it. Claim a repeater from Claimed radios meanwhile.',
          style: t.textTheme.bodyMedium,
        ),
      ),
    ),
  ];

  List<Widget> _body(BuildContext context, AppState s, RepeaterBatchController b, ThemeData t) {
    final connected = s.connected;
    final rows = b.rows;
    return [
      const Text(claimDisclosure, key: Key('claim-several-intro')),
      const SizedBox(height: Gap.s),
      Text(
        'One repeater at a time. Each has its own admin password.',
        style: t.textTheme.bodySmall,
      ),
      const SizedBox(height: Gap.m),
      if (!connected)
        Card(
          key: const Key('claim-several-needs-radio'),
          color: t.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Connect your radio first. It talks to the repeaters for you, so it must be within reach of each one.', style: TextStyle(color: t.colorScheme.onErrorContainer)),
                const SizedBox(height: Gap.s),
                // Build 76: the way out is a button here, not directions to another tab.
                FilledButton.tonalIcon(
                  key: const Key('claim-several-connect'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('Connect radio'),
                  onPressed: () => openConnect(context),
                ),
            ]),
          ),
        ),
      const SizedBox(height: Gap.m),
      if (_adding)
        ..._picker(s, b, t)
      else
        OutlinedButton.icon(
          key: const Key('claim-another'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
          icon: const Icon(Icons.add),
          label: const Text('Claim another'),
          onPressed: () => setState(() => _adding = true),
        ),
      if (rows.isNotEmpty) ...[
        Semantics(
          liveRegion: true,
          child: Text(
            '${b.claimedCount} claimed, ${b.failedCount} failed, ${b.waitingCount} to do',
            key: const Key('claim-several-summary'),
            style: t.textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: Gap.s),
        for (final r in rows) _rowCard(context, s, b, r, t, connected),
        if (b.claimedCount > 0 && !b.busy)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('claim-several-clear'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: b.clearClaimed,
              child: const Text('Clear the finished ones'),
            ),
          ),
      ],
      const SizedBox(height: Gap.l),
      FilledButton(
        key: const Key('claim-several-done'),
        style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
        onPressed: b.busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Done'),
      ),
      const SizedBox(height: Gap.l),
    ];
  }

  List<Widget> _picker(AppState s, RepeaterBatchController b, ThemeData t) {
    final matches = _matches(s, b);
    return [
      Text('Add repeaters', style: t.textTheme.titleMedium),
      const SizedBox(height: Gap.xs),
      TextField(
        key: const Key('claim-several-search'),
        controller: _search,
        decoration: const InputDecoration(labelText: 'Search the region\'s repeaters by name', prefixIcon: Icon(Icons.search)),
        onChanged: (_) => setState(() {}),
      ),
      for (final r in matches)
        ListTile(
          key: ValueKey('claim-several-pick-${r.key}'),
          minVerticalPadding: Gap.s,
          leading: const Icon(Icons.cell_tower),
          title: Text(r.name.isEmpty ? r.key.substring(0, 8) : r.name),
          subtitle: Text(r.key.substring(0, 12)),
          trailing: const Icon(Icons.add_circle_outline),
          onTap: () {
            b.add(r.key, name: r.name);
            _search.clear();
            setState(() => _adding = true);
          },
        ),
      const SizedBox(height: Gap.s),
      TextField(
        key: const Key('claim-several-paste'),
        controller: _paste,
        autocorrect: false,
        decoration: InputDecoration(labelText: 'Or paste a public key (64 characters)', errorText: _pasteError),
        onChanged: (v) {
          final k = normalizePublicKey(v);
          setState(() => _pasteError = v.trim().isEmpty || k != null ? null : 'A public key is 64 letters and digits (0-9, a-f).');
          if (k != null) {
            b.add(k);
            _paste.clear();
          }
        },
      ),
      if (b.rows.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('claim-several-close-picker'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => setState(() => _adding = false),
            child: const Text('Close the list'),
          ),
        ),
    ];
  }

  Widget _rowCard(BuildContext context, AppState s, RepeaterBatchController b, BatchRow r, ThemeData t, bool connected) {
    final others = b.busy && b.activeKey != r.key;
    final canProve = connected && !others && r.state != BatchRowState.proving;
    final claim = s.claims.claimFor(r.key);
    return Card(
      key: ValueKey('batch-${r.key}'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(r.label, style: t.textTheme.titleMedium)),
                _StateChip(r.state, key: ValueKey('batch-state-${r.key}')),
                if (r.state != BatchRowState.proving)
                  IconButton(
                    key: ValueKey('batch-remove-${r.key}'),
                    tooltip: 'Take it out of the list',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    icon: const Icon(Icons.close),
                    onPressed: () => b.remove(r.key),
                  ),
              ],
            ),
            Text(r.key.substring(0, 16), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: Gap.xs),
            switch (r.state) {
              BatchRowState.proving => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(liveRegion: true, child: Text(r.message ?? '', key: ValueKey('batch-message-${r.key}'))),
                  const SizedBox(height: Gap.s),
                  OutlinedButton.icon(
                    key: ValueKey('batch-cancel-${r.key}'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel'),
                    onPressed: b.cancel,
                  ),
                ],
              ),
              BatchRowState.claimed => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (r.alreadyYours)
                    const Padding(
                      padding: EdgeInsets.only(bottom: Gap.xs),
                      child: OwnedByYouChip(),
                    ),
                  Text(
                    r.alreadyYours ? 'Already yours. Nothing to prove.' : 'Claimed. Nothing on the repeater was changed.',
                    key: ValueKey('batch-message-${r.key}'),
                  ),
                  if (r.method != null) ...[
                    const SizedBox(height: Gap.xs),
                    KeyedSubtree(key: ValueKey('batch-proof-${r.key}'), child: ClaimProofLabel(r.method!)),
                  ],
                  if (claim != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: ValueKey('batch-release-${r.key}'),
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: t.colorScheme.error),
                        icon: const Icon(Icons.link_off),
                        label: const Text('Give up'),
                        onPressed: () async {
                          await releaseRadioClaim(context, s, claim);
                          if (mounted) setState(() {});
                        },
                      ),
                    ),
                ],
              ),
              _ => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (r.state == BatchRowState.failed) ...[
                    Text(
                      r.title ?? 'Could not claim it',
                      key: ValueKey('batch-title-${r.key}'),
                      style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.error),
                    ),
                    Text(r.message ?? '', key: ValueKey('batch-message-${r.key}')),
                    const SizedBox(height: Gap.s),
                  ],
                  TextField(
                    key: ValueKey('batch-password-${r.key}'),
                    controller: _pwFor(r.key),
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 15,
                    decoration: const InputDecoration(
                      labelText: 'Repeater admin password',
                      helperText: 'Kept in memory on this phone only.',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  FilledButton.icon(
                    key: ValueKey('batch-prove-${r.key}'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.verified_user_outlined),
                    label: Text(r.state == BatchRowState.failed ? 'Try again' : 'Claim this repeater'),
                    onPressed: canProve && _pwFor(r.key).text.isNotEmpty ? () => _prove(b, r.key) : null,
                  ),
                  if (!canProve)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xs),
                      child: Text(
                        !connected ? 'Needs a connected radio.' : 'Wait for the repeater being claimed to finish.',
                        style: t.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            },
          ],
        ),
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  final BatchRowState state;
  const _StateChip(this.state, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (text, icon, color) = switch (state) {
      BatchRowState.notStarted => ('Not started', Icons.radio_button_unchecked, t.colorScheme.onSurfaceVariant),
      BatchRowState.proving => ('Proving', Icons.hourglass_top, t.colorScheme.primary),
      BatchRowState.claimed => ('Claimed', Icons.check_circle, t.colorScheme.primary),
      BatchRowState.failed => ('Failed', Icons.error_outline, t.colorScheme.error),
    };
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 4),
          Text(text, style: t.textTheme.labelMedium?.copyWith(color: color)),
        ],
      ),
    );
  }
}
