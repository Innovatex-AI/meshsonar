// The planner's bottom sheet (release 0.38, plan §4.1): Dock / Medium / Full detents, bottom anchored, the map above it
// always usable. A NEW widget (the Drive panel's physics and dock are not reused or edited: their dock is speed-driven and
// has no Full detent). Built on design/sheet_detents.dart: Full is [kFormSheetFull], and at large Dynamic Type
// ([kFormSheetFullHeightScale] and up) the Medium detent is skipped, so the sheet never shows two lines of content.
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
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
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

  /// Height of the mode bar: four equal segments (symbol over up to two lines of label), or one row of chips at large text.
  static double modeBarHeight(BuildContext context) {
    final s = textScale(context);
    return compactModes(context) ? math.max(48.0, 20 * s + 20) + 8 : 20 * s + 4 + 2 * 16 * s + 16;
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

String detentWords(PlannerDetent d) => switch (d) {
      PlannerDetent.dock => 'collapsed',
      PlannerDetent.medium => 'half height',
      PlannerDetent.full => 'full height',
    };

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

  void _go(PlannerDetent d) {
    if (d != _current) unawaited(AppHaptics.selection());
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
    final handle = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => setState(() => _drag = target),
      onVerticalDragUpdate: (d) => setState(() => _drag = ((_drag ?? target) - d.delta.dy).clamp(dock, _h(PlannerDetent.full)).toDouble()),
      onVerticalDragEnd: _end,
      onVerticalDragCancel: () => setState(() => _drag = null),
      child: Semantics(
        key: const Key('planner-sheet-handle'),
        button: true,
        label: 'Plan sheet, ${detentWords(current)}',
        hint: i < ds.length - 1 ? 'Double-tap to make it taller' : 'Double-tap to make it smaller',
        onTap: () => _go(i < ds.length - 1 ? ds[i + 1] : ds[math.max(0, i - 1)]),
        onIncrease: i < ds.length - 1 ? () => _step(1) : null,
        onDecrease: i > 0 ? () => _step(-1) : null,
        child: SizedBox(
          height: 22,
          child: Center(
            child: Container(width: 40, height: 5, decoration: BoxDecoration(color: t.colorScheme.outline, borderRadius: BorderRadius.circular(3))),
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
              if (showBody)
                Expanded(
                  // Not lazy: a plan holds at most 30 nodes, and every row must be reachable by VoiceOver and ensureVisible.
                  child: SingleChildScrollView(
                    key: const Key('planner-sheet-body'),
                    controller: widget.scroll,
                    padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.xs, Layout.screenMargin, Gap.xl),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children),
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
      const PlanRadioChoice('eu', 'MeshCore EU / UK (narrow)', PlanRadio(freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 8)),
    ];

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
    return AppSheetScaffold(
      key: const Key('plan-settings'),
      controller: scroll,
      title: 'Radio and clutter',
      children: [
        Text('These settings belong to this plan. Every link and coverage Estimate uses them.', style: t.textTheme.bodyMedium),
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
        SliderTile(
          key: const ValueKey('plan-radio-sf'),
          sliderKey: const Key('plan-radio-sf-slider'),
          icon: symbolData(context, AppSymbols.waveform),
          title: 'Spreading factor',
          caption: 'Higher reaches farther and takes longer on the air.',
          stops: presetSf,
          value: r.sf,
          label: (v) => 'SF$v',
          onChanged: (v) => controller.setRadio(PlanRadio(freqMHz: r.freqMHz, bwKHz: r.bwKHz, sf: v, cr: r.cr)),
        ),
        const SizedBox(height: Gap.s),
        Text('Bandwidth', style: t.textTheme.titleSmall),
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
        const SizedBox(height: Gap.m),
        Semantics(header: true, child: Text('Clutter (Estimate)', style: t.textTheme.titleSmall)),
        Text('Trees and buildings are not in the terrain data, so the model adds this allowance. Turn it down for open country.', style: t.textTheme.bodySmall),
        SliderTile(
          key: const ValueKey('plan-canopy'),
          sliderKey: const Key('plan-canopy-slider'),
          icon: symbolData(context, AppSymbols.arrowUpCircleFill),
          title: 'Tree canopy height',
          stops: _canopyStops,
          value: p.clutter.canopyM.round(),
          label: (v) => '$v m',
          onChanged: (v) => controller.setClutter(PlanClutter(canopyM: v.toDouble(), dbPerKm: p.clutter.dbPerKm)),
        ),
        SliderTile(
          key: const ValueKey('plan-clutter-loss'),
          sliderKey: const Key('plan-clutter-loss-slider'),
          icon: symbolData(context, AppSymbols.minus),
          title: 'Loss through clutter',
          stops: _lossStops,
          value: (p.clutter.dbPerKm * 10).round(),
          label: (v) => '${(v / 10).toStringAsFixed(1)} dB/km',
          onChanged: (v) => controller.setClutter(PlanClutter(canopyM: p.clutter.canopyM, dbPerKm: v / 10)),
        ),
        const SizedBox(height: Gap.l),
      ],
    );
  }
}
