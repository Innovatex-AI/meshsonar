// "Claim my radio": the connected companion proves it is yours by signing a message from the server with its own
// identity key (Ed25519). Nothing goes over the air and there is no password.
import 'dart:async';

import 'package:flutter/material.dart';
import '../drive/drive_controls.dart' show openConnect;

import '../../core/claim_flow.dart';
import '../app.dart';
import 'claim_repeater_screen.dart' show claimOutcomeTitle;
import 'claim_widgets.dart';

class ClaimRadioScreen extends StatefulWidget {
  const ClaimRadioScreen({super.key});
  @override
  State<ClaimRadioScreen> createState() => _ClaimRadioScreenState();
}

class _ClaimRadioScreenState extends State<ClaimRadioScreen> {
  OwnRadioClaimFlow? _flow;
  StreamSubscription<ClaimFlowState>? _sub;
  ClaimFlowState _st = const ClaimFlowState();

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  bool get _busy => _flow != null && !_st.finished;

  void _start() {
    final f = AppScope.read(context).claims.startOwnRadioClaim();
    if (f == null) return;
    _sub?.cancel();
    setState(() {
      _flow = f;
      _st = f.state;
    });
    _sub = f.states.listen((s) {
      if (mounted) setState(() => _st = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final info = s.selfInfo;
    final connected = s.connected && info != null;
    final List<Widget> body;
    if (_flow == null) {
      body = [
        const Text('Proves the connected radio is yours. Your radio signs a short message from the server. No password, and nothing goes over the air.'),
        const SizedBox(height: Gap.m),
        if (connected)
          Card(
            child: ListTile(
              key: const Key('claim-radio-connected'),
              minVerticalPadding: Gap.s,
              leading: const Icon(Icons.settings_input_antenna),
              title: Text(info.name.isEmpty ? 'Your radio' : info.name),
              // The start and end of the key on one line (build 76): all 64 characters wrapped over three.
              subtitle: Text(info.publicKey.length > 20 ? 'Key ${info.publicKey.substring(0, 8)}…${info.publicKey.substring(info.publicKey.length - 8)}' : info.publicKey,
                  maxLines: 1, style: const TextStyle(fontFamily: 'monospace', fontSize: 12), semanticsLabel: 'Public key ${info.publicKey}'),
            ),
          )
        else
          Card(
            key: const Key('claim-radio-needs-radio'),
            color: t.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(Gap.m),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Connect your radio first. This claims the radio that is connected.', style: TextStyle(color: t.colorScheme.onErrorContainer)),
                const SizedBox(height: Gap.s),
                // Build 76: the way out is a button here, not directions to another tab.
                FilledButton.tonalIcon(
                  key: const Key('claim-radio-connect'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('Connect radio'),
                  onPressed: () => openConnect(context),
                ),
              ]),
            ),
          ),
        const SizedBox(height: Gap.m),
        Text(claimNeverGates, key: const Key('claim-never-gates'), style: t.textTheme.bodyMedium),
        const SizedBox(height: Gap.l),
        FilledButton.icon(
          key: const Key('claim-radio-start'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          icon: const Icon(Icons.verified_user_outlined),
          label: const Text('Claim this radio'),
          onPressed: connected ? _start : null,
        ),
        if (!connected)
          Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('Needs a connected radio.', style: t.textTheme.bodySmall)),
      ];
    } else if (!_st.finished) {
      body = [
        Semantics(liveRegion: true, child: Text(_st.message, key: const Key('claim-message'), style: t.textTheme.titleMedium)),
        const SizedBox(height: Gap.l),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: Gap.l),
        OutlinedButton(
          key: const Key('claim-cancel'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: _flow!.cancel,
          child: const Text('Cancel'),
        ),
      ];
    } else {
      final ok = _st.verified || _st.outcome == ClaimOutcome.alreadyYours;
      body = [
        Row(children: [
          Icon(ok ? Icons.check_circle : Icons.info_outline, size: 32, color: ok ? t.colorScheme.primary : t.colorScheme.error),
          const SizedBox(width: Gap.m),
          Expanded(child: Text(_st.verified ? 'This radio is yours' : claimOutcomeTitle(_st.outcome), key: const Key('claim-result-title'), style: t.textTheme.titleLarge)),
        ]),
        const SizedBox(height: Gap.m),
        Semantics(liveRegion: true, child: Text(_st.message, key: const Key('claim-message'))),
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
        if (!ok) ...[
          const SizedBox(height: Gap.s),
          OutlinedButton(
            key: const Key('claim-try-again'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: () => setState(() {
              _flow = null;
              _st = const ClaimFlowState();
            }),
            child: const Text('Try again'),
          ),
        ],
      ];
    }
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Claim my radio')),
        body: SafeArea(child: ListView(key: const Key('claim-radio-screen'), padding: const EdgeInsets.all(Gap.l), children: body)),
      ),
    );
  }
}
