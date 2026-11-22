// "How it was proven": the one place that words a claim's stored method (signature, advert, login), so Claimed radios and
// More > Observers cannot disagree. The long words are the website's (`METHOD_TRUST` in claim-model.ts); the short ones are the
// plan's ladder (identity-claims-observers-plan D3: a repeater login is "reported by the app", the weakest proof).
//
// [ClaimProofStyle.legacyChip] is Claimed radios exactly as it was in build 74. It is used while the server does not offer radio
// proof, so with that switch off nothing on that screen changes.
import 'package:flutter/material.dart';

import '../../core/node_claim.dart';
import '../theme.dart';

/// Short label, as in the plan: how this radio's owner was proven.
String claimProofShort(ClaimMethod m) => switch (m) {
  ClaimMethod.signature => 'Proved by the radio\'s signature',
  ClaimMethod.advert => 'Proved by its signed advert',
  ClaimMethod.login => 'Reported by the app',
  ClaimMethod.other => 'Proved by its owner',
};

/// The website's trust line for the method.
String claimProofWords(ClaimMethod m) => switch (m) {
  ClaimMethod.signature => "Proved with the radio's own key; we checked the signature ourselves.",
  ClaimMethod.advert => "Proved by the radio's own signed advert, heard by a MeshSonar observer; we checked the signature ourselves.",
  ClaimMethod.login => 'Attested by your app after an admin login from your own radio. We cannot see the login ourselves, so a later signature or advert proof from someone else replaces it.',
  ClaimMethod.other => 'Proved by its owner.',
};

/// Claimed radios' chip text in build 74 (no radio proof on the server).
String claimProofLegacy(ClaimMethod m) => switch (m) {
  ClaimMethod.signature => 'Verified by the radio\'s signature',
  ClaimMethod.advert => 'Verified by an observer hearing the code',
  ClaimMethod.login => 'Logged in as admin from your app',
  ClaimMethod.other => 'Verified',
};

enum ClaimProofStyle {
  /// A chip with the short label and, under it, the website's words ("How it was proven").
  chip,

  /// One line, `Proof: <the website's words>` (More > Observers).
  line,

  /// The build 74 chip of Claimed radios, nothing more.
  legacyChip,
}

class ClaimProofLabel extends StatelessWidget {
  final ClaimMethod method;
  final ClaimProofStyle style;
  const ClaimProofLabel(this.method, {super.key, this.style = ClaimProofStyle.chip});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    switch (style) {
      case ClaimProofStyle.line:
        return Text('Proof: ${claimProofWords(method)}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant));
      case ClaimProofStyle.legacyChip:
        return _chip(context, claimProofLegacy(method));
      case ClaimProofStyle.chip:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _chip(context, claimProofShort(method)),
            const SizedBox(height: Gap.xs),
            Text('How it was proven: ${claimProofWords(method)}', style: t.textTheme.bodySmall),
          ],
        );
    }
  }

  Widget _chip(BuildContext context, String text) {
    final t = Theme.of(context);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 4),
        decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.verified_outlined, size: 16),
            const SizedBox(width: 4),
            Flexible(child: Text(text, style: t.textTheme.labelMedium)),
          ],
        ),
      ),
    );
  }
}
