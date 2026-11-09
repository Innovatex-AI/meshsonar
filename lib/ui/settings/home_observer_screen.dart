// Settings > Privacy & data sharing > Home observer (and More > Radios and tools > Home observer). Phone observer step O3
// (contract meshsonar-infra docs/planning/phone-observer-contract-v2-2026-11-08.md section 4; Andy's decision Q3 Nov 8
// 2026): leave this phone at home next to its radio and it becomes a fixed observer at a spot the owner places on the map.
// The owner chooses how the public map shows it: exact, or rounded to about 1 km. While it is on, the screen stays awake,
// the radio is reconnected by itself, and a heartbeat goes to the server every 5 minutes so the Observers layer on the
// website shows it as up. Turning it off deletes the home position on the server (back to a moving observer).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../app/app_state.dart';
import '../../core/home_observer.dart';
import '../app.dart';
import '../design/app_surfaces.dart' show showAppToast;
import '../design/app_symbols.dart';
import '../map/coverage_map.dart' show CoverageMap;
import '../map/overlays/mini_map_credit.dart';
import '../map/region_center.dart';

/// The lead paragraph.
const String homeObserverLead =
    'Leave this phone at home, plugged in, next to your radio, and it works as a fixed observer: everything your radio '
    'hears is shared from the spot you place here, and the website shows it on the Observers layer.';

/// What turning it on does, said before the button.
const String homeObserverWhileOn =
    'While it is on: the screen stays awake (keep MeshSonar open and the phone charging), the radio is reconnected by '
    'itself if it drops, and every 5 minutes the phone tells the server it is still listening. Packets are shared from '
    'this position, never with your moving position.';

/// What the position choice means.
const String homeObserverPositionHelp =
    'The server keeps the exact spot for its analysis. The public map shows the choice you make here.';

class HomeObserverScreen extends StatefulWidget {
  /// Draw map tiles (tests switch them off: no network).
  final bool? showTiles;
  const HomeObserverScreen({super.key, this.showTiles});

  @override
  State<HomeObserverScreen> createState() => _HomeObserverScreenState();
}

class _HomeObserverScreenState extends State<HomeObserverScreen> {
  LatLng? _pin;
  HomeLocationPublic _public = HomeLocationPublic.rounded1km;
  bool _busy = false;
  String? _result;
  bool _seeded = false;
  final _map = MapController();

  bool get _tiles => widget.showTiles ?? CoverageMap.tilesByDefault;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    final s = AppScope.read(context);
    final h = s.settings.homeObserver;
    if (h != null) {
      _pin = LatLng(h.lat, h.lon);
      _public = h.locationPublic;
    }
    if (s.keyApproved) unawaited(s.refreshHomeObserverStatus());
  }

  LatLng _center(AppState s) => _pin ?? idleMapPosition(s) ?? viewedRegionCenter(s) ?? const LatLng(39.96, -83.0);

  void _useMyLocation(AppState s) {
    final f = s.phoneFix;
    if (f == null) {
      showAppToast(context, 'No position yet. Tap the map where the radio sits instead.');
      return;
    }
    final p = LatLng(f.fix.lat, f.fix.lon);
    setState(() => _pin = p);
    try {
      _map.move(p, 15);
    } catch (_) {}
  }

  Future<void> _turnOn(AppState s) async {
    final p = _pin;
    if (p == null || !HomeObserverConfig.validPosition(p.latitude, p.longitude)) {
      showAppToast(context, 'Place the observer on the map first.');
      return;
    }
    setState(() {
      _busy = true;
      _result = null;
    });
    final o = await s.startHomeObserver(p.latitude, p.longitude, _public);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = o == HomeCallOutcome.ok ? 'Home observer is on. The server has your position.' : homeCallText(o);
    });
  }

  Future<void> _turnOff(AppState s) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final o = await s.stopHomeObserver();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = o == HomeCallOutcome.ok
          ? 'Home observer is off. The server no longer shows a home position.'
          : 'Home observer is off on this phone. ${homeCallText(o)}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final on = s.homeObserverActive;
    final saved = s.settings.homeObserver;
    final moved = saved != null && _pin != null && (saved.lat != _pin!.latitude || saved.lon != _pin!.longitude || saved.locationPublic != _public);
    return Scaffold(
      appBar: AppBar(title: const Text('Home observer')),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const Key('home-observer-list'),
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.xl),
          children: [
            Text(homeObserverLead, style: t.textTheme.bodyLarge),
            const SizedBox(height: Gap.m),
            _StatusCard(state: s, on: on),
            const SizedBox(height: Gap.l),
            Semantics(header: true, child: Text('Where the radio sits', style: t.textTheme.titleMedium)),
            const SizedBox(height: Gap.xs),
            Text('Tap the map to place it.', style: t.textTheme.bodySmall),
            const SizedBox(height: Gap.s),
            _mapBox(context, s),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('home-observer-use-location'),
                onPressed: () => _useMyLocation(s),
                icon: const Icon(Icons.my_location),
                label: const Text('Use where this phone is now'),
              ),
            ),
            const SizedBox(height: Gap.s),
            Semantics(header: true, child: Text('On the public map', style: t.textTheme.titleMedium)),
            const SizedBox(height: Gap.xs),
            SegmentedButton<HomeLocationPublic>(
              key: const Key('home-observer-public'),
              showSelectedIcon: false,
              segments: [
                for (final p in HomeLocationPublic.values) ButtonSegment(value: p, label: Text(p.label)),
              ],
              selected: {_public},
              onSelectionChanged: _busy ? null : (v) => setState(() => _public = v.first),
            ),
            const SizedBox(height: Gap.xs),
            Text(homeObserverPositionHelp, style: t.textTheme.bodySmall),
            const SizedBox(height: Gap.l),
            Text(homeObserverWhileOn, style: t.textTheme.bodyMedium),
            if (!s.settings.telemetryEnabled) ...[
              const SizedBox(height: Gap.s),
              Text('"Share what my radio hears" is off. Turning on Home observer turns it back on.',
                  key: const Key('home-observer-sharing-off'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
            ],
            const SizedBox(height: Gap.m),
            if (!on || moved)
              FilledButton.icon(
                key: const Key('home-observer-on'),
                onPressed: _busy || _pin == null || !s.keyApproved ? null : () => _turnOn(s),
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.home_work_outlined),
                label: Text(on ? 'Save the new position' : 'Turn on Home observer'),
              ),
            if (on) ...[
              const SizedBox(height: Gap.s),
              OutlinedButton(
                key: const Key('home-observer-off'),
                onPressed: _busy ? null : () => _turnOff(s),
                child: const Text('Turn off Home observer'),
              ),
            ],
            if (!s.keyApproved)
              Padding(
                padding: const EdgeInsets.only(top: Gap.s),
                child: Text(homeCallText(HomeCallOutcome.noKey), key: const Key('home-observer-needs-key'), style: t.textTheme.bodySmall),
              ),
            if (_result != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.s),
                child: Semantics(liveRegion: true, child: Text(_result!, key: const Key('home-observer-result'))),
              ),
          ],
        ),
      ),
    );
  }

  Widget _mapBox(BuildContext context, AppState s) {
    final mc = MeshSonarColors.of(context);
    final t = Theme.of(context);
    final pin = _pin;
    final pub = pin == null ? null : publicHomePosition(pin.latitude, pin.longitude, _public);
    return ClipRRect(
      borderRadius: BorderRadius.circular(Corners.small),
      child: SizedBox(
        height: 260,
        child: Semantics(
          container: true,
          label: pin == null
              ? 'Map. No home position yet. Tap to place it, or use where this phone is now.'
              : 'Map. Home position placed.',
          child: FlutterMap(
            key: const Key('home-observer-map'),
            mapController: _map,
            options: MapOptions(
              initialCenter: _center(s),
              initialZoom: pin == null ? 11 : 15,
              minZoom: 3,
              maxZoom: 18,
              backgroundColor: mc.mapBackground,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              onTap: _busy ? null : (_, p) => setState(() => _pin = p),
            ),
            children: [
              if (_tiles)
                TileLayer(
                  urlTemplate: CoverageMap.tileUrl,
                  userAgentPackageName: CoverageMap.userAgentPackageName,
                  maxNativeZoom: 19,
                  tileBuilder: (context, tile, _) => ColorFiltered(colorFilter: ColorFilter.matrix(mc.tileMatrix), child: tile),
                ),
              if (pin != null && pub != null && _public == HomeLocationPublic.rounded1km)
                CircleLayer(circles: [
                  CircleMarker(
                    point: LatLng(pub.lat, pub.lon),
                    radius: 600,
                    useRadiusInMeter: true,
                    color: t.colorScheme.primary.withValues(alpha: 0.15),
                    borderColor: t.colorScheme.primary,
                    borderStrokeWidth: 1.5,
                  ),
                ]),
              if (pin != null)
                MarkerLayer(markers: [
                  Marker(
                    point: pin,
                    width: 32,
                    height: 32,
                    child: AppSymbolIcon(AppSymbols.locationFill, key: const Key('home-observer-pin'), color: mc.beacon, size: 32, scaleWithText: false),
                  ),
                ]),
              const MiniMapCredit(),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final AppState state;
  final bool on;
  const _StatusCard({required this.state, required this.on});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final svc = state.homeObserverService;
    final st = svc.status;
    final lines = <String>[
      on ? 'On' : 'Off',
      if (on) state.connected ? 'Radio connected; heartbeat every 5 minutes.' : 'Radio not connected. It reconnects by itself when it can.',
      if (st != null && st.packets24h != null) 'Packets heard in the last 24 h: ${st.packets24h}',
      if (st != null && st.lastHeartbeatAt != null) 'Last heartbeat: ${_ago(st.lastHeartbeatAt!, state.services.clock().toUtc())}',
      if (st != null && st.lastPacketAt != null) 'Last packet: ${_ago(st.lastPacketAt!, state.services.clock().toUtc())}',
      if (st != null) st.fixed ? 'The server lists this phone as a fixed (home) observer.' : 'The server lists this phone as a moving observer.',
      if (st == null && svc.lastOutcome != null && svc.lastOutcome != HomeCallOutcome.ok) homeCallText(svc.lastOutcome!),
    ];
    return Card(
      key: const Key('home-observer-status'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(on ? Icons.sensors : Icons.sensors_off, color: on ? t.colorScheme.primary : t.colorScheme.outline),
              const SizedBox(width: Gap.s),
              Expanded(child: Text(lines.first, style: t.textTheme.titleMedium)),
              IconButton(
                key: const Key('home-observer-refresh'),
                tooltip: 'Refresh',
                onPressed: state.keyApproved ? () => unawaited(state.refreshHomeObserverStatus()) : null,
                icon: const Icon(Icons.refresh),
              ),
            ]),
            for (final l in lines.skip(1)) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(l, style: t.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }

  static String _ago(DateTime at, DateTime now) {
    final d = now.difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 48) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }
}
