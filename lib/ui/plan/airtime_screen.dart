// Plan > Airtime and load. The calculator (time on air for any radio setting and packet, a flood across N relays, the
// repeater duty cycle: how many such packets an hour a repeater may send) runs on the phone with no network:
// lib/core/plan/airtime_calc.dart, a port of the website's src/lib/tools/airtime.ts verified against numbers generated
// from it. Read-only: nothing here talks to a radio. The live channel load and the load what-if (the region's
// `airtime-load` endpoint) were removed in M0 (Nov 8 2026): no region served it. Channel load returns with the Analyze
// rebuild ("Traffic & airtime", phase A).
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/plan/airtime_calc.dart';
import '../app.dart';
import 'plan_common.dart';

class AirtimeScreen extends StatefulWidget {
  const AirtimeScreen({super.key});

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

  bool _init = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    final p = AppScope.read(context).viewingPreset;
    if (p != null) {
      _src = _RadioSource.region;
      _radio = AirRadio(sf: p.sf, bwKHz: p.bwKhz, cr: p.cr);
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
        'Time on air is exact for the frame size (Semtech formula, MeshCore\'s preamble). It runs on your phone, with no connection.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: Gap.m),
      _calculator(context, s),
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
}
