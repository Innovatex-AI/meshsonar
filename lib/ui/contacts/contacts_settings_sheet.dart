// What the radio does with a node it hears advertise, and the nodes the user said no to.
import 'package:flutter/material.dart';

import '../../chat/contact_port.dart';
import '../design/app_surfaces.dart';
import '../theme.dart';
import 'contacts_controller.dart';

Future<void> showContactsSettings(BuildContext context, ContactsController controller) => showAppSheet<void>(
      context,
      detents: const [0.92],
      builder: (_, scroll) => PrimaryScrollController(controller: scroll, child: ContactsSettingsSheet(controller: controller)),
    );

class ContactsSettingsSheet extends StatefulWidget {
  final ContactsController controller;
  const ContactsSettingsSheet({super.key, required this.controller});
  @override
  State<ContactsSettingsSheet> createState() => _ContactsSettingsSheetState();
}

class _ContactsSettingsSheetState extends State<ContactsSettingsSheet> {
  String? _error;

  Future<void> _set(ContactPolicy p) async {
    setState(() => _error = null);
    try {
      await widget.controller.manager.setPolicy(p);
    } catch (_) {
      if (mounted) setState(() => _error = 'The radio did not take that. Check it is connected and try again.');
    }
  }

  static const _hops = <int, String>{0: 'Any distance', 1: 'Direct only', 2: 'Up to 1 repeater', 3: 'Up to 2 repeaters', 4: 'Up to 3 repeaters', 6: 'Up to 5 repeaters'};

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = widget.controller.manager;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final p = m.state.policy;
        final on = m.connected && p != null;
        final detail = on && p.askBeforeAdding && p.autoAddSupported;
        final hops = _hops.containsKey(p?.maxHops) ? p!.maxHops : 0;
        final ignored = m.ignored();
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
          child: Column(
            key: const Key('contacts-settings'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('New nodes', style: t.textTheme.titleLarge),
              const SizedBox(height: Gap.s),
              if (!on) Text('Connect your radio to change this.', key: const Key('settings-offline'), style: t.textTheme.bodyLarge),
              SwitchListTile(
                key: const Key('set-ask'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Ask me before adding new nodes'),
                subtitle: const Text('Off: the radio adds every node it hears and its list fills with strangers.'),
                value: p?.askBeforeAdding ?? false,
                onChanged: on ? (v) => _set(p.copyWith(askBeforeAdding: v)) : null,
              ),
              if (on && p.askBeforeAdding && !p.autoAddSupported)
                Text('This radio\'s firmware cannot add some kinds automatically. Every new node waits for you.', style: t.textTheme.bodyMedium),
              if (detail) ...[
                Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('Still add automatically', style: t.textTheme.titleSmall)),
                for (final e in <(String, String, bool, ContactPolicy Function(bool))>[
                  ('set-people', 'People', p.autoAddChat, (v) => p.copyWith(autoAddChat: v)),
                  ('set-repeaters', 'Repeaters', p.autoAddRepeaters, (v) => p.copyWith(autoAddRepeaters: v)),
                  ('set-rooms', 'Rooms', p.autoAddRooms, (v) => p.copyWith(autoAddRooms: v)),
                  ('set-sensors', 'Sensors', p.autoAddSensors, (v) => p.copyWith(autoAddSensors: v)),
                ])
                  SwitchListTile(key: Key(e.$1), contentPadding: EdgeInsets.zero, title: Text(e.$2), value: e.$3, onChanged: (v) => _set(e.$4(v))),
                SwitchListTile(
                  key: const Key('set-overwrite'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('When the radio list is full, replace the oldest'),
                  subtitle: const Text('Never a favourite. Your phone keeps the replaced contact.'),
                  value: p.overwriteOldest,
                  onChanged: (v) => _set(p.copyWith(overwriteOldest: v)),
                ),
                const SizedBox(height: Gap.s),
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  key: const Key('set-hops'),
                  initialValue: hops,
                  decoration: const InputDecoration(labelText: 'Only add nodes within'),
                  items: [for (final e in _hops.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) => v == null ? null : _set(p.copyWith(maxHops: v)),
                ),
              ],
              if (_error != null) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text(_error!, style: TextStyle(color: t.colorScheme.error))),
              const SizedBox(height: Gap.l),
              Text('Ignored nodes', style: t.textTheme.titleLarge),
              if (ignored.isEmpty)
                Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('None. A node you ignore is hidden from New nodes nearby and can be restored here.', style: t.textTheme.bodyMedium))
              else
                for (final a in ignored)
                  ListTile(
                    key: Key('ignored-${a.publicKey.substring(0, 8)}'),
                    contentPadding: EdgeInsets.zero,
                    minTileHeight: 56,
                    title: Text(a.name),
                    trailing: TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => m.restoreIgnored(a.publicKey), child: const Text('Restore')),
                  ),
            ],
          ),
        );
      },
    );
  }
}
