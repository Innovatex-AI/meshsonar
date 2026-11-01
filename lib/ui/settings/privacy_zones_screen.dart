// Settings > Privacy & data sharing > Privacy zones: the map editor. Circles where the pings of this driver are hidden from
// every public view (past and future drives); the start and end of each drive are also trimmed by the trim distance.
//
// Behaviour (mirrors the website's /me/privacy editor, meshcore-insights zone-editor.tsx):
//  - A tap on a zone SELECTS it; a tap on empty map selects nothing. A zone is only added from "Add a zone" (one tap on
//    the map = one zone) or "Use my location", so a tap meant to pick a zone can never drop a second one.
//  - Radius 50-5000 m (slider), at most 10 zones, coordinates rounded to 4 decimals and longitude wrapped before they are
//    saved or sent (lib/core/privacy_zones.dart), a name of up to 40 characters, "Move on map" and Delete with Undo.
//  - Works with no signal and no driver key: every change is saved on the phone at once and sent when it can be
//    (lib/app/privacy_zones_controller.dart). A server without `driverPrivacy` gets a plain message and no editing.
//
// Keys (tests): 'privacy-zones-screen', 'zones-map', 'zone-status', 'zone-add', 'zone-add-here', 'zone-add-banner',
// 'zone-add-cancel', 'zone-tile-<i>', 'zone-editor', 'zone-name', 'zone-radius', 'zone-move', 'zone-here', 'zone-delete',
// 'zone-trim', 'zone-limit', 'zones-unsupported', 'zones-website'.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../app/app_state.dart';
import '../../app/privacy_zones_controller.dart';
import '../../core/privacy_zones.dart';
import '../app.dart';
import '../map/coverage_map.dart' show CoverageMap;
import '../map/offline_basemap.dart';
import '../map/region_center.dart';

/// The copy that says what a zone does. One place, so the screen, the search entry and the docs agree.
const String privacyZonesExplain = 'Drives inside a zone are hidden from the public map. The start and end of each drive '
    'are also trimmed (the trim distance below). Zones hide pings from every public view, for drives you already uploaded '
    'and for future ones.';

/// The line under the Settings row: how many zones, and whether any wait to be sent.
String privacyZonesSummary(AppState s) {
  final c = s.privacyZones;
  if (!c.loaded) {
    unawaited(c.load());
    return 'Hide pings near home and other places';
  }
  final n = c.zones.length;
  if (c.support() == ZoneSupport.no) return 'Not supported by this server yet';
  final base = n == 0 ? 'No zones yet. Hide pings near home and other places.' : '$n ${n == 1 ? 'zone' : 'zones'}, trim ${c.trimM} m';
  return c.pending ? '$base · waiting to be sent' : base;
}

class PrivacyZonesScreen extends StatefulWidget {
  /// Widget tests turn the tiles off (no network, no plugins under `flutter test`).
  final bool? showTiles;

  /// Tests read the camera to place taps on the map.
  @visibleForTesting
  final MapController? mapController;
  const PrivacyZonesScreen({super.key = const Key('privacy-zones-screen'), this.showTiles, this.mapController});

  @override
  State<PrivacyZonesScreen> createState() => _PrivacyZonesScreenState();
}

enum _Mode { select, add, move }

class _PrivacyZonesScreenState extends State<PrivacyZonesScreen> {
  PrivacyZonesController? _c;
  late final MapController _map = widget.mapController ?? MapController();
  final FocusNode _nameFocus = FocusNode();
  final TextEditingController _name = TextEditingController();
  late final OfflinePackSelection _pack = OfflinePackSelection(OfflineBasemap.instance);

  int? _selected;
  _Mode _mode = _Mode.select;
  PrivacyZone? _draft; // the selected zone while its radius or name is being edited (not yet saved)
  ({PrivacyZone zone, int index})? _deleted;
  bool _mapReady = false;
  int? _trimDraft;

  bool get _tiles => widget.showTiles ?? CoverageMap.tilesByDefault;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) unawaited(_commitDraft());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c == null) {
      final c = AppScope.read(context).privacyZones;
      _c = c;
      c.addListener(_onChanged);
      unawaited(c.load().then((_) => c.sync()));
      if (_tiles) {
        OfflineBasemap.instance.ensureOpen();
        OfflineBasemap.instance.addListener(_onPacks);
      }
    }
  }

  void _onChanged() {
    if (!mounted) return;
    final n = _c!.zones.length;
    if (_selected != null && _selected! >= n) _selected = null;
    setState(() {});
  }

  void _onPacks() {
    if (mounted && _pack.refresh()) setState(() {});
  }

  @override
  void dispose() {
    _c?.removeListener(_onChanged);
    if (_tiles) OfflineBasemap.instance.removeListener(_onPacks);
    unawaited(_commitDraft());
    _nameFocus.dispose();
    _name.dispose();
    super.dispose();
  }

  PrivacyZonesController get c => _c!;

  /// The zones as drawn: the saved list with the one being edited replaced by its draft.
  List<PrivacyZone> get _zones {
    final z = c.zones;
    final d = _draft, i = _selected;
    if (d == null || i == null || i >= z.length) return z;
    return [...z]..[i] = d;
  }

  bool get _editable => c.support() != ZoneSupport.no;

  Future<void> _commitDraft() async {
    final d = _draft, i = _selected;
    _draft = null;
    final controller = _c;
    if (d == null || i == null || controller == null || i >= controller.zones.length) return;
    final next = [...controller.zones]..[i] = d;
    await controller.setZones(next);
  }

  Future<void> _select(int? i) async {
    if (i != _selected) await _commitDraft();
    if (!mounted) return;
    setState(() {
      _selected = i;
      _mode = _Mode.select;
      _draft = null;
      _name.text = i == null ? '' : (c.zones[i].label ?? '');
    });
    if (i != null && _mapReady) {
      final z = c.zones[i];
      _map.move(LatLng(z.lat, z.lon), math.max(_map.camera.zoom, _zoomFor(z.radiusM, z.lat)));
    }
  }

  /// A zoom at which a circle of [radiusM] at [lat] is about 110 px in radius: the whole circle and its surroundings in view.
  double _zoomFor(double radiusM, double lat) {
    final z = math.log(156543.03392 * math.cos(lat * math.pi / 180) * 110 / math.max(radiusM, 1)) / math.ln2;
    return z.clamp(9.0, 17.0);
  }

  Future<void> _addAt(double lat, double lon) async {
    await _commitDraft();
    if (c.zones.length >= kZoneMax) return;
    final z = PrivacyZone.normalized(lat: lat, lon: lon);
    await c.setZones([...c.zones, z]);
    if (!mounted) return;
    await _select(c.zones.length - 1);
  }

  Future<void> _onMapTap(LatLng p) async {
    if (!_editable) return;
    switch (_mode) {
      case _Mode.add:
        await _addAt(p.latitude, p.longitude);
      case _Mode.move:
        final i = _selected;
        if (i == null) return;
        await _commitDraft();
        await c.setZones([...c.zones]..[i] = c.zones[i].copyWith(lat: p.latitude, lon: wrapLon(p.longitude)));
        if (mounted) setState(() => _mode = _Mode.select);
      case _Mode.select:
        await _select(pickZone(_zones, p.latitude, p.longitude, _map.camera.zoom));
    }
  }

  ({double lat, double lon})? _phone() {
    final f = AppScope.read(context).phoneFix;
    return f == null ? null : (lat: f.fix.lat, lon: f.fix.lon);
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _addHere() async {
    final p = _phone();
    if (p == null) return _say('No location yet. Turn on location for MeshSonar, or tap "Add a zone" and tap the map.');
    await _addAt(p.lat, p.lon);
    if (mounted && _mapReady) _map.move(LatLng(c.zones.last.lat, c.zones.last.lon), _zoomFor(c.zones.last.radiusM, c.zones.last.lat));
  }

  Future<void> _moveHere() async {
    final i = _selected, p = _phone();
    if (i == null) return;
    if (p == null) return _say('No location yet. Turn on location for MeshSonar, or use "Move on map".');
    await _commitDraft();
    await c.setZones([...c.zones]..[i] = c.zones[i].copyWith(lat: p.lat, lon: p.lon));
    if (mounted && _mapReady) _map.move(LatLng(c.zones[i].lat, c.zones[i].lon), _map.camera.zoom);
  }

  Future<void> _delete() async {
    final i = _selected;
    if (i == null) return;
    await _commitDraft();
    final z = c.zones[i];
    await c.setZones([...c.zones]..removeAt(i));
    if (!mounted) return;
    setState(() {
      _selected = null;
      _draft = null;
      _deleted = (zone: z, index: i);
    });
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      key: const Key('zone-deleted'),
      content: Text('Deleted ${_title(z, i)}'),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(label: 'Undo', onPressed: () => unawaited(_undoDelete())),
    ));
  }

  Future<void> _undoDelete() async {
    final d = _deleted;
    if (d == null || c.zones.length >= kZoneMax) return;
    final at = d.index.clamp(0, c.zones.length);
    await c.setZones([...c.zones]..insert(at, d.zone));
    _deleted = null;
    if (mounted) await _select(at);
  }

  static String _title(PrivacyZone z, int i) => z.label ?? 'Zone ${i + 1}';

  // ---------------------------------------------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy zones')),
      body: SafeArea(
        child: LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth >= 720;
          final map = _mapBox(context, s, height: wide ? null : math.min(380.0, math.max(200.0, box.maxHeight * 0.36)));
          final panel = _panel(context, s);
          if (wide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: map),
              SizedBox(width: math.min(420, box.maxWidth * 0.45), child: ListView(key: const Key('zones-panel'), cacheExtent: 4000, padding: const EdgeInsets.all(Gap.l), children: panel)),
            ]);
          }
          // The map stays pinned on top while the list and the editor scroll under it, so a zone is always in view as it is edited.
          return Column(children: [
            map,
            Expanded(
              child: ListView(
                key: const Key('zones-panel'),
                cacheExtent: 4000, // the panel is short; keep all of it built (focus, semantics and tests)
                padding: const EdgeInsets.all(Gap.l),
                children: panel,
              ),
            ),
          ]);
        }),
      ),
    );
  }

  Widget _mapBox(BuildContext context, AppState s, {double? height}) {
    final mc = MeshSonarColors.of(context);
    final t = Theme.of(context);
    final zones = _zones;
    final start = _startView(s);
    final offline = _tiles ? _pack.reader : null;
    final sel = _selected;
    final map = Semantics(
      container: true,
      label: 'Map of your privacy zones. ${zones.isEmpty ? 'No zones yet.' : '${zones.length} ${zones.length == 1 ? 'zone' : 'zones'}.'} '
          'The list below the map is the way to select and edit a zone with a screen reader.',
      child: FlutterMap(
        key: const Key('zones-map'),
        mapController: _map,
        options: MapOptions(
          initialCenter: start.$1,
          initialZoom: start.$2,
          minZoom: 2,
          maxZoom: 18,
          backgroundColor: mc.mapBackground,
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          onMapReady: () {
            _mapReady = true;
            if (_tiles && _pack.update(start.$1.latitude, start.$1.longitude) && mounted) setState(() {});
          },
          onPositionChanged: (cam, _) {
            if (_tiles && _pack.update(cam.center.latitude, cam.center.longitude) && mounted) setState(() {});
          },
          onTap: (_, p) => unawaited(_onMapTap(p)),
        ),
        children: [
          if (offline != null)
            OfflineBasemapLayer(key: ValueKey('zones-offline-${_pack.code}'), reader: offline)
          else if (_tiles)
            TileLayer(
              urlTemplate: CoverageMap.tileUrl,
              userAgentPackageName: CoverageMap.userAgentPackageName,
              maxNativeZoom: 19,
              tileBuilder: (context, tile, _) => ColorFiltered(colorFilter: ColorFilter.matrix(mc.tileMatrix), child: tile),
            ),
          CircleLayer(circles: [
            for (var i = 0; i < zones.length; i++)
              CircleMarker(
                point: LatLng(zones[i].lat, zones[i].lon),
                radius: zones[i].radiusM,
                useRadiusInMeter: true,
                color: (i == sel ? t.colorScheme.primary : t.colorScheme.tertiary).withValues(alpha: i == sel ? 0.30 : 0.18),
                borderColor: i == sel ? t.colorScheme.primary : t.colorScheme.tertiary,
                borderStrokeWidth: i == sel ? 3 : 2,
              ),
          ]),
          // The number on each zone is also its tap target for a zone too small to hit on screen (48 px).
          MarkerLayer(markers: [
            for (var i = 0; i < zones.length; i++)
              Marker(
                point: LatLng(zones[i].lat, zones[i].lon),
                width: 48,
                height: 48,
                child: Semantics(
                  button: true,
                  selected: i == sel,
                  label: '${_title(zones[i], i)}, radius ${AppScope.unitsOf(context).distance(zones[i].radiusM)}',
                  child: GestureDetector(
                    key: Key('zone-pin-$i'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => unawaited(_mode == _Mode.select ? _select(i) : _onMapTap(LatLng(zones[i].lat, zones[i].lon))),
                    child: Center(
                      child: CircleAvatar(
                        radius: 13,
                        backgroundColor: i == sel ? t.colorScheme.primary : t.colorScheme.tertiary,
                        foregroundColor: i == sel ? t.colorScheme.onPrimary : t.colorScheme.onTertiary,
                        child: Text('${i + 1}', style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: i == sel ? t.colorScheme.onPrimary : t.colorScheme.onTertiary)),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
          if (_tiles && offline == null)
            const RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
            ),
        ],
      ),
    );
    final bannered = Stack(children: [
      Positioned.fill(child: map),
      if (_mode != _Mode.select) Positioned(left: Gap.s, right: Gap.s, top: Gap.s, child: _modeBanner(context)),
    ]);
    return height == null ? bannered : SizedBox(height: height, child: bannered);
  }

  Widget _modeBanner(BuildContext context) {
    final t = Theme.of(context);
    final text = _mode == _Mode.add ? 'Tap the map where the zone goes.' : 'Tap the map where the zone should move to.';
    // Overlays on the map keep their text at 1.3x at most (the full sentence is read aloud), so it never covers the map.
    final scale = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scale),
      child: Material(
        key: const Key('zone-add-banner'),
        elevation: 2,
        color: t.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(Corners.chip),
        child: Padding(
          padding: const EdgeInsets.only(left: Gap.m),
          child: Row(children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.s),
                  child: Text(text, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onPrimaryContainer, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
            IconButton(
              key: const Key('zone-add-cancel'),
              tooltip: 'Cancel',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: () => setState(() => _mode = _Mode.select),
              icon: Icon(Icons.close, color: t.colorScheme.onPrimaryContainer),
            ),
          ]),
        ),
      ),
    );
  }

  /// Where the map opens and how far in: the selected or first zone, else the phone, else the viewed region, else the world.
  (LatLng, double) _startView(AppState s) {
    final z = _selected != null && _selected! < c.zones.length ? c.zones[_selected!] : (c.zones.isEmpty ? null : c.zones.first);
    if (z != null) return (LatLng(z.lat, z.lon), _zoomFor(z.radiusM, z.lat));
    final p = _phone();
    if (p != null) return (LatLng(p.lat, p.lon), 14);
    final r = viewedRegionCenter(s);
    return r != null ? (r, 9) : (const LatLng(20, 0), 2);
  }

  List<Widget> _panel(BuildContext context, AppState s) {
    final t = Theme.of(context);
    final zones = _zones;
    final full = c.zones.length >= kZoneMax;
    final units = AppScope.unitsOf(context);
    return [
      Text(privacyZonesExplain, key: const Key('zones-explain'), style: t.textTheme.bodyMedium),
      const SizedBox(height: Gap.m),
      _statusBanner(context),
      const SizedBox(height: Gap.m),
      if (_editable) ...[
        Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
          FilledButton.icon(
            key: const Key('zone-add'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: full ? null : () => setState(() => _mode = _mode == _Mode.add ? _Mode.select : _Mode.add),
            icon: const Icon(Icons.add_location_alt_outlined),
            label: const Text('Add a zone'),
          ),
          OutlinedButton.icon(
            key: const Key('zone-add-here'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: full ? null : _addHere,
            icon: const Icon(Icons.my_location),
            label: const Text('Use my location'),
          ),
        ]),
        if (full)
          Padding(
            padding: const EdgeInsets.only(top: Gap.s),
            child: Text('$kZoneMax of $kZoneMax zones. Delete one to add another.', key: const Key('zone-limit'), style: t.textTheme.bodySmall),
          ),
        const SizedBox(height: Gap.m),
      ],
      if (zones.isEmpty)
        Text(
          _editable ? 'No zones yet. Tap "Add a zone", then tap the map, or use your location.' : 'No zones.',
          key: const Key('zones-empty'),
          style: t.textTheme.bodyMedium,
        )
      else
        for (var i = 0; i < zones.length; i++)
          Card(
            margin: const EdgeInsets.only(bottom: Gap.s),
            color: i == _selected ? t.colorScheme.primaryContainer : null,
            child: ListTile(
              key: Key('zone-tile-$i'),
              minVerticalPadding: Gap.s,
              selected: i == _selected,
              leading: CircleAvatar(radius: 14, child: Text('${i + 1}')),
              title: Text(_title(zones[i], i)),
              subtitle: Text('${units.distance(zones[i].radiusM)} radius · ${zones[i].lat.toStringAsFixed(kCoordDecimals)}, ${zones[i].lon.toStringAsFixed(kCoordDecimals)}'),
              trailing: _editable ? const Icon(Icons.chevron_right) : null,
              onTap: () => unawaited(_select(i == _selected ? null : i)),
            ),
          ),
      if (_editable && _selected != null && _selected! < zones.length) _editor(context, zones[_selected!], _selected!),
      const SizedBox(height: Gap.l),
      _trim(context),
      const SizedBox(height: Gap.l),
      OutlinedButton.icon(
        key: const Key('zones-website'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => unawaited(s.openWebPage('/me/privacy')),
        icon: const Icon(Icons.open_in_new, size: 18),
        label: const Text('Open privacy settings on the website'),
      ),
    ];
  }

  Widget _editor(BuildContext context, PrivacyZone z, int i) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final r = _draft?.radiusM ?? z.radiusM;
    // Logarithmic: 50 m to 5000 m needs fine steps near the small end. 100 steps, each about 4.7%.
    final pos = math.log(r / kZoneMinRadiusM) / math.log(kZoneMaxRadiusM / kZoneMinRadiusM);
    double radiusAt(double p) {
      final v = kZoneMinRadiusM * math.pow(kZoneMaxRadiusM / kZoneMinRadiusM, p);
      return (v < 500 ? (v / 10).round() * 10 : (v / 50).round() * 50).toDouble().clamp(kZoneMinRadiusM, kZoneMaxRadiusM);
    }

    return Card(
      key: const Key('zone-editor'),
      margin: const EdgeInsets.only(top: Gap.s),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(header: true, child: Text('Edit ${_title(z, i)}', style: t.textTheme.titleMedium)),
          const SizedBox(height: Gap.s),
          TextField(
            key: const Key('zone-name'),
            controller: _name,
            focusNode: _nameFocus,
            maxLength: kZoneLabelMax,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Name (optional)', hintText: 'Home'),
            onChanged: (v) => setState(() => _draft = (_draft ?? c.zones[i]).copyWith(label: cleanLabel(v))),
            onSubmitted: (_) => unawaited(_commitDraft()),
          ),
          const SizedBox(height: Gap.s),
          Text('Radius: ${units.distance(r)}', key: const Key('zone-radius-label'), style: t.textTheme.bodyLarge),
          Semantics(
            container: true,
            label: 'Radius',
            child: Slider(
              key: const Key('zone-radius'),
              value: pos.clamp(0.0, 1.0),
              divisions: 100,
              semanticFormatterCallback: (p) => units.distance(radiusAt(p)),
              onChanged: (p) => setState(() => _draft = (_draft ?? c.zones[i]).copyWith(radiusM: radiusAt(p))),
              onChangeEnd: (_) => unawaited(_commitDraft()),
            ),
          ),
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            OutlinedButton.icon(
              key: const Key('zone-move'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => setState(() => _mode = _mode == _Mode.move ? _Mode.select : _Mode.move),
              icon: const Icon(Icons.open_with),
              label: const Text('Move on map'),
            ),
            OutlinedButton.icon(
              key: const Key('zone-here'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _moveHere,
              icon: const Icon(Icons.my_location),
              label: const Text('Move here'),
            ),
            OutlinedButton.icon(
              key: const Key('zone-delete'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: t.colorScheme.error),
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _trim(BuildContext context) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final v = (_trimDraft ?? c.trimM).toDouble();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(header: true, child: Text('Trim the start and end of each drive', style: t.textTheme.titleMedium)),
      Text('Hides the first and last ${units.distance(v)} of every drive, wherever it starts. Applies to every drive you upload.',
          key: const Key('zone-trim-label'), style: t.textTheme.bodyMedium),
      Semantics(
        container: true,
        label: 'Trim distance',
        child: Slider(
          key: const Key('zone-trim'),
          value: v.clamp(0, kTrimMaxM.toDouble()),
          min: 0,
          max: kTrimMaxM.toDouble(),
          divisions: kTrimMaxM ~/ 50,
          label: units.distance(v),
          semanticFormatterCallback: (x) => units.distance(x),
          onChanged: _editable ? (x) => setState(() => _trimDraft = x.round()) : null,
          onChangeEnd: _editable
              ? (x) async {
                  final m = x.round();
                  await c.setTrim(m);
                  if (mounted) setState(() => _trimDraft = null);
                }
              : null,
        ),
      ),
    ]);
  }

  Widget _statusBanner(BuildContext context) {
    final t = Theme.of(context);
    final scope = c.state.scope;
    final (IconData icon, String text) = switch (c.status) {
      ZoneSyncStatus.unsupported => (Icons.info_outline, 'This server does not support privacy zones yet, so they cannot be set from the app. Nothing is hidden by zones until it does.'),
      ZoneSyncStatus.waitingForKey => (Icons.cloud_off_outlined, 'Saved on this phone. They are sent as soon as this phone has a driver key.'),
      ZoneSyncStatus.offline => (Icons.cloud_off_outlined, 'Saved on this phone. They are sent when the server can be reached.'),
      ZoneSyncStatus.rejected => (Icons.error_outline, c.error ?? 'The server did not accept the zones.'),
      ZoneSyncStatus.syncing => (Icons.sync, 'Sending…'),
      ZoneSyncStatus.synced => (
          Icons.cloud_done_outlined,
          scope == ZoneScope.account ? 'Saved. Shared with every driver key of your account.' : 'Saved. These apply to this driver key.',
        ),
      ZoneSyncStatus.idle => (Icons.cloud_outlined, c.zones.isEmpty ? 'Zones you add are saved on this phone and sent to the server.' : 'Saved on this phone.'),
    };
    final bad = c.status == ZoneSyncStatus.rejected;
    return Container(
      key: Key(c.status == ZoneSyncStatus.unsupported ? 'zones-unsupported' : 'zone-status'),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(
        color: bad ? t.colorScheme.errorContainer : t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Corners.chip),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: bad ? t.colorScheme.onErrorContainer : null),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(text, style: t.textTheme.bodyMedium?.copyWith(color: bad ? t.colorScheme.onErrorContainer : null))),
      ]),
    );
  }
}
