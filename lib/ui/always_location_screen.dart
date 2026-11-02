// Plain-language explanation shown BEFORE iOS's one-shot "Always" location prompt, plus the region-change preset
// question. Both are full explanations first, system prompt / action second. The explainer's words live in
// lib/ui/settings/data_sharing.dart (locationPoints), shared with Settings > Privacy & data sharing.
import 'package:flutter/material.dart';

import '../core/region_preset.dart';
import '../platform/always_location.dart';
import 'design/app_surfaces.dart' show showAppSheet;
import 'design/sheet_detents.dart';
import 'theme.dart' show Gap;
import 'settings/data_sharing.dart' show locationPoints;

const List<IconData> _pointIcons = [Icons.lock_outline, Icons.public, Icons.visibility_off_outlined, Icons.tune];

/// Shows the explainer (once) when iOS is at "While Using" and Always could still be granted.
Future<void> maybeAskAlwaysLocation(BuildContext context) async {
  if (await alwaysLocationState() != AlwaysLocationState.canUpgrade) return;
  if (await alwaysExplainerShown()) return;
  if (!context.mounted) return;
  await markAlwaysExplainerShown();
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const AlwaysLocationScreen()));
}

class AlwaysLocationScreen extends StatelessWidget {
  /// Opened from Settings to read again: one Done button, no permission request (iOS only asks once anyway; a change
  /// is made in iOS Settings, as the last point says).
  final bool explainOnly;
  const AlwaysLocationScreen({super.key, this.explainOnly = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget point(IconData i, String head, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, color: t.colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(head, style: t.textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(body, style: t.textTheme.bodyMedium),
            ])),
          ]),
        );
    return Scaffold(
      key: const Key('always-location-screen'),
      appBar: AppBar(title: const Text('Location while driving')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text('Let MeshSonar keep recording when the screen is off', style: t.textTheme.headlineSmall),
          const SizedBox(height: 18),
          for (final (i, p) in locationPoints.indexed) point(_pointIcons[i % _pointIcons.length], p.head, p.body),
          const SizedBox(height: 8),
          if (explainOnly)
            FilledButton(
              key: const Key('always-location-done'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            )
          else ...[
            FilledButton(
              key: const Key('always-location-continue'),
              onPressed: () async {
                await requestAlwaysLocation();
                if (context.mounted) Navigator.of(context).pop();
              },
              child: const Text('Continue'),
            ),
            TextButton(
              key: const Key('always-location-not-now'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
          ],
        ]),
      ),
    );
  }
}

/// A border crossing landed in a region whose radio preset differs from the connected radio. The app never changes
/// the radio; this only asks what the person wants to look at.
Future<void> showPresetPrompt(BuildContext context, RegionPresetPrompt p, {required void Function(bool switchView) onAnswer}) {
  String fmt(double f, double bw, int? sf, int? cr) => '${f.toStringAsFixed(3)} MHz · ${bw.toStringAsFixed(1)} kHz · SF$sf · CR$cr';
  final r = p.radio;
  return showAppSheet<void>(
    context,
    detents: formSheetDetents(context),
    dismissible: false,
    userInitiated: false,
    builder: (ctx, controller) => Column(
      key: const Key('region-preset-dialog'),
      children: [
        Expanded(
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, Gap.m),
            children: [
              Semantics(header: true, child: Text('${p.to.name} uses a different radio preset', style: Theme.of(ctx).textTheme.titleLarge)),
              const SizedBox(height: Gap.m),
              Text('Your radio', style: Theme.of(ctx).textTheme.bodySmall),
              Text(fmt(r.freqMhz ?? 0, r.bwKhz ?? 0, r.sf, r.cr)),
              const SizedBox(height: 10),
              Text('${p.preset.name} (${p.to.code})', style: Theme.of(ctx).textTheme.bodySmall),
              Text(fmt(p.preset.freqMhz, p.preset.bwKhz, p.preset.sf, p.preset.cr)),
              const SizedBox(height: 12),
              const Text('MeshSonar never changes your radio by itself. To use this region, change the preset on your radio '
                  '(More > Radio setup, or the MeshCore app), then reconnect.'),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l + MediaQuery.viewPaddingOf(ctx).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                key: const Key('region-preset-switch'),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  onAnswer(true);
                },
                child: Text('Show ${p.to.code}'),
              ),
              const SizedBox(height: Gap.xs),
              TextButton(
                key: const Key('region-preset-stay'),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  onAnswer(false);
                },
                child: Text('Keep showing ${p.from.code}'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
