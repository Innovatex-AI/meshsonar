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
          ? FilledButton(key: const Key('radio-proof-join'), style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)), onPressed: () => onAnswer(true), child: Text('Yes, add this $deviceWord'))
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
        // Build 76: each answer is its own card with a bold word and one or two short lines (it was three paragraphs that
        // started "Yes:" and "No:"), and Not now is a full-width button, not a small text link on the left.
        if (state.canJoin)
          _answer(context, key: const Key('radio-proof-yes-card'), icon: Icons.check_circle_outline, word: 'Yes', lines: [
            'This $deviceWord and its drives join $owner\'s account. Their other devices are told.',
            if (state.askFirst) '$owner approves new devices first, so you wait for their answer.',
          ], askFirst: state.askFirst)
        else
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.s),
            child: Text('This $deviceWord is signed in to an account, so it cannot join another one.', key: const Key('radio-proof-nojoin'), style: t.textTheme.bodyMedium),
          ),
        _answer(context, key: const Key('radio-proof-no-card'), icon: Icons.swap_horiz, word: 'No', lines: const [
          'Only the radio moves to you. Their drives and devices stay theirs, and they are told.',
        ]),
        if (state.canJoin) ...[
          const SizedBox(height: Gap.s),
          OutlinedButton(
            key: const Key('radio-proof-later'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: onLater,
            child: const Text('Not now'),
          ),
        ],
      ],
    );
  }

  Widget _answer(BuildContext context, {required Key key, required IconData icon, required String word, required List<String> lines, bool askFirst = false}) {
    final t = Theme.of(context);
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: Gap.s),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.small)),
      child: MergeSemantics(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 22, color: t.colorScheme.primary),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(word, style: t.textTheme.titleSmall),
              for (var i = 0; i < lines.length; i++)
                Text(lines[i], key: askFirst && i == 1 ? const Key('radio-proof-askfirst') : null, style: t.textTheme.bodyMedium),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Opens the sheet for [state]; true = Yes (join), false = No (take), null = Not now.
Future<bool?> showRadioProofSheet(BuildContext context, ProofFlowState state, {required String deviceWord}) => showAppSheet<bool>(
  context,
  // Taller (build 76): at 0.62 the Not now button sat under the fold on an iPhone SE.
  detents: const [0.78],
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
