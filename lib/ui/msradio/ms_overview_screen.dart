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
                MsValueRow('Battery', _battery(d)),
                MsValueRow('Running for', msDuration(d?.uptimeS)),
                MsValueRow('Clock', _clock(d)),
              ]),
              InsetGroup(header: 'Wi-Fi', rows: [
                MsValueRow('Network', (w?.ssid?.isNotEmpty ?? false) ? w!.ssid! : '—'),
                MsValueRow('Signal', _signalWords(w?.rssi)),
                if (w?.state != null) MsValueRow('State', w!.state!),
                MsValueRow('Address', w?.ip ?? c.state.address ?? '—'),
              ]),
              InsetGroup(header: 'MeshSonar uplink', rows: [
                MsValueRow('Uplink', u?.state ?? '—'),
              ]),
              InsetGroup(header: 'Firmware', rows: [
                MsValueRow('MeshSonar', d?.fw ?? c.fw.msVersion),
                MsValueRow('MeshCore', d?.core ?? c.fw.coreVersion),
                MsValueRow('Board', d?.model ?? d?.board ?? (c.fw.boardName.isEmpty ? '—' : c.fw.boardName)),
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
                      MsValueRow('Free memory', msBytes(d?.heapInternal)),
                      MsValueRow('Free PSRAM', msBytes(d?.psramFree)),
                      if (r?.freqMhz != null) MsValueRow('Mesh frequency', '${r!.freqMhz!.toStringAsFixed(3)} MHz'),
                      if (r?.bwKhz != null) MsValueRow('Bandwidth', '${r!.bwKhz} kHz'),
                      if (r?.sf != null) MsValueRow('Spreading factor', 'SF${r!.sf}'),
                      if (r?.cr != null) MsValueRow('Coding rate', '4/${r!.cr}'),
                      if (r?.txDbm != null) MsValueRow('Transmit power', '${r!.txDbm} dBm'),
                      if (r?.contacts != null) MsValueRow('Contacts', msCount(r!.contacts)),
                    ]),
                  ],
                ),
              ),
            ]);
          },
        ),
      );
}
