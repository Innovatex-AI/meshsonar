// More > Radios and tools > Become an observer: a step-by-step walk from "I have a radio / a repeater" to a repeater that
// reports to MeshSonar. It only guides; the proof is the existing login-attested claim (lib/ui/claims). Nothing is sent
// to the repeater by this screen, there is no approval and it is free: an observer that authenticates and publishes the
// right format is attached to its region automatically.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/node_claim.dart';
import '../app.dart';
import '../claims/claim_radio_screen.dart';
import '../claims/claim_repeater_screen.dart';
import '../shell/plan_tab.dart' show planToolUri;

/// The website page with the copy-paste settings for each kind of observer.
const String observerSetupPath = '/observers/setup';

/// How far along the wizard is, derived from the app's state; shown as done / next / waiting.
enum ObserverStepState { done, next, waiting }

class ObserverJoinProgress {
  final bool radioConnected;
  final bool radioClaimed;
  final bool repeaterClaimed;
  final String? claimsWhyNot;
  const ObserverJoinProgress({
    required this.radioConnected,
    required this.radioClaimed,
    required this.repeaterClaimed,
    this.claimsWhyNot,
  });

  /// Why claims cannot be used right now (no key, server too old), null when they can.
  static String? claimsBlocker(AppState s) {
    if (!s.hasKey) return 'Needs a driver key. Add one under Settings > Account & driver key.';
    if (s.uploadSiteConfig?.nodeClaims != true || s.uploadSiteConfig?.nodeClaimsLogin != true) {
      return 'This server does not offer claims yet.';
    }
    if (!s.keyApproved) return 'Needs a driver key the server accepts.';
    return null;
  }

  factory ObserverJoinProgress.of(AppState s) {
    final info = s.selfInfo;
    return ObserverJoinProgress(
      radioConnected: s.connected && info != null,
      radioClaimed: info != null && s.ownsRadio(info.publicKey.toLowerCase()),
      repeaterClaimed: s.claims.active.any((c) => c.nodeType == ClaimNodeType.repeater || c.nodeType == ClaimNodeType.observer),
      claimsWhyNot: claimsBlocker(s),
    );
  }

  bool get _canClaim => radioConnected && claimsWhyNot == null;

  ObserverStepState get connect => radioConnected ? ObserverStepState.done : ObserverStepState.next;
  ObserverStepState get claimRadio =>
      radioClaimed ? ObserverStepState.done : (_canClaim ? ObserverStepState.next : ObserverStepState.waiting);
  ObserverStepState get claimRepeater =>
      repeaterClaimed ? ObserverStepState.done : (_canClaim ? ObserverStepState.next : ObserverStepState.waiting);
}

class ObserverJoinScreen extends StatelessWidget {
  const ObserverJoinScreen({super.key});

  void _open(BuildContext context, Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final p = ObserverJoinProgress.of(s);
    final base = s.viewingRegion?.url ?? s.settings.serverUrl;

    Widget step(int n, String key, String title, String body, ObserverStepState st, {Widget? action}) {
      final done = st == ObserverStepState.done;
      return Card(
        key: Key('observer-step-$key'),
        margin: const EdgeInsets.only(bottom: Gap.s),
        child: Padding(
          padding: const EdgeInsets.all(Gap.m),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: done ? t.colorScheme.primary : t.colorScheme.surfaceContainerHighest,
              child: done
                  ? Icon(Icons.check, size: 16, color: t.colorScheme.onPrimary, semanticLabel: 'Done')
                  : Text('$n', style: t.textTheme.labelLarge),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: t.textTheme.titleMedium),
                const SizedBox(height: Gap.xs),
                Text(body, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                if (action != null) ...[const SizedBox(height: Gap.s), action],
              ]),
            ),
          ]),
        ),
      );
    }

    final why = p.claimsWhyNot;
    return Scaffold(
      appBar: AppBar(title: const Text('Become an observer')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              key: const Key('observer-join-screen'),
              padding: const EdgeInsets.all(Gap.l),
              children: [
                const Text(
                  'An observer is a repeater that also reports every packet it hears to MeshSonar, so the maps show what really reaches it. '
                  'It is free and nobody approves it: once it reports in the right format it is added to its region on its own.',
                  key: Key('observer-intro'),
                ),
                const SizedBox(height: Gap.m),
                if (why != null) ...[
                  Text(why, key: const Key('observer-why-not'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error)),
                  const SizedBox(height: Gap.m),
                ],
                step(1, 'connect', 'Connect your radio',
                    'The radio in your hand talks to the repeater for you, so it has to be within reach of it.', p.connect,
                    action: p.radioConnected ? null : Text('Open More > Radio to connect.', style: t.textTheme.bodySmall)),
                step(2, 'claim-radio', 'Claim your radio (optional)',
                    'Proves the radio is yours without a password, so you can manage it later.', p.claimRadio,
                    action: p.radioClaimed
                        ? null
                        : OutlinedButton(
                            key: const Key('observer-claim-radio'),
                            onPressed: p.claimRadio == ObserverStepState.next ? () => _open(context, const ClaimRadioScreen()) : null,
                            child: const Text('Claim my radio'))),
                step(3, 'claim-repeater', 'Claim the repeater',
                    'Your radio logs in to the repeater with its admin password, over the mesh. That is the proof it is yours. '
                    'Nothing on the repeater is changed, and the password stays on this phone and goes only to your radio.',
                    p.claimRepeater,
                    action: p.repeaterClaimed
                        ? null
                        : FilledButton(
                            key: const Key('observer-claim-repeater'),
                            onPressed: p.claimRepeater == ObserverStepState.next ? () => _open(context, const ClaimRepeaterScreen()) : null,
                            child: const Text('Claim a repeater'))),
                step(4, 'report', 'Point the repeater at MeshSonar',
                    'The repeater has to run observer firmware and publish to mqtt.meshsonar.com. The website lists the exact settings for '
                    'your hardware, ready to copy. This app never sends commands to your repeater.',
                    p.repeaterClaimed ? ObserverStepState.next : ObserverStepState.waiting,
                    action: OutlinedButton(
                        key: const Key('observer-open-setup'),
                        onPressed: () async {
                          final ok = await s.services.openUrl(planToolUri(base, observerSetupPath));
                          if (!ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('Couldn\'t open the browser. Try again, or visit meshsonar.com/observers/setup.')));
                          }
                        },
                        child: const Text('Open the setup steps'))),
                step(5, 'check', 'See it on the map',
                    'A few minutes after it reports, the repeater shows as an observer in your region and its pings get confirmed. '
                    'Drive near it and the Last ping line says how many observers confirmed.',
                    ObserverStepState.waiting),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
