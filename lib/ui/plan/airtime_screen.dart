// Plan > Airtime and load. The calculator (time on air for any radio setting and packet, a flood across N relays, the
// repeater duty cycle) runs on the phone with no network: lib/core/plan/airtime_calc.dart, a port of the website's
// src/lib/tools/airtime.ts verified against numbers generated from it. The live channel load (decoded airtime per
// observer-hour over the last 24 hours) and the what-if come from the region's `airtime-load` endpoint; the last result is
// kept on disk, so reopening offline shows it labelled "as of". Read-only: nothing here talks to a radio.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../app/app_state.dart';
import '../../core/plan/airtime_calc.dart';
import '../../core/plan/plan_api.dart';
import '../../core/plan/plan_store.dart';
import '../../core/region_repeaters_api.dart';
import '../app.dart';
import 'plan_common.dart';

class AirtimeScreen extends StatefulWidget {
  /// Test seams.
  final PlanStore? store;
  final http.Client Function()? client;
  final Future<RegionRepeaters> Function(String baseUrl, String slug)? roster;
  const AirtimeScreen({super.key, this.store, this.client, this.roster});

  @override
  State<AirtimeScreen> createState() => _AirtimeScreenState();
}

enum _RadioSource { region, mine, us, custom }

class _AirtimeScreenState extends State<AirtimeScreen> {
  // ---- calculator
  _RadioSource _src = _RadioSource.us;
  AirRadio _radio = meshcoreUs;
  PayloadKind _kind = PayloadKind.group;
  double _chars = 40, _nameLen = 12, _hops = 2, _relays = 4, _custom = 60;
  int _hashSize = 1;
  bool _location = true, _transport = false;
  double _dutyPct = dutyCycleDefaultPct;

  // ---- live load
  PlanResult<AirtimeLoad>? _load;
  bool _loading = false;
  String? _selected;
  double? _meanNeighbours;
  int _rosterRepeaters = 0;

  // ---- what-if
  double _add = 0, _floodMax = 11, _advH = 12;

  late final PlanStore _store;
  bool _init = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    final s = AppScope.read(context);
    _store = widget.store ?? s.planStore;
    final p = s.viewingPreset;
    if (p != null) {
      _src = _RadioSource.region;
      _radio = AirRadio(sf: p.sf, bwKHz: p.bwKhz, cr: p.cr);
    }
    unawaited(_loadLoad(s));
  }

  AirtimeLoadApi _api(AppState s) => AirtimeLoadApi(s.planBaseUrl, _store, client: widget.client);

  Future<void> _loadLoad(AppState s) async {
    final api = _api(s);
    final stored = await api.stored();
    if (!mounted) return;
    setState(() {
      _loading = true;
      if (stored != null && _load == null) _load = stored;
    });
    final r = await api.load();
    if (!mounted) return;
    setState(() {
      _loading = false;
      // A failed refresh keeps the stored copy on screen (flagged), and only says so if there was nothing.
      if (r.ok || _load == null || !_load!.ok) _load = r;
      final d = _load?.data;
      if (d != null && (_selected == null || !d.observers.any((o) => o.id == _selected))) _selected = d.observers.isEmpty ? null : d.observers.first.id;
    });
    unawaited(_loadRoster(s));
  }

  Future<void> _loadRoster(AppState s) async {
    final slug = s.viewingRegion?.slug;
    if (slug == null) return;
    try {
      final fetch = widget.roster ?? (b, sl) => fetchRegionRepeaters(b, sl, client: widget.client?.call());
      final r = await fetch(s.planBaseUrl, slug);
      final rows = [for (final x in r.rows) if (x.role == 'repeater' && x.neighbours != null) x];
      if (!mounted || rows.isEmpty) return;
      setState(() {
        _rosterRepeaters = rows.length;
        _meanNeighbours = rows.fold<int>(0, (a, x) => a + x.neighbours!) / rows.length;
      });
    } catch (_) {
      // The what-if just says it needs the roster.
    }
  }

  void _useRadio(_RadioSource src, AirRadio r) => setState(() {
        _src = src;
        _radio = r;
      });

  PacketSpec get _spec => PacketSpec(_kind,
      chars: _chars.round(),
      nameLen: _nameLen.round(),
      withLocation: _location,
      customBytes: _custom.round(),
      hops: _hops.round(),
      hashSize: _hashSize,
      transport: _transport);

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return PlanPage(id: 'airtime', title: 'Airtime and load', children: [
      Text(
        'Time on air is exact for the frame size (Semtech formula, MeshCore\'s preamble). It runs on your phone, with no connection. '
        'Channel load below is what the region\'s observers decoded, so it is a floor.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: Gap.m),
      _calculator(context, s),
      _liveCard(context, s),
      _whatIfCard(context, s),
    ]);
  }

  // ---------------------------------------------------------------- calculator
  Widget _calculator(BuildContext context, AppState s) {
    final t = Theme.of(context);
    final preset = s.viewingPreset;
    final mine = s.selfInfo?.radio;
    final mineRadio = (mine?.sf != null && mine?.bwKhz != null && mine?.cr != null) ? AirRadio(sf: mine!.sf!, bwKHz: mine.bwKhz!, cr: mine.cr!) : null;
    final bws = {...bwOptions, 500.0, _radio.bwKHz}.toList()..sort();
    final pkt = packetBytes(_spec);
    final toa = timeOnAir(pkt.total, _radio);
    final flood = floodAirtime(_spec, _relays.round(), _radio);
    final delay = relayDelayWindow(pkt, radio: _radio);
    final perHour = toa.totalMs > 0 ? (_dutyPct / 100) * 3600000 / toa.totalMs : 0.0;
    return PlanCard(
      cardKey: const Key('airtime-calc'),
      title: 'Calculator',
      lead: 'Time on air at the radio setting you pick.',
      children: [
        Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
          if (preset != null)
            ChoiceChip(
              key: const Key('airtime-src-region'),
              label: Text('${s.viewingRegion?.name ?? 'Region'} preset'),
              selected: _src == _RadioSource.region,
              onSelected: (_) => _useRadio(_RadioSource.region, AirRadio(sf: preset.sf, bwKHz: preset.bwKhz, cr: preset.cr)),
            ),
          if (mineRadio != null)
            ChoiceChip(key: const Key('airtime-src-mine'), label: const Text('My radio'), selected: _src == _RadioSource.mine, onSelected: (_) => _useRadio(_RadioSource.mine, mineRadio)),
          ChoiceChip(key: const Key('airtime-src-us'), label: const Text('MeshCore US default'), selected: _src == _RadioSource.us, onSelected: (_) => _useRadio(_RadioSource.us, meshcoreUs)),
        ]),
        const SizedBox(height: Gap.m),
        Row(children: [
          Expanded(
            child: PlanDropdown<int>(
                id: 'airtime-sf', label: 'SF', value: _radio.sf, items: sfOptions, text: (v) => 'SF$v', onChanged: (v) => setState(() {
                      _radio = _radio.copyWith(sf: v);
                      _src = _RadioSource.custom;
                    })),
          ),
          const SizedBox(width: Gap.s),
          Expanded(
            child: PlanDropdown<double>(
                id: 'airtime-bw', label: 'Bandwidth', value: _radio.bwKHz, items: bws, text: (v) => '${v == v.roundToDouble() ? v.round() : v} kHz', onChanged: (v) => setState(() {
                      _radio = _radio.copyWith(bwKHz: v);
                      _src = _RadioSource.custom;
                    })),
          ),
          const SizedBox(width: Gap.s),
          Expanded(
            child: PlanDropdown<int>(
                id: 'airtime-cr', label: 'CR', value: _radio.cr, items: crOptions, text: (v) => '4/$v', onChanged: (v) => setState(() {
                      _radio = _radio.copyWith(cr: v);
                      _src = _RadioSource.custom;
                    })),
          ),
        ]),
        const SizedBox(height: Gap.m),
        Text('Packet', style: t.textTheme.titleSmall),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
          for (final (k, label) in const [
            (PayloadKind.ack, 'ACK'),
            (PayloadKind.group, 'Channel message'),
            (PayloadKind.direct, 'Direct message'),
            (PayloadKind.advert, 'Advert'),
            (PayloadKind.custom, 'Custom bytes'),
          ])
            ChoiceChip(key: Key('airtime-kind-${k.name}'), label: Text(label), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
        ]),
        if (_kind == PayloadKind.group || _kind == PayloadKind.direct)
          PlanSlider(id: 'airtime-chars', label: 'Characters sent', valueText: '${_chars.round()}', value: _chars, min: 0, max: 160, divisions: 160, onChanged: (v) => setState(() => _chars = v)),
        if (_kind == PayloadKind.advert) ...[
          PlanSlider(id: 'airtime-name', label: 'Node name length', valueText: '${_nameLen.round()} bytes', value: _nameLen, min: 0, max: 32, divisions: 32, onChanged: (v) => setState(() => _nameLen = v)),
          SwitchListTile(key: const Key('airtime-location'), contentPadding: EdgeInsets.zero, title: const Text('Includes position (8 bytes)'), value: _location, onChanged: (v) => setState(() => _location = v)),
        ],
        if (_kind == PayloadKind.custom)
          PlanSlider(id: 'airtime-custom', label: 'Payload bytes', valueText: '${_custom.round()}', value: _custom, min: 0, max: 184, divisions: 184, onChanged: (v) => setState(() => _custom = v)),
        PlanSlider(
            id: 'airtime-hops', label: 'Hops already in the path', valueText: '${_hops.round()}', value: _hops, min: 0, max: 30, divisions: 30, onChanged: (v) => setState(() => _hops = v)),
        PlanSegments<int>(
          label: 'Path hash size',
          segKey: const Key('airtime-hash'),
          selected: _hashSize,
          segments: const [ButtonSegment(value: 1, label: Text('1 B')), ButtonSegment(value: 2, label: Text('2 B')), ButtonSegment(value: 3, label: Text('3 B'))],
          onChanged: (v) => setState(() => _hashSize = v),
        ),
        SwitchListTile(key: const Key('airtime-transport'), contentPadding: EdgeInsets.zero, title: const Text('Transport-code route (+4 bytes)'), value: _transport, onChanged: (v) => setState(() => _transport = v)),
        const Divider(),
        Semantics(
          liveRegion: true,
          child: Column(key: const Key('airtime-result'), crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(fmtMs(toa.totalMs), key: const Key('airtime-toa'), style: numberStyle(context, size: 34)),
            Text('on air for one transmission of ${pkt.total} bytes', style: t.textTheme.bodySmall),
            const SizedBox(height: Gap.s),
            if (pkt.overLimit != null) PlanNote('${pkt.overLimit}. The radio would refuse this packet.', icon: Icons.warning_amber, warn: true),
            PlanFacts([
              ('Frame', '${pkt.header} header + ${pkt.transport} transport + ${pkt.pathLen} path length + ${pkt.path} path + ${pkt.payload} payload'),
              ('Preamble', '${toa.preambleSymbols.toStringAsFixed(2)} symbols, ${fmtMs(toa.preambleMs)}'),
              ('Payload', '${toa.payloadSymbols} symbols, ${fmtMs(toa.payloadMs)}'),
              ('Symbol time', '${toa.tsymMs.toStringAsFixed(3)} ms${toa.ldro ? ', low data rate optimise on' : ''}'),
            ]),
          ]),
        ),
        const Divider(),
        Text('One flood', style: t.textTheme.titleSmall),
        PlanSlider(
          id: 'airtime-relays',
          label: 'Repeaters that relay it once',
          valueText: '${_relays.round()}',
          value: _relays,
          min: 0,
          max: 20,
          divisions: 20,
          onChanged: (v) => setState(() => _relays = v),
        ),
        PlanFacts([
          ('Channel time for the whole flood', fmtMs(flood.totalMs)),
          ('Largest relay frame', '${flood.steps.last.bytes} bytes'),
          ('A repeater waits before relaying', 'up to ${fmtMs(delay.maxMs)}, ${fmtMs(delay.meanMs)} on average'),
        ]),
        const Divider(),
        Text('Repeater duty cycle', style: t.textTheme.titleSmall),
        PlanSlider(
          id: 'airtime-duty',
          label: 'Duty cycle (firmware 1.15 and later; default 50 %)',
          valueText: '${_dutyPct.round()} %',
          value: _dutyPct,
          min: 1,
          max: 100,
          divisions: 99,
          onChanged: (v) => setState(() => _dutyPct = v),
        ),
        PlanFacts([('Packets like this one per hour', perHour >= 10 ? '${perHour.round()}' : perHour.toStringAsFixed(1))]),
      ],
    );
  }

  // ---------------------------------------------------------------- live load
  Widget _liveCard(BuildContext context, AppState s) {
    final r = _load;
    final d = r?.data;
    return PlanCard(
      cardKey: const Key('airtime-live'),
      title: 'Channel load, last 24 hours',
      lead: 'Decoded time on air per observer, per hour.',
      children: [
        if (d == null && _loading) const Center(key: Key('airtime-loading'), child: Padding(padding: EdgeInsets.all(Gap.l), child: CircularProgressIndicator())),
        if (d == null && r != null && r.error != null) PlanError(r.error!, onRetry: () => unawaited(_loadLoad(s))),
        if (d != null) ...[
          if (r!.offlineAsOf != null) OfflineAsOf(r.offlineAsOf!),
          if (_loading && r.offlineAsOf != null) const PlanNote('Refreshing...', icon: Icons.sync),
          ..._liveBody(context, d),
        ],
        const SizedBox(height: Gap.s),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(key: const Key('airtime-refresh'), onPressed: _loading ? null : () => unawaited(_loadLoad(s)), icon: const Icon(Icons.refresh), label: const Text('Refresh')),
        ),
      ],
    );
  }

  List<Widget> _liveBody(BuildContext context, AirtimeLoad d) {
    final t = Theme.of(context);
    if (d.observers.isEmpty) {
      return [const PlanNote('No observer decoded a packet in the last 24 hours.', key: Key('airtime-none'))];
    }
    final busiest = d.observers.reduce((a, b) => b.peakPct > a.peakPct ? b : a);
    final flagged = d.observers.where((o) => o.hoursOver > 0).toList();
    final total = d.byType.fold<double>(0, (a, b) => a + b.airtimeS);
    return [
      Text(
        'The busiest observer-hour was ${fmtPct(busiest.peakPct, 2)} at ${busiest.name}. '
        '${flagged.isEmpty ? 'No observer crossed ${d.flagPct.round()} % in any hour.' : '${flagged.length} observer${flagged.length == 1 ? '' : 's'} crossed ${d.flagPct.round()} %.'}',
        key: const Key('airtime-summary'),
        style: t.textTheme.bodyMedium,
      ),
      const SizedBox(height: Gap.s),
      PlanFacts([
        ('Radio the load is counted at', 'SF${d.sf}, ${d.bwKHz} kHz, CR 4/${d.cr}'),
        ('On-air transmissions', '${d.transmissions}, ${fmtSeconds(total)} on air'),
        ('Observers heard', '${d.observers.length}'),
        ('Last hour', '${d.lastHourTransmissions} transmissions'),
      ]),
      if (d.truncated) const PlanNote('The network feed was cut off before the window was complete, so these figures are lower than the truth.', icon: Icons.warning_amber),
      const SizedBox(height: Gap.s),
      Text('By observer', style: t.textTheme.titleSmall),
      for (final o in d.observers.take(12))
        ListTile(
          key: Key('airtime-obs-${o.id}'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          selected: o.id == _selected,
          title: Text(o.name),
          subtitle: Text('mean ${fmtPct(o.meanPct, 2)}, busiest hour ${fmtPct(o.peakPct, 2)}${o.hoursOver > 0 ? ', ${o.hoursOver} h over ${d.flagPct.round()} %' : ''}'),
          trailing: o.hoursOver > 0 ? const Icon(Icons.flag_outlined, semanticLabel: 'over the flag line') : null,
          onTap: () => setState(() => _selected = o.id),
        ),
      const SizedBox(height: Gap.s),
      Text('What the airtime is', style: t.textTheme.titleSmall),
      for (final ty in d.byType.take(8))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(_typeLabel(ty.type))),
            Text('${total > 0 ? (100 * ty.airtimeS / total).toStringAsFixed(1) : '0'} %, ${ty.transmissions} tx'),
          ]),
        ),
      if (d.talkers.isNotEmpty) ...[
        const SizedBox(height: Gap.s),
        Text('Top talkers', style: t.textTheme.titleSmall),
        for (final k in d.talkers.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Expanded(child: Text(k.name ?? (k.key.startsWith('h:') ? 'Node ${k.key.substring(2)}' : '${k.key.substring(0, k.key.length < 8 ? k.key.length : 8)}...'))),
              Text('${fmtSeconds(k.airtimeS)}, ${k.transmissions} tx'),
            ]),
          ),
      ],
    ];
  }

  static String _typeLabel(String t) => const {
        'ADVERT': 'Adverts',
        'GRP_TXT': 'Channel text',
        'GRP_DATA': 'Channel data',
        'TXT_MSG': 'Direct text',
        'REQ': 'Requests',
        'RESPONSE': 'Responses',
        'ANON_REQ': 'Logins',
        'PATH': 'Path returns',
        'ACK': 'ACKs',
        'TRACE': 'Traces',
        'MULTIPART': 'Multipart',
        'CONTROL': 'Control (discovery)',
      }[t] ??
      t;

  // ---------------------------------------------------------------- what-if
  Widget _whatIfCard(BuildContext context, AppState s) {
    final d = _load?.data;
    final obs = d?.observers.where((o) => o.id == _selected).firstOrNull;
    final t = Theme.of(context);
    Widget body;
    if (d == null || obs == null) {
      body = const PlanNote('The projection starts from measured airtime, which is not available yet.', key: Key('airtime-whatif-needs'));
    } else if (obs.mix == null) {
      body = const PlanNote('This server did not send the airtime mix the projection needs.', key: Key('airtime-whatif-needs'));
    } else if (_meanNeighbours == null || _rosterRepeaters == 0) {
      body = const PlanNote('The projection needs the region\'s repeater list (how many neighbours each repeater hears), which has not loaded.', key: Key('airtime-whatif-needs'));
    } else {
      const noCap = 64, baseAdv = 12.0;
      final floodMax = _floodMax >= 11 ? noCap : _floodMax.round();
      final r = _rosterRepeaters;
      final links = _meanNeighbours! * r / 2;
      final base = projectLoad(obs.mix!, WhatIf(repeaters: r, links: links, addRepeaters: 0, floodMax: noCap, advertIntervalH: baseAdv, baselineAdvertIntervalH: baseAdv));
      final proj = projectLoad(obs.mix!, WhatIf(repeaters: r, links: links, addRepeaters: _add.round(), floodMax: floodMax, advertIntervalH: _advH, baselineAdvertIntervalH: baseAdv));
      final ratio = base.total > 0 ? proj.total / base.total : 1.0;
      final windowS = d.hours * 3600;
      final meanNow = base.total / windowS * 100, meanProj = proj.total / windowS * 100;
      final peakNow = obs.peakPct, peakProj = obs.peakPct * ratio;
      final pNow = alohaCollision(peakNow / 100) * 100, pProj = alohaCollision(peakProj / 100) * 100;
      String change(double a, double b) => (b - a).abs() < 1e-9 ? '-' : '${b > a ? '+' : '-'}${fmtPct((b - a).abs(), b < 10 ? 2 : 1)}';
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Projected channel load at ${obs.name}', style: t.textTheme.titleSmall),
        PlanSlider(
          id: 'airtime-add',
          label: 'Add repeaters',
          valueText: '+${_add.round()}',
          value: _add,
          min: 0,
          max: 60,
          divisions: 60,
          onChanged: (v) => setState(() => _add = v),
          hint: 'Today $r repeaters, ${_meanNeighbours!.toStringAsFixed(1)} neighbours each on average. Each relayed flood is repeated by x${proj.rho.toStringAsFixed(2)} as many neighbours.',
        ),
        PlanSlider(
          id: 'airtime-floodmax',
          label: 'flood.max (hops)',
          valueText: floodMax == noCap ? '64, no cap' : '$floodMax',
          value: _floodMax,
          min: 1,
          max: 11,
          divisions: 10,
          onChanged: (v) => setState(() => _floodMax = v),
        ),
        PlanSlider(
          id: 'airtime-advert',
          label: 'Flood advert interval',
          valueText: '${_advH.round()} h',
          value: _advH,
          min: 3,
          max: 48,
          divisions: 45,
          onChanged: (v) => setState(() => _advH = v),
          hint: 'Scales flood-advert airtime by ${baseAdv.round()}/${_advH.round()}; zero-hop adverts stay as measured.',
        ),
        Table(key: const Key('airtime-proj'), columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(2), 2: FlexColumnWidth(2), 3: FlexColumnWidth(2)}, children: [
          TableRow(children: [for (final h in const ['Measure', 'Today', 'Projected', 'Change']) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(h, style: t.textTheme.labelMedium))]),
          for (final (name, now, v) in [('Busiest hour', peakNow, peakProj), ('${d.hours}-hour mean', meanNow, meanProj), ('Collision odds, busiest hour', pNow, pProj)])
            TableRow(children: [
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(name)),
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(fmtPct(now, now < 10 ? 2 : 1))),
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(fmtPct(v, v < 10 ? 2 : 1), style: const TextStyle(fontWeight: FontWeight.w700))),
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(change(now, v))),
            ]),
        ]),
        const SizedBox(height: Gap.s),
        Text(
          'Collision odds use pure ALOHA, 1 - e^(-2G) with G the hour\'s utilization. It treats every transmission as audible to every other and ignores LoRa capture, '
          'so it is an upper-end planning figure, not a measurement. Neighbour counts come from the region\'s repeater list.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ]);
    }
    return PlanCard(
      cardKey: const Key('airtime-whatif'),
      title: 'Load what-if',
      lead: 'Projects ${obs == null ? 'an observer\'s' : '${obs.name}\'s'} load with more repeaters, a tighter flood.max or a slower advert interval. A direction and rough size, not a forecast.',
      children: [body],
    );
  }
}
