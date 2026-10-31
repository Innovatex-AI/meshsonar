// Radio tab (read-only): what the connected radio reports about itself, compared field by field with the viewed
// region's preset and, on request, the MeshCore community presets. Nothing here writes to a radio.
import 'package:flutter/material.dart' hide Radio;

import '../../core/model.dart';
import '../../core/radio_presets.dart';
import '../../radio/radio_api.dart';
import '../app.dart';
import '../connect_screen.dart';
import '../region/preset_info.dart';

class RadioScreen extends StatefulWidget {
  /// Injected in tests; the app uses the community list at api.meshcore.nz.
  final CommunityPresetSource? communitySource;
  const RadioScreen({super.key, this.communitySource});
  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> {
  late final CommunityPresetSource _source = widget.communitySource ?? HttpCommunityPresetSource();
  List<CommunityPreset>? _community;
  bool _loading = false;
  String? _error;

  Future<void> _loadCommunity() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _source.fetch();
      if (!mounted) return;
      setState(() {
        _community = list;
        _loading = false;
        if (list.isEmpty) _error = 'The community list had no usable presets.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the community list. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final info = s.connected ? s.selfInfo : null;
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Radio')),
      body: SafeArea(
        child: ListView(
          key: const Key('radio-list'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (info == null) _notConnected(context) else _settingsCard(context, info),
            const SizedBox(height: Gap.l),
            _regionPreset(context, info?.radio),
            const SizedBox(height: Gap.l),
            _communitySection(context, info?.radio),
            const SizedBox(height: Gap.l),
            Text(
              'This screen only reads your radio. MeshSonar never changes its settings.',
              key: const Key('radio-readonly-note'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _notConnected(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      key: const Key('radio-not-connected'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.bluetooth_disabled, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(width: Gap.m),
          Expanded(child: Text('Radio not connected', style: t.textTheme.titleLarge)),
        ]),
        const SizedBox(height: Gap.s),
        Text('Connect a MeshCore radio to see its settings here and compare them with your region.',
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.m),
        FilledButton.icon(
          key: const Key('radio-connect'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen())),
          icon: const Icon(Icons.bluetooth),
          label: const Text('Connect a radio'),
        ),
      ],
    );
  }

  Widget _settingsCard(BuildContext context, SelfInfo info) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final r = info.radio;
    String v(String? x) => x ?? 'Not reported';
    final rows = <(String, String)>[
      ('Name', info.name),
      ('Firmware', v(info.firmware)),
      ('Frequency', v(r.freqMhz == null ? null : '${r.freqMhz!.toStringAsFixed(3)} MHz')),
      ('Bandwidth', v(r.bwKhz == null ? null : '${r.bwKhz!.toStringAsFixed(1)} kHz')),
      ('Spreading factor', v(r.sf == null ? null : 'SF${r.sf}')),
      ('Coding rate', v(r.cr == null ? null : 'CR${r.cr}')),
      ('TX power', v(r.txDbm == null ? null : '${r.txDbm!.toStringAsFixed(r.txDbm! % 1 == 0 ? 0 : 1)} dBm')),
    ];
    return Column(
      key: const Key('radio-settings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.settings_input_antenna, color: c.primary),
          const SizedBox(width: Gap.m),
          Expanded(child: Text('Connected radio', style: t.textTheme.titleLarge)),
        ]),
        const SizedBox(height: Gap.s),
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 4, child: Text(label, style: t.textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant))),
              Expanded(flex: 5, child: Text(value, style: numberStyle(context, size: 16))),
            ]),
          ),
      ],
    );
  }

  Widget _regionPreset(BuildContext context, Radio? radio) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final c = t.colorScheme;
    final region = s.viewingRegion;
    final site = s.siteConfig;
    final forView = s.siteConfigIsForViewing;
    final preset = s.viewingPreset;
    final provenance = preset == null ? null : presetProvenanceText(preset);
    final heading = region == null ? 'Region preset' : 'Region preset: ${region.name}';
    return Column(
      key: const Key('radio-region-preset'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(heading, style: t.textTheme.titleLarge),
        const SizedBox(height: Gap.s),
        if (site == null || !forView)
          Text('The region preset has not loaded yet.', style: t.textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant))
        else if (preset == null) ...[
          Text('This region has no suggested preset.', style: t.textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
          const SizedBox(height: Gap.s),
          NoPresetNote(regionName: region?.name ?? 'This region', none: s.viewingPresetNone),
        ] else ...[
          Text(preset.name, style: t.textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
          if (provenance != null) Text(provenance, key: const Key('radio-region-provenance'), style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
          const SizedBox(height: Gap.s),
          ComparisonTable(key: const Key('radio-region-compare'), comparison: compareRegionPreset(radio, preset), hasRadio: radio != null),
        ],
      ],
    );
  }

  Widget _communitySection(BuildContext context, Radio? radio) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final list = _community;
    return Column(
      key: const Key('radio-community'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Community presets', style: t.textTheme.titleLarge),
        const SizedBox(height: Gap.s),
        Text('Suggested by the MeshCore community (api.meshcore.nz). A different preset than your neighbours means you will not hear each other.',
            style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
        const SizedBox(height: Gap.m),
        if (_loading)
          const Row(children: [SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: Gap.m), Text('Loading')])
        else if (list == null || list.isEmpty) ...[
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: Gap.s), child: Text(_error!, key: const Key('radio-community-error'))),
          OutlinedButton.icon(
            key: const Key('radio-community-load'),
            onPressed: _loadCommunity,
            icon: const Icon(Icons.public),
            label: Text(_error == null ? 'Compare with community presets' : 'Try again'),
          ),
        ] else
          ..._communityRows(context, list, radio),
      ],
    );
  }

  List<Widget> _communityRows(BuildContext context, List<CommunityPreset> list, Radio? radio) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final rows = [for (final p in list) (p, p.compare(radio))];
    // Exact matches first so "which one am I on?" is the first thing seen.
    rows.sort((a, b) => (b.$2.allMatch ? 1 : 0).compareTo(a.$2.allMatch ? 1 : 0));
    return [
      if (radio == null)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.s),
          child: Text('Connect a radio to see which preset it matches.', key: const Key('radio-community-no-radio'), style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
        ),
      for (final (p, cmp) in rows)
        Padding(
          key: Key('community-${p.title}'),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.title, style: t.textTheme.titleMedium),
            Text('${p.freqMhz.toStringAsFixed(3)} MHz · ${p.bwKhz.toStringAsFixed(1)} kHz · SF${p.sf} · CR${p.cr}', style: numberStyle(context, size: 14, color: c.primary)),
            const SizedBox(height: 2),
            if (radio == null)
              const SizedBox.shrink()
            else if (cmp.allMatch)
              const _Verdict(FieldVerdict.matches, 'Matches your radio')
            else if (cmp.anyDiffers)
              _Verdict(FieldVerdict.differs, 'Differs: ${cmp.differing.join(', ')}')
            else
              const _Verdict(FieldVerdict.unknown, 'Your radio did not report enough to compare'),
          ]),
        ),
    ];
  }
}

/// Field | your radio | preset | verdict. Words and icons carry the verdict, never color alone.
class ComparisonTable extends StatelessWidget {
  final PresetComparison comparison;
  final bool hasRadio;
  const ComparisonTable({super.key, required this.comparison, required this.hasRadio});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(flex: 3, child: Text('Field', style: t.textTheme.labelMedium?.copyWith(color: c.onSurfaceVariant))),
        Expanded(flex: 3, child: Text('Your radio', style: t.textTheme.labelMedium?.copyWith(color: c.onSurfaceVariant))),
        Expanded(flex: 3, child: Text('Preset', style: t.textTheme.labelMedium?.copyWith(color: c.onSurfaceVariant))),
        Expanded(flex: 3, child: Text('Result', style: t.textTheme.labelMedium?.copyWith(color: c.onSurfaceVariant))),
      ]),
      for (final f in comparison.fields)
        Padding(
          key: Key('cmp-${f.label}'),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: Text(f.label, style: t.textTheme.bodySmall)),
            Expanded(flex: 3, child: Text(f.radioValue ?? (hasRadio ? 'Not reported' : 'No radio'), style: numberStyle(context, size: 14, weight: FontWeight.w500))),
            Expanded(flex: 3, child: Text(f.presetValue, style: numberStyle(context, size: 14, weight: FontWeight.w500, color: c.primary))),
            Expanded(flex: 3, child: hasRadio ? _Verdict(f.verdict, switch (f.verdict) { FieldVerdict.matches => 'Matches', FieldVerdict.differs => 'Differs', FieldVerdict.unknown => 'Unknown' }) : const Text('Not compared')),
          ]),
        ),
      if (hasRadio)
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: Text(
            comparison.allMatch
                ? 'Your radio matches this preset.'
                : comparison.anyDiffers
                    ? 'Your radio differs from this preset in: ${comparison.differing.join(', ')}.'
                    : 'Your radio did not report enough to compare.',
            key: const Key('cmp-summary'),
            style: t.textTheme.bodyMedium,
          ),
        ),
    ]);
  }
}

class _Verdict extends StatelessWidget {
  final FieldVerdict verdict;
  final String text;
  const _Verdict(this.verdict, this.text);
  @override
  Widget build(BuildContext context) {
    final icon = switch (verdict) { FieldVerdict.matches => Icons.check_circle_outline, FieldVerdict.differs => Icons.error_outline, FieldVerdict.unknown => Icons.help_outline };
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 16),
      const SizedBox(width: 4),
      Flexible(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
    ]);
  }
}
