// The planner's bottom sheet (release 0.38, plan §4.1): Dock / Medium / Full detents, bottom anchored, the map above it
// always usable. A NEW widget (the Drive panel's physics and dock are not reused or edited: their dock is speed-driven and
// has no Full detent). Built on design/sheet_detents.dart: Full is [kFormSheetFull], and at large Dynamic Type
// ([kFormSheetFullHeightScale] and up) the Medium detent is skipped, so the sheet never shows two lines of content.
// Look and words are the shared map panel's (design/map_panel.dart): the same grabber and chevron, a tap on the handle
// toggles Collapsed <-> Open, and the detents are named Collapsed (Dock), Open (Medium) and Full. Id in the map's panel
// group: [kPlannerPanelId]; its state is never saved (it always starts collapsed).
// The handle row is draggable (velocity snaps to the next detent) and, for VoiceOver, a button with increase / decrease
// actions. Reduce Motion: the height changes with a short fade-length step instead of the spring-like curve. On an iPad the
// sheet is the 760 dp reading column, centred.
//
// Also here: the plan's radio and clutter settings sheet ([showPlanSettings]).
//
// Keys: 'planner-sheet', 'planner-sheet-handle', 'planner-sheet-body', 'plan-settings', 'plan-radio-<id>',
// 'plan-radio-sf', 'plan-radio-bw', 'plan-canopy', 'plan-clutter-loss'.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../core/api.dart' show RadioPreset;
import '../../core/plan/plan_controller.dart';
import '../../core/plan/plan_model.dart' show planRadioFor;
import '../../core/plan/presets_calc.dart' show presetBw, presetSf, sensitivityDbm;
import '../../core/plan_contract.dart';
import '../app.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/map_panel.dart';
import '../design/sheet_detents.dart';
import '../design/tokens.dart';
import '../settings/settings_kit.dart' show InfoTile, SliderTile;
import 'plan_modes.dart' show PlanListenable, symbolData;

enum PlannerDetent { dock, medium, full }

/// Fraction of the height the Medium detent takes (the map keeps the larger half).
const double kPlannerMedium = 0.45;

/// The reading column on an iPad (plan §4.5 item 4).
const double kPlannerColumn = 760;

abstract final class PlannerSheetMetrics {
  static double textScale(BuildContext context) => MediaQuery.textScalerOf(context).scale(100) / 100;

  /// The detents this text size uses, lowest first.
  static List<PlannerDetent> detents(BuildContext context) =>
      textScale(context) >= kFormSheetFullHeightScale ? const [PlannerDetent.dock, PlannerDetent.full] : PlannerDetent.values;

  /// Large text: the mode bar becomes one scrolling row of chips (four equal segments would not fit their words).
  static bool compactModes(BuildContext context) => textScale(context) >= kFormSheetFullHeightScale;

  /// Height of the mode bar: four equal segments (symbol over one line of label: build 77, "Where to drive" no longer
  /// wraps and makes the bar taller for all four), or one row of chips at large text.
  static double modeBarHeight(BuildContext context) {
    final s = textScale(context);
    return compactModes(context) ? math.max(48.0, 20 * s + 20) + 8 : 20 * s + 4 + 16 * s + 16;
  }

  /// The handle and the mode bar, sized for the text.
  static double dockHeight(BuildContext context) => 22 + modeBarHeight(context) + 6;

  static double heightOf(PlannerDetent d, double available, BuildContext context) {
    final dock = math.min(dockHeight(context), available);
    final full = math.max(dock, available * kFormSheetFull);
    return switch (resolve(d, context)) {
      PlannerDetent.dock => dock,
      PlannerDetent.medium => (available * kPlannerMedium).clamp(math.min(dock + 160, full), full).toDouble(),
      PlannerDetent.full => full,
    };
  }

  /// [d] on this text size (Medium is Full at large Dynamic Type).
  static PlannerDetent resolve(PlannerDetent d, BuildContext context) => detents(context).contains(d) ? d : PlannerDetent.full;
}

/// The Planner sheet's id in its map's MapPanelGroup.
const String kPlannerPanelId = 'plan.main';

/// The shared state of a detent (design/map_panel.dart).
MapPanelState plannerPanelState(PlannerDetent d) => switch (d) {
      PlannerDetent.dock => MapPanelState.collapsed,
      PlannerDetent.medium => MapPanelState.open,
      PlannerDetent.full => MapPanelState.full,
    };

/// The same state names as every map panel: Collapsed, Open, Full.
String detentWords(PlannerDetent d) => mapPanelStateLabel(plannerPanelState(d));

class PlannerSheet extends StatefulWidget {
  final PlannerDetent detent;
  final ValueChanged<PlannerDetent> onDetent;

  /// The height the sheet lives in (the planner's body height).
  final double availableHeight;

  /// The always-visible row under the handle (the mode chips).
  final Widget dock;

  /// The scrolling content above the dock detent.
  final List<Widget> children;
  final ScrollController? scroll;
  const PlannerSheet({
    super.key,
    required this.detent,
    required this.onDetent,
    required this.availableHeight,
    required this.dock,
    required this.children,
    this.scroll,
  });

  @override
  State<PlannerSheet> createState() => _PlannerSheetState();
}

class _PlannerSheetState extends State<PlannerSheet> {
  double? _drag;

  List<PlannerDetent> get _detents => PlannerSheetMetrics.detents(context);
  PlannerDetent get _current => PlannerSheetMetrics.resolve(widget.detent, context);
  double _h(PlannerDetent d) => PlannerSheetMetrics.heightOf(d, widget.availableHeight, context);

  MapPanelGroup? _group;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final g = MapPanelScope.maybeRead(context);
    if (!identical(g, _group)) {
      _group?.removeListener(_groupChanged);
      _group = g?..addListener(_groupChanged);
      _synced = false;
    }
    if (!_synced) {
      _synced = true;
      _syncGroup();
    }
  }

  bool _synced = false;

  /// Tells the group where the sheet is (after the frame: listeners rebuild). The screen also moves the sheet when the person
  /// picks a mode or a node, so the group follows the detent, not only the handle.
  void _syncGroup() {
    final g = _group;
    if (g == null) return;
    final open = widget.detent != PlannerDetent.dock;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      open ? g.claim(kPlannerPanelId) : g.release(kPlannerPanelId);
    });
  }

  @override
  void didUpdateWidget(PlannerSheet old) {
    super.didUpdateWidget(old);
    if (old.detent != widget.detent) _syncGroup();
  }

  @override
  void dispose() {
    _group?.removeListener(_groupChanged);
    super.dispose();
  }

  /// One open panel per map: the person opened another panel on this map, so the sheet goes back to its header.
  void _groupChanged() {
    final open = _group?.openId;
    if (mounted && open != null && open != kPlannerPanelId && _current != PlannerDetent.dock) widget.onDetent(PlannerDetent.dock);
  }

  void _go(PlannerDetent d) {
    if (d != _current) unawaited(AppHaptics.selection());
    d == PlannerDetent.dock ? _group?.release(kPlannerPanelId) : _group?.claim(kPlannerPanelId);
    widget.onDetent(d);
    SemanticsService.sendAnnouncement(View.of(context), 'Plan sheet ${detentWords(d)}', Directionality.of(context));
  }

  void _step(int by) {
    final ds = _detents;
    final i = (ds.indexOf(_current) + by).clamp(0, ds.length - 1);
    _go(ds[i]);
  }

  void _end(DragEndDetails e) {
    final h = _drag ?? _h(_current);
    setState(() => _drag = null);
    final v = e.primaryVelocity ?? 0;
    final ds = _detents;
    if (v < -700) {
      _go(ds.firstWhere((d) => _h(d) > h + 1, orElse: () => ds.last));
      return;
    }
    if (v > 700) {
      _go(ds.lastWhere((d) => _h(d) < h - 1, orElse: () => ds.first));
      return;
    }
    var best = ds.first;
    for (final d in ds) {
      if ((_h(d) - h).abs() < (_h(best) - h).abs()) best = d;
    }
    _go(best);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final current = _current;
    final target = _h(current);
    final dock = _h(PlannerDetent.dock);
    final height = (_drag ?? target).clamp(dock, _h(PlannerDetent.full)).toDouble();
    final showBody = height > dock + 24;
    final ds = _detents;
    final i = ds.indexOf(current);
    // A tap toggles, as on every map panel: Collapsed opens, anything else collapses.
    void toggle() => _go(current == ds.first ? ds[1 < ds.length ? 1 : 0] : ds.first);
    final handle = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: toggle,
      onVerticalDragStart: (_) => setState(() => _drag = target),
      onVerticalDragUpdate: (d) => setState(() => _drag = ((_drag ?? target) - d.delta.dy).clamp(dock, _h(PlannerDetent.full)).toDouble()),
      onVerticalDragEnd: _end,
      onVerticalDragCancel: () => setState(() => _drag = null),
      child: Semantics(
        key: const Key('planner-sheet-handle'),
        button: true,
        label: 'Plan sheet, ${detentWords(current)}',
        hint: current == ds.first ? 'Double-tap to open' : 'Double-tap to collapse',
        onTap: toggle,
        onIncrease: i < ds.length - 1 ? () => _step(1) : null,
        onDecrease: i > 0 ? () => _step(-1) : null,
        child: SizedBox(
          height: 22,
          width: double.infinity,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const MapPanelGrabber(),
              Positioned(right: 12, top: 0, bottom: 0, child: MapPanelChevron(key: const Key('planner-sheet-chevron'), collapsed: current == ds.first, size: 18)),
            ],
          ),
        ),
      ),
    );
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kPlannerColumn),
        child: AnimatedContainer(
          key: const Key('planner-sheet'),
          duration: _drag != null ? Duration.zero : Motion.of(context, Motion.sheet),
          curve: Motion.reduced(context) ? Curves.linear : Curves.easeOutCubic,
          height: height,
          child: Material(
            elevation: 8,
            color: t.colorScheme.surface,
            surfaceTintColor: Colors.transparent,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              handle,
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: (_) => setState(() => _drag = target),
                onVerticalDragUpdate: (d) => setState(() => _drag = ((_drag ?? target) - d.delta.dy).clamp(dock, _h(PlannerDetent.full)).toDouble()),
                onVerticalDragEnd: _end,
                child: SizedBox(height: math.max(0, dock - 22), child: widget.dock),
              ),
              // Always built (also at the Dock, where it has no height), so a mode keeps its state and result while the
              // sheet is collapsed; hidden from VoiceOver while it cannot be seen.
              Expanded(
                child: ExcludeSemantics(
                  excluding: !showBody,
                  // Not lazy: a plan holds at most 30 nodes, and every row must be reachable by VoiceOver and ensureVisible.
                  child: SingleChildScrollView(
                    key: const Key('planner-sheet-body'),
                    controller: widget.scroll,
                    padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.xs, Layout.screenMargin, Gap.xl),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ radio + clutter

/// A named radio the settings offer.
class PlanRadioChoice {
  final String id, name;
  final PlanRadio radio;
  const PlanRadioChoice(this.id, this.name, this.radio);
}

/// The viewed region's preset first (when it has one), then MeshCore's published US and EU/UK narrow presets.
List<PlanRadioChoice> planRadioChoices(RadioPreset? region) => [
      if (region != null) PlanRadioChoice('region', 'This region: ${region.name}', planRadioFor(region)),
      const PlanRadioChoice('us', 'MeshCore US / Canada', PlanRadio.usDefault),
      const PlanRadioChoice('eu', 'MeshCore EU / UK (narrow)', kPlanRadioEuNarrow),
    ];

/// MeshCore's published EU / UK narrow preset.
const PlanRadio kPlanRadioEuNarrow = PlanRadio(freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 8);

/// The plan's radio in words for the panel's one row (round 4 P-V5): which preset, not its figures. The figures are in
/// Radio and trees.
String radioPresetWords(PlanRadio r, RadioPreset? region) {
  if (r == PlanRadio.usDefault) return 'US / Canada preset';
  if (r == kPlanRadioEuNarrow) return 'EU / UK preset';
  if (region != null && planRadioFor(region) == r) return '${region.name} preset';
  return 'Custom (SF${r.sf}, ${r.bwKHz % 1 == 0 ? r.bwKHz.toStringAsFixed(0) : r.bwKHz} kHz)';
}

String radioWords(PlanRadio r) => '${r.freqMHz.toStringAsFixed(3)} MHz, ${r.bwKHz % 1 == 0 ? r.bwKHz.toStringAsFixed(0) : r.bwKHz} kHz, SF${r.sf}, CR${r.cr}';

const List<int> _canopyStops = [0, 5, 10, 15, 20, 25, 30];

/// Loss per km in tenths of a dB (13.3 dB/km is the calibrated default).
const List<int> _lossStops = [0, 30, 60, 90, 133, 160, 200, 250];

Future<void> showPlanSettings(BuildContext context, PlanController controller, {RadioPreset? regionPreset}) => showAppSheet<void>(
      context,
      detents: formSheetDetents(context),
      builder: (ctx, scroll) => ListenableBuilder(
        listenable: PlanListenable(controller),
        builder: (ctx, _) => _PlanSettings(controller: controller, regionPreset: regionPreset, scroll: scroll),
      ),
    );

class _PlanSettings extends StatelessWidget {
  final PlanController controller;
  final RadioPreset? regionPreset;
  final ScrollController scroll;
  const _PlanSettings({required this.controller, required this.regionPreset, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = controller.plan;
    final r = p.radio;
    final choices = planRadioChoices(regionPreset);
    final units = AppScope.unitsOf(context);
    final sfTile = SliderTile(
      key: const ValueKey('plan-radio-sf'),
      sliderKey: const Key('plan-radio-sf-slider'),
      icon: symbolData(context, AppSymbols.waveform),
      title: 'Spreading factor',
      caption: 'Higher reaches farther and takes longer on the air.',
      stops: presetSf,
      value: r.sf,
      label: (v) => 'SF$v',
      onChanged: (v) => controller.setRadio(PlanRadio(freqMHz: r.freqMHz, bwKHz: r.bwKHz, sf: v, cr: r.cr)),
    );
    final isDefault = p.clutter.canopyM == const PlanClutter().canopyM && p.clutter.dbPerKm == const PlanClutter().dbPerKm;
    return AppSheetScaffold(
      key: const Key('plan-settings'),
      controller: scroll,
      title: 'Radio and trees',
      // Build 76: a full-width Done at the thumb (the sheet could only be dragged away), the two things people know
      // (which radio preset, how tall the trees are) first, and the expert figures under "Fine-tune".
      primaryAction: FilledButton(
        key: const Key('plan-settings-done'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 4)),
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Done'),
      ),
      children: [
        Text('Used for every Estimate in this plan.', style: t.textTheme.bodyMedium),
        const SizedBox(height: Gap.m),
        Semantics(header: true, child: Text('Radio', style: t.textTheme.titleSmall)),
        for (final c in choices)
          RadioListTile<String>(
            key: Key('plan-radio-${c.id}'),
            contentPadding: EdgeInsets.zero,
            value: c.id,
            // ignore: deprecated_member_use
            groupValue: choices.where((x) => x.radio == r).firstOrNull?.id,
            title: Text(c.name),
            subtitle: Text(radioWords(c.radio)),
            // ignore: deprecated_member_use
            onChanged: (_) => controller.setRadio(c.radio),
          ),
        const SizedBox(height: Gap.s),
        Semantics(header: true, child: Text('Trees and buildings (Estimate)', style: t.textTheme.titleSmall)),
        Text('The map data has no trees or buildings. Turn this down for open country.', style: t.textTheme.bodySmall),
        SliderTile(
          key: const ValueKey('plan-canopy'),
          sliderKey: const Key('plan-canopy-slider'),
          icon: symbolData(context, AppSymbols.arrowUpCircleFill),
          title: 'Tree height',
          stops: _canopyStops,
          value: p.clutter.canopyM.round(),
          label: (v) => units.height(v.toDouble()),
          onChanged: (v) => controller.setClutter(PlanClutter(canopyM: v.toDouble(), dbPerKm: p.clutter.dbPerKm)),
        ),
        const SizedBox(height: Gap.s),
        Semantics(header: true, child: Text('Fine-tune', style: t.textTheme.titleSmall)),
        sfTile,
        const SizedBox(height: Gap.s),
        Text('Bandwidth (kHz)', style: t.textTheme.titleSmall),
        const SizedBox(height: Gap.xs),
        SegmentedButton<double>(
          key: const Key('plan-radio-bw'),
          segments: [for (final b in presetBw) ButtonSegment(value: b, label: Text(b % 1 == 0 ? b.toStringAsFixed(0) : '$b'))],
          selected: {presetBw.contains(r.bwKHz) ? r.bwKHz : presetBw.first},
          onSelectionChanged: (v) => controller.setRadio(PlanRadio(freqMHz: r.freqMHz, bwKHz: v.first, sf: r.sf, cr: r.cr)),
        ),
        InfoTile(
          icon: symbolData(context, AppSymbols.antenna),
          title: 'Sensitivity ${sensitivityDbm(r.sf, r.bwKHz).toStringAsFixed(1)} dBm (Estimate)',
          subtitle: radioWords(r),
        ),
        SliderTile(
          key: const ValueKey('plan-clutter-loss'),
          sliderKey: const Key('plan-clutter-loss-slider'),
          icon: symbolData(context, AppSymbols.minus),
          title: 'Loss through trees',
          stops: _lossStops,
          value: (p.clutter.dbPerKm * 10).round(),
          label: (v) => '${(v / 10).toStringAsFixed(1)} dB/km',
          onChanged: (v) => controller.setClutter(PlanClutter(canopyM: p.clutter.canopyM, dbPerKm: v / 10)),
        ),
        // One tap back to the usual values, shown only when they were changed.
        if (!isDefault)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('plan-clutter-reset'),
              style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
              onPressed: () => controller.setClutter(const PlanClutter()),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Back to the usual tree settings'),
            ),
          ),
        const SizedBox(height: Gap.l),
      ],
    );
  }
}
