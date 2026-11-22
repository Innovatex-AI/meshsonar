// The Planner (release 0.38 Master Planner, plan §4.1, spec plan-tab-master-planner-2026-11-15.md §4.1): the Plan tab's
// root. One full-screen map (the same CoverageMap engine as the Drive tab, drawing this plan on its `plan` layer through
// a PlanOverlayController) and the planner sheet (planner_sheet.dart: Dock / Medium / Full) with the mode chips
// Link · Coverage · Find sites · Where to drive (plan_modes.dart). Every mode acts on the ONE plan held here by a
// PlanController (lib/core/plan), saved on the phone as it changes (SavedPlans) and reopened next time.
//
// On the map: a long-press drops a planned node (or, while moving a node, puts it there); a tap on a plan node selects it
// (a mode may take the tap first, e.g. Link picks its ends); a tap on a target the mode drew goes to the mode or opens the
// target sheet (Navigate). Moving a node: "Move on the map" in the node editor shows a crosshair; pan the map under it and
// press Set here, or long-press the spot. Or long-press a node's marker and drag it (CoverageMap.onPlanNodeDrag; one undo step).
//
// Requests from anywhere in the app (ShellController.openPlan, taken by plan_tab.dart) arrive at [PlannerScreenState.handle]:
// a shared plan link, Plan from here, Add to plan, Link to…, a point, a saved plan.
//
// First useful result within one tap (plan §4.5 item 8): an empty plan shows "Coverage from my location", which adds a
// node where the phone is and runs the coverage Estimate (without a phone position: "Coverage from the map centre").
//
// Keys: 'planner', 'planner-map', 'planner-mode-<id>' (chips), 'plan-name', 'plan-menu', 'plan-radio-summary',
// 'plan-quick-here', 'plan-quick-centre', 'plan-quick-network', 'plan-selected', 'plan-selected-edit', 'plan-node-drive' (J4:
// Navigate / Show on the Drive map for the selected node), 'plan-menu-drive-map' (the plan's planned sites on the Drive map), 'planner-move-bar', 'planner-move-set', 'planner-move-cancel', 'planner-crosshair',
// 'saved-plans', 'saved-plan-<id>'; Rename uses saved_plans.dart's sheet ('saved-plan-name-field', 'saved-plan-name-save').
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter_map/flutter_map.dart' show CameraFit, LatLngBounds;
import 'package:latlong2/latlong.dart' show LatLng;

import '../../app/app_state.dart';
import '../../core/map_prefs.dart' show kPlanLayerPage;
import '../../core/plan/plan_api.dart';
import '../../core/plan/plan_codec.dart' show decodePlanUri;
import '../../core/plan/plan_controller.dart';
import '../../core/plan/plan_model.dart';
import '../../core/plan/saved_plans.dart';
import '../../core/plan_contract.dart';
import '../app.dart';
import '../design/app_haptics.dart';
import '../design/map_panel.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../map/core/map_view_controller.dart';
import '../map/coverage_map.dart';
import '../map/layers/app_repeater_feed.dart';
import '../map/layers/map_layer.dart' show LongPressHit, PlanNodeHit, MapLayerState;
import '../map/layers/plan_node_sheet.dart' show showPlanNodeSheet;
import '../map/layers/plan_overlay.dart';
import '../map/layers/layers_model.dart' show PageLayersModel;
import '../map/layers/layers_sheet.dart' show showGeneratedLayersSheet;
import '../map/layers/registry.dart' show kPlanLayerId;
import '../map/legend_card.dart' show LegendCard, kLegendPanelId;
import '../map/legend_sheet.dart' show showMapLegend;
import '../map/map_layers.dart' show PingColorMode;
import '../map/layers/repeater_map_source.dart';
import '../map/main_map_focus.dart' show MainMapFocus;
import '../map/region_center.dart' show idleMapPosition, viewedRegionBounds, viewedRegionCenter;
import '../nodes/node_actions.dart' show shellControllerFor;
import '../shell/shell_controller.dart';
import 'modes/footprint_layer.dart' show PlanFootprintController, PlanFootprintLayer, PlanFootprintScope;
import 'node_list.dart';
import 'plan_modes.dart';
import 'plan_share.dart' show PlanImportAdded, PlanImportOpen, showPlanImport, showPlanShare;
import 'planner_sheet.dart';
import 'saved_plans.dart' show promptPlanName, showSavedPlans;

class PlannerScreen extends StatefulWidget {
  const PlannerScreen({super.key});

  /// Test seam: the planner API (default: the viewed region's host, with the website's score-link as the link fallback).
  @visibleForTesting
  static PlanApi Function(AppState state)? testApi;

  @override
  State<PlannerScreen> createState() => PlannerScreenState();
}

class PlannerScreenState extends State<PlannerScreen> {
  late AppState _s;
  late SavedPlans _saved;
  PlanApi? _api;
  String? _apiBase;
  PlanController? _c;
  final PlanOverlayController _overlay = PlanOverlayController();
  final PlanFootprintController _footprint = PlanFootprintController();
  final MapViewController _view = MapViewController();
  AppStateRepeaterFeed? _feed;
  RepeaterMapSource? _source;
  final PlanModeHooks _hooks = PlanModeHooks();
  final ScrollController _sheetScroll = ScrollController();
  final Completer<void> _ready = Completer<void>();
  bool _init = false;

  PlanModeId _mode = PlanModeId.link;
  PlannerDetent _detent = PlannerDetent.medium;

  /// The Plan map's panel group (one open panel per map).
  final MapPanelGroup _panels = MapPanelGroup();

  /// The Plan map's transient panel slot (Layers, Legend, an inspector): panels join [_panels], so the Planner sheet goes back to
  /// its header while one is open and they never stack.
  final MapPanelHostController _host = MapPanelHostController();

  /// What the one Layers panel reads and writes on this map (remembered under the `plan` page).
  late PageLayersModel _layersModel;
  String? _selected;
  String? _moving;
  PlanModeOverlay _modeOverlay = PlanModeOverlay.empty;
  PlanModeIntent? _intent;
  int _intentSeq = 0;
  String? _loadNote;
  double _available = 0;

  /// The open plan (null while the saved plans load).
  PlanController? get controller => _c;
  PlanModeId get mode => _mode;
  PlannerDetent get detent => _detent;
  String? get selectedNodeId => _selected;

  /// Resolves once the last plan has been opened.
  Future<void> get ready => _ready.future;

  @visibleForTesting
  PlanOverlayController get overlayForTest => _overlay;
  @visibleForTesting
  PlanModeHooks get hooksForTest => _hooks;
  @visibleForTesting
  void selectNodeForTest(String? id) => _select(id);
  @visibleForTesting
  Future<bool> longPressForTest(LongPressHit hit) => _onLongPress(context, hit);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    _s = AppScope.read(context);
    _saved = SavedPlans(_s.plans, clock: _s.services.clock);
    // A Drive-map request that names a saved plan draws it (J4). Holds only the store, not this screen.
    final saved = _saved;
    MainMapFocus.overlay.resolvePlan = (id) async {
      final p = await saved.load(id);
      return p == null ? null : planDriveOverlay(p);
    };
    _feed = AppStateRepeaterFeed(_s);
    _source = RepeaterMapSource(_feed!, clock: _s.services.clock);
    _layersModel = PageLayersModel(
      pageId: kPlanLayerPage,
      state: _s,
      repeaterSource: _source!,
      repeaterFeed: _feed!,
      mapName: 'the Plan map',
      alwaysOn: const {kPlanLayerId},
    )..addListener(_onLayersChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _refit?.cancel();
    _c?.removeListener(_onPlan);
    unawaited(_c?.dispose());
    _layersModel.dispose();
    _host.dispose();
    _source?.dispose();
    _feed?.dispose();
    _overlay.dispose();
    _footprint.dispose();
    _view.dispose();
    _sheetScroll.dispose();
    _panels.dispose();
    super.dispose();
  }

  PlanApi get api {
    final base = _s.planBaseUrl;
    final test = PlannerScreen.testApi;
    if (test != null) return _api ??= test(_s);
    if (_api == null || _apiBase != base) {
      _apiBase = base;
      _api = PlanApi(_s.services.cmatClientFactory(Uri.parse(base)), _s.planStore, scoreLink: ScoreLinkApi(base, _s.planStore), clock: _s.services.clock);
    }
    return _api!;
  }

  // ------------------------------------------------------------------------------------------------ the plan

  Plan _fresh() => Plan.create(region: _s.viewingRegion?.slug, preset: _s.siteConfig?.radioPreset, now: _s.services.clock());

  Future<void> _load() async {
    Plan? p;
    try {
      final list = await _saved.list();
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (list.isNotEmpty) p = await _saved.load(list.first.id);
    } catch (_) {
      _loadNote = 'Your saved plans could not be read. This is a new plan; the others are still on the phone.';
    }
    if (!mounted) return;
    _attach(p ?? _fresh());
    if (!_ready.isCompleted) _ready.complete();
  }

  void _attach(Plan p) {
    final c = _c;
    if (c == null) {
      _c = PlanController(p, saved: _saved)..addListener(_onPlan);
    } else {
      c.replace(p);
    }
    _c!.resolveMineFrom(_s.claims.claims);
    setState(() {
      _selected = null;
      _moving = null;
    });
    _syncOverlay();
    // Once now, and once more after the map's own first camera move (it centres on the phone's position when that arrives).
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitPlan());
    _refit?.cancel();
    _refit = Timer(const Duration(milliseconds: 900), _fitPlan);
  }

  Timer? _refit;

  Future<void> _open(Plan p) async {
    final c = _c;
    if (c != null && c.dirty) await c.save();
    if (!mounted) return;
    _attach(p);
  }

  void _onPlan() {
    if (!mounted) return;
    final c = _c!;
    if (_selected != null && c.plan.node(_selected!) == null) _selected = null;
    if (_moving != null && c.plan.node(_moving!) == null) _moving = null;
    setState(() {});
    _syncOverlay();
  }

  void _syncOverlay() {
    final c = _c;
    if (c == null) return;
    final ids = {for (final n in c.nodes) n.id};
    _overlay.showPlan(PlanOverlay(
      planId: c.plan.id,
      nodes: [
        for (final n in c.nodes)
          PlanOverlayNode(
            id: n.id,
            name: n.name,
            at: LatLng(n.lat, n.lon),
            kind: n.status == PlanNodeStatus.planned ? PlanOverlayNodeKind.planned : PlanOverlayNodeKind.installed,
          ),
      ],
      links: [for (final l in _modeOverlay.links) if (ids.contains(l.fromId) && ids.contains(l.toId)) l],
    ));
    _overlay.showTargets(_modeOverlay.targets);
  }

  void _setModeOverlay(PlanModeOverlay o) {
    if (o == _modeOverlay) return;
    _modeOverlay = o;
    // A mode may set its overlay while the sheet builds: the map redraws after the frame.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncOverlay();
      });
    } else {
      _syncOverlay();
    }
  }

  // ------------------------------------------------------------------------------------------------ the map

  double get _sheetHeight => _available <= 0 ? 0 : PlannerSheetMetrics.heightOf(_detent, _available, context);

  /// The sheet height the map works around: at Full the map is behind the sheet, so its view (Find sites, focus, the
  /// crosshair) is the part above the Medium line. That line is the plain Medium fraction of the height: at large Dynamic
  /// Type Medium opens as Full, and the map's controls and credit would otherwise be pushed up into the status bar.
  double get _mapSheetHeight => _available <= 0 ? 0 : math.min(_sheetHeight, _available * kPlannerMedium);

  T? _camera<T>(T Function() f) {
    try {
      return f();
    } catch (_) {
      return null; // the map has not laid out yet
    }
  }

  /// The map point at the middle of the part of the map above the sheet.
  LatLng? get _crosshair => _camera(() {
        final cam = _view.map.camera;
        return cam.screenOffsetToLatLng(Offset(cam.nonRotatedSize.width / 2, (cam.nonRotatedSize.height - _mapSheetHeight) / 2));
      });

  PlanBounds? _visibleBounds() => _camera(() {
        final cam = _view.map.camera;
        final a = cam.screenOffsetToLatLng(Offset.zero);
        final b = cam.screenOffsetToLatLng(Offset(cam.nonRotatedSize.width, cam.nonRotatedSize.height - _mapSheetHeight));
        return PlanBounds(
          south: a.latitude < b.latitude ? a.latitude : b.latitude,
          north: a.latitude < b.latitude ? b.latitude : a.latitude,
          west: a.longitude < b.longitude ? a.longitude : b.longitude,
          east: a.longitude < b.longitude ? b.longitude : a.longitude,
        );
      });

  /// Moves the map so [at] sits in the middle of the part above the sheet.
  void _focus(PlanPoint at, {double? zoom}) {
    _camera(() {
      final cam = _view.map.camera;
      final z = zoom ?? (cam.zoom < 11 ? 13.0 : cam.zoom);
      final px = cam.projectAtZoom(LatLng(at.lat, at.lon), z);
      final centre = cam.unprojectAtZoom(px + Offset(0, _mapSheetHeight / 2), z);
      _view.map.move(centre, z);
      return true;
    });
  }

  void _fitPlan() {
    final c = _c;
    if (!mounted || c == null || c.nodes.isEmpty) return;
    if (c.nodes.length == 1) {
      _focus(c.nodes.single.point, zoom: 13);
      return;
    }
    _camera(() => _view.map.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([for (final n in c.nodes) LatLng(n.lat, n.lon)]),
          padding: EdgeInsets.fromLTRB(48, MediaQuery.paddingOf(context).top + 96, 48, _mapSheetHeight + 48),
          maxZoom: 15,
        )));
  }

  Future<bool> _onLongPress(BuildContext context, LongPressHit hit) async {
    final at = PlanPoint(hit.lat, hit.lon);
    final c = _c;
    if (c == null) return true;
    final moving = _moving;
    if (moving != null) {
      _finishMove(moving, at);
      return true;
    }
    if (_hooks.onMapPoint?.call(at) == true) return true;
    _addAt(at);
    return true;
  }

  /// Drops a planned node at [at] (the long-press default).
  PlanNode? _addAt(PlanPoint at, {String? name}) {
    final c = _c!;
    try {
      final n = c.addNode(name: name ?? 'Site ${c.nodes.where((x) => x.status == PlanNodeStatus.planned).length + 1}', lat: at.lat, lon: at.lon);
      _select(n.id);
      unawaited(AppHaptics.success());
      showAppToast(context, 'Dropped ${n.name}.', actionLabel: 'Undo', onAction: c.undo);
      return n;
    } on PlanFullException catch (e) {
      showAppToast(context, e.toString(), kind: AppToastKind.error);
      return null;
    }
  }

  Future<bool> _onPlanNode(BuildContext context, PlanNodeHit hit) async {
    final c = _c;
    if (c == null || _moving != null) return true;
    if (_hooks.onNodeTap?.call(hit.nodeId) == true) return true;
    if (c.plan.node(hit.nodeId) != null) {
      _select(hit.nodeId);
      return true;
    }
    final target = _overlay.nodeById(hit.nodeId);
    if (target != null) {
      final fix = _s.phoneFix;
      await showPlanNodeSheet(context, target, here: fix == null ? null : LatLng(fix.fix.lat, fix.fix.lon));
    }
    return true;
  }

  void _select(String? id) {
    setState(() {
      _selected = id;
      if (id != null && _detent == PlannerDetent.dock) _detent = PlannerDetent.medium;
    });
    final n = id == null ? null : _c?.plan.node(id);
    if (n != null) {
      unawaited(AppHaptics.selection());
      _focus(n.point);
      if (_sheetScroll.hasClients) unawaited(_sheetScroll.animateTo(0, duration: Motion.of(context, Motion.sheet), curve: Curves.easeOut));
    }
  }

  // ------------------------------------------------------------------------------------------------ moving a node

  void _startMove(String id) {
    final n = _c?.plan.node(id);
    if (n == null) return;
    setState(() {
      _moving = id;
      _detent = PlannerDetent.dock;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus(n.point));
  }

  void _finishMove(String id, PlanPoint at) {
    final c = _c!;
    final ok = c.moveNode(id, at.lat, at.lon);
    setState(() {
      _moving = null;
      _detent = PlannerDetent.medium;
      _selected = id;
    });
    if (ok) {
      unawaited(AppHaptics.success());
      showAppToast(context, 'Moved ${c.plan.node(id)?.name ?? 'the node'}.', actionLabel: 'Undo', onAction: c.undo);
    }
  }

  // ------------------------------------------------------------------------------------------------ dragging a node

  String? _dragging;

  /// A plan node dragged on the map (CoverageMap.onPlanNodeDrag): one undo step for the whole drag.
  void _onDrag(String id, LatLng at) {
    final c = _c;
    final n = c?.plan.node(id);
    if (c == null || n == null || _moving != null || (n.lat == at.latitude && n.lon == at.longitude)) return;
    c.moveNode(id, at.latitude, at.longitude, continuing: _dragging == id);
    _dragging = id;
  }

  void _onDragEnd(String id, LatLng at) {
    _onDrag(id, at);
    final moved = _dragging == id;
    _dragging = null;
    final c = _c;
    if (!moved || c == null || !mounted) return;
    setState(() => _selected = id);
    unawaited(AppHaptics.success());
    showAppToast(context, 'Moved ${c.plan.node(id)?.name ?? 'the node'}.', actionLabel: 'Undo', onAction: c.undo);
  }

  // ------------------------------------------------------------------------------------------------ requests

  /// Applies a request from elsewhere in the app (plan_tab.dart takes it from ShellController.takePendingPlan).
  Future<void> handle(PlanRequest r) async {
    await ready;
    if (!mounted) return;
    switch (r.kind) {
      case PlanRequestKind.openLink:
        final link = r.link!;
        Plan shared;
        try {
          shared = decodePlanUri(link);
        } on FormatException {
          if (mounted) showAppToast(context, 'This plan link could not be read. Ask for a new link.', kind: AppToastKind.error);
          return;
        }
        final kept = await _saved.import(shared);
        await _open(kept);
        if (!mounted) return;
        final approx = kept.nodes.where((n) => n.approximate).length;
        showAppToast(context,
            'Opened the shared plan "${kept.name}"${approx == 0 ? '' : '. $approx ${approx == 1 ? 'position is' : 'positions are'} only about 1 km'}.',
            kind: AppToastKind.success);
      case PlanRequestKind.openSaved:
        final p = await _saved.load(r.planId!);
        if (!mounted) return;
        if (p == null) {
          showAppToast(context, 'That saved plan is no longer on this phone.', kind: AppToastKind.error);
          return;
        }
        await _open(p);
      case PlanRequestKind.planFrom:
        final seed = r.node!;
        final p = _fresh().copyWith(name: 'From ${seed.name}');
        await _open(p);
        final n = _addSeed(seed);
        if (n != null) _startMode(PlanModeId.coverage, PlanModeIntent(PlanModeIntentKind.coverageOf, n.id, seq: ++_intentSeq));
      case PlanRequestKind.addNode:
        final n = _addSeed(r.node!);
        if (n != null && mounted) showAppToast(context, 'Added ${n.name} to the plan.', kind: AppToastKind.success, actionLabel: 'Undo', onAction: _c!.undo);
      case PlanRequestKind.linkTo:
        final n = _addSeed(r.node!);
        if (n != null) {
          final other = _c!.nodes.where((x) => x.id != n.id).firstOrNull;
          _startMode(PlanModeId.link, PlanModeIntent(PlanModeIntentKind.linkFrom, n.id, otherId: null, seq: ++_intentSeq));
          if (mounted) {
            showAppToast(context, other == null ? 'Now add the other end: long-press the map or add a repeater.' : 'Pick the other end: tap a node on the map or choose End B.');
          }
        }
      case PlanRequestKind.point:
        final seed = r.node!;
        _addSeed(seed);
    }
  }

  PlanNode? _addSeed(PlanNodeSeed seed) {
    final c = _c!;
    final claimed = {for (final cl in _s.claims.claims) if (!cl.ended) cl.pubkey.toLowerCase()};
    final key = seed.key?.toLowerCase();
    final network = key != null && const {'repeater', 'observer', 'contact'}.contains(seed.source);
    try {
      final n = c.addNode(
        name: seed.name.trim().isEmpty ? 'Pin' : seed.name,
        lat: seed.lat,
        lon: seed.lon,
        status: network ? PlanNodeStatus.existing : PlanNodeStatus.planned,
        existingKey: key,
        mine: key != null && claimed.contains(key),
        role: seed.source == 'contact' ? PlanNodeRole.handheld : PlanNodeRole.repeater,
      );
      _select(n.id);
      return n;
    } on PlanFullException catch (e) {
      if (mounted) showAppToast(context, e.toString(), kind: AppToastKind.error);
      return null;
    }
  }

  void _startMode(PlanModeId id, PlanModeIntent? intent) {
    _hooks.clear();
    setState(() {
      _mode = id;
      _intent = intent;
      _modeOverlay = PlanModeOverlay.empty;
      if (_detent == PlannerDetent.dock) _detent = PlannerDetent.medium;
    });
    _syncOverlay();
  }

  // ------------------------------------------------------------------------------------------------ sheet actions

  void _openPicker() {
    final c = _c;
    if (c == null) return;
    final centre = _crosshair;
    unawaited(showNodePicker(context, c, near: centre == null ? null : PlanPoint(centre.latitude, centre.longitude), onAdded: (n) => _select(n.id)));
  }

  void _edit(String id) {
    final c = _c;
    if (c == null) return;
    unawaited(showNodeEditor(context, c, id, onMove: _startMove));
  }

  void _quickHere() {
    final fix = _s.phoneFix;
    if (fix == null) return;
    final n = _addAt(PlanPoint(fix.fix.lat, fix.fix.lon), name: 'My location');
    if (n == null) return;
    _c!.updateNode(n.id, (x) => x.copyWith(mine: true));
    _startMode(PlanModeId.coverage, PlanModeIntent(PlanModeIntentKind.coverageOf, n.id, seq: ++_intentSeq));
  }

  /// The quick start without a phone position: a planned node at the middle of the map above the sheet, then its coverage.
  void _quickCentre() {
    final at = _crosshair;
    if (at == null) return;
    final n = _addAt(PlanPoint(at.latitude, at.longitude));
    if (n == null) return;
    _startMode(PlanModeId.coverage, PlanModeIntent(PlanModeIntentKind.coverageOf, n.id, seq: ++_intentSeq));
  }

  Future<void> _menu() async {
    final c = _c;
    if (c == null) return;
    final pick = await showAppActionSheet<String>(
      context,
      title: c.plan.name,
      sheetKey: const Key('plan-menu-sheet'),
      actions: [
        const AppAction('Rename', 'rename', symbol: AppSymbols.squareAndPencil, key: Key('plan-menu-rename')),
        const AppAction('Radio and clutter', 'settings', symbol: AppSymbols.antenna, key: Key('plan-menu-settings')),
        if (planDriveTargets(c.nodes).isNotEmpty)
          const AppAction('Show plan on the Drive map', 'drive', symbol: AppSymbols.car, key: Key('plan-menu-drive-map')),
        const AppAction('Share or export', 'share', symbol: AppSymbols.squareAndArrowUp, key: Key('plan-menu-share')),
        const AppAction('Saved plans', 'open', symbol: AppSymbols.tray, key: Key('plan-menu-open')),
        const AppAction('Import a plan or contacts', 'import', symbol: AppSymbols.squareAndArrowDown, key: Key('plan-menu-import')),
        const AppAction('New plan', 'new', symbol: AppSymbols.plus, key: Key('plan-menu-new')),
        if (c.canUndo) const AppAction('Undo', 'undo', symbol: AppSymbols.chevronLeft, key: Key('plan-menu-undo')),
        if (c.canRedo) const AppAction('Redo', 'redo', symbol: AppSymbols.chevronRight, key: Key('plan-menu-redo')),
      ],
    );
    if (!mounted) return;
    switch (pick) {
      case 'rename':
        await _rename();
      case 'settings':
        await showPlanSettings(context, c, regionPreset: _s.siteConfig?.radioPreset);
      case 'drive':
        await _showPlanOnDrive();
      case 'share':
        await showPlanShare(context, c.plan);
      case 'open':
        await _openSavedList();
      case 'import':
        await _import();
      case 'new':
        await _open(_fresh());
        if (mounted) showAppToast(context, 'New plan. The last one is saved on this phone.');
      case 'undo':
        c.undo();
      case 'redo':
        c.redo();
    }
  }

  /// "Show plan on the Drive map": the Drive tab's map with the plan's planned sites as targets to drive to, and the plan's
  /// installed and network nodes drawn from the saved plan ([MainMapFocus.overlay]'s resolvePlan). Hidden positions never go.
  Future<void> _showPlanOnDrive() async {
    final c = _c;
    if (c == null) return;
    final targets = planDriveTargets(c.nodes);
    if (targets.isEmpty) return;
    if (c.dirty) await c.save(); // the Drive map reads the saved plan
    if (!mounted) return;
    final shell = shellControllerFor(context);
    if (shell == null) return;
    Navigator.maybeOf(context, rootNavigator: true)?.popUntil((r) => r.isFirst);
    MainMapFocus.request(targets.first.at, 11, showLayers: const {kPlanLayerId}, planId: c.plan.id, targets: targets);
    shell.openDrive();
  }

  /// The plan bar's name and the menu's Rename: the same sheet as Saved plans (promptPlanName owns its text controller,
  /// so it lives as long as the sheet does, also while the sheet animates away).
  Future<void> _rename() async {
    final c = _c!;
    final name = await promptPlanName(context, initial: c.plan.name);
    if (name != null && mounted) c.rename(name);
  }

  Future<void> _openSavedList() async {
    final pick = await showSavedPlans(context, saved: _saved, current: _c);
    if (pick == null || !mounted) return;
    if (pick.import) return _import();
    final p = await _saved.load(pick.openId!);
    if (!mounted) return;
    if (p == null) {
      showAppToast(context, 'That saved plan could not be read.', kind: AppToastKind.error);
      return;
    }
    await _open(p);
  }

  /// Paste import (plan_share.dart): a plan opens through [handle] like a tapped link; contacts join this plan.
  Future<void> _import() async {
    final c = _c;
    if (c == null) return;
    final at = _crosshair;
    final claimed = {for (final cl in _s.claims.claims) if (!cl.ended) cl.pubkey.toLowerCase()};
    final r = await showPlanImport(context, controller: c, near: at == null ? null : PlanPoint(at.latitude, at.longitude), claimed: claimed);
    if (!mounted) return;
    switch (r) {
      case PlanImportOpen(:final link):
        await handle(PlanRequest.openLink(link));
      case PlanImportAdded(:final count) when count > 0:
        showAppToast(context, 'Added $count ${count == 1 ? 'node' : 'nodes'} to the plan.', kind: AppToastKind.success, actionLabel: 'Undo', onAction: () {
          for (var i = 0; i < count; i++) {
            c.undo();
          }
        });
      default:
    }
  }

  // ------------------------------------------------------------------------------------------------ build

  PlanModeContext _modeContext(PlanController c) => PlanModeContext(
        controller: c,
        plan: PlanListenable(c),
        api: api,
        selectedNodeId: _selected,
        selectNode: _select,
        setOverlay: _setModeOverlay,
        focusMap: _focus,
        visibleBounds: _visibleBounds,
        hooks: _hooks,
        intent: _intent,
        switchMode: (id) => _startMode(id, null),
        openNodePicker: _openPicker,
        editNode: _edit,
      );

  MapLayerState get _layers => _layersModel.layerState;

  void _onLayersChanged() {
    if (mounted) setState(() {});
  }

  /// The legend as the map's transient panel (a second tap on the chip closes it).
  void _toggleLegend() {
    if (_host.currentId == kLegendPanelId) return _host.close(kLegendPanelId);
    final s = _s;
    _host.show(
      id: kLegendPanelId,
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge([_layersModel, s]),
        builder: (context, _) => MapPanel(
          id: kLegendPanelId,
          title: 'Legend',
          leading: const Icon(Icons.palette_outlined, size: 18),
          bottomSafe: false,
          onClose: () => _host.close(kLegendPanelId),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(child: LegendCard(asPanel: true, on: _layers.on, meta: s.coverageV2 ? s.coverageMeta : null, drivePanel: false)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('legend-open-guide'),
                  onPressed: () => showMapLegend(context, pingColors: PingColorMode.snr),
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
    final s = AppScope.of(context);
    final fix = s.phoneFix;
    final c = _c;
    final topInset = MediaQuery.paddingOf(context).top;
    // The coverage footprint: Coverage mode fills it (through the scope), the map draws it under the plan layer.
    // One open panel on the Plan map (design/map_panel.dart rule 5): the Planner sheet and the map's transient panel (the
    // inspector, a tapped observer) share this group, so opening one sends the other back to its header.
    return MapPanelScope(
      group: _panels,
      child: PlanFootprintScope(
      controller: _footprint,
      child: Scaffold(
      key: const Key('planner'),
      body: LayoutBuilder(builder: (context, box) {
        _available = box.maxHeight;
        final sheetH = _sheetHeight;
        return Stack(children: [
          Positioned.fill(
            child: Semantics(
              container: true,
              label: 'Plan map. Long-press to drop a planned node; tap a node to select it.',
              child: CoverageMap(
                key: const Key('planner-map'),
                viewController: _view,
                pings: const [],
                position: fix == null ? null : LatLng(fix.fix.lat, fix.fix.lon),
                follow: false,
                fallbackCenter: idleMapPosition(s) ?? viewedRegionCenter(s),
                fallbackBounds: viewedRegionBounds(s),
                repeaterSource: _source,
                layerState: _layers,
                baseStyle: _layersModel.baseStyle,
                panelHost: _host,
                onLayers: () => showGeneratedLayersSheet(context, _layersModel, host: _host),
                legend: LegendCard(
                  key: const Key('planner-legend-card'),
                  on: _layers.on,
                  meta: s.coverageV2 ? s.coverageMeta : null,
                  drivePanel: false,
                  onOpen: _toggleLegend,
                ),
                openLegend: () => showMapLegend(context, pingColors: PingColorMode.snr),
                repeaterLabel: s.repeaterLabel,
                coverageV2: s.coverageV2
                    ? CoverageV2Inputs(tiles: s.coverageTiles, meta: s.coverageMeta, drawTiles: !s.coverageTiles.offline, fetchCell: s.coverageCell, heard: s.coverageHeard)
                    : null,
                planOverlay: _overlay,
                onPlanNode: _onPlanNode,
                onLongPress: _onLongPress,
                onPlanNodeDrag: _onDrag,
                onPlanNodeDragEnd: _onDragEnd,
                extraLayers: [PlanFootprintLayer(controller: _footprint)],
                topClearance: topInset,
                // At Full the map is behind the sheet: its controls and credit stay at the Medium line, clear of the status bar.
                bottomClearance: _mapSheetHeight,
                topLeading: _titlePill(context, c),
              ),
            ),
          ),
          if (_moving != null) ..._moveUi(context, box, sheetH),
          PlannerSheet(
            detent: _detent,
            onDetent: (d) => setState(() => _detent = d),
            availableHeight: box.maxHeight,
            scroll: _sheetScroll,
            dock: _chips(context),
            children: c == null
                ? [ConstrainedBox(constraints: const BoxConstraints(minHeight: 160), child: AppLoadingView(key: Key('planner-loading'), label: 'Opening your plan…'))]
                : _body(context, c),
          ),
        ]);
      }),
      ),
      ),
    );
  }

  Widget _titlePill(BuildContext context, PlanController? c) {
    final t = Theme.of(context);
    return Semantics(
      header: true,
      child: Material(
        color: t.colorScheme.surface.withValues(alpha: 0.92),
        shape: const StadiumBorder(),
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
          child: Text(c == null ? 'Plan' : 'Plan · ${c.plan.name}', key: const Key('planner-title'), style: t.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }

  void _pickMode(PlanMode m) {
    if (m.id == _mode) return;
    unawaited(AppHaptics.selection());
    _startMode(m.id, null);
  }

  /// The mode bar: four equal segments (symbol and words), or a scrolling row of chips at large text.
  Widget _chips(BuildContext context) {
    final t = Theme.of(context);
    if (PlannerSheetMetrics.compactModes(context)) {
      return SingleChildScrollView(
        key: const Key('planner-chips'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.xs),
        child: Row(children: [
          for (final m in planModes)
            Padding(
              padding: const EdgeInsets.only(right: Gap.s),
              child: Semantics(
                hint: m.hint,
                child: ChoiceChip(
                  key: Key('planner-mode-${m.id.name}'),
                  avatar: AppSymbolIcon(m.symbol, size: 16),
                  label: Text(m.label),
                  selected: _mode == m.id,
                  onSelected: (_) => _pickMode(m),
                ),
              ),
            ),
        ]),
      );
    }
    return Padding(
      key: const Key('planner-chips'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.s),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final m in planModes)
          Expanded(
            child: Semantics(
              button: true,
              selected: _mode == m.id,
              hint: m.hint,
              excludeSemantics: true,
              label: '${m.label} mode',
              onTap: () => _pickMode(m),
              child: InkWell(
                key: Key('planner-mode-${m.id.name}'),
                borderRadius: BorderRadius.circular(Corners.small),
                onTap: () => _pickMode(m),
                child: AnimatedContainer(
                  duration: Motion.of(context, Motion.crossFade),
                  margin: const EdgeInsets.all(2),
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                  decoration: BoxDecoration(
                    color: _mode == m.id ? t.colorScheme.primary.withValues(alpha: 0.14) : Colors.transparent,
                    borderRadius: BorderRadius.circular(Corners.small),
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    AppSymbolIcon(m.symbol, size: 20, color: _mode == m.id ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 4),
                    Text(
                      m.label,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      style: t.textTheme.labelMedium?.copyWith(
                        height: 1.2,
                        fontWeight: _mode == m.id ? FontWeight.w700 : FontWeight.w500,
                        color: _mode == m.id ? t.colorScheme.primary : t.colorScheme.onSurface,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  List<Widget> _body(BuildContext context, PlanController c) {
    final t = Theme.of(context);
    final p = c.plan;
    final mode = planModeOf(_mode);
    final sel = _selected == null ? null : p.node(_selected!);
    return [
      // The plan bar: name, count, save state, menu.
      Row(children: [
        Expanded(
          child: InkWell(
            key: const Key('plan-name'),
            onTap: _rename,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Hit.min),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(p.name, style: t.textTheme.titleMedium, semanticsLabel: 'Plan ${p.name}. Double-tap to rename.'),
                Text('${p.nodes.length} ${p.nodes.length == 1 ? 'node' : 'nodes'} · ${c.dirty ? 'Saving…' : 'Saved on this phone'}',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ]),
            ),
          ),
        ),
        IconButton(
          key: const Key('plan-menu'),
          tooltip: 'Plan options',
          constraints: const BoxConstraints(minWidth: Hit.min, minHeight: Hit.min),
          onPressed: _menu,
          icon: const AppSymbolIcon(AppSymbols.ellipsisCircle),
        ),
      ]),
      InkWell(
        key: const Key('plan-radio-summary'),
        onTap: () => showPlanSettings(context, c, regionPreset: _s.siteConfig?.radioPreset),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Hit.min),
          child: PlanLine(AppSymbols.antenna, 'Radio ${radioWords(p.radio)} · clutter ${AppScope.unitsOf(context).height(p.clutter.canopyM.roundToDouble())} trees (Estimate). Tap to change.'),
        ),
      ),
      if (_loadNote != null) PlanLine(AppSymbols.exclamationTriangle, _loadNote!, key: const Key('planner-load-note')),
      const Divider(),
      if (p.nodes.isEmpty && mode.needsNodes) ..._quickStart(context),
      if (sel != null) _selectedCard(context, sel),
      mode.buildSheet(_modeContext(c)),
      const SizedBox(height: Gap.m),
      const Divider(),
      NodeList(controller: c, selectedId: _selected, onSelect: _select, onEdit: _edit, onAdd: _openPicker),
    ];
  }

  List<Widget> _quickStart(BuildContext context) {
    final t = Theme.of(context);
    final fix = _s.phoneFix;
    return [
      Semantics(header: true, child: Text('Start a plan', style: t.textTheme.titleSmall)),
      const SizedBox(height: Gap.xs),
      if (fix != null)
        FilledButton.icon(
          key: const Key('plan-quick-here'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 8)),
          onPressed: _quickHere,
          icon: const AppSymbolIcon(AppSymbols.locationFill, size: 18),
          label: const Text('Coverage from my location'),
        )
      else ...[
        // No position for the phone yet (location off or still coming): still one tap to a result, from the map's centre.
        FilledButton.icon(
          key: const Key('plan-quick-centre'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 8)),
          onPressed: _quickCentre,
          icon: const AppSymbolIcon(AppSymbols.map, size: 18),
          label: const Text('Coverage from the map centre'),
        ),
        const PlanLine(AppSymbols.location, 'Allow location to start from where you are.', key: Key('plan-quick-no-location')),
      ],
      const SizedBox(height: Gap.s),
      OutlinedButton.icon(
        key: const Key('plan-quick-network'),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 4)),
        onPressed: _openPicker,
        icon: const AppSymbolIcon(AppSymbols.antenna, size: 18),
        label: const Text('Add a repeater from the network'),
      ),
      const PlanLine(AppSymbols.pin, 'Or long-press the map to drop a planned node.'),
      const Divider(),
    ];
  }

  /// The selected node in one row: what it is, Edit (name, height, power, Move, Delete) and clear. A mode uses the selected
  /// node as its default (Coverage estimates it, Link starts from it).
  Widget _selectedCard(BuildContext context, PlanNode n) {
    final t = Theme.of(context);
    final edit = TextButton(
      key: const Key('plan-selected-edit'),
      style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
      onPressed: () => _edit(n.id),
      child: Text('Edit', semanticsLabel: 'Edit ${n.name}'),
    );
    final clear = IconButton(
      tooltip: 'Clear the selection',
      constraints: const BoxConstraints(minWidth: Hit.min, minHeight: Hit.min),
      onPressed: () => _select(null),
      icon: const AppSymbolIcon(AppSymbols.xmark, size: 18),
    );
    final what = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(n.name, style: t.textTheme.titleSmall),
      Text(nodeSummary(n, context), style: t.textTheme.bodySmall),
    ]);
    // At large text the buttons go under the words, so the name keeps the full width.
    final large = MediaQuery.textScalerOf(context).scale(14) > 14 * 1.6;
    final drive = nodeCanBeDrivenTo(n) ? PlanNodeDriveActions(node: n) : null;
    Widget card(Widget top) => drive == null
        ? top
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [top, Padding(padding: const EdgeInsets.only(bottom: Gap.xs), child: drive)]);
    return Container(
      key: const Key('plan-selected'),
      margin: const EdgeInsets.only(bottom: Gap.s),
      padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: Gap.xs),
      decoration: BoxDecoration(color: t.colorScheme.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Corners.small)),
      child: card(large
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AppSymbolIcon(nodeSymbol(n), color: t.colorScheme.primary),
                const SizedBox(width: Gap.s),
                Expanded(child: what),
              ]),
              Wrap(alignment: WrapAlignment.end, children: [edit, clear]),
            ])
          : Row(children: [
              AppSymbolIcon(nodeSymbol(n), color: t.colorScheme.primary),
              const SizedBox(width: Gap.s),
              Expanded(child: what),
              edit,
              clear,
            ])),
    );
  }

  List<Widget> _moveUi(BuildContext context, BoxConstraints box, double sheetH) {
    final t = Theme.of(context);
    final n = _c?.plan.node(_moving!);
    final top = MediaQuery.paddingOf(context).top;
    final cy = (box.maxHeight - sheetH) / 2;
    return [
      Positioned(
        left: box.maxWidth / 2 - 22,
        top: cy - 22,
        child: IgnorePointer(
          child: Semantics(
            label: 'Crosshair: the new position of ${n?.name ?? 'the node'}',
            child: SizedBox(
              key: const Key('planner-crosshair'),
              width: 44,
              height: 44,
              child: CustomPaint(painter: _CrosshairPainter(t.colorScheme.primary, t.colorScheme.surface)),
            ),
          ),
        ),
      ),
      Positioned(
        left: Layout.screenMargin,
        right: Layout.screenMargin,
        top: top + Gap.s,
        child: Material(
          key: const Key('planner-move-bar'),
          elevation: 4,
          color: t.colorScheme.surface,
          borderRadius: BorderRadius.circular(Corners.small),
          child: Padding(
            padding: const EdgeInsets.all(Gap.s),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Semantics(
                liveRegion: true,
                child: Text('Move ${n?.name ?? 'the node'}: pan the map under the crosshair, or long-press the new spot.', style: t.textTheme.bodyMedium),
              ),
              const SizedBox(height: Gap.xs),
              Wrap(alignment: WrapAlignment.end, spacing: Gap.s, children: [
                TextButton(
                  key: const Key('planner-move-cancel'),
                  style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
                  onPressed: () => setState(() {
                    _moving = null;
                    _detent = PlannerDetent.medium;
                  }),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('planner-move-set'),
                  style: FilledButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
                  onPressed: () {
                    final at = _crosshair;
                    if (at != null) _finishMove(_moving!, PlanPoint(at.latitude, at.longitude));
                  },
                  child: const Text('Set here'),
                ),
              ]),
            ]),
          ),
        ),
      ),
    ];
  }
}

class _CrosshairPainter extends CustomPainter {
  final Color line, halo;
  _CrosshairPainter(this.line, this.halo);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (final (w, col) in [(5.0, halo), (2.0, line)]) {
      final p = Paint()
        ..color = col
        ..strokeWidth = w
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(c, 10, p);
      canvas.drawLine(Offset(c.dx, 0), Offset(c.dx, c.dy - 12), p);
      canvas.drawLine(Offset(c.dx, c.dy + 12), Offset(c.dx, size.height), p);
      canvas.drawLine(Offset(0, c.dy), Offset(c.dx - 12, c.dy), p);
      canvas.drawLine(Offset(c.dx + 12, c.dy), Offset(size.width, c.dy), p);
    }
  }

  @override
  bool shouldRepaint(_CrosshairPainter old) => old.line != line || old.halo != halo;
}
