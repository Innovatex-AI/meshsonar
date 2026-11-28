// Build 78 (builder A), brief C.2: Overview, from GET /status (polled every 2 s while open and in front): battery, uptime,
// clock and its source, Wi-Fi network and signal, uplink state, firmware and board; memory and the mesh radio settings in
// a "Details" fold.
import 'package:flutter/material.dart';

import '../../core/msradio/msradio.dart';
import '../../core/time_format.dart' as tf;
import '../radio/inset_list.dart';
import 'ms_common.dart';

String _signalWords(int? rssi) {
  if (rssi == null) return '—';
  final w = rssi >= -60 ? 'Strong' : (rssi >= -70 ? 'Good' : (rssi >= -80 ? 'Fair' : 'Weak'));
  return '$w ($rssi dBm)';
}

String _battery(MsDevice? d) {
  if (d == null || (d.battPct == null && d.battMv == null)) return '—';
  final pct = d.battPct == null ? null : '${d.battPct} %';
  final v = d.battMv == null ? null : '${(d.battMv! / 1000).toStringAsFixed(2)} V';
  return [?pct, ?v].join(' · ');
}

String _clock(MsDevice? d) {
  if (d == null) return '—';
  if (d.clockSet == false || d.time == null) return 'Not set';
  final src = d.clockSource == null ? '' : ' (from ${d.clockSource})';
  return '${tf.shortDateTime(d.time)}$src';
}

class MsOverviewScreen extends StatelessWidget {
  final MsRadioController c;
  const MsOverviewScreen(this.c, {super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('ms-overview-screen'),
        appBar: AppBar(title: const Text('Overview')),
        body: MsLive<MsStatus>(
          c: c,
          every: kMsMinPoll,
          load: (api) => api.status(),
          builder: (context, live) {
            final s = live.data;
            final d = s.device, w = s.wifi, u = s.uplink, r = s.radio;
            return MsBody(listKey: const Key('ms-overview-list'), children: [
              if (live.refreshError != null) MsBanner('Not updated: ${live.refreshError}'),
              InsetGroup(header: 'Radio', rows: [
                InsetRow(title: 'Battery', value: _battery(d), chevron: false),
                InsetRow(title: 'Running for', value: msDuration(d?.uptimeS), chevron: false),
                InsetRow(title: 'Clock', value: _clock(d), chevron: false),
              ]),
              InsetGroup(header: 'Wi-Fi', rows: [
                InsetRow(title: 'Network', value: (w?.ssid?.isNotEmpty ?? false) ? w!.ssid! : '—', chevron: false),
                InsetRow(title: 'Signal', value: _signalWords(w?.rssi), chevron: false),
                if (w?.state != null) InsetRow(title: 'State', value: w!.state!, chevron: false),
                InsetRow(title: 'Address', value: w?.ip ?? c.state.address ?? '—', chevron: false),
              ]),
              InsetGroup(header: 'MeshSonar uplink', rows: [
                InsetRow(title: 'Uplink', value: u?.state ?? '—', chevron: false),
              ]),
              InsetGroup(header: 'Firmware', rows: [
                InsetRow(title: 'MeshSonar', value: d?.fw ?? c.fw.msVersion, chevron: false),
                InsetRow(title: 'MeshCore', value: d?.core ?? c.fw.coreVersion, chevron: false),
                InsetRow(title: 'Board', value: d?.model ?? d?.board ?? (c.fw.boardName.isEmpty ? '—' : c.fw.boardName), chevron: false),
              ]),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ExpansionTile(
                  key: const Key('ms-overview-details'),
                  title: const Text('Details'),
                  tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  children: [
                    InsetGroup(rows: [
                      InsetRow(title: 'Free memory', value: msBytes(d?.heapInternal), chevron: false),
                      InsetRow(title: 'Free PSRAM', value: msBytes(d?.psramFree), chevron: false),
                      if (r?.freqMhz != null) InsetRow(title: 'Mesh frequency', value: '${r!.freqMhz!.toStringAsFixed(3)} MHz', chevron: false),
                      if (r?.bwKhz != null) InsetRow(title: 'Bandwidth', value: '${r!.bwKhz} kHz', chevron: false),
                      if (r?.sf != null) InsetRow(title: 'Spreading factor', value: 'SF${r!.sf}', chevron: false),
                      if (r?.cr != null) InsetRow(title: 'Coding rate', value: '4/${r!.cr}', chevron: false),
                      if (r?.txDbm != null) InsetRow(title: 'Transmit power', value: '${r!.txDbm} dBm', chevron: false),
                      if (r?.contacts != null) InsetRow(title: 'Contacts', value: msCount(r!.contacts), chevron: false),
                    ]),
                  ],
                ),
              ),
            ]);
          },
        ),
      );
}
