// "Contacts on your radio": what the radio's table holds, and a way to free slots without touching the phone's book.
import 'package:flutter/material.dart';

import '../theme.dart';
import 'contacts_controller.dart';

Future<void> showRadioListSheet(BuildContext context, ContactsController controller) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => RadioListSheet(controller: controller),
    );

class RadioListSheet extends StatefulWidget {
  final ContactsController controller;
  const RadioListSheet({super.key, required this.controller});
  @override
  State<RadioListSheet> createState() => _RadioListSheetState();
}

class _RadioListSheetState extends State<RadioListSheet> {
  final Set<String> _picked = {};
  bool _busy = false;
  String? _error;

  Future<void> _remove() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final n = await widget.controller.manager.removeFromRadio(_picked);
      _picked.clear();
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$n taken off your radio. They are still on this phone.')));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'The radio did not answer. Check it is on and close by, then try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = widget.controller.manager;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final s = m.state;
        final cands = m.connected ? m.cleanupSuggestions() : const [];
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
          child: Column(
            key: const Key('radio-list-sheet'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Contacts on your radio', style: t.textTheme.titleLarge),
              const SizedBox(height: Gap.s),
              if (s.radioCount != null && s.capacity != null) ...[
                Text('${s.radioCount} of ${s.capacity} used', style: t.textTheme.titleMedium),
                const SizedBox(height: Gap.xs),
                LinearProgressIndicator(value: s.capacity == 0 ? 0 : (s.radioCount! / s.capacity!).clamp(0, 1).toDouble()),
              ],
              const SizedBox(height: Gap.m),
              Text(
                'Your phone keeps every contact. The radio holds a copy of the ones it needs. Taking one off the radio does not '
                'delete it from your phone, but the radio can no longer receive messages from them until it is put back.',
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: Gap.m),
              if (!m.connected)
                Text('Connect your radio to change what is on it.', key: const Key('radio-list-offline'), style: t.textTheme.bodyLarge)
              else if (cands.isEmpty)
                Text('Nothing to suggest. Favourites and people you have talked to are never suggested.', key: const Key('radio-list-none'), style: t.textTheme.bodyLarge)
              else ...[
                Text('Safe to take off', style: t.textTheme.titleSmall),
                for (final c in cands)
                  CheckboxListTile(
                    key: Key('cleanup-${c.contact.publicKey.substring(0, 8)}'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _picked.contains(c.contact.publicKey),
                    onChanged: _busy ? null : (v) => setState(() => v == true ? _picked.add(c.contact.publicKey) : _picked.remove(c.contact.publicKey)),
                    title: Text(c.contact.displayName),
                    subtitle: Text(c.reason),
                  ),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text(_error!, style: TextStyle(color: t.colorScheme.error))),
                const SizedBox(height: Gap.m),
                FilledButton(
                  key: const Key('radio-list-remove'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _picked.isEmpty || _busy ? null : _remove,
                  child: Text(_picked.isEmpty ? 'Pick contacts to take off' : 'Take ${_picked.length} off the radio'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
