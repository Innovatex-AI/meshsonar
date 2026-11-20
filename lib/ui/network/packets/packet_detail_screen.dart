// Packet detail (AZ-3.2), opened from the Packets list, from My radio, from "Decode a packet" and from a
// `…/packets/<hash>` link. Website twin: `/packets/:hash` (analyzer-api-contract.md route table).
//
// States: loading; ready from `/v1` (every field, bytes, inspector); ready from today's region read while `/v1` is not
// live (who heard it and the paths, no bytes: the screen says so, and uses the radio's bytes when the connected radio
// heard the same hash); offline with the stored copy ("Offline - as of"); offline with nothing stored; not found.
// A My radio packet opens with its local decode at once and asks the network in the background for
// "Also heard by the network: N observers".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/network_request.dart';
import '../../../core/v1/local_decoder.dart';
import '../../../core/v1/my_radio_packets.dart';
import '../../../core/v1/packets_api.dart';
import '../../../radio/tools/rx_log.dart';
import '../../design/app_surfaces.dart' show showAppToast;
import '../../design/state_views.dart';
import '../../design/app_symbols.dart';
import '../../region/region_common.dart' show RegionOfflineEmpty;
import 'packet_context.dart';
import 'packet_detail_body.dart';

/// Test seam for the share sheet.
Future<void> Function(String text)? packetShareOverride;

Future<void> openNetworkPacket(BuildContext context, {required String baseUrl, String? regionSlug, required String hash, PacketDetail? local}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => NetworkPacketScreen(baseUrl: baseUrl, regionSlug: regionSlug, hash: hash, local: local)));

class NetworkPacketScreen extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;
  final String hash;

  /// A packet decoded on the phone (My radio, pasted): shown at once; the network is asked about it in the background.
  final PacketDetail? local;

  /// Test seams.
  final PacketsApi? api;
  final RxLog? radioLog;
  final DateTime Function()? clock;
  const NetworkPacketScreen({super.key, required this.baseUrl, this.regionSlug, required this.hash, this.local, this.api, this.radioLog, this.clock});

  @override
  State<NetworkPacketScreen> createState() => _NetworkPacketScreenState();
}

class _NetworkPacketScreenState extends State<NetworkPacketScreen> {
  late final PacketsApi _api = widget.api ?? packetsApiFactory(widget.baseUrl);
  PacketDetailRead? _read;
  V1Error? _error;
  bool _loading = true;
  bool _loadingMore = false;
  List<LocalChannelKey> _keys = const [];
  List<MyRadioPacket> _radio = const [];

  bool get _localFirst => widget.local != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (!mounted) return;
    _keys = await packetHashtagKeys(context);
    if (!mounted) return;
    final log = widget.radioLog ?? packetRadioTools(context)?.rxLog;
    setState(() => _radio = radioHeard(log, widget.hash, hashtagKeys: _keys));
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _api.detail(widget.hash);
      if (!mounted) return;
      setState(() {
        _read = r;
        _loading = false;
      });
    } on V1Error catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _more() async {
    final r = _read;
    if (r == null || r.detail.observationsNext == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _api.observations(widget.hash, cursor: r.detail.observationsNext);
      if (!mounted) return;
      final seen = {for (final o in r.detail.observations) o.id};
      setState(() {
        _read = PacketDetailRead(
          r.detail.copyWith(observations: [...r.detail.observations, ...page.rows.where((o) => !seen.contains(o.id))], observationsNext: page.next, clearNext: page.next == null),
          sources: r.sources,
          nodeListTrusted: r.nodeListTrusted,
          nodeListReason: r.nodeListReason,
        );
      });
    } catch (_) {
      if (mounted) showAppToast(context, 'More observers did not load. Try again in a moment.');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  NetworkRequest get _request => NetworkRequest.packet(widget.hash, region: widget.regionSlug);

  Future<void> _share() async {
    final link = _request.toWebUri().toString();
    if (packetShareOverride != null) return packetShareOverride!(link);
    await SharePlus.instance.share(ShareParams(text: link, subject: 'MeshSonar packet ${widget.hash}'));
  }

  String? get _raw => widget.local?.raw ?? (_read?.detail.raw) ?? (_radio.isEmpty ? null : _radio.first.detail?.raw);

  @override
  Widget build(BuildContext context) {
    final raw = _raw;
    return Scaffold(
      key: const Key('network-packet-screen'),
      appBar: AppBar(
        title: Text(widget.local?.source == PacketSource.myRadio ? 'Packet (your radio)' : 'Packet'),
        actions: [
          if (raw != null)
            IconButton(
              key: const Key('packet-copy-hex'),
              tooltip: 'Copy the packet as hex',
              icon: const Icon(Icons.data_object),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: raw));
                showAppToast(context, 'Packet hex copied');
              },
            ),
          IconButton(key: const Key('packet-share'), tooltip: 'Share a link to this packet', icon: const Icon(Icons.ios_share), onPressed: _share),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final clock = widget.clock ?? DateTime.now;
    final web = _request.toWebUri();
    final heardByRadio = _radio.isEmpty
        ? null
        : (snr: _radio.first.entry.snrDb, rssi: _radio.first.entry.rssiDbm, at: _radio.first.entry.at);
    if (_localFirst) {
      final net = _read;
      return PacketDetailBody(
        d: widget.local!,
        clock: clock,
        web: web,
        cross: PacketCrossSource(
          networkObservers: net?.detail.observerCount,
          onOpenNetwork: net == null
              ? null
              : () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => NetworkPacketScreen(baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, hash: widget.hash, api: widget.api, radioLog: widget.radioLog, clock: widget.clock))),
        ),
      );
    }
    if (_loading && _read == null) return const AppLoadingView(key: Key('packet-loading'), label: 'Loading the packet');
    final e = _error;
    if (_read == null && e != null) {
      // The radio heard it: show the radio's copy rather than an empty error.
      final mine = _radio.isEmpty ? null : _radio.first.detail;
      if (mine != null) {
        return PacketDetailBody(
          d: mine.copyWith(missing: [
            e.notFound ? 'The network has no record of this packet; this is what your radio heard.' : 'The network copy did not load (${e.message}); this is what your radio heard.',
            ...mine.missing,
          ]),
          clock: clock,
          web: web,
          onRetry: _load,
        );
      }
      if (e.offline) return ListView(children: [RegionOfflineEmpty(what: 'this packet', onRetry: _load)]);
      if (e.notFound) {
        return const AppEmptyView(
            key: Key('packet-not-found'), symbol: AppSymbols.globe, title: 'Packet not found', message: 'No observer on this server heard this packet, or it is older than 90 days.');
      }
      return AppErrorView(key: const Key('packet-error'), title: 'The packet did not load', message: e.message, onRetry: _load);
    }
    final r = _read!;
    return RefreshIndicator(
      onRefresh: _load,
      child: PacketDetailBody(
        d: r.detail,
        sources: r.sources,
        nodeListTrusted: r.nodeListTrusted,
        nodeListReason: r.nodeListReason,
        bytesFrom: r.detail.hasBytes || _radio.isEmpty ? null : _radio.first.detail,
        cross: PacketCrossSource(radio: heardByRadio),
        onLoadMoreObservations: _more,
        loadingMore: _loadingMore,
        onRetry: _load,
        web: web,
        clock: clock,
      ),
    );
  }
}
