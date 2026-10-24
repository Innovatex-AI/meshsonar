// Settings > Region: which region the app shows, which region the server answers for, and that region's suggested
// radio preset next to the connected radio's own (information only; the app never writes to the radio).
import 'package:flutter/material.dart' hide Radio;

import '../../core/api.dart';
import '../../core/model.dart' show Radio;
import '../app.dart';
import '../region/region_switcher.dart';
import 'settings_kit.dart';

const String regionHelp = 'The app opens on the region your phone is in. Pick any region to view its coverage, repeaters '
    'and activity. This never changes your radio.';

/// The section's rows. The two server rows exist only once `GET /api/cmh/site-config` has answered; a slow or failing
/// fetch leaves them out and nothing else is affected.
List<Widget> regionSectionRows(BuildContext context) {
  final s = AppScope.of(context);
  return [
    const SettingsAnchor(id: 'region-pick', child: RegionPickTile()),
    if (s.siteConfig != null) const SettingsAnchor(id: 'site-region', child: RegionTile()),
    if (s.siteConfig != null) const SettingsAnchor(id: 'site-radio-preset', child: RadioPresetTile()),
  ];
}

/// Which region the current server URL resolves to (`GET /api/cmh/site-config`). Only built once that answer has
/// arrived (see regionSectionRows) — a slow or failing fetch simply leaves this tile out, the
/// Server URL tile above it is unaffected either way.
class RegionTile extends StatelessWidget {
  const RegionTile({super.key});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final region = s.siteConfig!.region;
    // No human-readable region name exists on the wire; the host is the recognisable part.
    final host = Uri.tryParse(region.url)?.host ?? region.url;
    return ListTile(
      key: const Key('site-region'),
      leading: const Icon(Icons.public),
      title: const Text('Connected to'),
      subtitle: Text('$host\nThe region your server answers for. Change it with Server URL.'),
    );
  }
}

/// This region's suggested MeshCore radio/channel preset, compared against whatever the connected radio is actually
/// using. Informational only — the app only ever reads RF parameters off the connected hardware; it never writes a
/// preset to it. Covers every state: no preset configured for the region, a preset with no radio connected, and a
/// preset shown side by side with the connected radio's own live parameters.
class RadioPresetTile extends StatelessWidget {
  const RadioPresetTile({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final c = t.colorScheme;
    final preset = s.siteConfig!.radioPreset;

    if (preset == null) {
      return const ListTile(
        key: Key('site-radio-preset'),
        leading: Icon(Icons.settings_input_antenna_outlined),
        title: Text('Radio preset'),
        subtitle: Text('This region has no suggested preset.'),
      );
    }

    final radio = s.selfInfo?.radio; // the connected radio's own live RF parameters, or null if none is connected
    return Padding(
      key: const Key('site-radio-preset'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.settings_input_antenna_outlined, color: c.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(child: Text('Radio preset', style: t.textTheme.titleMedium)),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 40, top: 8),
          child: radio == null
              ? Column(
                  key: const Key('site-radio-preset-no-radio'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${preset.name} (this region)', style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                    Text(_formatPreset(preset), style: numberStyle(context, size: 16, color: c.primary)),
                    const SizedBox(height: 6),
                    Text('No radio connected to compare.', style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                  ],
                )
              : Column(
                  key: const Key('site-radio-preset-compare'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Yours', style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                    Text(_formatRadio(radio), style: numberStyle(context, size: 16)),
                    const SizedBox(height: 8),
                    Text('${preset.name} (this region)', style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                    Text(_formatPreset(preset), style: numberStyle(context, size: 16, color: c.primary)),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 40, top: 8),
          child: Text('Information only. MeshSonar never changes your radio; change the preset in the MeshCore app.',
              style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

/// `freqMHz · bwKHz · SFn · CRn`, matching the fields CMAT's site-config sends.
String _formatPreset(RadioPreset p) =>
    '${p.freqMhz.toStringAsFixed(3)} MHz · ${p.bwKhz.toStringAsFixed(1)} kHz · SF${p.sf} · CR${p.cr}';

/// Same shape as [_formatPreset] but for the connected radio's own readings, any of which can be unmeasured (null).
String _formatRadio(Radio r) {
  final freq = r.freqMhz == null ? '—' : '${r.freqMhz!.toStringAsFixed(3)} MHz';
  final bw = r.bwKhz == null ? '—' : '${r.bwKhz!.toStringAsFixed(1)} kHz';
  final sf = r.sf == null ? '—' : 'SF${r.sf}';
  final cr = r.cr == null ? '—' : 'CR${r.cr}';
  return '$freq · $bw · $sf · $cr';
}

/// Which region the app is viewing; opens the switcher.
class RegionPickTile extends StatelessWidget {
  const RegionPickTile({super.key});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final v = s.viewingRegion;
    return ListTile(
      key: const Key('region-pick'),
      leading: const Icon(Icons.map_outlined),
      title: const Text('Region'),
      subtitle: Text(v == null
          ? 'Not loaded yet. It appears once the region list downloads.'
          : '${v.name} (${v.code}) · ${s.viewingIsManual ? 'picked by you' : 'following your location'}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showRegionSwitcher(context),
    );
  }
}

