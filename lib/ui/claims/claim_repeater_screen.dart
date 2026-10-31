// "Claim a repeater": prove a repeater is yours with its admin password, through your own radio, over the mesh.
// The password stays in memory on this phone; the server only ever sees a short claim code that an observer hears in
// the repeater's advert. The flow itself is lib/core/claim_flow.dart; this screen only shows it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../core/claim_flow.dart';
import '../../core/model.dart';
import '../../core/node_claim.dart';
import '../app.dart';
import 'claim_widgets.dart';

String claimOutcomeTitle(ClaimOutcome o) => switch (o) {
      ClaimOutcome.verified => 'The repeater is yours',
      ClaimOutcome.alreadyYours => 'Already yours',
      ClaimOutcome.cancelled => 'Cancelled',
      ClaimOutcome.noRadio => 'Connect your radio',
      ClaimOutcome.radioLost => 'The radio disconnected',
      ClaimOutcome.notAdmin => 'Not the admin password',
      ClaimOutcome.loginSilent => 'No answer from the repeater',
      ClaimOutcome.loginRefused => 'Login refused',
      ClaimOutcome.noContact => 'Your radio could not add the repeater',
      ClaimOutcome.nameUnreadable => 'Could not read the repeater\'s name',
      ClaimOutcome.setNameFailed => 'The repeater would not take the code',
      ClaimOutcome.expired => 'The code ran out',
      ClaimOutcome.serverRefused => 'The server said no',
      ClaimOutcome.serverUnavailable => 'Could not finish',
      ClaimOutcome.signFailed => 'The radio could not sign',
      ClaimOutcome.signatureRejected => 'The signature did not match',
      ClaimOutcome.none => '',
    };

const _stepTitles = [
  'Log in to the repeater over the mesh',
  'Read its current name',
  'Add the code to its name',
  'Announce the repeater',
  'Wait for an observer to hear the code',
  'Put the name back',
];

int _stepIndex(ClaimStep s) => switch (s) {
      ClaimStep.idle || ClaimStep.starting || ClaimStep.loggingIn => 0,
      ClaimStep.readingName => 1,
      ClaimStep.settingName => 2,
      ClaimStep.advertising => 3,
      ClaimStep.waitingForObserver => 4,
      ClaimStep.restoring || ClaimStep.checkingLater => 5,
      ClaimStep.signing || ClaimStep.completing => 0,
      ClaimStep.done => _stepTitles.length,
    };

class ClaimRepeaterScreen extends StatefulWidget {
  /// A repeater already chosen (from the map, its sheet or a list). Null: the person picks or pastes one.
  final String? initialKey;
  final String? initialName;

  /// Finish a name restore left over from an earlier claim instead of claiming.
  final PendingRestore? restore;
  const ClaimRepeaterScreen({super.key, this.initialKey, this.initialName, this.restore});

  @override
  State<ClaimRepeaterScreen> createState() => _ClaimRepeaterScreenState();
}

class _ClaimRepeaterScreenState extends State<ClaimRepeaterScreen> {
  String? _key;
  String _name = '';
  final _password = TextEditingController();
  final _search = TextEditingController();
  final _paste = TextEditingController();
  String? _pasteError;
  RepeaterClaimFlow? _flow;
  StreamSubscription<ClaimFlowState>? _sub;
  ClaimFlowState _st = const ClaimFlowState();
  bool _attached = false;

  @override
  void initState() {
    super.initState();
    _key = widget.initialKey?.toLowerCase();
    _name = widget.initialName ?? '';
    if (widget.restore != null) {
      _key = widget.restore!.pubkey;
      _name = widget.restore!.originalName;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_attached) return;
    _attached = true;
    final running = AppScope.of(context).claims.repeaterFlow;
    if (running != null && !running.state.finished) _follow(running);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _password.dispose();
    _search.dispose();
    _paste.dispose();
    super.dispose();
  }

  void _follow(RepeaterClaimFlow f) {
    _sub?.cancel();
    _flow = f;
    _st = f.state;
    _sub = f.states.listen((s) {
      if (mounted) setState(() => _st = s);
    });
  }

  bool get _busy => _flow != null && !_st.finished;

  void _start() {
    final s = AppScope.of(context);
    final key = _key;
    if (key == null || _password.text.isEmpty) return;
    final f = widget.restore != null
        ? s.claims.startRestore(widget.restore!, _password.text)
        : s.claims.startRepeaterClaim(pubkey: key, password: _password.text, nodeName: _name);
    _password.clear(); // the flow holds it now; nothing on screen does
    if (f == null) return;
    setState(() => _follow(f));
  }

  void _again() {
    AppScope.of(context).claims.clearFlows();
    _sub?.cancel();
    setState(() {
      _flow = null;
      _st = const ClaimFlowState();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final body = _flow == null ? _setup(context, s, t) : (_st.finished ? _result(context, t) : _progress(context, t));
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _busy) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('A claim is running. Press "Cancel and put the name back" first: the repeater\'s name must be restored.')));
        }
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.restore != null ? 'Put a name back' : 'Claim a repeater')),
        body: SafeArea(
          child: ListView(
            key: const Key('claim-repeater-screen'),
            padding: const EdgeInsets.all(Gap.l),
            children: body,
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ setup

  List<Widget> _setup(BuildContext context, AppState s, ThemeData t) {
    final connected = s.connected;
    final restoring = widget.restore != null;
    final picked = _key != null;
    final matches = _matches(s);
    final owned = picked && s.ownsRadio(_key!) && !restoring;
    final canStart = connected && picked && !owned && _password.text.isNotEmpty;
    return [
      Text(restoring
          ? 'An earlier claim could not confirm this repeater\'s name was put back. Log in again and it will be restored.'
          : 'Prove a repeater is yours. Your radio logs in to it over the mesh with its admin password, and the repeater\'s name carries a short code for about a minute so an observer can hear it.'),
      const SizedBox(height: Gap.m),
      if (!connected)
        Card(
          key: const Key('claim-needs-radio'),
          color: t.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Text('Connect your radio first (More > Radio). It talks to the repeater for you, so it has to be within reach of the repeater.',
                style: TextStyle(color: t.colorScheme.onErrorContainer)),
          ),
        ),
      const SizedBox(height: Gap.s),
      Text('Repeater', style: t.textTheme.titleMedium),
      const SizedBox(height: Gap.xs),
      if (picked)
        Card(
          child: ListTile(
            key: const Key('claim-picked'),
            minVerticalPadding: Gap.s,
            leading: const Icon(Icons.cell_tower),
            title: Text(_name.isEmpty ? 'Repeater ${_key!.substring(0, 8)}' : _name),
            subtitle: Text(_key!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            trailing: restoring
                ? null
                : TextButton(
                    key: const Key('claim-change'),
                    onPressed: () => setState(() {
                      _key = null;
                      _name = '';
                    }),
                    child: const Text('Change'),
                  ),
          ),
        )
      else ...[
        TextField(
          key: const Key('claim-search'),
          controller: _search,
          decoration: const InputDecoration(labelText: 'Search your repeaters by name', prefixIcon: Icon(Icons.search)),
          onChanged: (_) => setState(() {}),
        ),
        for (final r in matches)
          ListTile(
            key: ValueKey('claim-pick-${r.key}'),
            minVerticalPadding: Gap.s,
            leading: const Icon(Icons.cell_tower),
            title: Text(r.name.isEmpty ? r.key.substring(0, 8) : r.name),
            subtitle: Text(r.key.substring(0, 12)),
            onTap: () => setState(() {
              _key = r.key;
              _name = r.name;
            }),
          ),
        const SizedBox(height: Gap.s),
        TextField(
          key: const Key('claim-paste'),
          controller: _paste,
          autocorrect: false,
          decoration: InputDecoration(labelText: 'Or paste its public key (64 characters)', errorText: _pasteError),
          onChanged: (v) {
            final k = normalizePublicKey(v);
            setState(() {
              _pasteError = v.trim().isEmpty || k != null ? null : 'A public key is 64 letters and digits (0-9, a-f).';
              if (k != null) {
                _key = k;
                _name = '';
              }
            });
          },
        ),
      ],
      if (owned)
        const Padding(
          padding: EdgeInsets.only(top: Gap.s),
          child: Row(children: [OwnedByYouChip(), SizedBox(width: Gap.s), Expanded(child: Text('Already yours. Nothing to prove, no password needed.', key: Key('claim-already-yours')))]),
        ),
      const SizedBox(height: Gap.l),
      TextField(
        key: const Key('claim-password'),
        controller: _password,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        maxLength: 15,
        decoration: const InputDecoration(
          labelText: 'Repeater admin password',
          helperText: 'Repeaters read at most 15 characters. Kept in memory on this phone only.',
          helperMaxLines: 3,
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: Gap.m),
      _DisclosureCard(key: const Key('claim-disclosure')),
      const SizedBox(height: Gap.l),
      FilledButton.icon(
        key: const Key('claim-start'),
        style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
        icon: const Icon(Icons.verified_user_outlined),
        label: Text(restoring ? 'Put the name back' : 'Claim this repeater'),
        onPressed: canStart ? _start : null,
      ),
      if (!canStart)
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: Text(
            !connected ? 'Needs a connected radio.' : (!picked ? 'Pick or paste a repeater.' : (owned ? 'This repeater is already yours.' : 'Enter the admin password.')),
            key: const Key('claim-why-not'),
            style: t.textTheme.bodySmall,
          ),
        ),
    ];
  }

  List<RepeaterRef> _matches(AppState s) {
    final all = s.repeaters;
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return all.where((r) => r.name.toLowerCase().contains(q) || r.key.startsWith(q)).take(8).toList();
  }

  // ------------------------------------------------------------ progress

  List<Widget> _progress(BuildContext context, ThemeData t) {
    final at = _stepIndex(_st.step);
    final restoringNow = _st.step == ClaimStep.restoring;
    return [
      Semantics(
        liveRegion: true,
        child: Text(_st.message, key: const Key('claim-message'), style: t.textTheme.titleMedium),
      ),
      const SizedBox(height: Gap.m),
      if (_st.code != null)
        Card(
          key: const Key('claim-code-card'),
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Code on the repeater\'s name for a short while', style: t.textTheme.labelLarge),
              const SizedBox(height: Gap.xs),
              Text(_st.code!, key: const Key('claim-code'), style: t.textTheme.headlineMedium?.copyWith(fontFamily: 'monospace', fontWeight: FontWeight.w800)),
              if (_st.originalName != null) ...[
                const SizedBox(height: Gap.xs),
                Text('Original name: ${_st.originalName}', style: t.textTheme.bodySmall),
              ],
            ]),
          ),
        ),
      const SizedBox(height: Gap.m),
      for (var i = 0; i < _stepTitles.length; i++) _StepRow(title: _stepTitles[i], state: i < at ? _StepState.done : (i == at ? _StepState.now : _StepState.waiting)),
      if (_st.step == ClaimStep.checkingLater)
        const _StepRow(title: 'Keep listening for an observer\'s report', state: _StepState.now),
      const SizedBox(height: Gap.l),
      const _DisclosureCard(),
      const SizedBox(height: Gap.l),
      OutlinedButton.icon(
        key: const Key('claim-cancel'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
        icon: const Icon(Icons.close),
        label: Text(restoringNow ? 'Putting the name back…' : (_st.step == ClaimStep.checkingLater ? 'Stop waiting' : 'Cancel and put the name back')),
        onPressed: restoringNow || _flow!.isCancelled ? null : _flow!.cancel,
      ),
    ];
  }

  // ------------------------------------------------------------ result

  List<Widget> _result(BuildContext context, ThemeData t) {
    final ok = _st.verified || _st.outcome == ClaimOutcome.alreadyYours;
    final risky = _st.restore == RestoreState.failed;
    return [
      Row(children: [
        Icon(ok ? Icons.check_circle : Icons.info_outline, size: 32, color: ok ? t.colorScheme.primary : t.colorScheme.error),
        const SizedBox(width: Gap.m),
        Expanded(child: Text(claimOutcomeTitle(_st.outcome), key: const Key('claim-result-title'), style: t.textTheme.titleLarge)),
      ]),
      const SizedBox(height: Gap.m),
      Semantics(liveRegion: true, child: Text(_st.message, key: const Key('claim-message'))),
      if (risky) ...[
        const SizedBox(height: Gap.l),
        Card(
          key: const Key('claim-restore-commands'),
          color: t.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Put the repeater\'s name back yourself', style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onErrorContainer)),
              const SizedBox(height: Gap.xs),
              Text('Its name may still end with ${_st.code ?? 'the code'}. In the MeshCore app, log in to the repeater and send these two commands, one at a time:',
                  style: TextStyle(color: t.colorScheme.onErrorContainer)),
              const SizedBox(height: Gap.s),
              for (final c in _st.restoreCommands) _CommandBox(command: c),
              const SizedBox(height: Gap.xs),
              Text('We also keep a reminder in My radios until you finish this.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onErrorContainer)),
            ]),
          ),
        ),
      ],
      const SizedBox(height: Gap.l),
      FilledButton(
        key: const Key('claim-done'),
        style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
        onPressed: () {
          AppScope.read(context).claims.clearFlows();
          Navigator.of(context).pop();
        },
        child: const Text('Done'),
      ),
      if (!ok && widget.restore == null) ...[
        const SizedBox(height: Gap.s),
        OutlinedButton(
          key: const Key('claim-try-again'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: _again,
          child: const Text('Try again'),
        ),
      ],
      const SizedBox(height: Gap.l),
      const _DisclosureCard(),
    ];
  }
}

class _DisclosureCard extends StatelessWidget {
  const _DisclosureCard({super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      color: t.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.lock_outline, size: 20),
          const SizedBox(width: Gap.s),
          Expanded(child: Text(claimDisclosure, style: t.textTheme.bodyMedium)),
        ]),
      ),
    );
  }
}

enum _StepState { done, now, waiting }

class _StepRow extends StatelessWidget {
  final String title;
  final _StepState state;
  const _StepRow({required this.title, required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final label = switch (state) {
      _StepState.done => 'done',
      _StepState.now => 'in progress',
      _StepState.waiting => 'waiting',
    };
    return Semantics(
      label: '$title, $label',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 28,
            child: switch (state) {
              _StepState.done => Icon(Icons.check_circle, size: 22, color: t.colorScheme.primary),
              _StepState.now => const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5)),
              _StepState.waiting => Icon(Icons.radio_button_unchecked, size: 22, color: t.colorScheme.outline),
            },
          ),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text(title,
                style: t.textTheme.bodyLarge?.copyWith(
                    fontWeight: state == _StepState.now ? FontWeight.w700 : FontWeight.w400,
                    color: state == _StepState.waiting ? t.colorScheme.onSurfaceVariant : null)),
          ),
        ]),
      ),
    );
  }
}

class _CommandBox extends StatelessWidget {
  final String command;
  const _CommandBox({required this.command});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.s),
      padding: const EdgeInsets.only(left: Gap.m),
      decoration: BoxDecoration(color: t.colorScheme.surface, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Row(children: [
        Expanded(child: SelectableText(command, style: const TextStyle(fontFamily: 'monospace', fontSize: 15))),
        IconButton(
          tooltip: 'Copy "$command"',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.copy, size: 20),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: command));
            if (!context.mounted) return;
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Copied')));
          },
        ),
      ]),
    );
  }
}
