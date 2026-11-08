// The map layers sheet (Drive plan 4.7, wireframe F; sections per the coverage redesign plan section 5, Nov 8 2026), generated
// from the registry (registry.dart, [kSheetRows]): Base map, then Coverage (Measured coverage, Predicted coverage, This drive
// with its Ping dots) and Network (Repeaters with a This region / All MeshCore scope and a Names sub-switch, Observers, Lines
// to repeaters), one switch per row, each with its honest status line from
// [DriveMapModel.statusOf] (count, source, "Not available on this server yet", "Couldn't load" + Retry, "Saved copy from ...")
// and its inline key (the swatches are built from the same colour functions the map paints with, so a key can never disagree
// with the map). A layer whose data is unsupported or empty is shown with its switch disabled and the reason, never hidden;
// one that is on can always be switched off.
//
// Non-modal (the map stays live above it, every toggle applies instantly): [showGeneratedLayersSheet] opens it in the Drive tab's
// anchored host when given one, else as a non-modal app sheet with detents [0.4, 0.75]. "Coverage options" is a page inside the
// sheet (window, growth slider, source). The colour-by selector, detail chips and range rings are gone (plan D1, D9).
//
// Keys: 'layers-sheet', 'layers-done', 'layers-base-map', 'base-map-<id>', 'layers-group-<group>', the switch per layer from
// [layerSwitchKey] (the pre-registry keys are kept: measured = 'layer-network-coverage', heard = 'layer-repeaters', repeaters
// (roster) = 'layer-region-repeaters'; the rest are 'layer-<id>'), 'layer-<id>-status', 'layer-<id>-retry', 'layer-<id>-key',
// 'layer-color-snr', 'layer-color-result', 'layer-repeaters-scope', 'layer-measured-options', 'layers-options-page', 'layers-options-back',
// 'layers-filter', 'layers-credits', 'layers-legend', 'layers-reset', 'network-legend', 'roster-legend'.
import 'package:flutter/cupertino.dart' show CupertinoButton, CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';

import '../../../core/map_styles.dart';
import '../../../core/network_coverage.dart' show CoverageLevel;
import '../../../core/region_repeaters_api.dart' show RepeaterActivity;
import '../../design/anchored_sheet.dart';
import '../../design/app_surfaces.dart';
import '../../design/app_symbols.dart';
import '../../design/app_widgets.dart' show AppSwitchTile;
import '../../design/map_tokens.dart';
import '../../design/tokens.dart' show Hit;
import '../../drive/drive_map_model.dart';
import '../../theme.dart';
import '../../../core/coverage_v2.dart' show CoverageMeta;
import '../coverage_bands.dart';
import '../coverage_layer_controls.dart';
import '../coverage_map.dart' show networkLevelColor;
import '../sheets/coverage_cell_sheet.dart' show CoverageBandSwatch;
import '../legend_sheet.dart' show LegendSwatch, SwatchShape, showMapLegend;
import '../map_layers.dart' show PingColorMode;
import 'repeater_cluster_layer.dart' show regionRepeaterColor;
import '../sheets/repeater_sheet.dart' show rosterStatusText;
import '../map_tools.dart' show showMapFilterSheet;
import '../overlays/credits_sheet.dart' show showMapCredits;
import 'map_layer.dart';
import 'registry.dart';
import 'repeater_map_source.dart';

/// Layers this build draws: every registry layer (the dead `neighbours` entry is gone).
final Set<String> kDrawnLayerIds = {for (final l in kMapLayers) l.id};

/// The widget key of a layer's switch. Pre-registry keys stay (tests and muscle memory).
Key layerSwitchKey(String id) => Key(switch (id) {
  'measured' => 'layer-network-coverage',
  'heard' => 'layer-repeaters',
  kRosterLayerId => 'layer-region-repeaters',
  _ => 'layer-$id',
});

/// Title and one-line description per layer (Drive plan 7.1).
({String title, String? description}) layerPresentation(BuildContext context, MapLayerSpec spec, {String? regionName, bool hasPosition = true}) {
  return switch (spec.id) {
    'pings' => (title: 'Ping dots', description: 'Each ping you sent.'),
    'hexes' => (title: 'This drive', description: 'Your pings this session, in the same cells and colours.'),
    'links' => (title: 'Lines to repeaters', description: 'Live lines to repeaters you hear, and lines when you tap a repeater or cell.'),
    'measured' => (title: 'Measured coverage', description: "Everyone's drives: the average signal in each cell."),
    'predicted' => (title: 'Predicted coverage', description: 'An estimate near measured cells, hatched.'),
    'heard' => (title: 'Heard this drive', description: 'Repeaters your pings reached (highlighted).'),
    kRosterLayerId => (title: 'Repeaters', description: 'By last advert. Repeaters your pings reached are lit.'),
    kNetworkLayerId => (
      title: 'All MeshCore repeaters',
      description: 'Every repeater with a public position (MeshCore Map). Turn on to see every repeater in the country.',
    ),
    'observers' => (title: 'Observers', description: 'Observers that share a position.'),
    kLabelsLayerId => (title: 'Names', description: 'Name beside each repeater; fewer when zoomed out.'),
    _ => (title: spec.label, description: null),
  };
}

/// Opens the sheet for [model]. With an [anchored] host (the Drive tab's) it sits above the dock; otherwise it is a non-modal
/// app sheet, so the map behind stays interactive either way.
Future<void> showGeneratedLayersSheet(BuildContext context, DriveMapModel model, {AnchoredSheetController? anchored}) {
  if (anchored != null) {
    anchored.show(
      id: 'layers',
      maxFraction: 0.75,
      builder: (ctx) => MapLayersSheet(model: model, onDone: () => anchored.close('layers')),
    );
    return Future.value();
  }
  return showAppSheet<void>(
    context,
    detents: const [0.4, 0.75],
    modal: false,
    builder: (ctx, c) => MapLayersSheet(model: model, scroll: c, onDone: () => Navigator.of(ctx).pop()),
  );
}

class MapLayersSheet extends StatefulWidget {
  final DriveMapModel model;

  /// The sheet's scroll controller (hands a drag on the list to the sheet); null inside the anchored host.
  final ScrollController? scroll;
  final VoidCallback? onDone;
  const MapLayersSheet({super.key, required this.model, this.scroll, this.onDone});

  @override
  State<MapLayersSheet> createState() => _MapLayersSheetState();
}

class _MapLayersSheetState extends State<MapLayersSheet> {
  bool _options = false;

  DriveMapModel get model => widget.model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([model, model.repeaterSource]),
      builder: (context, _) => Column(
        key: const Key('layers-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _options ? _optionsPage(context) : _mainPage(context),
      ),
    );
  }

  // ------------------------------------------------------------------ the main page

  List<Widget> _mainPage(BuildContext context) {
    final t = Theme.of(context);
    final st = model.layerState;
    return [
      _Header(title: 'Map layers', trailing: _TextAction(key: const Key('layers-done'), label: 'Done', onTap: widget.onDone)),
      Flexible(
        child: ListView(
          controller: widget.scroll,
          shrinkWrap: true,
          padding: EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(context).bottom + Gap.m),
          children: [
            const _SectionLabel('Base map', key: Key('layers-group-base')),
            _BaseMapPicker(model: model),
            for (final g in LayerGroup.values) ...[
              _SectionLabel(g.label, key: Key('layers-group-${g.name}')),
              for (final row in kSheetRows[g]!) ..._layer(context, layerSpec(row.id)!, st, sub: row.parent != null),
              if (g == LayerGroup.coverage)
                _NavRow(
                  key: const Key('layer-measured-options'),
                  title: 'Coverage options',
                  subtitle: _optionsSummary(),
                  onTap: () => setState(() => _options = true),
                ),
            ],
            _NavRow(
              key: const Key('layers-filter'),
              title: 'Filter pings and cells',
              trailing: model.filter.activeCount == 0 ? null : '${model.filter.activeCount} active',
              onTap: () => showMapFilterSheet(context, model),
            ),
            const _SectionLabel(''),
            _NavRow(
              key: const Key('layers-credits'),
              title: 'Map credits and sources',
              onTap: () => showMapCredits(
                context,
                style: model.baseStyle,
                meshCoreCredit: st.isOn(kNetworkLayerId) ? model.repeaterFeed.global.attribution : null,
                openLegend: () => showMapLegend(context, pingColors: model.pingColors),
              ),
            ),
            _NavRow(
              key: const Key('layers-legend'),
              title: 'What do the symbols mean?',
              symbol: AppSymbols.infoCircle,
              onTap: () => showMapLegend(context, pingColors: model.pingColors),
            ),
            _NavRow(key: const Key('layers-reset'), title: 'Reset layers', destructive: true, chevron: false, onTap: () => _confirmReset(context)),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
              child: Text(
                'The base map, filter and timeline position are not layers: Reset leaves them alone.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showAppActionSheet<bool>(
      context,
      title: 'Reset layers?',
      message: 'Layers, ping colours and the coverage options go back to the defaults.',
      sheetKey: const Key('layers-reset-sheet'),
      actions: const [AppAction('Reset layers', true, destructive: true, key: Key('layers-reset-confirm'))],
    );
    if (ok == true) model.resetLayers();
  }

  List<Widget> _layer(BuildContext context, MapLayerSpec spec, MapLayerState st, {bool sub = false}) {
    final t = Theme.of(context);
    final p = layerPresentation(context, spec, regionName: model.state.viewingRegion?.name, hasPosition: model.position != null);
    // The Repeaters row is the roster and the all-MeshCore layers together: its status is the scope's.
    final isRepeaters = spec.id == kRosterLayerId;
    final on = isRepeaters ? repeatersOn(st) : st.isOn(spec.id);
    final statusId = isRepeaters && model.repeatersAll ? kNetworkLayerId : spec.id;
    final status = model.statusOf(statusId);
    // A sub-switch (Ping dots, Names) works only while its parent is on.
    final parentOff = sub && !(spec.id == kLabelsLayerId ? repeatersOn(st) : st.isOn('hexes'));
    final unsupported = status.availability == LayerAvailability.unsupported;
    // Drive layers draw what this phone recorded: no status line. Server-fed layers always say where they stand.
    final detail = spec.serverFed ? status.detail : null;
    final tile = AppSwitchTile(
      title: p.title,
      subtitle: p.description,
      switchKey: layerSwitchKey(spec.id),
      // A default-on layer the server does not offer shows off and disabled (it cannot draw anything). Otherwise
      // unsupported/empty layers cannot be switched on, and a layer that is on can always be switched off.
      // The Repeaters switch shows what the person chose: a scope the server lacks says so on the status line, and the switch
      // can still be turned off.
      value: on && (isRepeaters || !unsupported),
      onChanged: parentOff || (unsupported && !(isRepeaters && on)) ? null : ((on || status.enabled) ? (v) => model.setLayer(spec.id, v) : null),
    );
    return [
      if (sub) Padding(padding: const EdgeInsets.only(left: Gap.l), child: tile) else tile,
      if (detail != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  detail,
                  key: Key('layer-${spec.id}-status'),
                  style: t.textTheme.bodySmall?.copyWith(
                    color: status.availability == LayerAvailability.failed ? t.colorScheme.error : t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (status.canRetry)
                CupertinoButton(
                  key: Key('layer-${spec.id}-retry'),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                  minimumSize: const Size(Hit.min, Hit.min),
                  onPressed: () => model.retry(statusId),
                  child: const Text('Retry'),
                ),
            ],
          ),
        ),
      if (spec.id == 'pings') _PingModeRow(model: model),
      if (isRepeaters) _RepeaterScopeRow(model: model),
      if (on && !unsupported) _InlineKey(layerId: isRepeaters && model.repeatersAll ? kNetworkLayerId : spec.id, model: model),
    ];
  }

  String _optionsSummary() {
    final q = model.coverageQuery;
    final when = q.until == null ? 'Live' : 'As of ${q.until!.toLocal().year}-${q.until!.toLocal().month.toString().padLeft(2, '0')}-${q.until!.toLocal().day.toString().padLeft(2, '0')}';
    return 'Window ${q.since.label}  ·  Source ${q.source.label}  ·  $when';
  }

  // ------------------------------------------------------------------ the network coverage options page

  List<Widget> _optionsPage(BuildContext context) => [
    _Header(
      title: 'Coverage options',
      leading: _TextAction(key: const Key('layers-options-back'), label: 'Layers', onTap: () => setState(() => _options = false), back: true),
      trailing: _TextAction(key: const Key('layers-done'), label: 'Done', onTap: widget.onDone),
    ),
    Flexible(
      child: ListView(
        key: const Key('layers-options-page'),
        controller: widget.scroll,
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, MediaQuery.viewPaddingOf(context).bottom + Gap.m),
        children: [CoverageOptionsBody(model: model)],
      ),
    ),
  ];
}

// ====================================================================================================== pieces

class _Header extends StatelessWidget {
  final String title;
  final Widget? leading, trailing;
  const _Header({required this.title, this.leading, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          SizedBox(width: 96, child: Align(alignment: Alignment.centerLeft, child: leading)),
          Expanded(child: Semantics(header: true, child: Text(title, style: t.textTheme.titleMedium, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis))),
          SizedBox(width: 96, child: Align(alignment: Alignment.centerRight, child: trailing)),
        ],
      ),
    );
  }
}

class _TextAction extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool back;
  const _TextAction({super.key, required this.label, required this.onTap, this.back = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: Gap.m),
      minimumSize: const Size(Hit.min, Hit.min),
      onPressed: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (back) AppSymbolIcon(AppSymbols.chevronLeft, size: 16, color: t.colorScheme.primary),
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.primary))),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.xs),
      child: Semantics(
        header: text.isNotEmpty,
        child: Text(text.toUpperCase(), style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant, letterSpacing: 0.6)),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  final String title;
  final String? subtitle, trailing;
  final AppSymbol? symbol;
  final bool destructive, chevron;
  final VoidCallback onTap;
  const _NavRow({super.key, required this.title, this.subtitle, this.trailing, this.symbol, this.destructive = false, this.chevron = true, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ink = destructive ? t.colorScheme.error : null;
    return Semantics(
      button: true,
      label: [title, ?subtitle, ?trailing].join('. '),
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
              child: Row(
                children: [
                  if (symbol != null) ...[AppSymbolIcon(symbol!, size: 20, color: t.colorScheme.primary), const SizedBox(width: Gap.m)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: t.textTheme.bodyLarge?.copyWith(color: ink)),
                        if (subtitle != null) Text(subtitle!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  if (trailing != null) Text(trailing!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  if (chevron) ...[const SizedBox(width: Gap.xs), AppSymbolIcon(AppSymbols.chevronRight, size: 16, color: t.colorScheme.onSurfaceVariant)],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The four base maps as 72 x 72 tiles (replaces the cycling button and its toast, U10).
class _BaseMapPicker extends StatelessWidget {
  final DriveMapModel model;
  const _BaseMapPicker({required this.model});

  static Color _tint(BaseMapStyle s, Brightness b) => switch (s) {
    BaseMapStyle.chart => b == Brightness.dark ? const Color(0xFF2B2F36) : MapTokens.landLight,
    BaseMapStyle.street => const Color(0xFFF2EFE9),
    BaseMapStyle.dark => const Color(0xFF1B1F24),
    BaseMapStyle.topo => const Color(0xFFD7E6C6),
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sel = model.baseStyle;
    return Padding(
      key: const Key('layers-base-map'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.l),
      child: Wrap(
        spacing: Gap.m,
        runSpacing: Gap.s,
        children: [
          for (final s in BaseMapStyle.values)
            Semantics(
              button: true,
              selected: s == sel,
              label: '${s.label} base map. ${s.blurb}',
              child: ExcludeSemantics(
                child: GestureDetector(
                  key: Key('base-map-${s.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => model.setBaseStyle(s),
                  child: SizedBox(
                    width: 72,
                    child: Column(
                      children: [
                        Container(
                          width: 72,
                          height: 56,
                          decoration: BoxDecoration(
                            color: _tint(s, t.brightness),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: s == sel ? t.colorScheme.primary : t.colorScheme.outlineVariant, width: s == sel ? 3 : 1),
                          ),
                          child: Center(
                            child: s == sel
                                ? AppSymbolIcon(AppSymbols.checkmarkCircleFill, size: 22, color: t.colorScheme.primary)
                                : null,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(s.label, style: t.textTheme.labelMedium, maxLines: 1),
                        if (s == BaseMapStyle.topo) Text('needs signal', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant), maxLines: 1),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// This region | All MeshCore, under the Repeaters row (plan section 5: one switch, a scope).
class _RepeaterScopeRow extends StatelessWidget {
  final DriveMapModel model;
  const _RepeaterScopeRow({required this.model});

  @override
  Widget build(BuildContext context) {
    final on = repeatersOn(model.layerState);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
      child: Opacity(
        opacity: on ? 1 : 0.4,
        child: CupertinoSlidingSegmentedControl<bool>(
          key: const Key('layer-repeaters-scope'),
          groupValue: model.repeatersAll,
          children: const {
            false: Padding(padding: EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6), child: Text('This region', key: Key('layer-scope-region'))),
            true: Padding(padding: EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6), child: Text('All MeshCore', key: Key('layer-scope-all'))),
          },
          onValueChanged: (v) {
            if (v != null) model.repeatersAll = v;
          },
        ),
      ),
    );
  }
}

/// By SNR | Heard, under the Ping dots row (the dots' colours; This drive's cells always use the coverage bands with v2).
class _PingModeRow extends StatelessWidget {
  final DriveMapModel model;
  const _PingModeRow({required this.model});

  @override
  Widget build(BuildContext context) {
    final pingsOn = model.layerState.isOn('pings');
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
      child: IgnorePointer(
        ignoring: !pingsOn,
        child: Opacity(
          opacity: pingsOn ? 1 : 0.4,
          child: CupertinoSlidingSegmentedControl<PingColorMode>(
            groupValue: model.pingColors,
            children: const {
              PingColorMode.snr: Padding(padding: EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6), child: Text('By SNR', key: Key('layer-color-snr'))),
              PingColorMode.result: Padding(padding: EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6), child: Text('Heard', key: Key('layer-color-result'))),
            },
            onValueChanged: (v) {
              if (v != null) model.pingColors = v;
            },
          ),
        ),
      ),
    );
  }
}

/// The inline key under a layer's row: swatches from the colour functions the map paints with.
class _InlineKey extends StatelessWidget {
  final String layerId;
  final DriveMapModel model;
  const _InlineKey({required this.layerId, required this.model});

  @override
  Widget build(BuildContext context) {
    final items = layerKeyItems(context, layerId, model);
    if (items.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    final style = t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Padding(
      key: Key('layer-$layerId-key'),
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
      child: Wrap(
        spacing: Gap.m,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final i in items)
            Row(mainAxisSize: MainAxisSize.min, children: [i.swatch, const SizedBox(width: 4), Text(i.label, style: style)]),
        ],
      ),
    );
  }
}

/// One swatch and its words in an inline key.
class KeyItem {
  final Widget swatch;
  final String label;
  const KeyItem(this.swatch, this.label);
}

/// The inline key of layer [layerId] right now (empty when the layer has none). Public so tests and the guide can read the same
/// rows the sheet shows.
List<KeyItem> layerKeyItems(BuildContext context, String layerId, DriveMapModel model) {
  final mc = MeshSonarColors.of(context);
  Widget dot(Color c) => LegendSwatch(color: c, shape: SwatchShape.dot, size: 16);
  Widget hex(Color c, {bool none = false}) => LegendSwatch(color: c, size: 18, silentCell: none);
  switch (layerId) {
    case 'pings':
      return model.pingColors == PingColorMode.result
          ? [KeyItem(dot(mc.snrStrong), 'heard'), KeyItem(dot(mc.silent), 'not heard')]
          : [
              KeyItem(dot(mc.forPing(heard: true, snr: -10)), 'weak'),
              KeyItem(dot(mc.forPing(heard: true, snr: 0)), 'middling'),
              KeyItem(dot(mc.forPing(heard: true, snr: 10)), 'strong'),
              KeyItem(dot(mc.heardUnknown), 'no reading'),
              KeyItem(dot(mc.silent), 'nothing heard'),
            ];
    case 'hexes':
      if (model.coverageV2) return const [KeyItem(SizedBox.shrink(), 'same colours as Measured coverage, outlined')];
      return model.pingColors == PingColorMode.result
          ? [KeyItem(hex(mc.snrStrong), 'heard'), KeyItem(hex(mc.silent, none: true), 'not heard')]
          : [
              KeyItem(hex(mc.forPing(heard: true, snr: 10)), 'strong'),
              KeyItem(hex(mc.forPing(heard: true, snr: 3)), 'good'),
              KeyItem(hex(mc.forPing(heard: true, snr: -3)), 'fair'),
              KeyItem(hex(mc.forPing(heard: true, snr: -10)), 'weak'),
            ];
    case 'measured':
      if (model.coverageV2) return coverageBandKey(context, model.state.coverageMeta);
      return [
        for (final (level, text) in coverageLegend())
          KeyItem(hex(networkLevelColor(context, level), none: level == CoverageLevel.none), text),
      ];
    case 'predicted':
      if (!model.coverageV2) return const [];
      final c = CoverageBandColors.of(mc.palette, Theme.of(context).brightness);
      return [
        KeyItem(CoverageBandSwatch(band: 4, colors: c, predicted: true, size: 16), 'estimate, same colours'),
        KeyItem(CoverageBandSwatch(band: 0, colors: c, predicted: true, size: 16), 'no coverage'),
      ];
    case kRosterLayerId:
      return repeaterFreshnessKey(context, hours: false);
    case kNetworkLayerId:
      return repeaterFreshnessKey(context, hours: true);
    case 'heard':
      return [KeyItem(ExcludeSemantics(child: Icon(Icons.check_circle, size: 16, color: mc.snrStrong)), 'green tick = heard this drive')];
    default:
      return const [];
  }
}

/// The coverage v2 bands as inline key items (strongest first, then No reply), from [meta]'s labels.
List<KeyItem> coverageBandKey(BuildContext context, CoverageMeta meta) {
  final c = CoverageBandColors.of(MeshSonarColors.of(context).palette, Theme.of(context).brightness);
  return [
    for (final b in const [5, 4, 3, 2, 1, 0]) KeyItem(CoverageBandSwatch(band: b, colors: c, size: 16), meta.labelOf(b).toLowerCase()),
  ];
}

/// The three repeater freshness states (Drive plan 6.3): solid = fresh, tinted ring = recent, hollow dashed = older. The colours are
/// palette-independent (MapTokens) and differ from the signal ramp. [hours] adds the 24 h / 7 d edges.
List<KeyItem> repeaterFreshnessKey(BuildContext context, {required bool hours}) {
  final b = Theme.of(context).brightness;
  Widget badge(Color c, int state) => ExcludeSemantics(
    child: CustomPaint(size: const Size(16, 16), painter: _FreshnessBadge(c, state)),
  );
  return [
    KeyItem(badge(MapTokens.repeaterFresh(b), 0), hours ? 'fresh, 24 h' : 'fresh'),
    KeyItem(badge(MapTokens.repeaterAging(b), 1), hours ? 'recent, 7 d' : 'recent'),
    KeyItem(badge(MapTokens.repeaterStale(b), 2), 'older'),
  ];
}

class _FreshnessBadge extends CustomPainter {
  final Color color;
  final int state;
  _FreshnessBadge(this.color, this.state);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 1.5;
    switch (state) {
      case 0:
        canvas.drawCircle(c, r, Paint()..color = color);
      case 1:
        canvas.drawCircle(c, r, Paint()..color = color.withValues(alpha: 0.35));
        canvas.drawCircle(c, r, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2);
      default:
        final p = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5;
        for (var i = 0; i < 8; i++) {
          canvas.drawArc(Rect.fromCircle(center: c, radius: r), i * 0.785, 0.4, false, p);
        }
    }
  }

  @override
  bool shouldRepaint(_FreshnessBadge o) => o.color != color || o.state != state;
}

/// The global layer's colour key (website advert-age bands, `core/repeater_points.dart` advertAgeBand: inclusive
/// 24 h / 7 d / 30 d edges), the data's own "as of" and its credit line. Kept for the compact map key and the guide until
/// WP7 removes the map key.
class NetworkAgeLegend extends StatelessWidget {
  final MapRepeaterSet set;

  /// One compact row for the map overlay (no as-of / credit lines).
  final bool dense;
  const NetworkAgeLegend({super.key, required this.set, this.dense = false});

  static const List<(CoverageLevel, String)> steps = [
    (CoverageLevel.strong, '24 h'),
    (CoverageLevel.good, '7 d'),
    (CoverageLevel.fair, '30 d'),
    (CoverageLevel.none, 'Older'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final style = (dense ? t.textTheme.labelSmall : t.textTheme.bodySmall)?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final row = Wrap(
      spacing: dense ? 6 : Gap.s,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!dense) Text('Last advert:', style: style),
        for (final (level, label) in steps)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Dot(color: networkLevelColor(context, level), size: dense ? 8 : 10),
              const SizedBox(width: 3),
              Text(label, style: style),
            ],
          ),
        if (!dense) ...[
          Row(mainAxisSize: MainAxisSize.min, children: [_Ring(color: t.colorScheme.onSurfaceVariant), const SizedBox(width: 3), Text('room server', style: style)]),
        ],
      ],
    );
    if (dense) return KeyedSubtree(key: const Key('map-network-legend'), child: row);
    final asOf = set.asOf;
    return Column(
      key: const Key('network-legend'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        // One credit line, not two: the source credit and its age together ("Data: MeshCore Map (...), as of ...").
        if (set.attribution != null)
          Text(asOf != null ? '${set.attribution!}, as of ${_stamp(asOf)}' : set.attribution!,
              key: const Key('network-legend-attribution'), style: style)
        else if (asOf != null)
          Text('MeshCore Map data as of ${_stamp(asOf)}', key: const Key('network-legend-asof'), style: style),
      ],
    );
  }

  static String _stamp(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

/// The region roster layer's colour key (roster status, same colours the old pin layer used).
class RosterStatusLegend extends StatelessWidget {
  const RosterStatusLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final style = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Wrap(
      key: const Key('roster-legend'),
      spacing: Gap.s,
      runSpacing: 2,
      children: [
        for (final a in RepeaterActivity.values)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [_Dot(color: regionRepeaterColor(a, Theme.of(context).brightness), size: 10), const SizedBox(width: 3), Text(rosterStatusText(a), style: style)],
          ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final double size;
  const _Dot({required this.color, required this.size});
  @override
  Widget build(BuildContext context) => Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

class _Ring extends StatelessWidget {
  final Color color;
  const _Ring({required this.color});
  @override
  Widget build(BuildContext context) =>
      Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)));
}
