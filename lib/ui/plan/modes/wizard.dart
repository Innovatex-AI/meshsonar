// The Find sites wizard ("Guide me", release 0.38 A10, plan §4.4): for someone who does not know where to start.
//
//   1. What matters most: a slider Personal - Balanced - Mesh.
//   2. About where: a ZIP code or address, looked up ON THE PHONE by the platform geocoder (CLGeocoder on iOS, through the
//      `app.meshsonar/geocoder` channel) and never sent to MeshSonar; or a point on the map (touch and hold); or the
//      phone's own location. Whatever the source, the point is rounded to 2 decimals (about 1 km) the moment it is picked,
//      and only the rounded point (and a box around it, built from the rounded point) is ever sent.
//   3. Two ranked lists: "For your coverage" (goal Coverage, near the point) and "To extend the mesh" (goal Links,
//      Best overall or Redundancy as the slider moves toward Mesh). The slider also sets which list comes first and how
//      long each is. A site in the first list is not repeated in the second.
//
// The lists use the same rows as the view search (find_sites_mode.dart): reason, stage-1 estimate, Verify top 5, Add to
// plan, Navigate, Show. Pins are `C1`, `C2`… (coverage) and `M1`, `M2`… (mesh) on the map.
//
// Keys: 'wizard-lean', 'wizard-address', 'wizard-find-address', 'wizard-pick-map', 'wizard-use-here', 'wizard-picking',
// 'wizard-point', 'wizard-lookup-error', 'wizard-run', 'wizard-list-coverage', 'wizard-list-mesh',
// 'wizard-verify-coverage', 'wizard-verify-mesh', 'wizard-error-<list>', 'wizard-empty-<list>', 'wizard-preparing'.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, MissingPluginException, PlatformException;
import 'package:latlong2/latlong.dart' show LatLng;

import '../../../core/plan/plan_api.dart';
import '../../../core/plan_contract.dart';
import '../../app.dart';
import '../../design/app_haptics.dart';
import '../../design/app_symbols.dart';
import '../../design/state_views.dart';
import '../../design/tokens.dart';
import '../../map/main_map_focus.dart' show MapFocusTarget;
import '../../shell/drive_next_card.dart' show showTargetsOnDriveMap;
import '../../settings/settings_kit.dart' show SliderTile;
import '../plan_modes.dart';
import 'find_sites_mode.dart';

// ------------------------------------------------------------------------------------------------ the place finder

/// What a ZIP code / address lookup found: the place and its plain name (both stay on the phone; only the rounded point
/// is used afterwards).
class PlaceResult {
  final PlanPoint? at;
  final String? label;
  final String? error;

  /// The phone has no geocoder this app can use.
  final bool unavailable;
  const PlaceResult.found(PlanPoint this.at, {this.label})
      : error = null,
        unavailable = false;
  const PlaceResult.failed(String this.error, {this.unavailable = false})
      : at = null,
        label = null;
}

/// Turns a ZIP code or address into a point, on the phone.
abstract class PlaceFinder {
  Future<PlaceResult> find(String query);
}

/// The platform geocoder (iOS CLGeocoder) over `app.meshsonar/geocoder`: method `geocode` with `{query}` answers
/// `{lat, lon, label}` or null when nothing matched. The address goes to the operating system's geocoder only.
class PlatformPlaceFinder implements PlaceFinder {
  static const MethodChannel _c = MethodChannel('app.meshsonar/geocoder');
  const PlatformPlaceFinder();

  @override
  Future<PlaceResult> find(String query) async {
    try {
      final r = await _c.invokeMethod<Map<Object?, Object?>>('geocode', {'query': query}).timeout(const Duration(seconds: 15));
      final lat = r?['lat'], lon = r?['lon'];
      if (lat is! num || lon is! num || !lat.isFinite || !lon.isFinite) return PlaceResult.failed('Nothing found for "$query". Check the ZIP code or address.');
      final label = r?['label'];
      return PlaceResult.found(PlanPoint(lat.toDouble(), lon.toDouble()), label: label is String && label.isNotEmpty ? label : null);
    } on MissingPluginException {
      return const PlaceResult.failed('This version of the app cannot look up addresses on this phone. Touch and hold the map at about where you are instead.',
          unavailable: true);
    } on TimeoutException {
      return const PlaceResult.failed('The address lookup took too long. Try again, or touch and hold the map.');
    } on PlatformException catch (e) {
      return PlaceResult.failed(e.code == 'not_found'
          ? 'Nothing found for "$query". Check the ZIP code or address.'
          : 'The phone could not look that up${e.code == 'network' ? ' (no connection)' : ''}. Try again, or touch and hold the map.');
    }
  }
}

// ------------------------------------------------------------------------------------------------ rounding (privacy)

double _r2(double v) => (v * 100).roundToDouble() / 100;

/// [p] rounded to 2 decimals (about 1 km): the only form of the person's place the wizard keeps or sends.
PlanPoint approximatePoint(PlanPoint p) => PlanPoint(_r2(p.lat), _r2(p.lon));

/// A box of about [km] each way around [p] (already approximate), its edges rounded to 2 decimals, so the box says no
/// more about the place than the rounded point does.
PlanBounds approximateBounds(PlanPoint p, {double km = 20}) {
  final dLat = km / 111.0;
  final dLon = km / (111.0 * math.cos(p.lat * math.pi / 180).abs().clamp(0.2, 1.0));
  return PlanBounds(south: _r2(p.lat - dLat), north: _r2(p.lat + dLat), west: _r2(p.lon - dLon), east: _r2(p.lon + dLon));
}

// ------------------------------------------------------------------------------------------------ the model

enum WizardLean { personal, balanced, mesh }

String leanWords(WizardLean l) => switch (l) {
      WizardLean.personal => 'Personal',
      WizardLean.balanced => 'Balanced',
      WizardLean.mesh => 'Mesh',
    };

String leanCaption(WizardLean l) => switch (l) {
      WizardLean.personal => 'Mostly about covering where you are. "For your coverage" comes first.',
      WizardLean.balanced => 'Both: your own coverage and sites that help the whole mesh.',
      WizardLean.mesh => 'Mostly about the mesh: links, a second path and joining separate parts. "To extend the mesh" comes first.',
    };

/// The goal of the "To extend the mesh" list for [l].
PlanGoal meshGoalFor(WizardLean l) => switch (l) {
      WizardLean.personal => PlanGoal.links,
      WizardLean.balanced => PlanGoal.overall,
      WizardLean.mesh => PlanGoal.redundancy,
    };

/// How many picks each list shows for [l]: (coverage, mesh).
(int, int) listSizesFor(WizardLean l) => switch (l) {
      WizardLean.personal => (10, 5),
      WizardLean.balanced => (8, 8),
      WizardLean.mesh => (5, 10),
    };

enum WizardList { coverage, mesh }

/// One of the two ranked lists.
class WizardListState {
  final WizardList which;
  PlanResult<PlanSuggestResult>? res;
  List<PlanSite> sites = const [];
  final SiteChecks checks = SiteChecks();
  WizardListState(this.which);

  String get keyBase => which == WizardList.coverage ? 'wiz-c' : 'wiz-m';
  String get pinPrefix => which == WizardList.coverage ? 'C' : 'M';
  String get title => which == WizardList.coverage ? 'For your coverage' : 'To extend the mesh';
  String nameOf(int i) => '${which == WizardList.coverage ? 'Coverage' : 'Mesh'} pick ${i + 1}';

  void reset() {
    res = null;
    sites = const [];
    checks.clear();
  }
}

/// The wizard's state, owned by the Find sites body so it survives switching between "This view" and "Guide me".
class WizardModel {
  final PlanModeContext ctx;
  final VoidCallback onChanged;
  WizardModel(this.ctx, {required this.onChanged});

  /// The geocoder (a test seam; the platform's otherwise).
  static PlaceFinder Function()? testPlaceFinder;

  WizardLean lean = WizardLean.balanced;

  /// The person's place, ALREADY rounded ([approximatePoint]); the precise point is never kept.
  PlanPoint? point;

  /// The geocoder's name for the place (stays on the phone).
  String? placeLabel;
  final TextEditingController address = TextEditingController();
  bool picking = false, looking = false, loading = false;
  String? lookupError;
  bool lookupUnavailable = false;
  final WizardListState coverage = WizardListState(WizardList.coverage), mesh = WizardListState(WizardList.mesh);
  int _seq = 0;
  Timer? _again;
  int _preparingTries = 0;
  bool _disposed = false;

  bool get hasResults => coverage.res != null || mesh.res != null;
  bool get preparing => [coverage, mesh].any((l) => l.res?.data?.preparing == true);

  /// The lists in the order the slider puts them.
  List<WizardListState> get ordered => lean == WizardLean.mesh ? [mesh, coverage] : [coverage, mesh];

  List<MapFocusTarget> get targets => [
        for (final l in ordered)
          for (var i = 0; i < l.sites.length; i++)
            MapFocusTarget(id: '${l.keyBase}-${l.sites[i].id}', at: LatLng(l.sites[i].at.lat, l.sites[i].at.lon), label: '${l.pinPrefix}${i + 1}'),
      ];

  void _changed() {
    if (!_disposed) onChanged();
  }

  void dispose() {
    _disposed = true;
    _again?.cancel();
    coverage.checks.clear();
    mesh.checks.clear();
    stopPicking(notify: false);
    address.dispose();
  }

  void setLean(BuildContext context, WizardLean l) {
    if (l == lean) return;
    lean = l;
    unawaited(AppHaptics.selection());
    _changed();
    if (point != null && hasResults && !loading) unawaited(run(context));
  }

  // ---------------------------------------------------------------- where

  /// Takes [precise] as the person's place: rounds it at once, moves the map there and ranks.
  void setPlace(BuildContext context, PlanPoint precise, {String? label}) {
    point = approximatePoint(precise);
    placeLabel = label;
    lookupError = null;
    stopPicking(notify: false);
    ctx.focusMap(point!, zoom: 11);
    unawaited(AppHaptics.success());
    _changed();
    unawaited(run(context));
  }

  Future<void> lookUp(BuildContext context) async {
    final q = address.text.trim();
    if (q.isEmpty) {
      lookupError = 'Type a ZIP code or an address first.';
      _changed();
      return;
    }
    looking = true;
    lookupError = null;
    _changed();
    final r = await (testPlaceFinder?.call() ?? const PlatformPlaceFinder()).find(q);
    if (_disposed) return;
    looking = false;
    if (r.at == null) {
      lookupError = r.error;
      lookupUnavailable = r.unavailable;
      _changed();
      return;
    }
    if (context.mounted) setPlace(context, r.at!, label: r.label);
  }

  void startPicking() {
    picking = true;
    ctx.hooks.onMapPoint = _onMapPoint;
    _changed();
  }

  BuildContext? _pickContext;

  /// Remembers the context the map point should rank in (the wizard's own).
  void bindPickContext(BuildContext context) => _pickContext = context;

  bool _onMapPoint(PlanPoint at) {
    final c = _pickContext;
    if (!picking || c == null || !c.mounted) return false;
    setPlace(c, at);
    return true;
  }

  void stopPicking({bool notify = true}) {
    if (ctx.hooks.onMapPoint == _onMapPoint) ctx.hooks.onMapPoint = null;
    if (!picking) return;
    picking = false;
    if (notify) _changed();
  }

  void useHere(BuildContext context) {
    final fix = AppScope.read(context).phoneFix;
    if (fix == null) return;
    setPlace(context, PlanPoint(fix.fix.lat, fix.fix.lon), label: 'your location');
  }

  void clearPlace() {
    point = null;
    placeLabel = null;
    _again?.cancel();
    _seq++;
    loading = false;
    coverage.reset();
    mesh.reset();
    _changed();
  }

  // ---------------------------------------------------------------- ranking

  PlanSuggestRequest requestFor(WizardList which, PlanPoint p) {
    final plan = ctx.controller.plan;
    final (covN, meshN) = listSizesFor(lean);
    final cov = which == WizardList.coverage;
    return PlanSuggestRequest(
      bounds: approximateBounds(p),
      goal: cov ? PlanGoal.coverage : meshGoalFor(lean),
      limit: cov ? covN : meshN,
      radio: plan.radio,
      clutter: plan.clutter,
      receiverM: plan.receiverM,
      // "Mesh" ranks across the whole box; otherwise sites near the person count more.
      near: !cov && lean == WizardLean.mesh ? null : p,
    );
  }

  /// Asks for both lists, the first-shown one first (one request at a time), and drops from the second list any site
  /// the first already shows.
  Future<void> run(BuildContext context, {bool auto = false}) async {
    final p = point;
    if (p == null) return;
    _again?.cancel();
    if (!auto) _preparingTries = 0;
    final n = ++_seq;
    final hidden = hiddenNodePoints(context);
    loading = true;
    for (final l in [coverage, mesh]) {
      l.checks.clear();
    }
    _changed();
    final order = ordered;
    final shown = <String>{};
    for (final l in order) {
      final r = await ctx.api.suggest(requestFor(l.which, p));
      if (_disposed || n != _seq) return;
      l.res = r;
      l.sites = r.ok ? [for (final s in publicCandidates(r.data!.sites, hiddenNodes: hidden)) if (!shown.contains(s.id)) s] : const [];
      shown.addAll(l.sites.map((s) => s.id));
      _changed();
    }
    loading = false;
    if (preparing && _preparingTries < 10) {
      _preparingTries++;
      _again = Timer(const Duration(seconds: 30), () {
        if (!_disposed && context.mounted) unawaited(run(context, auto: true));
      });
    }
    _changed();
  }

  bool onTargetTap(BuildContext context, String id) {
    for (final l in [coverage, mesh]) {
      final i = l.sites.indexWhere((s) => '${l.keyBase}-${s.id}' == id);
      if (i >= 0) {
        if (!siteInPlan(ctx.controller, l.sites[i])) addSiteToPlan(context, ctx, l.sites[i], l.nameOf(i));
        return true;
      }
    }
    return false;
  }

  Future<void> verify(BuildContext context, WizardListState l) => l.checks.verifyTop(context, ctx, l.sites, changed: _changed, alive: () => !_disposed);
}

// ------------------------------------------------------------------------------------------------ the widget

class FindSitesWizard extends StatelessWidget {
  final WizardModel model;
  const FindSitesWizard({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = model;
    m.bindPickContext(context);
    final fix = AppScope.of(context).phoneFix;
    final p = m.point;
    return Column(key: const Key('sites-wizard'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(header: true, child: Text('1. What matters most', style: t.textTheme.titleSmall)),
      SliderTile(
        sliderKey: const Key('wizard-lean'),
        icon: symbolData(context, AppSymbols.gauge),
        title: 'Personal or mesh',
        caption: leanCaption(m.lean),
        stops: const [0, 1, 2],
        value: m.lean.index,
        label: (v) => leanWords(WizardLean.values[v]),
        minLabel: 'Personal',
        maxLabel: 'Mesh',
        onChanged: (v) => m.setLean(context, WizardLean.values[v]),
      ),
      const SizedBox(height: Gap.s),
      Semantics(header: true, child: Text('2. About where', style: t.textTheme.titleSmall)),
      Text('Looked up on this phone. Only a point rounded to about 1 km is sent.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.s),
      TextField(
        key: const Key('wizard-address'),
        controller: m.address,
        enabled: !m.looking,
        textInputAction: TextInputAction.search,
        keyboardType: TextInputType.streetAddress,
        autocorrect: false,
        decoration: const InputDecoration(labelText: 'ZIP code or address', border: OutlineInputBorder()),
        onSubmitted: (_) => unawaited(m.lookUp(context)),
      ),
      const SizedBox(height: Gap.xs),
      sitesSecondaryButton(
        key: const Key('wizard-find-address'),
        label: m.looking ? 'Looking it up on this phone…' : 'Look up',
        symbol: AppSymbols.magnifyingglass,
        onPressed: m.looking ? null : () => unawaited(m.lookUp(context)),
      ),
      if (m.lookupError != null)
        PlanLine(m.lookupUnavailable ? AppSymbols.infoCircle : AppSymbols.exclamationTriangle, m.lookupError!,
            key: const Key('wizard-lookup-error'), color: m.lookupUnavailable ? null : t.colorScheme.error),
      Wrap(spacing: Gap.xs, children: [
        TextButton.icon(
          key: const Key('wizard-pick-map'),
          style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
          onPressed: m.picking ? m.stopPicking : m.startPicking,
          icon: AppSymbolIcon(m.picking ? AppSymbols.xmark : AppSymbols.pin, size: 18),
          label: Text(m.picking ? 'Cancel' : 'Pick on the map', semanticsLabel: m.picking ? 'Stop picking on the map' : 'Pick about where you are on the map'),
        ),
        if (fix != null)
          TextButton.icon(
            key: const Key('wizard-use-here'),
            style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
            onPressed: () => m.useHere(context),
            icon: const AppSymbolIcon(AppSymbols.location, size: 18),
            label: const Text('Use my location', semanticsLabel: 'Use my location, rounded to about 1 kilometre'),
          ),
      ]),
      if (m.picking)
        const PlanLine(AppSymbols.pin, 'Touch and hold the map at about where you are. The point is rounded to about 1 km.', key: Key('wizard-picking')),
      if (p != null)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: PlanLine(
              AppSymbols.locationFill,
              'Around ${p.lat.toStringAsFixed(2)}, ${p.lon.toStringAsFixed(2)}${m.placeLabel == null ? '' : ' (${m.placeLabel})'}, rounded to about 1 km.',
              key: const Key('wizard-point'),
            ),
          ),
          IconButton(
            key: const Key('wizard-clear-point'),
            tooltip: 'Clear the place',
            constraints: const BoxConstraints(minWidth: Hit.min, minHeight: Hit.min),
            onPressed: m.clearPlace,
            icon: const AppSymbolIcon(AppSymbols.xmarkCircleFill, size: 20),
          ),
        ]),
      const SizedBox(height: Gap.s),
      Semantics(header: true, child: Text('3. Your picks', style: t.textTheme.titleSmall)),
      sitesPrimaryButton(
        key: const Key('wizard-run'),
        label: m.loading ? 'Finding sites…' : m.hasResults ? 'Find again' : 'Find sites for me',
        symbol: AppSymbols.magnifyingglass,
        busy: m.loading,
        onPressed: p == null ? null : () => unawaited(m.run(context)),
      ),
      if (p == null) const PlanLine(AppSymbols.infoCircle, 'Pick a place first (step 2).'),
      if (m.loading && !m.hasResults)
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 120),
          child: AppLoadingView(label: 'Ranking places around you…', timeout: const Duration(seconds: 45), onRetry: () => unawaited(m.run(context))),
        ),
      if (!m.loading && m.preparing)
        SitesPreparingView(
          key: const Key('wizard-preparing'),
          note: [m.coverage, m.mesh].map((l) => l.res?.data?.notes.firstOrNull).nonNulls.firstOrNull,
          onRetry: () => unawaited(m.run(context)),
        )
      else ...[
        for (final l in m.ordered)
          if (l.res != null) _list(context, l),
        if (m.targets.isNotEmpty) ...[
          const SizedBox(height: Gap.s),
          sitesSecondaryButton(
            key: const Key('wizard-drive-map'),
            label: 'Show all on the Drive map',
            symbol: AppSymbols.car,
            onPressed: () => showTargetsOnDriveMap(context, m.targets, zoom: 11),
          ),
        ],
      ],
    ]);
  }

  Widget _list(BuildContext context, WizardListState l) {
    final t = Theme.of(context);
    final m = model;
    final r = l.res!;
    final caption = l.which == WizardList.coverage
        ? 'Where a repeater would best cover the area around you. Pins ${l.pinPrefix}1, ${l.pinPrefix}2… on the map.'
        : 'Where a repeater would help the mesh most (${siteGoalWords(meshGoalFor(m.lean))}). Pins ${l.pinPrefix}1, ${l.pinPrefix}2… on the map.';
    final name = l.which.name;
    return Padding(
      key: Key('wizard-list-$name'),
      padding: const EdgeInsets.only(top: Gap.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(header: true, child: Text(l.title, style: t.textTheme.titleMedium)),
        Text(caption, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xs),
        if (!r.ok)
          AppErrorView(
            key: Key('wizard-error-$name'),
            title: r.unavailable ? 'Find sites is not on this region\'s server yet' : 'Could not find sites',
            message: r.unavailable ? '${r.error} Your plan, Link and Coverage keep working; try again later.' : r.error,
            onRetry: () => unawaited(m.run(context)),
          )
        else if (l.sites.isEmpty)
          AppEmptyView(
            key: Key('wizard-empty-$name'),
            symbol: AppSymbols.magnifyingglass,
            title: l.which == WizardList.coverage ? 'No sites near this place' : 'No other sites that help the mesh here',
            message: 'Try another place, or move the slider.',
          )
        else ...[
          ...resultNotes(context, r),
          sitesPrimaryButton(
            key: Key('wizard-verify-$name'),
            label: l.checks.busy ? 'Double-checking ${l.checks.step} of ${l.checks.of}…' : 'Double-check the top ${math.min(kVerifyTop, l.sites.length)}',
            symbol: AppSymbols.antenna,
            busy: l.checks.busy,
            onPressed: () => unawaited(m.verify(context, l)),
          ),
          for (var i = 0; i < l.sites.length; i++)
            SiteRow(
              keyBase: l.keyBase,
              pin: '${l.pinPrefix}${i + 1}',
              name: l.nameOf(i),
              site: l.sites[i],
              check: l.checks.results[l.sites[i].id],
              checking: l.checks.running.contains(l.sites[i].id),
              inPlan: siteInPlan(m.ctx.controller, l.sites[i]),
              onAdd: () => addSiteToPlan(context, m.ctx, l.sites[i], l.nameOf(i)),
              onShow: () => m.ctx.focusMap(l.sites[i].at, zoom: 14),
              onRetryCheck: () => unawaited(l.checks.retry(context, m.ctx, l.sites[i], changed: m.onChanged, alive: () => !m._disposed)),
            ),
          Text(confidenceWords(r.data!.provenance), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
      ]),
    );
  }
}
