// First-run disclosure for telemetry (on by default, opt-out). Plain language; both choices are equally visible.
import 'package:flutter/material.dart';

import 'app.dart';
import 'onboarding/ui_prefs.dart';

const String telemetryHelp =
    'Shares packet headers and signal strength your radio hears, to build the live packet feed. Never message text.';

Future<void> showTelemetryDisclosure(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    builder: (_) => const _TelemetrySheet(),
  );
}

class _TelemetrySheet extends StatelessWidget {
  const _TelemetrySheet();

  Future<void> _choose(BuildContext context, bool share) async {
    final s = AppScope.read(context);
    final prefs = uiPrefsFor(s);
    Navigator.of(context).pop();
    if (s.settings.telemetryEnabled != share) await s.updateSettings(s.settings.copyWith(telemetryEnabled: share));
    await prefs.markTelemetryDisclosed();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget bullet(IconData i, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 20, color: t.colorScheme.primary),
            const SizedBox(width: Gap.m),
            Expanded(child: Text(text, style: t.textTheme.bodyLarge)),
          ]),
        );
    return SingleChildScrollView(
      key: const Key('telemetry-sheet'),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('Help build the live packet feed', style: t.textTheme.headlineSmall),
        const SizedBox(height: Gap.m),
        Text('MeshSonar can share what your radio overhears on the mesh, so everyone gets a live view of the network. This is on unless you turn it off.', style: t.textTheme.bodyLarge),
        const SizedBox(height: Gap.m),
        bullet(Icons.check, 'Shared: packet type, the repeaters it passed through, signal strength (SNR, RSSI), time and region.'),
        bullet(Icons.block, 'Never shared: message text or any message content, private channels, direct messages, your name, or your location attached to packets.'),
        bullet(Icons.toggle_on_outlined, 'Change your mind any time in Settings, under Privacy.'),
        const SizedBox(height: Gap.l),
        FilledButton(key: const Key('telemetry-keep'), onPressed: () => _choose(context, true), child: const Text('Share headers')),
        const SizedBox(height: Gap.s),
        OutlinedButton(key: const Key('telemetry-off'), onPressed: () => _choose(context, false), child: const Text('Turn off')),
      ]),
    );
  }
}
