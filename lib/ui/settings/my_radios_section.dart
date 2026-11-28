// Settings > Claimed radios: the radios you manage (name, whether the position is public, giving one up), "Claim my radio"
// and "Claim a repeater". A claim only manages a radio; it never decides whether its data is recorded or counted.
import 'package:flutter/material.dart';

import '../app.dart';
import 'account_section.dart' show CreateKeyScreen;
import '../claims/claim_radio_screen.dart';
import '../claims/claim_repeater_screen.dart';
import '../claims/my_radios_screen.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String myRadiosHelp = 'Claim a radio to manage its name and whether its position is public.';

/// Said once on the page when the phone has no driver key (build 77, round 5 S8: each of the three rows said it).
const String claimsNeedKey = 'Claiming and managing radios needs a driver key.';

String? _whyNot(BuildContext context, {bool needsRadio = false}) {
  final s = AppScope.of(context);
  if (!s.hasKey) return 'Needs a driver key. Add one under Settings > Account.';
  if (s.uploadSiteConfig?.nodeClaims != true) return 'This server does not offer radio claims yet.';
  if (!s.keyApproved) return 'Needs a driver key the server accepts.';
  if (needsRadio && !s.connected) return 'Connect your radio first (More > Radio).';
  return null;
}

/// "3 radios" / "None yet" / why it cannot be used: the Claimed radios row on the first level of Account.
String claimsCaption(BuildContext context) {
  final s = AppScope.of(context);
  final why = _whyNot(context);
  if (why != null) return why;
  final n = s.claims.active.length;
  if (!s.claims.loadedOnce) return 'The radios you manage, and claiming one.';
  return n == 0 ? 'None yet. Claim your radio or a repeater you run.' : '$n ${n == 1 ? 'radio' : 'radios'} claimed.';
}

List<Widget> myRadiosSectionRows(BuildContext context) {
  final s = AppScope.of(context);
  final n = s.claims.active.length;
  final listWhy = _whyNot(context);
  final ownWhy = _whyNot(context, needsRadio: true);
  final repWhy = _whyNot(context) ?? (s.uploadSiteConfig?.nodeClaimsLogin == true ? null : 'The server is being updated for repeater claims.');
  void open(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  if (!s.hasKey) {
    // One note and one button in place of three rows that each said "Needs a driver key". The three anchors stay on it, so
    // search and links still land here.
    final t = Theme.of(context);
    return [
      SettingsAnchor(
        id: 'my-radios',
        child: SettingsAnchor(
          id: 'claim-my-radio',
          child: SettingsAnchor(
            id: 'claim-repeater',
            child: Padding(
              key: const Key('claims-need-key'),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.vpn_key_outlined, color: t.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 16),
                  Expanded(child: SettingsWhyNot(claimsNeedKey, style: t.textTheme.bodyMedium)),
                ]),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 40),
                  child: FilledButton.icon(
                    key: const Key('claims-create-key'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: s.keyBusy ? null : () => open(const CreateKeyScreen()),
                    icon: const Icon(Icons.vpn_key),
                    label: const Text('Create my key'),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    ];
  }
  return [
    SettingsAnchor(
      id: 'my-radios',
      child: ListTile(
        key: const Key('my-radios'),
        leading: const Icon(Icons.verified_user_outlined),
        title: Text(settingsEntry('my-radios').title),
        subtitle: listWhy != null
            ? SettingsWhyNot(listWhy)
            : Text(s.claims.loadedOnce
                ? (n == 0 ? 'None yet.' : '$n ${n == 1 ? 'radio' : 'radios'}. Rename, hide a position, give one up.')
                : 'Rename, hide a position, give one up.'),
        trailing: listWhy == null ? const Icon(Icons.chevron_right) : null,
        onTap: listWhy == null ? () => open(const MyRadiosScreen()) : null,
      ),
    ),
    SettingsAnchor(
      id: 'claim-my-radio',
      child: ListTile(
        key: const Key('claim-my-radio'),
        leading: const Icon(Icons.settings_input_antenna),
        title: Text(settingsEntry('claim-my-radio').title),
        subtitle: ownWhy != null ? SettingsWhyNot(ownWhy) : const Text('The connected radio signs a message. No password.'),
        trailing: ownWhy == null ? const Icon(Icons.chevron_right) : null,
        onTap: ownWhy == null ? () => open(const ClaimRadioScreen()) : null,
      ),
    ),
    SettingsAnchor(
      id: 'claim-repeater',
      child: ListTile(
        key: const Key('claim-repeater'),
        leading: const Icon(Icons.cell_tower),
        title: Text(settingsEntry('claim-repeater').title),
        subtitle: repWhy != null ? SettingsWhyNot(repWhy) : const Text('With its admin password, which never leaves your phone.'),
        trailing: repWhy == null ? const Icon(Icons.chevron_right) : null,
        onTap: repWhy == null ? () => open(const ClaimRepeaterScreen()) : null,
      ),
    ),
  ];
}
