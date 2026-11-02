// Medium's content (Drive plan 4.5, 5.2) as a list of widgets for the panel's scroll view, in order: unsaved warning, location
// note, the ratio line with the Passenger switch, the 2x3 stat grid, "Heard last ping" (2 rows), then the list rows (antenna,
// ping settings, log, chat, map guide). WP3b finishes this content; this is the shell with every old footer function kept.
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../app/chat_wiring.dart';
import '../../../core/heard.dart' show haversineM;
import '../../../app/chat_controller.dart';
import '../../../core/model.dart';
import '../../../radio/radio_api.dart' show GeoFix;
import '../../chat/chat_drive_sheet.dart';
import '../../design/tokens.dart';
import '../../drive_stats.dart' show formatDuration;
import '../../location_status.dart';
import '../../theme.dart';
import '../../widgets.dart';
import '../drive_controls.dart';
import '../drive_live_stats.dart';
import '../ping_settings_sheet.dart';

double _distanceM(List<DrivePing> pings) {
  var d = 0.0;
  for (var i = 1; i < pings.length; i++) {
    d += haversineM(pings[i - 1].lat, pings[i - 1].lon, pings[i].lat, pings[i].lon);
  }
  return d;
}

class MediumContent {
  /// Rebuilds on every state change because the panel's builder does (the caller wraps it in a listener).
  static List<Widget> build(
    BuildContext context, {
    required AppState state,
    required DriveLiveStats liveStats,
    required GeoFix? fix,
    required bool passenger,
    required ValueChanged<bool> onPassenger,
    required VoidCallback openGuide,
  }) {
    final s = state;
    final t = Theme.of(context);
    final c = AppColors.fromTheme(t);
    final driving = s.driving;
    final pct = s.heardPercent;
    final session = s.currentSession;
    final elapsed = session == null ? null : s.services.clock().toUtc().difference(session.startedAt);
    final last = s.recentPings.isEmpty ? null : s.recentPings.first;
    final lastSnr = last == null ? null : bestSnr(last);
    final acc = fix?.accuracyM;
    final ready = liveStats.historyLoaded;
    final repeaters = <String>{for (final p in s.drivePings) for (final e in p.echoes) e.repeater}.length;

    Widget cell(String label, String value, Key key) => Expanded(
          child: Semantics(
            container: true,
            label: '$label: $value',
            excludeSemantics: true,
            child: SizedBox(
              height: 52,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, key: key, style: numberStyle(context, size: 22, weight: FontWeight.w600))),
                  const SizedBox(height: 2),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.textMuted)),
                ],
              ),
            ),
          ),
        );

    Widget row(IconData icon, String title, VoidCallback onTap, {Key? key}) => GestureDetector(
          key: key,
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(children: [
              Icon(icon, size: 20, color: c.textMuted),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 16))),
              Icon(Icons.chevron_right_rounded, color: c.textMuted),
            ]),
          ),
        );

    final heardRows = <Widget>[];
    if (last != null && last.kind == PingKind.tx) {
      final ech = [...last.echoes]..sort((a, b) => (b.snrDb ?? -99).compareTo(a.snrDb ?? -99));
      final seen = <String>{};
      for (final e in ech) {
        if (!seen.add(e.repeater)) continue;
        if (heardRows.length == 2) break;
        heardRows.add(SizedBox(
          height: 44,
          child: Row(children: [
            Expanded(child: Text(s.repeaterLabel(e.repeater), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16))),
            Text(e.snrDb == null ? '' : '${e.snrDb! > 0 ? '+' : ''}${e.snrDb!.toStringAsFixed(1)} dB', style: numberStyle(context, size: 14, weight: FontWeight.w500)),
          ]),
        ));
      }
    }

    return [
      if (s.unsavedCount > 0) Padding(padding: const EdgeInsets.only(bottom: 8), child: ErrorBanner('${s.unsavedCount} ping(s) not yet saved to this device. Retrying.')),
      if (s.locationNote != null && !driving) Padding(padding: const EdgeInsets.only(bottom: 8), child: LocationNoteBanner(state: s)),
      if (s.needsAntennaSetup && !driving) const Padding(padding: EdgeInsets.only(bottom: 8), child: AntennaSetupHint()),
      if (driving) ...[
        Row(children: [
          Expanded(
            child: Text(
              s.pingCount == 0 ? 'No pings yet' : '${s.heardCount} of ${s.pingCount} pings heard${pct == null ? '' : ' ($pct%)'}',
              key: const Key('medium-ratio'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          const Text('Passenger', style: TextStyle(fontSize: 15)),
          const SizedBox(width: 8),
          CupertinoSwitch(key: const Key('passenger-switch'), value: passenger, onChanged: onPassenger),
        ]),
        Text('Passenger keeps this open while the car moves', style: TextStyle(fontSize: 12, color: c.textMuted)),
        const SizedBox(height: 8),
        Row(children: [
          cell('Distance', s.units.distance(_distanceM(s.drivePings)), const Key('stat-distance')),
          cell('Elapsed', formatDuration(elapsed), const Key('stat-elapsed')),
          cell('Last SNR', last == null ? '—' : (last.heardNothing ? 'none' : (lastSnr == null ? '—' : '${lastSnr > 0 ? '+' : ''}${lastSnr.toStringAsFixed(1)} dB')), const Key('stat-snr')),
        ]),
        Row(children: [
          cell('New cells', ready ? '${liveStats.newCells}' : '—', const Key('stat-cells')),
          cell('Repeaters', '$repeaters', const Key('stat-repeaters')),
          cell('GPS accuracy', fix == null ? 'No fix' : (acc == null ? '—' : '±${s.units.shortLength(acc)}'), const Key('stat-gps')),
        ]),
        const Divider(height: 16),
        if (heardRows.isNotEmpty) ...[
          Text('HEARD LAST PING', style: TextStyle(fontSize: 12, letterSpacing: 0.6, color: c.textMuted)),
          ...heardRows,
          const Divider(height: 16),
        ],
      ],
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [AntennaChip(state: s), PingSettingsChip(state: s), LogButton(state: s)]),
      const SizedBox(height: 4),
      ValueListenableBuilder<ChatController?>(
        valueListenable: ChatWiring.controller,
        builder: (context, chat, _) => chat == null
            ? const SizedBox.shrink()
            : row(Icons.chat_bubble_outline_rounded, chat.unreadConversations > 0 ? 'Messages (${chat.unreadConversations} unread)' : 'Messages', () => showChatDriveSheet(context, chat), key: const Key('drive-chat')),
      ),
      row(Icons.help_outline_rounded, 'Map guide', openGuide, key: const Key('medium-guide')),
    ];
  }
}
