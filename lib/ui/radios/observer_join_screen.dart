// More > Radios and tools > Set up a repeater observer (release 0.38 vocabulary, build plan §4.5 item 6: "Observer" is
// this phone sharing public packets, set in Settings > Observer; this guide is for a repeater): a step-by-step walk from
// "I have a radio / a repeater" to a repeater that reports to MeshSonar. It only guides; the proof is the existing login-attested claim (lib/ui/claims). Nothing is sent
// to the repeater by this screen, there is no approval and it is free: an observer that authenticates and publishes the
// right format is attached to its region automatically.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/node_claim.dart';
import '../app.dart';
import '../claims/claim_radio_screen.dart';
import '../claims/claim_repeater_screen.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../drive/drive_controls.dart' show openConnect;
import '../shell/plan_tab.dart' show planToolUri;

/// The screen's title (also the More row's label: one wording everywhere).
const String observerJoinTitle = 'Set up a repeater observer';

/// The intro: the phone is already an observer; this guide is for a repeater.
const String observerJoinIntro =
    'Make a repeater report what it hears to MeshSonar. Free. (Your phone already does this while your radio is '
    'connected: Settings > Sharing & privacy.)';

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
    if (!s.hasKey) return 'Needs a driver key. Add one under Settings > Account.';
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
      // Every state in words as well as by the number's colour: Done, Next or Waiting (VoiceOver reads it with the title).
      final (word, colour) = switch (st) {
        ObserverStepState.done => ('Done', t.colorScheme.primary),
        ObserverStepState.next => ('Next', t.colorScheme.secondary),
        ObserverStepState.waiting => ('Waiting', t.colorScheme.onSurfaceVariant),
      };
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
                  ? ExcludeSemantics(child: AppSymbolIcon(AppSymbols.checkmark, size: 16, color: t.colorScheme.onPrimary))
                  : Text('$n', style: t.textTheme.labelLarge),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: t.textTheme.titleMedium),
                Text(word, key: Key('observer-step-$key-state'), style: t.textTheme.labelMedium?.copyWith(color: colour)),
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
      appBar: AppBar(title: const Text(observerJoinTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              key: const Key('observer-join-screen'),
              padding: const EdgeInsets.all(Gap.l),
              children: [
                const Text(observerJoinIntro, key: Key('observer-intro')),
                const SizedBox(height: Gap.m),
                if (why != null) ...[
                  MergeSemantics(
                    child: Row(key: const Key('observer-why-not'), crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: AppSymbolIcon(AppSymbols.exclamationCircle, size: 18, color: t.colorScheme.error),
                      ),
                      const SizedBox(width: Gap.s),
                      Expanded(child: Text(why, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error))),
                    ]),
                  ),
                  const SizedBox(height: Gap.m),
                ],
                step(1, 'connect', 'Connect your radio',
                    'It talks to the repeater for you, so stay within reach of it.', p.connect,
                    // Build 76: a button, not directions to another tab.
                    action: p.radioConnected
                        ? null
                        : OutlinedButton.icon(
                            key: const Key('observer-connect'),
                            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                            icon: const AppSymbolIcon(AppSymbols.antenna, size: 18),
                            label: const Text('Connect radio'),
                            onPressed: () => openConnect(context))),
                step(2, 'claim-radio', 'Claim your radio (optional)',
                    'Proves the radio is yours. No password.', p.claimRadio,
                    action: p.radioClaimed
                        ? null
                        : OutlinedButton(
                            key: const Key('observer-claim-radio'),
                            onPressed: p.claimRadio == ObserverStepState.next ? () => _open(context, const ClaimRadioScreen()) : null,
                            child: const Text('Claim my radio'))),
                step(3, 'claim-repeater', 'Claim the repeater',
                    'Your radio logs in to the repeater with its admin password. Nothing on the repeater is changed, and the '
                    'password never leaves this phone and your radio.',
                    p.claimRepeater,
                    action: p.repeaterClaimed
                        ? null
                        : FilledButton(
                            key: const Key('observer-claim-repeater'),
                            onPressed: p.claimRepeater == ObserverStepState.next ? () => _open(context, const ClaimRepeaterScreen()) : null,
                            child: const Text('Claim a repeater'))),
                step(4, 'report', 'Point the repeater at MeshSonar',
                    'The repeater needs observer firmware. The website has the exact settings for your hardware, ready to copy.',
                    p.repeaterClaimed ? ObserverStepState.next : ObserverStepState.waiting,
                    action: OutlinedButton(
                        key: const Key('observer-open-setup'),
                        onPressed: () async {
                          final ok = await s.services.openUrl(planToolUri(base, observerSetupPath));
                          if (!ok && context.mounted) {
                            showAppToast(context, 'Couldn\'t open the browser. Try again, or visit meshsonar.com/observers/setup.', kind: AppToastKind.error);
                          }
                        },
                        child: const Text('Open the setup steps'))),
                step(5, 'check', 'See it on the map',
                    'A few minutes later it shows as an observer in your region.',
                    ObserverStepState.waiting),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
