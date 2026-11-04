// Ping and trace results (chat plan 4.8). A person is pinged with a route discovery (CMD 52: fresh route out and back plus the
// round trip, floods); a repeater, room or sensor with a trace along the saved route (CMD 36, signal at every hop). The sheet
// shows sending (with the wait), the result, or "no reply" in words, and writes every outcome to `ping_results` and the
// contact's last ping. Uses showAppSheet at detent 0.45.
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';

import '../../chat/contact_manager.dart';
import '../../chat/models.dart';
import '../../radio/path_tools.dart';
import '../../radio/tools/ping_tool.dart';
import '../../radio/tools/radio_tools.dart';
import '../../radio/tools/trace_tool.dart' show TraceStop;
import '../contacts/contact_widgets.dart' show contactTypeLabel;
import '../contacts/route_nodes.dart';
import '../design/app_surfaces.dart';
import '../design/app_type.dart';
import '../design/hop_chain.dart';
import '../design/tokens.dart';

const String _airtimeKey = 'ping_airtime_ack';

/// "1.8 s" / "420 ms".
String formatRtt(int ms) => ms < 950 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(1)} s';

/// The headline of a result: "Reply in 1.8 s" or the failure in words.
String pingHeadline(PingResult r) => switch (r.status) {
      PingStatus.ok => r.rttMs == null ? 'Reply received' : 'Reply in ${formatRtt(r.rttMs!)}',
      PingStatus.noReply => 'No reply${r.waitedMs == null ? '' : ' after ${(r.waitedMs! / 1000).round()} s'}',
      PingStatus.unsupported => 'Not supported',
      PingStatus.notConnected => 'Radio not connected',
      PingStatus.tooSoon => 'Wait a moment',
      PingStatus.refused => 'The radio said no',
      PingStatus.invalid => 'Nothing to send',
    };

/// The sentence under the headline for a failure.
String pingFailureBody(PingResult r) => switch (r.status) {
      PingStatus.noReply => 'Not heard. Out of range, route out of date, or the radio is busy.',
      PingStatus.unsupported => 'This radio\'s firmware cannot search for a route. Update the radio\'s firmware to use Ping.',
      PingStatus.notConnected => 'Connect your radio to ping.',
      PingStatus.tooSoon => r.detail ?? 'A ping just ran. Try again in a few seconds.',
      PingStatus.refused => r.detail ?? 'The radio did not take the request.',
      PingStatus.invalid => r.detail ?? 'There is nothing to send.',
      PingStatus.ok => '',
    };

/// What the sheet gives back: the route to adopt when the person tapped "Use this route".
class PingSheetOutcome {
  final PathRoute? useRoute;
  const PingSheetOutcome(this.useRoute);
}

/// Pings [contact]. First time ever: an action sheet says it uses airtime. Returns the route picked with "Use this route".
Future<PingSheetOutcome?> showPingSheet(
  BuildContext context, {
  required Contact contact,
  required ContactManager manager,
  RadioTools? tools,
  bool directOnly = false,
  int hashSize = 1,
  Future<void> Function(PathRoute route)? onUseRoute,
}) async {
  final t = tools ?? radioToolsOf(context);
  final db = manager.store.db;
  if (db.setting(_airtimeKey) == null) {
    final go = await showAppConfirm(context,
        title: 'Ping uses radio airtime',
        message: 'It sends a short message through the mesh and times the reply.',
        confirmLabel: 'Ping',
        confirmKey: const Key('ping-airtime-confirm'));
    if (!go || !context.mounted) return null;
    db.putSetting(_airtimeKey, '1');
  }
  if (!context.mounted) return null;
  return showAppSheet<PingSheetOutcome>(
    context,
    detents: const [0.45, 0.92],
    builder: (ctx, controller) => PingResultBody(
      controller: controller,
      contact: contact,
      manager: manager,
      tools: t,
      directOnly: directOnly,
      hashSize: hashSize,
      onUseRoute: onUseRoute,
    ),
  );
}

/// Long press on the Ping tile: Ping, Direct only (the node's own radio range, no repeater in between) and the hash size a
/// ID size a direct or unrouted trace carries (1, 2 or 3 bytes). Each choice runs the ping sheet with those parameters.
Future<PingSheetOutcome?> showPingOptions(
  BuildContext context, {
  required Contact contact,
  required ContactManager manager,
  RadioTools? tools,
  Future<void> Function(PathRoute route)? onUseRoute,
}) async {
  final pick = await showAppActionSheet<(bool, int)>(
    context,
    title: 'Ping ${contact.displayName}',
    message: 'Direct only skips every repeater. Longer IDs tell nearby repeaters apart more reliably.',
    sheetKey: const Key('ping-options'),
    actions: const [
      AppAction('Ping', (false, 1), key: Key('ping-opt-normal')),
      AppAction('Direct only', (true, 1), key: Key('ping-opt-direct')),
      AppAction('Direct only, 2-byte IDs', (true, 2), key: Key('ping-opt-direct-2')),
      AppAction('Direct only, 3-byte IDs', (true, 3), key: Key('ping-opt-direct-3')),
    ],
  );
  if (pick == null || !context.mounted) return null;
  return showPingSheet(context,
      contact: contact, manager: manager, tools: tools, directOnly: pick.$1, hashSize: pick.$2, onUseRoute: onUseRoute);
}

class PingResultBody extends StatefulWidget {
  final ScrollController controller;
  final Contact contact;
  final ContactManager manager;
  final RadioTools? tools;
  final bool directOnly;
  final int hashSize;
  final Future<void> Function(PathRoute route)? onUseRoute;
  const PingResultBody({
    super.key,
    required this.controller,
    required this.contact,
    required this.manager,
    required this.tools,
    this.directOnly = false,
    this.hashSize = 1,
    this.onUseRoute,
  });
  @override
  State<PingResultBody> createState() => _PingResultBodyState();
}

class _PingResultBodyState extends State<PingResultBody> {
  PingResult? _result;
  bool _running = false;
  int _waitSeconds = 0;
  Timer? _tick;
  bool _forceDiscovery = false;

  Contact get _c => widget.manager.store.contacts.get(widget.manager.radioId ?? '', widget.contact.publicKey) ?? widget.contact;
  bool get _person => widget.contact.type == ContactType.companion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _run({bool discovery = false}) async {
    final tools = widget.tools;
    if (_running) return;
    _forceDiscovery = discovery;
    setState(() {
      _running = true;
      _result = null;
      _waitSeconds = 0;
    });
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _waitSeconds++);
    });
    final PingResult r;
    if (tools == null || !widget.manager.connected) {
      r = PingResult(kind: PingMethod.discovery, status: PingStatus.notConnected, at: DateTime.now());
    } else if (_person || discovery) {
      r = await tools.ping.discover(_c.publicKey);
    } else {
      final route = decodePath(_c.outPathLen, _c.outPath ?? const []);
      final known = [
        for (final k in widget.manager.store.contacts.list(widget.manager.radioId ?? '')) k
      ];
      r = await tools.ping.trace(
        keyHex: _c.publicKey,
        name: _c.displayName,
        route: route,
        directOnly: widget.directOnly,
        hashSize: widget.hashSize,
        known: [for (final k in known) if (k.type == ContactType.repeater || k.type == ContactType.room) TraceStopOf.of(k)],
      );
    }
    _tick?.cancel();
    if (!mounted) return;
    _record(r);
    setState(() {
      _running = false;
      _result = r;
    });
  }

  void _record(PingResult r) {
    if (r.status == PingStatus.tooSoon || r.status == PingStatus.notConnected || r.status == PingStatus.unsupported) return;
    widget.manager.recordPing(
      _c.publicKey,
      kind: switch (r.kind) { PingMethod.discovery => 'discovery', PingMethod.trace => 'trace', PingMethod.zeroHop => 'zerohop' },
      ok: r.ok,
      rttMs: r.rttMs,
      hops: r.repeaters,
      snr: r.hopSnrDb,
      out: r.outRoute?.text,
      back: r.backRoute?.text,
      failReason: r.failReason,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final r = _result;
    final repeaters = widget.manager.store.contacts.list(widget.manager.radioId ?? '');
    final scaleBig = MediaQuery.textScalerOf(context).scale(1.0) > 1.3;
    final route = r?.outRoute;
    final children = <Widget>[];
    if (_running) {
      final est = _person || _forceDiscovery ? 'up to 45 s' : 'up to 12 s';
      children.addAll([
        const SizedBox(height: Gap.l),
        const Center(child: CupertinoActivityIndicator(radius: 14)),
        const SizedBox(height: Gap.m),
        Text('Sending…', key: const Key('ping-sending'), textAlign: TextAlign.center, style: AppType.headline.copyWith(color: c.textPrimary)),
        Text('Waiting $_waitSeconds s ($est)', textAlign: TextAlign.center, style: AppType.footnote.copyWith(color: c.textMuted)),
      ]);
    } else if (r != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: Gap.s, bottom: Gap.m),
        child: Column(children: [
          Semantics(
            liveRegion: true,
            child: Text(pingHeadline(r), key: const Key('ping-headline'), textAlign: TextAlign.center, style: AppType.num(28).copyWith(color: r.ok ? c.textPrimary : c.warning)),
          ),
          if (!r.ok) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(pingFailureBody(r), key: const Key('ping-failure'), textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: c.textMuted))),
        ]),
      ));
      if (r.ok) {
        final out = routeNodes(targetName: _c.displayName, route: route ?? decodePath(_c.outPathLen, _c.outPath ?? const []), repeaters: repeaters, snr: r.hopSnrDb);
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: Gap.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Route out', style: AppType.footnote.copyWith(color: c.textMuted)),
            const SizedBox(height: Gap.xs),
            HopChain(key: const Key('ping-route-out'), nodes: out, semanticsLabel: describeHopChain(out, prefix: 'Route out')),
            if (r.backRoute != null && r.kind == PingMethod.discovery) ...[
              const SizedBox(height: Gap.m),
              Text('Route back', style: AppType.footnote.copyWith(color: c.textMuted)),
              const SizedBox(height: Gap.xs),
              Builder(builder: (_) {
                final back = routeNodes(targetName: _c.displayName, route: r.backRoute, repeaters: repeaters, youLabel: _c.displayName);
                final rev = [for (var i = 0; i < back.length; i++) back[i]];
                return HopChain(key: const Key('ping-route-back'), nodes: [rev.first, ...rev.sublist(1, rev.length - 1), const HopNode('You')], semanticsLabel: describeHopChain([rev.first, ...rev.sublist(1, rev.length - 1), const HopNode('You')], prefix: 'Route back'));
              }),
            ],
            if (r.hopSnrDb.isNotEmpty) ...[
              const SizedBox(height: Gap.m),
              Text('Signal at each repeater: ${r.hopSnrDb.map((s) => '${s >= 0 ? '+' : ''}${s.toStringAsFixed(1)}').join('  ')} dB',
                  key: const Key('ping-snr'), style: AppType.subhead.copyWith(color: c.textMuted)),
            ],
          ]),
        ));
      }
    }
    final canUse = r != null && r.ok && r.kind == PingMethod.discovery && r.outRoute != null && !r.outRoute!.isEmpty && widget.onUseRoute != null;
    final buttons = <Widget>[
      if (canUse) _btn('ping-use-route', 'Use this route', () async {
            final nav = Navigator.of(context);
            await widget.onUseRoute!(r.outRoute!);
            if (mounted) nav.pop(PingSheetOutcome(r.outRoute));
          }),
      if (r != null && !r.ok && r.status == PingStatus.noReply && !(_person || _forceDiscovery) && widget.manager.connected)
        _btn('ping-search-wider', 'Search wider', () => _run(discovery: true)),
      if (r != null && r.status != PingStatus.unsupported && r.status != PingStatus.notConnected) _btn('ping-again', 'Ping again', () => _run(discovery: _forceDiscovery)),
      _btn('ping-close', 'Close', () => Navigator.of(context).pop()),
    ];
    return AppSheetScaffold(
      controller: widget.controller,
      title: 'Ping ${_c.displayName}',
      children: [
        Text(contactTypeLabel(_c.type), textAlign: TextAlign.center, style: AppType.footnote.copyWith(color: c.textMuted)),
        ...children,
        const SizedBox(height: Gap.s),
        if (scaleBig || buttons.length > 2)
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: buttons)
        else
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final b in buttons) Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.xs), child: b)]),
        const SizedBox(height: Gap.l),
      ],
    );
  }

  Widget _btn(String key, String label, VoidCallback onTap) {
    final c = AppColors.of(context);
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        key: Key(key),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Hit.minAndroid, minWidth: Hit.minAndroid),
            child: Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s), child: Text(label, style: AppType.body.copyWith(color: c.accent)))),
          ),
        ),
      ),
    );
  }
}

/// TraceStop from a chat contact (name, key, position).
// ignore: avoid_classes_with_only_static_members
class TraceStopOf {
  static TraceStop of(Contact k) => TraceStop(name: k.displayName, keyHex: k.publicKey, lat: k.lat, lon: k.lon);
}
