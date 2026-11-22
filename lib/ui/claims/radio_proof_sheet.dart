// "Is that you?" (ID step 2): shown when the connected radio is on another person's account. The question is plain words, never a
// key. Yes = this device joins that person; No = the radio alone moves here. RadioProofHost watches the app's proof controller and
// opens the sheet (how a proof ended is said through AppState's notice, see RadioProofController.say); it does nothing at all while the server does not advertise radio proof.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/radio_proof_flow.dart';
import '../app.dart';
import '../design/app_surfaces.dart';

/// What a person is asked and offered, from the flow's asking state. [deviceWord] is "iPad" or "iPhone".
class RadioProofQuestion extends StatelessWidget {
  final ProofFlowState state;
  final String deviceWord;
  final ScrollController controller;
  final void Function(bool join) onAnswer;
  final VoidCallback onLater;
  const RadioProofQuestion({
    super.key,
    required this.state,
    required this.deviceWord,
    required this.controller,
    required this.onAnswer,
    required this.onLater,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final owner = state.ownerName == null ? 'that person' : state.ownerName!;
    return AppSheetScaffold(
      key: const Key('radio-proof-sheet'),
      controller: controller,
      title: 'Is that you?',
      primaryAction: state.canJoin
          ? FilledButton(key: const Key('radio-proof-join'), onPressed: () => onAnswer(true), child: Text('Yes, add this $deviceWord'))
          : FilledButton(
              key: const Key('radio-proof-take'),
              onPressed: () => onAnswer(false),
              child: const Text('No, the radio is mine now'),
            ),
      secondaryAction: state.canJoin
          ? TextButton(key: const Key('radio-proof-take'), onPressed: () => onAnswer(false), child: const Text('No, the radio is mine now'))
          : TextButton(key: const Key('radio-proof-later'), onPressed: onLater, child: const Text('Not now')),
      children: [
        Text(state.question, key: const Key('radio-proof-question'), style: t.textTheme.titleMedium),
        const SizedBox(height: Gap.m),
        if (state.canJoin) ...[
          Text(
            'Yes: this $deviceWord and what it recorded join $owner\'s account. The account\'s other devices get a notice.',
            style: t.textTheme.bodyMedium,
          ),
          if (state.askFirst) ...[
            const SizedBox(height: Gap.s),
            Text(
              '$owner asked to approve new devices first, so they will get a request and you will wait for their answer.',
              key: const Key('radio-proof-askfirst'),
              style: t.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: Gap.s),
        ] else ...[
          Text(
            'This $deviceWord is signed in to an account, so it cannot join another one.',
            key: const Key('radio-proof-nojoin'),
            style: t.textTheme.bodyMedium,
          ),
          const SizedBox(height: Gap.s),
        ],
        Text(
          'No: only the radio moves to you. Their drives, devices and settings stay theirs, and they are told.',
          style: t.textTheme.bodyMedium,
        ),
        if (state.canJoin) ...[
          const SizedBox(height: Gap.m),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(key: const Key('radio-proof-later'), onPressed: onLater, child: const Text('Not now')),
          ),
        ],
      ],
    );
  }
}

/// Opens the sheet for [state]; true = Yes (join), false = No (take), null = Not now.
Future<bool?> showRadioProofSheet(BuildContext context, ProofFlowState state, {required String deviceWord}) => showAppSheet<bool>(
  context,
  detents: const [0.62],
  userInitiated: false,
  builder: (ctx, controller) => RadioProofQuestion(
    state: state,
    deviceWord: deviceWord,
    controller: controller,
    onAnswer: (j) => Navigator.pop(ctx, j),
    onLater: () => Navigator.pop(ctx, null),
  ),
);

class RadioProofHost extends StatefulWidget {
  final Widget child;
  const RadioProofHost({super.key, required this.child});
  @override
  State<RadioProofHost> createState() => _RadioProofHostState();
}

class _RadioProofHostState extends State<RadioProofHost> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.maybeOf(context);
    if (s == null || !s.radioProofEnabled) return widget.child; // flag off: nothing
    final c = s.radioProof;
    final st = c.state;
    if (c.pending && !_open) {
      _open = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final word = MediaQuery.sizeOf(context).shortestSide >= 600 ? 'iPad' : 'iPhone';
        final r = await showRadioProofSheet(context, st, deviceWord: word);
        _open = false;
        if (r == null) {
          c.dismiss();
        } else {
          c.answer(join: r);
        }
      });
    }
    return widget.child;
  }
}
