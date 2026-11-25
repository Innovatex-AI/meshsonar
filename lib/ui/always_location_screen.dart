// Plain-language explanation shown BEFORE iOS's one-shot "Always" location prompt, plus the region-change preset
// question. Both are full explanations first, system prompt / action second. The explainer's words live in
// lib/ui/settings/data_sharing.dart (locationPoints), shared with Settings > Privacy & data sharing.
import 'package:flutter/material.dart';

import '../core/region_preset.dart';
import '../platform/always_location.dart';
import '../platform/open_url.dart' show openAppSettingsPage;
import 'design/app_surfaces.dart' show showAppSheet, showAppToast;
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

/// The first sentence of [body] and the rest: the page shows the first under each heading and opens the rest on a tap.
@visibleForTesting
(String first, String rest) splitFirstSentence(String body) {
  final m = RegExp(r'[.!?](\s+)').firstMatch(body);
  if (m == null) return (body, '');
  return (body.substring(0, m.start + 1), body.substring(m.end));
}

class AlwaysLocationScreen extends StatelessWidget {
  /// Opened from Settings to read again: Done and "Open iOS Settings", no permission request (iOS only asks once anyway;
  /// a change is made in iOS Settings, as the last point says).
  final bool explainOnly;
  const AlwaysLocationScreen({super.key, this.explainOnly = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // Each point is its heading and one sentence; a tap opens the rest (build 76: the page was four full paragraphs).
    Widget point(int n, IconData i, String head, String body) {
      final (first, rest) = splitFirstSentence(body);
      final icon = Icon(i, color: t.colorScheme.primary);
      final title = Text(head, style: t.textTheme.titleMedium);
      if (rest.isEmpty) return ListTile(key: Key('always-location-point-$n'), contentPadding: EdgeInsets.zero, leading: icon, title: title, subtitle: Text(first));
      return ExpansionTile(
        key: Key('always-location-point-$n'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 40, bottom: Gap.m),
        expandedAlignment: Alignment.centerLeft,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: icon,
        title: title,
        subtitle: Text(first),
        children: [Text(rest, style: t.textTheme.bodyMedium)],
      );
    }

    final big = FilledButton.styleFrom(minimumSize: const Size.fromHeight(52));
    final plain = TextButton.styleFrom(minimumSize: const Size.fromHeight(48));
    return Scaffold(
      key: const Key('always-location-screen'),
      appBar: AppBar(title: const Text('Location while driving')),
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 12), children: [
              Text(
                explainOnly ? 'How MeshSonar uses your location' : 'Keep recording when the screen is off',
                key: const Key('always-location-title'),
                style: t.textTheme.headlineSmall,
              ),
              const SizedBox(height: Gap.s),
              for (final (i, p) in locationPoints.indexed) point(i, _pointIcons[i % _pointIcons.length], p.head, p.body),
            ]),
          ),
          // The buttons stay at the bottom of the screen, under the thumb, instead of at the end of the scrolling text.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, Gap.s, 20, Gap.m),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (explainOnly) ...[
                FilledButton(
                  key: const Key('always-location-done'),
                  style: big,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
                TextButton(
                  key: const Key('always-location-settings'),
                  style: plain,
                  onPressed: () async {
                    final ok = await openAppSettingsPage();
                    if (!ok && context.mounted) showAppToast(context, 'Open the Settings app, then MeshSonar > Location.');
                  },
                  child: const Text('Change it in iOS Settings'),
                ),
              ] else ...[
                Text('Next, iOS asks. Choose "Change to Always Allow".',
                    key: const Key('always-location-next'), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
                const SizedBox(height: Gap.s),
                FilledButton(
                  key: const Key('always-location-continue'),
                  style: big,
                  onPressed: () async {
                    await requestAlwaysLocation();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('Continue'),
                ),
                TextButton(
                  key: const Key('always-location-not-now'),
                  style: plain,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Not now'),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// "910.525 MHz · 62.5 kHz · SF7 · CR5"; parts the radio has not reported are left out ("Not reported yet" when none).
@visibleForTesting
String presetLine(double? freqMhz, double? bwKhz, int? sf, int? cr) {
  final parts = [
    if (freqMhz != null && freqMhz > 0) '${freqMhz.toStringAsFixed(3)} MHz',
    if (bwKhz != null && bwKhz > 0) '${bwKhz.toStringAsFixed(1)} kHz',
    if (sf != null) 'SF$sf',
    if (cr != null) 'CR$cr',
  ];
  return parts.isEmpty ? 'Not reported yet' : parts.join(' · ');
}

/// A border crossing landed in a region whose radio preset differs from the connected radio. The app never changes
/// the radio; this only asks what the person wants to look at.
Future<void> showPresetPrompt(BuildContext context, RegionPresetPrompt p, {required void Function(bool switchView) onAnswer}) {
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
              Semantics(header: true, child: Text('${p.to.name} uses different radio settings', style: Theme.of(ctx).textTheme.titleLarge)),
              const SizedBox(height: Gap.m),
              Text('Your radio', style: Theme.of(ctx).textTheme.bodySmall),
              Text(presetLine(r.freqMhz, r.bwKhz, r.sf, r.cr), key: const Key('region-preset-radio')),
              const SizedBox(height: 10),
              Text('${p.preset.name} (${p.to.code})', style: Theme.of(ctx).textTheme.bodySmall),
              Text(presetLine(p.preset.freqMhz, p.preset.bwKhz, p.preset.sf, p.preset.cr), key: const Key('region-preset-region')),
              const SizedBox(height: 12),
              const Text('Your radio is not changed. To use it here, change its preset in More > Radio setup.', key: Key('region-preset-note')),
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
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                child: Text('Show ${p.to.name}'),
              ),
              const SizedBox(height: Gap.xs),
              TextButton(
                key: const Key('region-preset-stay'),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  onAnswer(false);
                },
                style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: Text('Keep showing ${p.from.name}'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
