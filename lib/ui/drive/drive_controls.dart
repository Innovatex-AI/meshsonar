// Drive-screen parts below (and on) the map: the stats strip, the status line with the next-ping indicator, the
// antenna chip, the log button, the drive-report card, the Start/Stop + Ping now buttons, the empty-map hint and
// the ping result flash. Shared by the Drive screen and the full-screen map.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/antenna_profile.dart';
import '../../core/model.dart';
import '../../core/units.dart';
import '../antenna_sheet.dart';
import '../connect_screen.dart';
import '../design/app_surfaces.dart';
import '../design/tokens.dart' show AppColors;
import '../ping_log_screen.dart' show openPingLog;
import '../region/region_switch_sheet.dart' show showNearestRegionsSheet;
import '../report/drive_report_screen.dart';
import '../theme.dart';

void openConnect(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen()));
}

/// Finished-dock hook point: "View drive report". The dock (and the mini bar) call this, never `openDriveReport` ad hoc.
Future<void> openFinishedDriveReport(BuildContext context, String sessionId) => openDriveReport(context, sessionId);

/// Asks "Stop this drive?" and, on confirm, stops it. The Start/Stop button and the mini bar both go through here.
Future<bool> confirmAndStopDrive(BuildContext context, AppState s) async {
  if (!await confirmStopDrive(context)) return false;
  unawaited(s.stopDrive());
  return true;
}

/// "Stop this drive?" so a bump in the car can't end a drive. An iOS action sheet: the red Stop drive row, then a
/// separate Keep driving (cancel). Returns true to stop; dismissing the sheet keeps driving.
Future<bool> confirmStopDrive(BuildContext context) async {
  final stop = await showAppActionSheet<bool>(
    context,
    title: 'Stop this drive?',
    message: 'Pings stop and the drive is saved on this phone. Start drive begins a new one.',
    actions: const [AppAction<bool>('Stop drive', true, destructive: true, key: Key('stop-drive-confirm'))],
    cancelLabel: 'Keep driving',
    cancelKey: const Key('stop-drive-keep'),
    sheetKey: const Key('stop-drive-dialog'),
  );
  return stop == true;
}

class LiveDot extends StatelessWidget {
  final Color color;
  const LiveDot({super.key, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    width: 14,
    height: 14,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8, spreadRadius: 1)],
    ),
  );
}

// ------------------------------------------------------------------------------------------------ antenna + log

/// The connected radio's antenna ("Roof mag-mount · 5.8 dBi · 1.8 m"); tap to change it before a drive. While driving
/// it is locked and shows what the drive records ("External · 5.8 dBi · 1.8 m"). A radio that hasn't been set up
/// shows [AntennaSetupHint] instead, and Start drive waits for it.
class AntennaChip extends StatelessWidget {
  final AppState state;
  const AntennaChip({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final recorded = s.currentSession?.antenna;
    final profile = s.antennaProfile;
    final String text;
    if (recorded != null) {
      text = recordedAntennaSummary(recorded, s.units);
    } else if (profile != null) {
      text = profile.summaryIn(s.units);
    } else {
      return s.needsAntennaSetup ? const AntennaSetupHint() : const SizedBox.shrink();
    }
    final locked = recorded != null;
    return DrivePanelRow(
      key: const Key('antenna-chip'),
      icon: locked ? Icons.lock_rounded : Icons.settings_input_antenna_rounded,
      label: 'Antenna',
      value: text,
      semanticsHint: locked ? 'Fixed for this drive' : 'Change this radio\'s antenna',
      onTap: locked ? null : () => showAntennaSheet(context),
    );
  }
}

/// One row of the Drive panel's list (build 76): icon, what it is, its current value, a chevron when it opens something.
/// 48 pt tall, the whole row is the tap target. Replaces the unlabelled chips ("Handheld · 5 ft" said nothing about being
/// the antenna) and the lone Log button.
class DrivePanelRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final String? semanticsHint;
  final VoidCallback? onTap;
  const DrivePanelRow({super.key, required this.icon, required this.label, this.value, this.semanticsHint, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.fromTheme(Theme.of(context));
    return Semantics(
      button: onTap != null,
      label: value == null ? label : '$label: $value',
      hint: semanticsHint,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Corners.small),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(children: [
            Icon(icon, size: 20, color: c.textMuted),
            const SizedBox(width: 12),
            // Label left, value right; at large text (or a long value) the value drops under the label instead of clipping.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  children: [
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                    if (value != null) Text(value!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: c.textMuted)),
                  ],
                ),
              ),
            ),
            if (onTap != null) Icon(Icons.chevron_right_rounded, color: c.textMuted) else const SizedBox(width: 4),
          ]),
        ),
      ),
    );
  }
}

/// Which MeshSonar region the phone is physically in right now (live, local awareness — see lib/core/
/// region_lookup.dart). Four states, each shown plainly rather than left blank:
///  - nothing yet (no cache, no fetch has ever answered): hidden, same convention as [AntennaChip]'s "nothing
///    to show" case;
///  - no GPS fix yet: "Locating…";
///  - a fix, but outside every known region's bbox: "Outside coverage";
///  - a fix inside a region: the region's code, with its full name (and, if the index itself may be stale, a
///    note to that effect) in the tooltip.
class RegionChip extends StatelessWidget {
  final AppState state;

  /// The Drive screen (plan 4.20): the chip is rendered in EVERY state. "Locating..." until a fix, the region code, then "Choose
  /// region" when location is denied / off. Opaque 36 pt chip, 44 pt hit. (The old footer layout's Material chip is gone, build 70.)
  const RegionChip({super.key = const Key('region-chip'), required this.state});

  @override
  Widget build(BuildContext context) => _alwaysChip(context);
}

extension on RegionChip {
  Widget _alwaysChip(BuildContext context) {
    final s = state;
    final c = AppColors.fromTheme(Theme.of(context));
    final region = s.currentRegion;
    final noFix = !s.regionFixKnown;
    final choose = noFix && s.locationNote != null;
    final outside = s.regionFixKnown && region == null;
    final String label = choose ? 'Choose region' : (noFix || !s.regionIndexLoaded ? 'Locating…' : (region == null ? 'Outside coverage' : region.code));
    final tappable = choose || outside;
    final scale = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6);
    final chip = Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: c.outline)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.map_outlined, size: 16, color: region == null ? c.textMuted : c.accent),
        const SizedBox(width: 6),
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary))),
        if (tappable) Icon(Icons.expand_more_rounded, size: 16, color: c.textMuted),
      ]),
    );
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scale),
      child: Semantics(
        button: tappable,
        label: choose ? 'Choose region' : (noFix ? 'Locating your region' : (region == null ? 'Outside coverage. Tap for the nearest regions' : 'Region ${region.name}')),
        excludeSemantics: true,
        onTap: tappable ? () => unawaited(showNearestRegionsSheet(context)) : null,
        child: GestureDetector(
          key: const Key('region-chip-hit'),
          behavior: HitTestBehavior.opaque,
          onTap: tappable ? () => unawaited(showNearestRegionsSheet(context)) : null,
          child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 44), child: Center(widthFactor: 1, heightFactor: 1, child: chip)),
        ),
      ),
    );
  }
}

/// "External · 5.8 dBi · 1.8 m": the Drive Format v1 antenna a drive records (the mount itself isn't recorded).
String recordedAntennaSummary(Antenna a, [Units units = Units.metric]) => [
  a.type == 'external' ? 'External' : 'Internal',
  if (a.gainDbi != null) '${formatAntennaNumber(a.gainDbi!)} dBi',
  if (a.heightM != null) units.height(a.heightM!),
].join(' · ');

/// "Set up this radio's antenna": shown where Start drive is, while it waits for the connected radio's antenna.
class AntennaSetupHint extends StatelessWidget {
  const AntennaSetupHint({super.key = const Key('antenna-setup')});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () => showAntennaSheet(context),
      icon: const Icon(Icons.warning_amber_rounded),
      label: const Text('Set up this radio\'s antenna'),
    );
  }
}

/// Opens the live ping log of this drive; shows how many pings it holds.
class LogButton extends StatelessWidget {
  final AppState state;
  const LogButton({super.key = const Key('open-log'), required this.state});
  @override
  Widget build(BuildContext context) {
    final n = state.pingCount;
    return DrivePanelRow(
      icon: Icons.receipt_long_rounded,
      label: 'Ping log',
      value: n == 0 ? 'No pings yet' : '$n ${n == 1 ? 'ping' : 'pings'}',
      onTap: () => openPingLog(context),
    );
  }
}

/// Square icon button floated on the map.
class MapIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool active;
  const MapIconButton({super.key, required this.icon, required this.tooltip, required this.onPressed, this.active = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? t.colorScheme.primaryContainer : t.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Corners.small + 2),
          side: BorderSide(color: t.colorScheme.outlineVariant),
        ),
        elevation: 2,
        shadowColor: Colors.black54,
        child: InkWell(
          borderRadius: BorderRadius.circular(Corners.small + 2),
          onTap: onPressed,
          child: SizedBox(
            width: 46,
            height: 46,
            child: Icon(icon, size: 24, color: active ? t.colorScheme.onPrimaryContainer : t.colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}
