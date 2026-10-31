// Settings > My radios: the radios you manage (name, whether the position is public, giving one up), "Claim my radio"
// and "Claim a repeater". A claim only manages a radio; it never decides whether its data is recorded or counted.
import 'package:flutter/material.dart';

import '../app.dart';
import '../claims/claim_radio_screen.dart';
import '../claims/claim_repeater_screen.dart';
import '../claims/my_radios_screen.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String myRadiosHelp = 'Claim a radio to manage it: its name, whether its position is public, giving it up. '
    'Every radio keeps feeding and counting whether or not it is claimed.';

String? _whyNot(BuildContext context, {bool needsRadio = false}) {
  final s = AppScope.of(context);
  if (!s.hasKey) return 'Needs a driver key. Add one under Account & driver key.';
  if (s.uploadSiteConfig?.nodeClaims != true) return 'This server does not offer radio claims yet.';
  if (!s.keyApproved) return 'Needs a driver key the server accepts.';
  if (needsRadio && !s.connected) return 'Connect your radio first (Radio tab).';
  return null;
}

List<Widget> myRadiosSectionRows(BuildContext context) {
  final s = AppScope.of(context);
  final n = s.claims.active.length;
  final listWhy = _whyNot(context);
  final ownWhy = _whyNot(context, needsRadio: true);
  final repWhy = _whyNot(context) ?? (s.uploadSiteConfig?.nodeClaimsLogin == true ? null : 'The server is being updated for repeater claims.');
  void open(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
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
                ? (n == 0 ? 'None yet. Claim your radio or a repeater you run.' : '$n ${n == 1 ? 'radio' : 'radios'}. Edit a name, hide a position, give one up.')
                : settingsEntry('my-radios').summary),
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
        subtitle: ownWhy != null ? SettingsWhyNot(ownWhy) : Text(settingsEntry('claim-my-radio').summary),
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
        subtitle: repWhy != null ? SettingsWhyNot(repWhy) : Text(settingsEntry('claim-repeater').summary),
        trailing: repWhy == null ? const Icon(Icons.chevron_right) : null,
        onTap: repWhy == null ? () => open(const ClaimRepeaterScreen()) : null,
      ),
    ),
  ];
}
