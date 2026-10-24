// Native Live feed for one region: the website's `region-live` SSE stream as a scrolling packet list plus a small map of
// the repeaters (resolved hops) that carried recent packets. Battery-conscious: the connection is dropped when the app is
// backgrounded / the screen is off / the tab is hidden, and reopened on return. View-only, so safe while driving.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/live_stream.dart';
import '../../core/region_packets_api.dart' show packetTypeName, packetRouteName;
import '../map/coverage_map.dart';
import 'region_common.dart';

class LivePanel extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;

  /// Test seam; defaults to a [LiveStream] on [baseUrl].
  final LiveStream? stream;
  const LivePanel({super.key, required this.baseUrl, required this.regionSlug, this.stream});

  @override
  State<LivePanel> createState() => _LivePanelState();
}

class _LivePanelState extends State<LivePanel> with WidgetsBindingObserver {
  static const _maxRows = 100;
  static const _maxHopPoints = 60;

  late final LiveStream _stream;
  StreamSubscription<LiveEvent>? _evSub;
  StreamSubscription<LiveConnState>? _stSub;
  final List<LivePacket> _rows = []; // newest first
  final Map<String, LiveHop> _hops = {}; // recent repeater positions, insertion ordered
  LiveConnState _conn = LiveConnState.connecting;
  int? _online;
  bool _foreground = true;
  bool _visible = true;
  bool _showMap = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stream = widget.stream ?? LiveStream(Uri.parse(widget.baseUrl));
    _evSub = _stream.events.listen(_onEvent);
    _stSub = _stream.states.listen((s) {
      if (mounted) setState(() => _conn = s);
    });
    _stream.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = TickerMode.valuesOf(context).enabled; // false when an enclosing tab/route is hidden
    if (v != _visible) {
      _visible = v;
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    if (_foreground && _visible) {
      _stream.resume();
    } else {
      _stream.pause();
    }
  }

  void _onEvent(LiveEvent e) {
    if (!mounted) return;
    setState(() {
      switch (e) {
        case LivePacketEvent(:final packet):
          final i = _rows.indexWhere((r) => r.hash == packet.hash);
          if (i >= 0) {
            _rows[i] = _rows[i].merged(packet);
          } else {
            _rows.insert(0, packet);
            if (_rows.length > _maxRows) _rows.removeLast();
          }
          for (final h in packet.hops) {
            _hops.remove(h.key);
            _hops[h.key] = h;
          }
          while (_hops.length > _maxHopPoints) {
            _hops.remove(_hops.keys.first);
          }
        case LiveStatusEvent(:final observersOnline):
          _online = observersOnline;
        case LiveHeartbeatEvent():
          break;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _evSub?.cancel();
    _stSub?.cancel();
    if (widget.stream == null) _stream.dispose();
    super.dispose();
  }

  (String, Color) _statusLabel(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (_conn) {
      LiveConnState.live => (_online == null ? 'Live' : 'Live, $_online observers online', cs.primary),
      LiveConnState.connecting => ('Connecting', cs.outline),
      LiveConnState.reconnecting => ('Reconnecting', cs.error),
      LiveConnState.paused => ('Paused (app in background)', cs.outline),
      LiveConnState.idle => ('Idle', cs.outline),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (label, color) = _statusLabel(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(
            children: [
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(label, key: const Key('live-status'), style: Theme.of(context).textTheme.labelLarge)),
              if (_hops.isNotEmpty)
                IconButton(
                  key: const Key('live-map-toggle'),
                  tooltip: _showMap ? 'Hide map' : 'Show map',
                  icon: Icon(_showMap ? Icons.map : Icons.map_outlined),
                  onPressed: () => setState(() => _showMap = !_showMap),
                ),
            ],
          ),
        ),
        if (_showMap && _hops.isNotEmpty) SizedBox(height: 150, child: _MiniMap(hops: _hops.values.toList())),
        Expanded(
          child: _rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _conn == LiveConnState.paused ? 'Live feed is paused while the app is in the background.' : 'Waiting for packets. New traffic appears here as observers hear it.',
                      key: const Key('live-empty'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  key: const Key('live-list'),
                  itemCount: _rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _LiveRow(packet: _rows[i]),
                ),
        ),
      ],
    );
  }
}

class _LiveRow extends StatelessWidget {
  final LivePacket packet;
  const _LiveRow({required this.packet});

  @override
  Widget build(BuildContext context) {
    final snrs = packet.observations.map((o) => o.snrDb).whereType<double>();
    final best = snrs.isEmpty ? null : snrs.reduce((a, b) => a > b ? a : b);
    final minHops = packet.observations.isEmpty ? null : packet.observations.map((o) => o.hops).reduce((a, b) => a < b ? a : b);
    final n = packet.observations.length;
    return ListTile(
      dense: true,
      title: Text(packetTypeName(packet.type)),
      subtitle: Text([
        packetRouteName(packet.route),
        '$n observer${n == 1 ? '' : 's'}',
        if (minHops != null) '$minHops hop${minHops == 1 ? '' : 's'}',
        if (best != null) '${best.toStringAsFixed(1)} dB',
      ].join(' · ')),
      trailing: Text(agoText(packet.at)),
    );
  }
}

class _MiniMap extends StatelessWidget {
  final List<LiveHop> hops;
  const _MiniMap({required this.hops});

  @override
  Widget build(BuildContext context) {
    final pts = [for (final h in hops) LatLng(h.lat, h.lon)];
    final cs = Theme.of(context).colorScheme;
    final single = pts.length == 1;
    return FlutterMap(
      key: const Key('live-map'),
      options: MapOptions(
        initialCenter: pts.first,
        initialZoom: 10,
        initialCameraFit: single ? null : CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(24), maxZoom: 13),
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag),
      ),
      children: [
        TileLayer(urlTemplate: CoverageMap.tileUrl, userAgentPackageName: CoverageMap.userAgentPackageName, maxNativeZoom: 19),
        CircleLayer(circles: [
          for (final p in pts) CircleMarker(point: p, radius: 5, color: cs.primary.withValues(alpha: 0.8), borderColor: cs.onPrimary, borderStrokeWidth: 1),
        ]),
      ],
    );
  }
}
