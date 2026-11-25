// The Drive screen, built for one hand in a moving car: the live coverage map full bleed and never resized, the bottom panel
// (lib/ui/drive/panel/: Dock, Medium, Full and the collapsed pill) on top of it, the shell's tab bar below. The old footer
// layout (map in a box with the controls underneath, its full-screen button and the "No pings yet" hint) was deleted in
// build 70 (item 70-2); this is the only Drive screen.
//
// Battery (build 70, battery plan A1): the screen stays awake per PowerProfile.current.screenOn (always while driving,
// only while the Drive tab is in front, or never).
//
// Only the person moves a panel (build 76): nothing here locks, collapses or clears a panel because the car is moving.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app/app_state.dart';
import '../core/dead_area.dart';
import '../core/power_profile.dart';
import 'app.dart';
import 'design/anchored_sheet.dart';
import 'design/map_panel.dart';
import 'drive/dead_area_chip.dart';
import 'device_feedback.dart';
import 'location_status.dart';
import 'map/region_center.dart';
import 'drive/drive_clock.dart';
import 'drive/drive_controls.dart';
import 'drive/drive_live_stats.dart';
import 'drive/drive_map_model.dart';
import 'map/coverage_map.dart';
import 'map/map_key.dart';
import 'map/legend_card.dart';
import 'map/legend_sheet.dart' show showMapLegend;
import 'map/layers/layers_sheet.dart' show showGeneratedLayersSheet;
import 'map/layers/friends_layer.dart' show friendsLayerWidgets, showMeetHereMenu;
import 'map/map_health_overlay.dart';
import '../platform/compass_sensors_plus.dart';
import 'ping_cue.dart';
import 'map/repeater_page_link.dart';
import 'map/coverage_timeline_slider.dart';
import 'drive/dock_strip.dart';
import 'drive/status_capsule.dart';
import 'drive/panel/drive_panel.dart';
import 'drive/panel/immersive_pill.dart';
import 'drive/panel/drive_panel_controller.dart';
import 'drive/panel/panel_dock.dart';
import 'drive/panel/panel_medium.dart';
import 'drive/panel/panel_meshtrack.dart';
import 'drive/panel/panel_physics.dart';

export 'drive/drive_controls.dart' show openConnect;

class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key});
  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> with TickerProviderStateMixin {
  AppState? _state;
  DeviceFeedback? _feedback;
  DriveMapModel? _model;
  DriveLiveStats? _liveStats;
  ShellController? _shell;

  String? _lastPingId;

  /// The wakelock is held (battery plan A1), and since when (for PowerCounters.screenOnSeconds).
  bool _awake = false;
  DateTime? _awakeSince;

  /// The Drive tab is the visible tab (the shell gives hidden tabs a disabled TickerMode; true in isolated tests).
  bool _visible = true;

  // One open panel on the Drive map (design/map_panel.dart rule 5): the Drive panel (`drive.main`, its own engine) and the
  // one transient slot above it (inspector, layers, legend, a tapped observer).
  final MapPanelGroup _panels = MapPanelGroup();
  final MapPanelHostController _transient = MapPanelHostController();

  // The bottom panel and the settled overlay clearance.
  DrivePanelController? _panel;
  final PingDebounce _debounce = PingDebounce();
  double? _navBar;
  double? _clearance;
  bool _wasDriving = false;
  bool? _remoteWas;

  @override
  void initState() {
    super.initState();
    UiForeground.ensureObserving();
    UiForeground.notifier.addListener(_syncClocks);
    PowerProfile.addListener(_powerChanged);
    _panels.addListener(_panelGroupChanged);
  }

  /// The person opened another panel on this map (the inspector, layers, the legend): the Drive panel goes back to the Dock.
  void _panelGroupChanged() {
    final open = _panels.openId, p = _panel;
    if (open != null && open != kDrivePanelId && p != null && p.detent == PanelDetent.medium) p.settleTo(PanelDetent.dock);
  }

  /// The battery mode changed: the wakelock rule.
  void _powerChanged() {
    if (!mounted) return;
    _syncClocks();
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _feedback = DeviceFeedbackScope.of(context);
    _visible = TickerMode.valuesOf(context).enabled;
    final shell = ShellScope.maybeRead(context);
    if (!identical(shell, _shell)) {
      _shell?.removeListener(_shellChanged);
      _shell = shell;
      shell?.addListener(_shellChanged);
    }
    final s = AppScope.read(context);
    _panel ??= _makePanel();
    _panel!.reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!identical(s, _state)) {
      _state?.removeListener(_onState);
      _model?.dispose();
      _liveStats?.dispose();
      _state = s;
      _model = DriveMapModel(s, compass: CoverageMap.tilesByDefault ? SensorsPlusCompass() : null);
      _liveStats = DriveLiveStats(s);
      s.addListener(_onState);
      _onState();
    }
    _syncClocks();
  }

  void _shellChanged() {
    // Left the tab (or something else brought the tab bar back): the panel cannot stay Immersive without it.
    final p = _panel;
    if (p != null && p.detent == PanelDetent.immersive && _shell != null && !_shell!.immersive) p.settleTo(PanelDetent.dock);
    _syncClocks();
  }

  DrivePanelController _makePanel() {
    // Always starts at the Dock (Andy, Nov 12 2026): the last detent used to be restored, so a panel left at Medium reopened in the
    // middle of the screen on launch and covered the map while the radio was still reconnecting. Nothing but the person's own
    // drag or tap moves the panel; a connect attempt never does.
    final c = DrivePanelController(vsync: this);
    c.onDetentChanged = (from, to) {
      // The tab bar follows the panel: Immersive hides it (250 ms, shell), anything else brings it back.
      _shell?.setImmersive(to == PanelDetent.immersive);
      to == PanelDetent.medium ? _panels.claim(kDrivePanelId) : _panels.release(kDrivePanelId);
      // The map's buttons move to where the panel is GOING, at once (one write per move, never per frame). Waiting for the
      // spring to come to rest left them under the opened panel for more than a second: the panel is visually there in about
      // 0.3 s, but the spring's tail is long, and for that time Layers and Recenter could not be tapped.
      final target = c.geometry?.extentOf(to);
      if (mounted && target != null && _clearance != target) setState(() => _clearance = target);
    };
    c.onSettled = () {
      // Overlay clearances and MapInsets are written once, here, never per animation frame.
      if (!mounted) return;
      final next = c.extent.value;
      if (_clearance != next) setState(() => _clearance = next);
    };
    return c;
  }

  /// The Drive tab is what the person sees: it is the visible tab and the app is in front.
  bool get _onScreen => _visible && (_shell == null || _shell!.tab == AppTab.drive) && UiForeground.value;

  /// Drive started or ended: the radio queue's background refresh follows it.
  void _syncDriving(AppState s) {
    final driving = s.driving;
    if (driving == _wasDriving) return;
    _wasDriving = driving;
    final queue = s.radioSessions.remoteQueue;
    if (driving) {
      // Background repeater refreshes would compete with pings for the radio (Chat WP5 note): off while driving.
      _remoteWas = queue.autoRefreshEnabled;
      queue.autoRefreshEnabled = false;
    } else {
      queue.autoRefreshEnabled = _remoteWas ?? true;
      _remoteWas = null;
    }
  }

  bool? _wasOnScreen;

  /// The wakelock (battery plan A1), and the panel's listenable when the tab comes on or leaves the screen.
  void _syncClocks() {
    if (!mounted) return;
    final on = _onScreen;
    if (_wasOnScreen != null && _wasOnScreen != on && SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      setState(() {}); // the panel's listenable follows [_onScreen]
    }
    _wasOnScreen = on;
    final s = _state;
    final driving = s?.driving ?? false;
    final awake = driving &&
        switch (PowerProfile.current.screenOn) {
          ScreenOnMode.always => true,
          ScreenOnMode.driveTabOnly => _onScreen,
          ScreenOnMode.never => false,
        };
    _setAwake(awake);
  }

  void _setAwake(bool on) {
    if (on == _awake) return;
    _awake = on;
    final now = DateTime.now();
    if (on) {
      _awakeSince = now;
    } else {
      final since = _awakeSince;
      if (since != null) PowerCounters.inc(PowerCounters.screenOnSeconds, now.difference(since).inSeconds);
      _awakeSince = null;
    }
    unawaited(_feedback?.keepAwake(on));
  }

  void _onState() {
    final s = _state;
    if (s == null) return;

    // Feedback on a newly finished ping (not for pings already there when the screen opened).
    final recent = s.recentPings;
    final newest = recent.isEmpty ? null : recent.first;
    if (newest != null && newest.id != _lastPingId) {
      if ((_lastPingId != null || s.driving) && s.driving) {
        unawaited(PingCue.ping(s.settings, _feedback, heard: !newest.heardNothing));
      }
      _lastPingId = newest.id;
    }

    _syncDriving(s);
    _syncClocks();
  }

  @override
  void dispose() {
    UiForeground.notifier.removeListener(_syncClocks);
    PowerProfile.removeListener(_powerChanged);
    final st = _state;
    if (st != null && _remoteWas != null) st.radioSessions.remoteQueue.autoRefreshEnabled = _remoteWas!;
    _panel?.dispose();
    _panels.dispose();
    _transient.dispose();
    _state?.removeListener(_onState);
    _shell?.removeListener(_shellChanged);
    _model?.dispose();
    _liveStats?.dispose();
    if (_awake) {
      final since = _awakeSince;
      if (since != null) PowerCounters.inc(PowerCounters.screenOnSeconds, DateTime.now().difference(since).inSeconds);
      unawaited(_feedback?.keepAwake(false));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final model = _model!;
    final liveStats = _liveStats!;

    // MeshTrack's toasts (asked where you are, radio gone, hour up) are listened to here, once, whatever the panel shows.
    return MeshTrackEvents(
      child: AnimatedBuilder(animation: model, builder: (context, _) => _stage(context, s, model, liveStats)),
    );
  }

  /// The new Drive screen (plan 4.1): the map full bleed and never resized, the panel above it, the shell's tab bar below.
  Widget _stage(BuildContext context, AppState s, DriveMapModel model, DriveLiveStats liveStats) {
    final panel = _panel!;
    final mq = MediaQuery.of(context);
    return MapPanelScope(
      group: _panels,
      child: Scaffold(
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (context, box) {
          // The tab bar zone is measured while the bar is shown and remembered while it is hidden (Immersive).
          if (!(_shell?.immersive ?? false)) _navBar = mq.padding.bottom;
          // iPad / landscape phone (width >= 700): a floating card, never the full-width phone panel (plan 4.21).
          final floating = box.maxWidth >= 700;
          final cardWidth = !floating ? null : (box.maxHeight < 500 ? kCardWidthLandscape : kCardWidthPad);
          final cardLeft = 16 + mq.viewPadding.left;
          final g = PanelGeometry.forScreen(
            screenHeight: box.maxHeight,
            navBar: floating ? 16 + mq.viewPadding.bottom : (_navBar ?? mq.padding.bottom),
            safeBottom: mq.viewPadding.bottom,
            dockRow: DriveDock.isAx(context) ? kPanelDockRowAx : kPanelDockRowHeight,
            floating: floating,
          );
          if (panel.geometry == null) {
            panel.setGeometry(g);
            _clearance = panel.extent.value;
          } else if (panel.geometry != g) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              panel.setGeometry(g);
              // A geometry without an Immersive detent rests the panel on the Dock: the tab bar must be back then.
              if (panel.detent != PanelDetent.immersive && (_shell?.immersive ?? false)) _shell!.setImmersive(false);
            });
          }
          final axText = DriveDock.isAx(context); // read outside the clamp below
          final map = MediaQuery(
            data: mq.copyWith(textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6)),
            child: AnimatedBuilder(
              animation: Listenable.merge([model, s, s.gpsHealth]),
              builder: (context, _) => _MapPane(
                state: s,
                model: model,
                collapseCapsule: axText,
                topClearance: mq.padding.top,
                // The strip is part of the panel surface, so the overlays sit above it too.
                // Floating card: it sits bottom-left, the controls and attribution are bottom-right, so only the margin is cleared.
                bottomClearance: floating
                    ? 16 + mq.viewPadding.bottom
                    : (_clearance ?? panel.extent.value) + (stripFor(s, s.gpsHealth.value) == null ? 0 : kPanelStripHeight),
                rotatable: panel.detent == PanelDetent.immersive,
                panelHost: _transient,
                // Floating card: the transient panel is a card too, stacked on top of the Drive card.
                panelInset: floating ? 16 + mq.viewPadding.bottom + g.dockHeight + 8 + (stripFor(s, s.gpsHealth.value) == null ? 0 : kPanelStripHeight) : null,
              ),
            ),
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: map),
              Positioned.fill(
                child: ListenableBuilder(
                  // The panel shows live numbers (GPS accuracy, countdown): while the tab is on screen it follows every engine
                  // tick (AppState itself notifies at most every 2 s for position-only ticks, battery plan A4).
                  listenable: Listenable.merge([s, s.gpsHealth, panel, liveStats, if (_onScreen) s.driveStatus]),
                  builder: (context, _) {
                    final strip = stripFor(s, s.gpsHealth.value);
                    final idlePill = !s.driving && s.lastFinishedSessionId == null && panel.detent == PanelDetent.immersive && panel.settled;
                    return Stack(fit: StackFit.expand, children: [
                      DrivePanel(
                    hidden: idlePill,
                    cardWidth: cardWidth,
                    cardLeft: cardLeft,
                    strip: strip == null ? null : DockStripView(info: strip),
                    controller: panel,
                    dock: DriveDock(state: s, debounce: _debounce),
                    mediumChildren: MediumContent.build(
                      context,
                      state: s,
                      liveStats: liveStats,
                      fix: model.fix,
                      openGuide: () => showMapLegend(context, pingColors: model.pingColors),
                      nearby: model.position == null ? const [] : nearestRepeaters(model.regionRepeaters, model.position!.latitude, model.position!.longitude),
                      onPickNearby: (key) {
                        model.select(key);
                        panel.settleTo(PanelDetent.dock);
                      },
                    ),
                  ),
                      if (idlePill)
                        Positioned(
                          left: floating ? cardLeft : 0,
                          width: floating ? cardWidth! : box.maxWidth,
                          bottom: (floating ? 16 : 0) + mq.viewPadding.bottom + 8,
                          child: Center(heightFactor: 1, child: ImmersivePill(state: s, controller: panel)),
                        ),
                    ]);
                  },
                ),
              ),
            ],
          );
        },
      ),
      ),
    );
  }

}

/// The map with its overlay slots filled (state chips, status capsule, map health). The map itself mounts the overlay host, the
/// attribution line and the credit sheet. Full bleed: the overlays keep out of the status bar and the panel.
class _MapPane extends StatelessWidget {
  final AppState state;
  final DriveMapModel model;
  final double topClearance, bottomClearance;
  final bool rotatable;
  final bool collapseCapsule;
  final MapPanelHostController panelHost;
  final double? panelInset;
  const _MapPane({required this.state, required this.model, required this.panelHost, this.panelInset, this.collapseCapsule = false, this.topClearance = 0, this.bottomClearance = 0, this.rotatable = false});

  /// The legend as the map's transient panel (a second tap on the chip closes it).
  void _toggleLegend() {
    if (panelHost.currentId == kLegendPanelId) return panelHost.close(kLegendPanelId);
    final s = state;
    panelHost.show(
      id: kLegendPanelId,
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge([model, s]),
        builder: (context, _) => MapPanel(
          id: kLegendPanelId,
          title: 'Legend',
          leading: const Icon(Icons.palette_outlined, size: 18),
          bottomSafe: false,
          onClose: () => panelHost.close(kLegendPanelId),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: LegendCard(
                  asPanel: true,
                  on: model.layerState.on,
                  meta: model.coverageV2 ? s.coverageMeta : null,
                  local: model.coverageFiltered,
                  drivePanel: model.pings.isNotEmpty || s.driving,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('legend-open-guide'),
                  onPressed: () => showMapLegend(context, pingColors: model.pingColors),
                  child: const Text('Full guide'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = state;
    return LayoutBuilder(
      builder: (context, box) {
        return CoverageMap(
          key: const Key('drive-map'),
          viewController: model.mapView,
          pings: model.visiblePings,
          repeaters: model.repeaters,
          // Not driving: the phone's position (last-known at once, then the fresh fix) so the map opens on it.
          position: model.position ?? (model.pings.isEmpty ? idleMapPosition(s) : null),
          puck: model.puck,
          telemetry: model.telemetry,
          rotatable: rotatable,
          topClearance: topClearance,
          bottomClearance: bottomClearance,
          panelHost: panelHost,
          panelInset: panelInset,
          repeaterLabel: s.repeaterLabel,
          heard: model.heard,
          networkCells: model.visibleNetworkCells,
          baseStyle: model.baseStyle,
          onBoundsChanged: model.onMapBounds,
          regionRepeaters: model.regionRepeaters,
          repeaterSource: model.repeaterSource,
          layerState: model.layerState,
          observers: model.observers,
          observersRegionName: s.viewingRegion?.name,
          estimates: model.estimatesToShow,
          estimateFreshness: model.freshnessOfEstimate,
          redundancyCells: model.redundancy?.cells ?? const [],
          snrLinks: model.snrLinesToShow,
          openRepeaterPage: openRepeaterPageFromMap,
          highlightKey: model.selected,
          onSelectRepeater: model.select,
          simulated: model.simulated,
          onZoomChanged: model.onMapZoom,
          coverageV2: model.coverageV2
              ? CoverageV2Inputs(
                  tiles: s.coverageTiles, meta: s.coverageMeta, drawTiles: model.drawTiles, fetchCell: s.coverageCell, heard: s.coverageHeard)
              : null,
          mapKey: MapKey(model: model),
          regionBorders: model.regionBorders,
          takesFocusRequests: true,
          // MeshTrack: friends' pins, trails, the meet-up point and my last sent position (additive, above the other layers).
          extraLayers: [if (model.friendsOn) ...friendsLayerWidgets(s.meshTrack!)],
          // Long-press with a group: "Meet here" (the only long-press on the Drive map).
          onLongPress: s.meshTrack != null && s.meshTrack!.state.groups.isNotEmpty
              ? (context, hit) => showMeetHereMenu(context, s.meshTrack!, hit.lat, hit.lon)
              : null,
          legend: LegendCard(
            key: const Key('drive-legend-card'),
            on: model.layerState.on,
            meta: model.coverageV2 ? s.coverageMeta : null,
            local: model.coverageFiltered,
            drivePanel: model.pings.isNotEmpty || s.driving,
            onOpen: _toggleLegend,
          ),
          openLegend: () => showMapLegend(context, pingColors: model.pingColors),
          fallbackCenter: viewedRegionCenter(s),
          fallbackBounds: viewedRegionBounds(s),
          onLayers: () => showGeneratedLayersSheet(context, model, host: panelHost),
          topLeading: _StateChips(state: s, model: model, maxWidth: box.maxWidth),
          topTrailing: StatusCapsule(state: s, collapsed: collapseCapsule, onPressed: () => openConnect(context)),
          bottom: Align(alignment: Alignment.bottomLeft, child: MapHealthOverlay(model: model)),
        );
      },
    );
  }
}

/// Top-leading stack of the new Drive screen: the always-present RegionChip, then at most two state chips (plan 4.12): offline
/// data, coverage as-of, dead area, phone-fix note. Each is an opaque pill; further states are dropped (the status capsule's
/// sheet holds the rest).
class _StateChips extends StatelessWidget {
  final AppState state;
  final DriveMapModel model;
  final double maxWidth;
  const _StateChips({required this.state, required this.model, required this.maxWidth});

  @override
  Widget build(BuildContext context) {
    final s = state;
    // At most half the width: the status capsule shares the top edge on the right, and the two must never overlap.
    final w = ((maxWidth - 3 * Gap.s) / 2).clamp(120.0, 320.0);
    final chips = <Widget>[
      if (s.driving && silentPingStreak(s.drivePings) >= deadAreaPings) DeadAreaChip(streak: silentPingStreak(s.drivePings)),
      if (s.regionDataOfflineLabel != null)
        _Pill(
          key: const Key('region-offline-label'),
          icon: Icons.cloud_off_rounded,
          text: s.regionDataOfflineLabel!,
        ),
      CoverageAsOfBadge(model: model),
      if (s.phoneFixNote != null && !s.driving && model.pings.isEmpty) PhoneFixNoteChip(state: s),
    ];
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: w),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RegionChip(state: s),
          for (final c in chips.take(2)) ...[const SizedBox(height: Gap.xs), c],
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Pill({super.key, required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: t.colorScheme.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: t.colorScheme.outlineVariant)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: t.textTheme.labelMedium)),
      ]),
    );
  }
}
