// The ONE Layers sheet (build 74, MAP slice 4): any map opens it with a [MapLayersModel] (layers_model.dart: the Drive map's
// DriveMapModel, the Plan map's PageLayersModel). Build 77 (Round 1 N1) order, in plain words: Map style (real thumbnails),
// Signal coverage (Measured first, Redundancy under Advanced), My drive, Repeaters (one switch with This region / Everywhere,
// then names, estimated positions, lines and link quality), People and listeners, Appearance (sizes, colour by, palette, region
// outline), Filters (the Drive map's, with a count), More (credits, guide, Reset), and last ONE "Not on this map" line that
// opens to the layers this map cannot draw, each with its reason (never hidden). Section names and hints come from the
// definition's `sections` (schemaMinor 10) when it has them. A layer's hint stays visible on or off.
//
// The website's Layers panel (plan unified-map-system §2.4-2.5, phase M2), generated from the Map
// Definition (registry.dart [sheetRows]): Basemap, then the definition's groups (Coverage, Network, Context) with its layers,
// names and hints (top of the map first: Measured, Heard by phones, Predicted; Moving phones, Observers, Repeaters, All MeshCore
// repeaters, Link lines; Region borders), Filters ("Measured in" / "Drives from" from `filters`, plus the app's growth
// timeline), Palette (Standard / Colour-blind safe from `palettes`), then credits, the guide and Reset. The app's drive panel
// adds This drive (the definition's panel-only `drive` layer) with Ping dots, and Names under Repeaters. Each row keeps its
// honest status line from [DriveMapModel.statusOf] and its inline key (drawn with the colour functions the map paints with).
//
// Non-modal (the map stays live above it, every toggle applies instantly): [showGeneratedLayersSheet] opens it in the Drive tab's
// map's transient panel slot when given one (MapPanel `drive.layers`), else as a non-modal app sheet with detents [0.4, 0.75].
//
// Keys: 'layers-sheet', 'layers-done', 'layers-base-map', 'base-map-<id>', 'layers-group-<groupId>' (+ 'layers-group-filters',
// 'layers-group-palette', 'layers-group-labels', 'layers-group-activity', 'layers-group-mine'), the switch per layer from [layerSwitchKey], 'layer-<id>-status', 'layer-<id>-retry', 'layer-<id>-key',
// 'layer-color-snr', 'layer-color-result', 'layers-palette-<paletteId>', 'layers-filter', 'layers-credits', 'layers-legend',
// 'layers-reset', 'network-legend'.
import '../../../core/time_format.dart' as tf;
import 'package:flutter/cupertino.dart' show CupertinoButton, CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';

import '../../../core/map_styles.dart';
import '../../../core/network_coverage.dart' show CoverageLevel;
import '../../design/anchored_sheet.dart';
import '../../design/map_panel.dart';
import '../../design/app_surfaces.dart';
import '../../design/app_symbols.dart';
import '../../design/app_widgets.dart' show AppSwitchTile;
import '../../design/tokens.dart' show Hit;
import '../../drive/drive_map_model.dart';
import '../../../core/coverage_query.dart' show CoverageSince, CoverageSource;
import 'layers_model.dart';
import '../../theme.dart';
import '../../../core/coverage_v2.dart' show CoverageMeta;
import '../coverage_bands.dart';
import '../coverage_layer_controls.dart';
import '../coverage_map.dart' show networkLevelColor;
import '../sheets/coverage_cell_sheet.dart' show CoverageBandSwatch;
import '../legend_sheet.dart' show LegendSwatch, SwatchShape, showMapLegend;
import '../legend_card.dart' show PaletteSwitch, RepeaterRingKey;
import '../active_map_definition.dart';
import '../map_size_controls.dart';
import '../legend_card.dart' show legendEntryKey;
import '../../../core/map_basemaps.dart' show MapBasemaps;
import '../map_layers.dart' show PingColorMode;
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

/// Title and the line under it. Definition layers: the definition's name, and its hint while the layer is off (the website's
/// panel). The app's drive extras keep their own words.
({String title, String? description}) layerPresentation(BuildContext context, MapLayerSpec spec, {String? regionName, bool hasPosition = true, bool on = false}) {
  final defId = definitionLayerId(spec.id);
  final def = ActiveMapDefinition.current;
  final l = defId == null ? null : def.layerDef(defId);
  final own = switch (spec.id) {
    'pings' => 'Each ping you sent.',
    'hexes' => 'Your pings this session, in the same cells and colours.',
    'heard' => 'Repeaters your pings reached (highlighted).',
    kLabelsLayerId => 'Name beside each repeater, from street zoom; fewer when crowded.',
    kFriendsLayerId => 'Friends sharing their position in your MeshTrack groups, and the meet-up point.',
    _ => null,
  };
  // Build 77 (Round 1 N1): the hint stays visible with the layer on, so the person keeps the explanation of what they see.
  return (title: layerLabel(spec.id, def), description: l == null ? own : l.hint);
}

/// Opens the layers for [model]. On a map with a transient panel slot ([host], the Drive map's) they are the non-modal
/// MapPanel `drive.layers` above the persistent panel, so the map is visible while layers are switched and the coverage
/// timeline is scrubbed; otherwise a non-modal app sheet. The map behind stays interactive either way.
Future<void> showGeneratedLayersSheet(BuildContext context, MapLayersModel model, {MapPanelHostController? host}) {
  if (host != null) {
    if (host.currentId == kLayersPanelId) {
      host.close(kLayersPanelId);
      return Future.value();
    }
    host.show(
      id: kLayersPanelId,
      builder: (ctx) => MapPanel(
        id: kLayersPanelId,
        title: 'Layers',
        leading: const Icon(Icons.layers_outlined, size: 18),
        bottomSafe: false,
        onClose: () => host.close(kLayersPanelId),
        closeKey: const Key('layers-done'),
        child: MapLayersSheet(model: model, inPanel: true),
      ),
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

/// The transient panel id of the layers on a map.
const String kLayersPanelId = 'drive.layers';

class MapLayersSheet extends StatefulWidget {
  final MapLayersModel model;

  /// The sheet's scroll controller (hands a drag on the list to the sheet); null inside a MapPanel.
  final ScrollController? scroll;
  final VoidCallback? onDone;

  /// Inside a MapPanel: the panel's header is the title and the close button, so the sheet's own header row is left out.
  final bool inPanel;
  const MapLayersSheet({super.key, required this.model, this.scroll, this.onDone, this.inPanel = false});

  @override
  State<MapLayersSheet> createState() => _MapLayersSheetState();
}

class _MapLayersSheetState extends State<MapLayersSheet> {
  MapLayersModel get model => widget.model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([model, model.repeaterSource]),
      builder: (context, _) => Column(
        key: const Key('layers-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _mainPage(context),
      ),
    );
  }

  // ------------------------------------------------------------------ the main page

  /// Every switch row the definition offers this app (flattened), and the rows it lists that the app cannot draw.
  List<SheetRow> _allRows() => [for (final (_, rows) in sheetRows()) ...rows];

  /// The Layers sheet in plain words (build 77, Round 1 N1): Map style / Signal coverage (Measured first) / My drive / Repeaters
  /// (one switch, "This region / Everywhere") / People and listeners / Appearance / Filters, then More. Hints stay visible with
  /// the layer on or off, and what this map cannot draw is one "Not on this map" line at the bottom. No function is removed.
  List<Widget> _mainPage(BuildContext context) {
    final st = model.layerState;
    final m = model;
    final drive = m is DriveMapModel ? m : null;
    final q = model.coverageQuery;
    final filterCount = model.filter.activeCount + (q.since != CoverageSince.all ? 1 : 0) + (q.source != CoverageSource.all ? 1 : 0) + (q.until != null ? 1 : 0);
    final def = ActiveMapDefinition.current;
    final sec = {for (final x in def.layerSections) x.id: x};
    String title(String id, String fallback) => sec[id]?.name ?? fallback;
    String? hint(String id, String? fallback) => sec[id]?.hint ?? fallback;

    final rows = _allRows();
    final ids = {for (final r in rows) r.id};
    bool cannotDraw(String id) => model.statusOf(id).availability == LayerAvailability.unsupported;
    final notHere = <String>[for (final r in rows) if (cannotDraw(r.id) && r.parent == null) r.id];
    final inactive = inactiveRows();
    List<Widget> rowsOf(List<String> order, {Set<String> sub = const {}}) => [
      for (final id in order)
        if (ids.contains(id) && !notHere.contains(id)) ..._layer(context, layerSpec(id)!, st, sub: sub.contains(id)),
    ];
    Widget section(String id, String fallback, {String? hintFallback}) => _SectionLabel(title(id, fallback), key: Key('layers-group-$id'), hint: hint(id, hintFallback));

    final coverage = rowsOf(['measured', 'predicted', kHeardCellsLayerId]);
    final backup = rowsOf(['redundancy']);
    final mine = rowsOf(['hexes', 'pings', 'heard', kPlanLayerId], sub: {'pings'});
    final repeaterRows = _repeaterRows(context, st, ids, notHere, drive);
    final people = rowsOf([kFriendsLayerId, 'observers', 'phones']);
    final appearance = rowsOf(['borders']);
    return [
      if (!widget.inPanel) _Header(title: 'Layers', trailing: _TextAction(key: const Key('layers-done'), label: 'Done', onTap: widget.onDone)),
      Flexible(
        child: ListView(
          controller: widget.scroll,
          shrinkWrap: true,
          padding: EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(context).bottom + Gap.m),
          children: [
            _SectionLabel(title('style', 'Map style'), key: const Key('layers-group-base')),
            _BaseMapPicker(model: model),
            if (coverage.isNotEmpty || backup.isNotEmpty) ...[
              section('coverage', 'Signal coverage', hintFallback: 'Where a radio can reach a repeater.'),
              ...coverage,
              if (backup.isNotEmpty) ...[const _SubLabel('Advanced', key: Key('layers-coverage-advanced')), ...backup],
            ],
            if (mine.isNotEmpty) ...[section('drive', 'My drive', hintFallback: 'What you measured yourself.'), ...mine],
            if (repeaterRows.isNotEmpty) ...[section('repeaters', 'Repeaters', hintFallback: 'The radios that pass messages on.'), ...repeaterRows],
            if (people.isNotEmpty) ...[section('people', 'People and listeners', hintFallback: 'Listening stations, phones and your friends.'), ...people],
            section('appearance', 'Appearance', hintFallback: 'Sizes, colours and outlines.'),
            ...appearance,
            const MapSizeControls(),
            const ColourByControl(),
            const Padding(
              padding: EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
              child: Align(alignment: Alignment.centerLeft, child: PaletteSwitch(keyPrefix: 'layers-palette')),
            ),
            if (drive != null) ...[
              _SectionLabel(filterCount == 0 ? title('filters', 'Filters') : '${title('filters', 'Filters')} · $filterCount', key: const Key('layers-group-filters'), hint: hint('filters', 'Show only part of the data.')),
              Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.l), child: CoverageOptionsBody(model: drive)),
              _NavRow(
                key: const Key('layers-filter'),
                title: 'Filter pings and cells',
                trailing: model.filter.activeCount == 0 ? null : '${model.filter.activeCount} active',
                onTap: () => showMapFilterSheet(context, drive),
              ),
            ],
            const _SectionLabel('More'),
            _NavRow(
              key: const Key('layers-credits'),
              title: 'Map credits',
              onTap: () => showMapCredits(
                context,
                style: model.baseStyle,
                meshCoreCredit: st.isOn(kNetworkLayerId) ? model.repeaterFeed.global.attribution : null,
                openLegend: () => showMapLegend(context, pingColors: model.pingColors),
              ),
            ),
            _NavRow(
              key: const Key('layers-legend'),
              title: 'Map guide',
              symbol: AppSymbols.infoCircle,
              onTap: () => showMapLegend(context, pingColors: model.pingColors),
            ),
            // What Reset leaves alone is said where it matters, in its confirmation (build 76; it was a footnote here).
            _NavRow(key: const Key('layers-reset'), title: 'Reset layers', destructive: true, chevron: false, onTap: () => _confirmReset(context)),
            // What this map cannot draw: one line at the bottom, open for the reasons (never hidden).
            if (notHere.isNotEmpty || inactive.isNotEmpty)
              _NotOnThisMap(
                count: notHere.length + inactive.length,
                children: [
                  for (final id in notHere) ..._layer(context, layerSpec(id)!, st),
                  for (final r in inactive) _InactiveRow(row: r),
                ],
              ),
          ],
        ),
      ),
    ];
  }

  /// Repeaters: one switch (This region / Everywhere), then its options: names (and all names while driving), estimated
  /// positions, lines when tapped, link quality.
  List<Widget> _repeaterRows(BuildContext context, MapLayerState st, Set<String> ids, List<String> notHere, DriveMapModel? drive) {
    bool has(String id) => ids.contains(id) && !notHere.contains(id);
    final out = <Widget>[];
    final region = has(kRosterLayerId), everywhere = has(kNetworkLayerId);
    if (region) {
      // ONE switch: on draws this region's repeaters (and every MeshCore repeater with Everywhere); off hides them all.
      out.addAll(_layer(context, layerSpec(kRosterLayerId)!, st, value: repeatersOn(st), onSet: (v) {
        model.setLayer(kRosterLayerId, v);
        if (!v && st.isOn(kNetworkLayerId)) model.setLayer(kNetworkLayerId, false);
      }));
      if (everywhere) out.add(_RepeaterScope(model: model));
    } else if (everywhere) {
      out.addAll(_layer(context, layerSpec(kNetworkLayerId)!, st));
    }
    if (has(kLabelsLayerId)) {
      out.addAll(_layer(context, layerSpec(kLabelsLayerId)!, st, sub: true));
      // The Drive map shows fewer names while a drive runs (build 76); this brings every name back.
      if (drive != null) {
        out.add(Padding(
          padding: const EdgeInsets.only(left: Gap.l),
          child: AppSwitchTile(
            title: 'All names while driving',
            subtitle: 'Every repeater name, also during a drive. Off keeps the road readable.',
            switchKey: const Key('layer-all-names-driving'),
            value: drive.allNamesWhileDriving,
            onChanged: repeatersOn(st) && st.isOn(kLabelsLayerId) ? (v) => drive.allNamesWhileDriving = v : null,
          ),
        ));
      }
    }
    for (final id in const ['estimated', 'links', 'snrlinks']) {
      if (has(id)) out.addAll(_layer(context, layerSpec(id)!, st, sub: region || everywhere));
    }
    return out;
  }

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showAppActionSheet<bool>(
      context,
      title: 'Reset layers?',
      message: 'Layers, ping colours and the coverage options go back to the defaults. The base map and your filters stay as they are.',
      sheetKey: const Key('layers-reset-sheet'),
      actions: const [AppAction('Reset layers', true, destructive: true, key: Key('layers-reset-confirm'))],
    );
    if (ok == true) model.resetLayers();
  }

  List<Widget> _layer(BuildContext context, MapLayerSpec spec, MapLayerState st, {bool sub = false, bool? value, ValueChanged<bool>? onSet}) {
    final t = Theme.of(context);
    final on = value ?? st.isOn(spec.id);
    final p = layerPresentation(context, spec, regionName: model.state.viewingRegion?.name, hasPosition: model.position != null, on: on);
    final statusId = spec.id;
    final status = model.statusOf(statusId);
    // A sub-switch (Ping dots, Names) works only while its parent is on.
    final parentOff = spec.id == kLabelsLayerId ? !repeatersOn(st) : sub && !st.isOn('hexes');
    final unsupported = status.availability == LayerAvailability.unsupported;
    // Drive layers draw what this phone recorded: no status line. Server-fed layers always say where they stand.
    // A layer this map cannot draw says why (the Plan map has no drive), and Names says what it waits for.
    final detail = (spec.serverFed || unsupported) ? status.detail : (spec.id == kLabelsLayerId && parentOff ? 'Turn on Repeaters to show names.' : null);
    final tile = AppSwitchTile(
      title: p.title,
      subtitle: p.description,
      switchKey: layerSwitchKey(spec.id),
      // A default-on layer the server does not offer shows off and disabled (it cannot draw anything). Otherwise
      // unsupported/empty layers cannot be switched on, and a layer that is on can always be switched off.
      value: on && !unsupported,
      onChanged: parentOff || unsupported ? null : ((on || status.enabled) ? (onSet ?? (v) => model.setLayer(spec.id, v)) : null),
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
      if (spec.id == 'pings' && !unsupported) _PingModeRow(model: model),
      if (on && !unsupported) _InlineKey(layerId: spec.id, model: model),
    ];
  }

}

// ====================================================================================================== pieces

/// "This region / Everywhere" under the Repeaters switch (Round 1 N1): Everywhere also draws every MeshCore repeater (the
/// `network` layer, about 4 MB the first time). Keys: 'layers-repeater-scope', 'layers-scope-region', 'layers-scope-everywhere'.
class _RepeaterScope extends StatelessWidget {
  final MapLayersModel model;
  const _RepeaterScope({required this.model});

  @override
  Widget build(BuildContext context) {
    final st = model.layerState;
    final on = st.isOn(kRosterLayerId) || st.isOn(kNetworkLayerId);
    final status = model.statusOf(kNetworkLayerId);
    final canEverywhere = st.isOn(kNetworkLayerId) || status.enabled;
    final hint = ActiveMapDefinition.current.layerDef('network')?.hint;
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l * 2, 0, Gap.l, Gap.s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [IgnorePointer(
        ignoring: !on,
        child: Opacity(
          opacity: on ? 1 : 0.4,
          child: Semantics(
            label: 'Which repeaters',
            child: CupertinoSlidingSegmentedControl<bool>(
              key: const Key('layers-repeater-scope'),
              groupValue: st.isOn(kNetworkLayerId),
              children: {
                false: const Padding(padding: EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6), child: Text('This region', key: Key('layers-scope-region'))),
                true: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6),
                  child: Text('Everywhere', key: const Key('layers-scope-everywhere'), style: canEverywhere ? null : TextStyle(color: Theme.of(context).disabledColor)),
                ),
              },
              onValueChanged: (v) {
                if (v == null || (v && !canEverywhere)) return;
                model.setLayer(kNetworkLayerId, v);
              },
            ),
          ),
        ),
      ),
        if (st.isOn(kNetworkLayerId)) _InlineKey(layerId: kNetworkLayerId, model: model),
        // "Everywhere": what it costs, and why it may not be offered (the network layer's own hint and status).
        if (hint != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(hint, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
        if (status.detail != null)
          Text(status.detail!, key: const Key('layer-network-status'), style: t.textTheme.bodySmall?.copyWith(color: status.availability == LayerAvailability.failed ? t.colorScheme.error : t.colorScheme.onSurfaceVariant)),
        if (status.canRetry)
          CupertinoButton(
            key: const Key('layer-network-retry'),
            padding: EdgeInsets.zero,
            minimumSize: const Size(Hit.min, Hit.min),
            onPressed: () => model.retry(kNetworkLayerId),
            child: const Text('Retry'),
          ),
      ]),
    );
  }
}

/// The layers this map cannot draw, as one closed line at the bottom of the sheet; open, each with its reason.
class _NotOnThisMap extends StatefulWidget {
  final int count;
  final List<Widget> children;
  const _NotOnThisMap({required this.count, required this.children});

  @override
  State<_NotOnThisMap> createState() => _NotOnThisMapState();
}

class _NotOnThisMapState extends State<_NotOnThisMap> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      key: const Key('layers-not-here'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NavRow(
          key: const Key('layers-not-here-toggle'),
          title: 'Not on this map',
          trailing: '${widget.count}',
          chevron: false,
          onTap: () => setState(() => _open = !_open),
        ),
        if (_open) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xs),
            child: Text('These layers are drawn on other maps.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
          ...widget.children,
        ],
      ],
    );
  }
}

/// A small heading inside a section ("Advanced").
class _SubLabel extends StatelessWidget {
  final String text;
  const _SubLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
      child: Text(text, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    );
  }
}

/// A layer of the definition the app cannot draw (Live packets, Path): a disabled switch with the reason under it.
class _InactiveRow extends StatelessWidget {
  final InactiveRow row;
  const _InactiveRow({required this.row});

  @override
  Widget build(BuildContext context) => AppSwitchTile(
    title: row.name,
    subtitle: row.reason,
    switchKey: Key('layer-${row.id}'),
    value: false,
    onChanged: null,
  );
}

class _Header extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const _Header({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          const SizedBox(width: 96),
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
  const _TextAction({super.key, required this.label, required this.onTap});

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
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.primary))),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  /// One plain line under the heading (what the section is for).
  final String? hint;
  const _SectionLabel(this.text, {super.key, this.hint});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: text.isNotEmpty,
            child: Text(text.toUpperCase(), style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant, letterSpacing: 0.6)),
          ),
          if (hint != null) Text(hint!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  final String title;
  final String? trailing;
  final AppSymbol? symbol;
  final bool destructive, chevron;
  final VoidCallback onTap;
  const _NavRow({super.key, required this.title, this.trailing, this.symbol, this.destructive = false, this.chevron = true, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ink = destructive ? t.colorScheme.error : null;
    return Semantics(
      button: true,
      label: [title, ?trailing].join('. '),
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

/// The base maps the app offers (Road, Light, Dark; Topo and Satellite when the definition advertises them), each a real thumbnail
/// of the style (build 77, Round 1 N3; assets/map/thumbs), the chosen one outlined in the accent with a tick.
class _BaseMapPicker extends StatelessWidget {
  final MapLayersModel model;
  const _BaseMapPicker({required this.model});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sel = model.baseStyle;
    final satNote = sel == BaseMapStyle.satellite ? ActiveMapDefinition.current.satellite?.coverageNote : null;
    return Padding(
      key: const Key('layers-base-map'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.l),
      // One row: up to five tiles share the row's width (bigger targets on a bigger phone); on a phone too narrow for five at
      // 60 pt (an iPhone SE) the row scrolls sideways.
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [LayoutBuilder(builder: (context, box) {
        final n = model.availableBaseStyles.length;
        final share = box.maxWidth.isFinite ? (box.maxWidth - (n - 1) * Gap.s) / n : 0.0;
        final w = n <= 5 && share >= 60 ? share.clamp(60.0, 120.0) : 72.0;
        return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: Gap.s,
        children: [
          for (final s in model.availableBaseStyles)
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
                    width: w,
                    child: Column(
                      children: [
                        Container(
                          width: w,
                          height: 56,
                          foregroundDecoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: s == sel ? t.colorScheme.primary : t.colorScheme.outlineVariant, width: s == sel ? 3 : 1),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.asset(
                                  s.thumbnailAsset(appDark: t.brightness == Brightness.dark),
                                  key: Key('base-map-thumb-${s.id}'),
                                  fit: BoxFit.cover,
                                  excludeFromSemantics: true,
                                  errorBuilder: (_, _, _) => ColoredBox(color: t.colorScheme.surfaceContainerHighest),
                                ),
                                if (s == sel)
                                  Center(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(color: t.colorScheme.surface, shape: BoxShape.circle),
                                      child: AppSymbolIcon(AppSymbols.checkmarkCircleFill, size: 22, color: t.colorScheme.primary),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        // The chosen map's name is bold in the accent colour, so the choice reads without the tick too.
                        Text(s.label, style: t.textTheme.labelMedium?.copyWith(fontWeight: s == sel ? FontWeight.w700 : null, color: s == sel ? t.colorScheme.primary : null), maxLines: 1),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ));
      }),
      if (satNote != null) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text(satNote, key: const Key('layers-base-map-note'), style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
      ]),
    );
  }
}

/// Signal strength | Reached or not (build 77 plain words; it was By SNR | Heard), under the Ping dots row (the dots' colours; This drive's cells always use the coverage bands with v2).
class _PingModeRow extends StatelessWidget {
  final MapLayersModel model;
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
              PingColorMode.snr: Padding(padding: EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6), child: Text('Signal strength', key: Key('layer-color-snr'))),
              PingColorMode.result: Padding(padding: EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6), child: Text('Reached or not', key: Key('layer-color-result'))),
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
  final MapLayersModel model;
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
            Row(mainAxisSize: MainAxisSize.min, children: [i.swatch, const SizedBox(width: 4), Flexible(child: Text(i.label, style: style))]), // long definition labels wrap
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
List<KeyItem> layerKeyItems(BuildContext context, String layerId, MapLayersModel model) {
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
    case 'redundancy':
    case 'snrlinks':
    case 'estimated':
      return definitionKeyItems(context, layerId);
    default:
      return const [];
  }
}

/// The inline key of an M3 layer straight from the definition's `legend` (the website draws the same entries): labels and colours
/// are the definition's, nothing is written here.
List<KeyItem> definitionKeyItems(BuildContext context, String appLayerId) {
  final def = ActiveMapDefinition.current;
  final defId = definitionLayerId(appLayerId);
  final layer = defId == null ? null : def.layerDef(defId);
  if (layer == null) return const [];
  final mc = MeshSonarColors.of(context);
  final bands = CoverageBandColors.of(mc.palette, Theme.of(context).brightness, definition: def);
  final labels = def.bandLabels;
  return [
    for (final e in layer.legend)
      if (e.kind == 'bands')
        for (var b = e.from ?? 5; (e.from ?? 5) >= (e.to ?? 1) ? b >= (e.to ?? 1) : b <= (e.to ?? 1); b += (e.from ?? 5) >= (e.to ?? 1) ? -1 : 1)
          KeyItem(CoverageBandSwatch(band: b, colors: bands, size: 16), (labels[b] ?? 'Band $b').toLowerCase())
      else
        KeyItem(legendEntryKey(context, e, def), e.label ?? ''),
  ];
}

/// The coverage v2 bands as inline key items (strongest first, then No reply), from [meta]'s labels.
List<KeyItem> coverageBandKey(BuildContext context, CoverageMeta meta) {
  final c = CoverageBandColors.of(MeshSonarColors.of(context).palette, Theme.of(context).brightness);
  return [
    for (final b in const [5, 4, 3, 2, 1, 0]) KeyItem(CoverageBandSwatch(band: b, colors: c, size: 16), meta.labelOf(b).toLowerCase()),
  ];
}

/// The three repeater states as the map draws them (the Map Definition's `symbols.repeater`: the neutral tower with a solid ring,
/// a dashed ring, or no ring and faded). [hours] adds the 24 h / 7 d edges.
List<KeyItem> repeaterFreshnessKey(BuildContext context, {required bool hours}) => [
  KeyItem(const RepeaterRingKey(state: 'fresh'), hours ? 'heard in 24 h (solid ring)' : 'fresh'),
  KeyItem(const RepeaterRingKey(state: 'recent'), hours ? 'heard in 7 d (dashed ring)' : 'recent'),
  KeyItem(const RepeaterRingKey(state: 'stale'), 'older (faded)'),
];

/// The repeater layer's key in the Credits sheet's map key and the guide: the SAME three freshness badges and colours the
/// repeater markers are painted with (repeater_sprites.dart freshnessOfAge: <= 24 h fresh, <= 7 d recent, older), never the
/// signal colours (audit 03 §4.1 item 12: this key used green/yellow/grey steps while the markers are blue/amber/grey), plus
/// the data's own "as of" and its credit line.
class NetworkAgeLegend extends StatelessWidget {
  final MapRepeaterSet set;

  /// One compact row for the map overlay (no as-of / credit lines).
  final bool dense;
  const NetworkAgeLegend({super.key, required this.set, this.dense = false});

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
        for (final item in repeaterFreshnessKey(context, hours: true))
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: dense ? 10 : 14, height: dense ? 10 : 14, child: FittedBox(child: item.swatch)),
              const SizedBox(width: 3),
              Text(item.label, style: style),
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
    return tf.shortDateTime(t);
  }
}

class _Ring extends StatelessWidget {
  final Color color;
  const _Ring({required this.color});
  @override
  Widget build(BuildContext context) =>
      Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)));
}
