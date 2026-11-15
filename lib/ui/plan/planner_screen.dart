// The Planner (release 0.38 Master Planner, plan §4.1, spec plan-tab-master-planner-2026-11-15.md §4.1): the Plan tab's
// root. One full-screen map (the same CoverageMap engine as the Drive tab, drawing this plan on its `plan` layer through
// a PlanOverlayController) and the planner sheet (planner_sheet.dart: Dock / Medium / Full) with the mode chips
// Link · Coverage · Find sites · Where to drive (plan_modes.dart). Every mode acts on the ONE plan held here by a
// PlanController (lib/core/plan), saved on the phone as it changes (SavedPlans) and reopened next time.
//
// On the map: a long-press drops a planned node (or, while moving a node, puts it there); a tap on a plan node selects it
// (a mode may take the tap first, e.g. Link picks its ends); a tap on a target the mode drew goes to the mode or opens the
// target sheet (Navigate). Moving a node: "Move on the map" in the node editor shows a crosshair; pan the map under it and
// press Set here, or long-press the spot.
//
// Requests from anywhere in the app (ShellController.openPlan, taken by plan_tab.dart) arrive at [PlannerScreenState.handle]:
// a shared plan link, Plan from here, Add to plan, Link to…, a point, a saved plan.
//
// First useful result within one tap (plan §4.5 item 8): an empty plan shows "Coverage from my location", which adds a
// node where the phone is and runs the coverage Estimate.
//
// Keys: 'planner', 'planner-map', 'planner-mode-<id>' (chips), 'plan-name', 'plan-menu', 'plan-radio-summary',
// 'plan-quick-here', 'plan-quick-network', 'plan-selected', 'plan-selected-edit', 'plan-selected-link',
// 'plan-selected-coverage', 'planner-move-bar', 'planner-move-set', 'planner-move-cancel', 'planner-crosshair',
// 'saved-plans', 'saved-plan-<id>', 'plan-rename-field', 'plan-rename-save'.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter_map/flutter_map.dart' show CameraFit, LatLngBounds;
import 'package:latlong2/latlong.dart' show LatLng;

import '../../app/app_state.dart';
import '../../core/map_prefs.dart' show MapPrefs, kPlanLayerPage;
import '../../core/plan/plan_api.dart';
import '../../core/plan/plan_codec.dart' show decodePlanUri;
import '../../core/plan/plan_controller.dart';
import '../../core/plan/plan_model.dart';
import '../../core/plan/saved_plans.dart';
import '../../core/plan_contract.dart';
import '../app.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/sheet_detents.dart' show formSheetDetents;
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../map/core/map_view_controller.dart';
import '../map/coverage_map.dart';
import '../map/layers/app_repeater_feed.dart';
import '../map/layers/map_layer.dart' show LongPressHit, PlanNodeHit, MapLayerState;
import '../map/layers/plan_node_sheet.dart' show showPlanNodeSheet;
import '../map/layers/plan_overlay.dart';
import '../map/layers/registry.dart' show kPlanLayerId, layerStateFromPrefs;
import '../map/layers/repeater_map_source.dart';
import '../map/region_center.dart' show idleMapPosition, viewedRegionBounds, viewedRegionCenter;
import '../shell/shell_controller.dart';
import 'node_list.dart';
import 'plan_modes.dart';
import 'planner_sheet.dart';

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
  final MapViewController _view = MapViewController();
  AppStateRepeaterFeed? _feed;
  RepeaterMapSource? _source;
  final PlanModeHooks _hooks = PlanModeHooks();
  final ScrollController _sheetScroll = ScrollController();
  final Completer<void> _ready = Completer<void>();
  bool _init = false;

  PlanModeId _mode = PlanModeId.link;
  PlannerDetent _detent = PlannerDetent.medium;
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
    _feed = AppStateRepeaterFeed(_s);
    _source = RepeaterMapSource(_feed!, clock: _s.services.clock);
    unawaited(_load());
  }

  @override
  void dispose() {
    _c?.removeListener(_onPlan);
    unawaited(_c?.dispose());
    _source?.dispose();
    _feed?.dispose();
    _overlay.dispose();
    _view.dispose();
    _sheetScroll.dispose();
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitPlan());
  }

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
        return cam.screenOffsetToLatLng(Offset(cam.nonRotatedSize.width / 2, (cam.nonRotatedSize.height - _sheetHeight) / 2));
      });

  PlanBounds? _visibleBounds() => _camera(() {
        final cam = _view.map.camera;
        final a = cam.screenOffsetToLatLng(Offset.zero);
        final b = cam.screenOffsetToLatLng(Offset(cam.nonRotatedSize.width, cam.nonRotatedSize.height - _sheetHeight));
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
      final centre = cam.unprojectAtZoom(px + Offset(0, _sheetHeight / 2), z);
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
          padding: EdgeInsets.fromLTRB(48, 96, 48, _sheetHeight + 48),
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
      setState(() => _selected = n.id);
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
        const AppAction('Open a saved plan', 'open', symbol: AppSymbols.tray, key: Key('plan-menu-open')),
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
      case 'open':
        await _openSavedList();
      case 'new':
        await _open(_fresh());
        if (mounted) showAppToast(context, 'New plan. The last one is saved on this phone.');
      case 'undo':
        c.undo();
      case 'redo':
        c.redo();
    }
  }

  Future<void> _rename() async {
    final c = _c!;
    final field = TextEditingController(text: c.plan.name);
    final name = await showAppSheet<String>(
      context,
      detents: formSheetDetents(context),
      builder: (ctx, scroll) => AppSheetScaffold(
        controller: scroll,
        title: 'Rename the plan',
        primaryAction: FilledButton(
          key: const Key('plan-rename-save'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 4)),
          onPressed: () => Navigator.of(ctx).pop(field.text),
          child: const Text('Save'),
        ),
        children: [
          TextField(
            key: const Key('plan-rename-field'),
            controller: field,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Plan name', border: OutlineInputBorder()),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
        ],
      ),
    );
    field.dispose();
    if (name != null) c.rename(name);
  }

  Future<void> _openSavedList() async {
    final id = await showAppSheet<String>(
      context,
      detents: formSheetDetents(context),
      builder: (ctx, scroll) => _SavedPlansSheet(saved: _saved, currentId: _c?.plan.id, scroll: scroll),
    );
    if (id == null || !mounted) return;
    final p = await _saved.load(id);
    if (!mounted) return;
    if (p == null) {
      showAppToast(context, 'That saved plan could not be read.', kind: AppToastKind.error);
      return;
    }
    await _open(p);
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

  MapLayerState get _layers => layerStateFromPrefs(MapPrefs.shared.layerPrefs(kPlanLayerPage)).toggle(kPlanLayerId, true);

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final fix = s.phoneFix;
    final c = _c;
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
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
                repeaterLabel: s.repeaterLabel,
                coverageV2: s.coverageV2
                    ? CoverageV2Inputs(tiles: s.coverageTiles, meta: s.coverageMeta, drawTiles: !s.coverageTiles.offline, fetchCell: s.coverageCell, heard: s.coverageHeard)
                    : null,
                planOverlay: _overlay,
                onPlanNode: _onPlanNode,
                onLongPress: _onLongPress,
                topClearance: topInset,
                bottomClearance: sheetH,
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
          child: PlanLine(AppSymbols.antenna, 'Radio ${radioWords(p.radio)} · clutter ${p.clutter.canopyM.round()} m trees (Estimate). Tap to change.'),
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
      else
        const PlanLine(AppSymbols.location, 'Allow location to start from where you are.'),
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

  Widget _selectedCard(BuildContext context, PlanNode n) {
    final t = Theme.of(context);
    Widget action(Key key, String label, AppSymbol sym, VoidCallback onTap) => TextButton.icon(
          key: key,
          style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
          onPressed: onTap,
          icon: AppSymbolIcon(sym, size: 18),
          label: Text(label),
        );
    return Container(
      key: const Key('plan-selected'),
      margin: const EdgeInsets.only(bottom: Gap.s),
      padding: const EdgeInsets.all(Gap.s),
      decoration: BoxDecoration(color: t.colorScheme.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Corners.small)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppSymbolIcon(nodeSymbol(n), color: t.colorScheme.primary),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(n.name, style: t.textTheme.titleSmall),
              Text(nodeSummary(n, context), style: t.textTheme.bodySmall),
            ]),
          ),
          IconButton(
            tooltip: 'Clear the selection',
            constraints: const BoxConstraints(minWidth: Hit.min, minHeight: Hit.min),
            onPressed: () => _select(null),
            icon: const AppSymbolIcon(AppSymbols.xmark, size: 18),
          ),
        ]),
        Wrap(spacing: Gap.xs, children: [
          action(const Key('plan-selected-edit'), 'Edit', AppSymbols.squareAndPencil, () => _edit(n.id)),
          action(const Key('plan-selected-link'), 'Link from here', AppSymbols.route,
              () => _startMode(PlanModeId.link, PlanModeIntent(PlanModeIntentKind.linkFrom, n.id, seq: ++_intentSeq))),
          action(const Key('plan-selected-coverage'), 'Coverage', AppSymbols.antenna,
              () => _startMode(PlanModeId.coverage, PlanModeIntent(PlanModeIntentKind.coverageOf, n.id, seq: ++_intentSeq))),
          action(const Key('plan-selected-move'), 'Move', AppSymbols.location, () => _startMove(n.id)),
        ]),
      ]),
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

/// The saved plans on this phone (open one, delete one). Loading, empty and error states from the kit.
class _SavedPlansSheet extends StatefulWidget {
  final SavedPlans saved;
  final String? currentId;
  final ScrollController scroll;
  const _SavedPlansSheet({required this.saved, required this.currentId, required this.scroll});
  @override
  State<_SavedPlansSheet> createState() => _SavedPlansSheetState();
}

class _SavedPlansSheetState extends State<_SavedPlansSheet> {
  late Future<List<SavedPlanSummary>> _list = _read();

  Future<List<SavedPlanSummary>> _read() async {
    final l = await widget.saved.list();
    l.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return l;
  }

  Future<void> _delete(SavedPlanSummary p) async {
    final ok = await showAppConfirm(
      context,
      title: 'Delete "${p.name}"?',
      message: 'The plan and its ${p.nodeCount} ${p.nodeCount == 1 ? 'node' : 'nodes'} are removed from this phone. Links you shared keep working.',
      confirmLabel: 'Delete plan',
      destructive: true,
      confirmKey: Key('saved-plan-delete-confirm-${p.id}'),
    );
    if (!ok) return;
    await widget.saved.delete(p.id);
    if (mounted) setState(() => _list = _read());
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return FutureBuilder<List<SavedPlanSummary>>(
      future: _list,
      builder: (context, snap) => AppSheetScaffold(
        key: const Key('saved-plans'),
        controller: widget.scroll,
        title: 'Saved plans',
        children: [
          if (snap.connectionState != ConnectionState.done) ConstrainedBox(constraints: const BoxConstraints(minHeight: 160), child: AppLoadingView(label: 'Reading your plans…')),
          if (snap.hasError)
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 200), child: AppErrorView(title: 'Could not read your plans', message: 'Try again.', onRetry: () => setState(() => _list = _read()))),
          if (snap.hasData && snap.data!.isEmpty)
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 200), child: AppEmptyView(symbol: AppSymbols.tray, title: 'No saved plans yet', message: 'A plan is saved here as soon as you add a node.')),
          if (snap.hasData)
            for (final p in snap.data!)
              ListTile(
                key: Key('saved-plan-${p.id}'),
                contentPadding: EdgeInsets.zero,
                leading: AppSymbolIcon(p.id == widget.currentId ? AppSymbols.checkmarkCircleFill : AppSymbols.map, color: p.id == widget.currentId ? t.colorScheme.primary : null),
                title: Text(p.name),
                subtitle: Text('${p.nodeCount} ${p.nodeCount == 1 ? 'node' : 'nodes'} · saved ${p.updatedAt.toLocal().toString().substring(0, 16)}${p.id == widget.currentId ? ' · open now' : ''}'),
                onTap: () => Navigator.of(context).pop(p.id),
                trailing: p.id == widget.currentId
                    ? null
                    : IconButton(
                        key: Key('saved-plan-delete-${p.id}'),
                        tooltip: 'Delete ${p.name}',
                        constraints: const BoxConstraints(minWidth: Hit.min, minHeight: Hit.min),
                        onPressed: () => _delete(p),
                        icon: const AppSymbolIcon(AppSymbols.trash),
                      ),
              ),
        ],
      ),
    );
  }
}
