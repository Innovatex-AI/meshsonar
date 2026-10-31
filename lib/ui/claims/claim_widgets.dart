// Small pieces shared by the claim screens and the repeater sheets: the "Owned by you" chip and the "Claim this
// repeater" button. Both show only when the server takes claims (capability nodeClaims) and this phone's key is
// approved; they never touch recording or uploading.
import 'package:flutter/material.dart';

import '../app.dart' show AppScope;
import '../theme.dart';
import 'claim_repeater_screen.dart';
import 'my_radios_screen.dart';

/// The wording of the promise every claim screen repeats, in one place so the screens and the tests agree.
const String claimDisclosure = 'Nothing on your repeater is changed: your radio just logs in with the admin password. '
    'We never see or store your admin password; claiming only lets you manage this radio, it never affects whether its data counts.';

/// A claim never decides whether data counts. Said on every claim screen.
const String claimNeverGates = 'Claiming only lets you manage a radio (its name, whether its position is public, giving it up). '
    'Every radio keeps feeding and counting whether or not anyone claims it.';

class OwnedByYouChip extends StatelessWidget {
  const OwnedByYouChip({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      label: 'Owned by you',
      excludeSemantics: true,
      child: Container(
        key: const Key('owned-by-you'),
        padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 3),
        decoration: BoxDecoration(
          color: t.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(Corners.chip),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.verified_outlined, size: 16, color: t.colorScheme.onPrimaryContainer),
          const SizedBox(width: 4),
          Text('Owned by you', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

/// "Owned by you" (tap: My radios) when this key has claimed [keyHex]; else "Claim this repeater"; nothing when claims
/// are not available. [isRoom] repeaters are left out: the login for a room server differs and is not supported yet.
class ClaimRepeaterAction extends StatelessWidget {
  final String keyHex;
  final String name;
  final bool isRoom;
  const ClaimRepeaterAction({super.key, required this.keyHex, required this.name, this.isRoom = false});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.maybeOf(context);
    if (s == null || !s.nodeClaimsEnabled || isRoom || keyHex.length != 64) return const SizedBox.shrink();
    if (!s.ownsRadio(keyHex) && !s.repeaterClaimEnabled) return const SizedBox.shrink();
    if (s.ownsRadio(keyHex)) {
      return Padding(
        padding: const EdgeInsets.only(top: Gap.s),
        child: Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            key: const Key('owned-by-you-open'),
            borderRadius: BorderRadius.circular(Corners.chip),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MyRadiosScreen())),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: const Align(widthFactor: 1, child: OwnedByYouChip()),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: Gap.m),
      child: OutlinedButton.icon(
        key: const Key('claim-this-repeater'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        icon: const Icon(Icons.verified_user_outlined),
        label: const Text('Claim this repeater'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => ClaimRepeaterScreen(initialKey: keyHex, initialName: name)),
        ),
      ),
    );
  }
}
