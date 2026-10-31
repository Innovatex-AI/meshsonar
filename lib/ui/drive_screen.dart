// Home screen, built for one hand in a moving car. The live coverage map dominates, with the HEARD box floated on
// it (who's in range right now, held for a few pings, then greyed) and a button to go full screen. Below the map:
// the status line with what the next auto-ping is waiting for, a compact stats strip, the antenna chip and the
// LOG button, the "View drive report" card after a drive, and the big Start/Stop and Ping now buttons in thumb
// reach. The screen stays awake while driving.
//
// Parts live in lib/ui/drive/ (controls, heard box, the shared map model) and lib/ui/map/ (map, full-screen map).
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import 'app.dart';
import 'device_feedback.dart';
import 'location_status.dart';
import 'map/region_center.dart';
import 'drive/drive_controls.dart';
import 'drive/drive_live_stats.dart';
import 'drive/drive_map_model.dart';
import 'drive/heard_box.dart';
import 'map/coverage_map.dart';
import 'map/fullscreen_map.dart';
import 'map/repeater_page_link.dart';
import 'map/coverage_timeline_slider.dart';
import 'widgets.dart';

export 'drive/drive_controls.dart' show openConnect;

class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key});
  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  AppState? _state;
  DeviceFeedback? _feedback;
  DriveMapModel? _model;
  DriveLiveStats? _liveStats;

  String? _lastPingId;
  bool _awake = false;

  /// The report card for this drive was closed.
  String? _dismissedReport;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _feedback = DeviceFeedbackScope.of(context);
    final s = AppScope.read(context);
    if (!identical(s, _state)) {
      _state?.removeListener(_onState);
      _model?.dispose();
      _liveStats?.dispose();
      _state = s;
      _model = DriveMapModel(s);
      _liveStats = DriveLiveStats(s);
      s.addListener(_onState);
      _onState();
    }
  }

  void _onState() {
    final s = _state;
    if (s == null) return;

    // Feedback on a newly finished ping (not for pings already there when the screen opened).
    final recent = s.recentPings;
    final newest = recent.isEmpty ? null : recent.first;
    if (newest != null && newest.id != _lastPingId) {
      if ((_lastPingId != null || s.driving) && s.driving) {
        unawaited(_feedback?.pingResult(heard: !newest.heardNothing));
      }
      _lastPingId = newest.id;
    }

    // Keep the screen on while driving.
    if (s.driving != _awake) {
      _awake = s.driving;
      unawaited(_feedback?.keepAwake(_awake));
    }
  }

  @override
  void dispose() {
    _state?.removeListener(_onState);
    _model?.dispose();
    _liveStats?.dispose();
    if (_awake) unawaited(_feedback?.keepAwake(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final model = _model!;
    final liveStats = _liveStats!;
    final report = s.driving ? null : s.lastFinishedSessionId;
    final showReport = report != null && report != _dismissedReport;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: Gap.l,
        toolbarHeight: 60,
        title: Row(
          children: [
            Icon(Icons.radar, color: t.colorScheme.primary, size: 26),
            const SizedBox(width: Gap.s),
            // At the largest text sizes the logo alone leaves the connection chip room to say its state.
            if (MediaQuery.textScalerOf(context).scale(16) <= 22)
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Map', maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
                    // Drive is a mode of the Map tab: say which one this is.
                    Text(
                      s.driving ? 'Drive mode' : 'Not driving',
                      key: const Key('map-mode'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.labelSmall?.copyWith(
                        color: s.driving ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Gap.m),
            // Leaves room for the title on narrow phones and with large text.
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.65),
              child: ConnectionChip(state: s, onPressed: () => openConnect(context)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, box) {
            // The overlays on the map (heard box, region chip, hint) are glanceable extras on a map of fixed size; they
            // stop growing past 1.3x so they never swallow it. Everything under the map follows the system size.
            final map = MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3)),
              child: ClipRRect(
              borderRadius: BorderRadius.circular(Corners.card),
              child: AnimatedBuilder(
                animation: model,
                builder: (context, _) => _MapPane(
                  state: s,
                  model: model,
                  // After Stop the drive's report is one tap away (on the map, clear of snackbars).
                  report: showReport
                      ? DriveReportCard(
                          sessionId: report,
                          onDismiss: () => setState(() => _dismissedReport = report),
                        )
                      : null,
                ),
              ),
            ));
            final controls = <Widget>[
              // Location off / not asked / approximate: say so with the one action (the map still opens on the region).
              if (s.locationNote != null && !s.driving)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, 0),
                  child: LocationNoteBanner(state: s),
                ),
              DriveStatusRow(state: s),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                child: DriveStatsStrip(state: s),
              ),
              if (s.driving)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, 0),
                  // liveStats notifies on its own, separately from AppState (e.g. once its one-time local-history
                  // read for the new/repeat cell tally resolves), so this tile needs its own small listener too.
                  child: AnimatedBuilder(
                    animation: liveStats,
                    builder: (context, _) => DriveLiveStatsStrip(state: s, liveStats: liveStats, fix: model.fix),
                  ),
                ),
              if (s.unsavedCount > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                  child: ErrorBanner('${s.unsavedCount} ping(s) not yet saved to this device. Retrying.'),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, 0),
                // A Wrap, not a Row: at the largest text sizes the two stack instead of overflowing.
                child: SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: Gap.s,
                    runSpacing: Gap.s,
                    children: [
                      AntennaChip(state: s),
                      LogButton(state: s),
                    ],
                  ),
                ),
              ),
            ];
            final actions = DriveActionButtons(state: s);
            // Landscape (phone on a dash mount, tablet): map on the left, controls on the right.
            if (box.maxWidth > box.maxHeight && box.maxWidth >= 640) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Padding(padding: const EdgeInsets.fromLTRB(Gap.m, 0, 0, Gap.m), child: map),
                  ),
                  SizedBox(
                    width: (box.maxWidth * 0.42).clamp(340.0, 440.0),
                    child: SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...controls, actions]),
                    ),
                  ),
                ],
              );
            }
            // Large Dynamic Type: the status, stats and chips no longer fit under the map. The map keeps a fixed
            // height and scrolls away with them; Start/Stop and Ping now stay pinned at the bottom.
            if (MediaQuery.textScalerOf(context).scale(16) > 22) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const Key('drive-large-text-scroll'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                            child: SizedBox(height: (box.maxHeight * 0.4).clamp(200.0, 360.0), child: map),
                          ),
                          ...controls,
                        ],
                      ),
                    ),
                  ),
                  actions,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.m), child: map),
                ),
                ...controls,
                actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The map with its overlays (heard box, full-screen and layer buttons, hint, result flash).
class _MapPane extends StatelessWidget {
  final AppState state;
  final DriveMapModel model;
  final Widget? report;
  const _MapPane({required this.state, required this.model, this.report});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final pings = s.recentPings;
    final showHeard = pings.isNotEmpty && (s.driving || model.heard.isNotEmpty);
    return LayoutBuilder(
      builder: (context, box) {
        final boxWidth = (box.maxWidth - 46 - 3 * Gap.s).clamp(160.0, 260.0);
        // Room for about this many rows under the header.
        final rows = ((box.maxHeight - 110) / 44).floor().clamp(1, 5);
        return Stack(
          children: [
            Positioned.fill(
              child: CoverageMap(
                key: const Key('drive-map'),
                pings: model.pings,
                repeaters: model.repeaters,
                // Not driving: the phone's position (last-known at once, then the fresh fix) so the map opens on it.
                position: model.position ?? (model.pings.isEmpty ? idleMapPosition(s) : null),
                showRings: s.driving,
                repeaterLabel: s.repeaterLabel,
                heard: model.heard,
                layers: model.layers,
                networkCells: model.networkCells,
                regionRepeaters: model.regionRepeaters,
                repeaterSource: model.repeaterSource,
                layerState: model.layerState,
                observers: model.observers,
                observersRegionName: s.viewingRegion?.name,
                openRepeaterPage: openRepeaterPageFromMap,
                highlightKey: model.selected,
                onSelectRepeater: model.select,
                simulated: model.simulated,
                onZoomChanged: model.onMapZoom,
                hexRes: model.coverageQuery.res,
                labelAvoidKeys: model.driveOverlayKeys,
                fallbackCenter: viewedRegionCenter(s),
              ),
            ),
            Positioned(left: Gap.s, bottom: 44, child: CoverageAsOfBadge(model: model)),
            if (s.regionDataOfflineLabel != null)
              Positioned(
                left: Gap.s,
                bottom: Gap.s,
                child: Chip(
                  key: const Key('region-offline-label'),
                  avatar: const Icon(Icons.cloud_off, size: 16),
                  label: Text(s.regionDataOfflineLabel!),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            // Below the region chip (top right), which is wider than the icon buttons and used to overlap the hint.
            if (pings.isEmpty) Positioned(left: 0, right: 50, top: Gap.s + 44, child: MapHint(state: s)),
            if (showHeard)
              Positioned(
                left: Gap.s,
                top: Gap.s,
                child: KeyedSubtree(
                  key: model.driveOverlayKeys[0],
                  child: HeardBox(
                  heard: model.heard,
                  holdPings: s.settings.heardHoldPings,
                  here: model.position,
                  selected: model.selected,
                  onSelect: model.select,
                  driving: s.driving,
                  maxRows: rows,
                  width: boxWidth,
                  ),
                ),
              ),
            Positioned(
              right: Gap.s,
              top: Gap.s,
              child: Column(
                key: model.driveOverlayKeys[1],
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Region awareness lives in this corner, above the icon buttons, so it never competes with
                  // the hint/heard-box/report overlays for the same space. Nothing is added here (no chip, no
                  // gap) until there's something real to show — see RegionChip's own "no cache yet" state.
                  if (s.regionIndexLoaded) ...[
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: (box.maxWidth - 2 * Gap.s - 46).clamp(80.0, 180.0)),
                      child: RegionChip(state: s),
                    ),
                    const SizedBox(height: Gap.s),
                  ],
                  if (s.phoneFixNote != null && !s.driving && model.pings.isEmpty) ...[
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: (box.maxWidth - 2 * Gap.s - 46).clamp(80.0, 220.0)),
                      child: PhoneFixNoteChip(state: s),
                    ),
                    const SizedBox(height: Gap.s),
                  ],
                  MapIconButton(
                    key: const Key('map-fullscreen'),
                    icon: Icons.open_in_full_rounded,
                    tooltip: 'Full-screen map',
                    onPressed: () => openFullscreenMap(context, model),
                  ),
                  const SizedBox(height: Gap.s),
                  MapIconButton(
                    key: const Key('drive-map-layers'),
                    icon: Icons.layers_rounded,
                    tooltip: 'Map layers',
                    onPressed: () => showMapLayersSheet(context, model),
                  ),
                ],
              ),
            ),
            if (report != null)
              Positioned(left: Gap.s, right: Gap.s, bottom: model.attributionStackHeight + 12, child: report!),
            if (pings.isNotEmpty && s.driving)
              Positioned(
                bottom: model.attributionStackHeight + 8,
                left: Gap.l,
                right: Gap.l,
                child: Center(child: PingResultFlash(ping: pings.first, label: model.labelFor)),
              ),
          ],
        );
      },
    );
  }
}

/// Radio connection status; tap to connect or change radio. In Simulator mode it says so plainly.
class ConnectionChip extends StatelessWidget {
  final AppState state;
  final VoidCallback onPressed;
  const ConnectionChip({super.key = const Key('connection-chip'), required this.state, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final sim = s.connected && s.radioKind == RadioKind.simulator;
    final retrying = s.connecting || (s.reconnecting && s.driving);
    final Color dot = retrying ? mc.beacon : (sim ? mc.beacon : (s.connected ? t.colorScheme.primary : mc.silent));
    // In the app bar the chip keeps a fixed height, so it stops growing at 1.5x (the label is two lines by then).
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.5)),
      child: ActionChip(
      onPressed: onPressed,
      avatar: retrying
          ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: dot))
          : Icon(
              s.connected
                  ? (sim ? Icons.science_rounded : Icons.bluetooth_connected_rounded)
                  : Icons.bluetooth_disabled_rounded,
              size: 20,
              color: dot,
            ),
      label: sim
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.connectionLabel,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.labelLarge?.copyWith(height: 1.1)),
                const SizedBox(height: 2),
                const SimulatedTag(key: Key('chip-simulated'), dense: true),
              ],
            )
          : Text(s.connectionLabel,
              maxLines: 1, overflow: TextOverflow.ellipsis),
      side: BorderSide(color: dot.withValues(alpha: 0.6)),
      backgroundColor: dot.withValues(alpha: 0.10),
    ));
  }
}
