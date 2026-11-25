// A drive as the SERVER holds it, with every ping (the website's /me/drives/<id>): the map of the track, the totals, and the
// per-ping list (time, heard or not, which repeaters answered and how strongly). Rename, hide from the public maps, delete on
// the server. For drives that are not on this phone, or to see what the server kept. The owner's view: untrimmed.
import 'package:flutter/material.dart';

import '../../app/messages.dart';
import '../../core/api.dart';
import '../../core/driver_account.dart';
import '../../core/driver_summary.dart';
import '../../core/model.dart';
import '../app.dart';
import '../drive_detail_map.dart';
import '../settings/settings_kit.dart' show confirmSettingsChange;
import '../widgets.dart';
import '../design/app_surfaces.dart';

Future<void> openServerDrive(BuildContext context, ServerDrive drive) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ServerDriveScreen(drive: drive)));

class ServerDriveScreen extends StatefulWidget {
  final ServerDrive drive;
  const ServerDriveScreen({super.key, required this.drive});
  @override
  State<ServerDriveScreen> createState() => _ServerDriveScreenState();
}

class _ServerDriveScreenState extends State<ServerDriveScreen> {
  Future<ServerDriveDetail>? _future;
  String? _label;
  bool? _hidden;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= AppScope.read(context).loadServerDrive(widget.drive.id);
  }

  List<DrivePing> _asPings(ServerDriveDetail d) => [
        for (final p in d.pings)
          DrivePing(
            id: p.id,
            ts: p.at,
            lat: p.lat,
            lon: p.lon,
            gpsAccuracyM: p.accuracyM,
            echoes: [for (final e in p.echoes) Echo(repeater: e.repeaterId, snrDb: e.snr, rssiDbm: e.rssi)],
          ),
      ];

  Future<void> _rename(ServerDriveDetail d) async {
    final v = await showAppSheet<String>(
      context,
      detents: [MediaQuery.textScalerOf(context).scale(10) > 13 ? 0.92 : 0.4], // large text needs the room for both buttons
      builder: (ctx, controller) => _NameSheet(initial: _label ?? d.drive.label ?? '', controller: controller),
    );
    if (v == null || !mounted) return;
    await _run('Renaming', () => AppScope.read(context).updateServerDrive(d.drive.id, label: v, clearLabel: v.isEmpty), then: () {
      // An emptied name goes back to the date at once (it used to leave a blank title until the page was reopened).
      setState(() => _label = v);
      showAppToast(context, v.isEmpty ? 'Name removed.' : 'Renamed.', kind: AppToastKind.success);
    });
  }

  void _retry() {
    final f = AppScope.read(context).loadServerDrive(widget.drive.id)..ignore(); // the FutureBuilder shows a failure
    setState(() {
      _future = f;
    });
  }

  Future<void> _hide(ServerDriveDetail d) async {
    final hide = !(_hidden ?? d.drive.review == 'hidden');
    await _run(hide ? 'Hiding' : 'Showing', () => AppScope.read(context).updateServerDrive(d.drive.id, hidden: hide), then: () {
      setState(() => _hidden = hide);
      showAppToast(context, hide ? 'Hidden from the public maps.' : 'Shown on the public maps again.', kind: AppToastKind.success);
    });
  }

  Future<void> _delete(ServerDriveDetail d) async {
    final ok = await confirmSettingsChange(context,
        dialogKey: 'server-drive-delete-dialog',
        title: 'Delete this drive from the server?',
        body: 'The server forgets this drive and its pings. A copy on this phone stays. This cannot be undone.',
        confirmLabel: 'Delete from server',
        destructive: true);
    if (!ok || !mounted) return;
    await _run('Deleting', () => AppScope.read(context).deleteServerDrive(d.drive.id), then: () => Navigator.of(context).pop(true));
  }

  Future<void> _run(String what, Future<void> Function() act, {required VoidCallback then}) async {
    setState(() => _busy = true);
    try {
      await act();
      if (!mounted) return;
      then();
    } catch (e) {
      if (mounted) showAppToast(context, friendlyError(e, action: what), kind: AppToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final units = AppScope.unitsOf(context);
    final t = Theme.of(context);
    final x = widget.drive;
    final name = _label ?? x.label ?? '';
    return Scaffold(
      appBar: AppBar(title: Text(name.isEmpty ? formatDateTime(x.startedAt) : name)),
      body: SafeArea(
        child: FutureBuilder<ServerDriveDetail>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(
                key: Key('server-drive-loading'),
                child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: Gap.s), Text('Loading the drive…')]),
              );
            }
            if (snap.hasError) {
              final e = snap.error;
              final gone = e is CmatException && e.status == 404;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.l),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(gone ? Icons.search_off : Icons.cloud_off_outlined, size: 40, color: t.colorScheme.onSurfaceVariant),
                    const SizedBox(height: Gap.s),
                    Text(gone ? 'The server no longer has this drive.' : friendlyError(e!, action: 'Loading the drive'),
                        key: const Key('server-drive-error'), textAlign: TextAlign.center),
                    const SizedBox(height: Gap.m),
                    // A drive that is gone will not come back by asking again: the only useful step is back.
                    if (gone)
                      FilledButton.tonal(
                        key: const Key('server-drive-back'),
                        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const Text('Back'),
                      )
                    else
                      FilledButton.tonalIcon(
                        key: const Key('server-drive-retry'),
                        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'),
                      ),
                  ]),
                ),
              );
            }
            final d = snap.data!;
            final pings = _asPings(d);
            final isHidden = _hidden ?? x.review == 'hidden';
            final heardPct = d.pings.isEmpty ? null : (100 * d.heardCount / d.pings.length).round();
            final dim = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
            const tap = Size(48, 48);
            return ListView(key: const Key('server-drive-screen'), padding: const EdgeInsets.all(Gap.l), children: [
              if (pings.isNotEmpty) SizedBox(height: 240, child: ClipRRect(borderRadius: BorderRadius.circular(Corners.card), child: DriveDetailMap(pings: pings, showZones: false))),
              const SizedBox(height: Gap.m),
              Text(
                '${formatDateTime(x.startedAt)}${x.endedAt == null ? '' : ' to ${formatDateTime(x.endedAt!)}'}',
                style: t.textTheme.titleMedium,
              ),
              const SizedBox(height: Gap.xs),
              Text(
                [
                  '${d.pings.length} pings',
                  if (heardPct != null) '$heardPct% heard',
                  if (x.km != null) units.distance(x.km! * 1000),
                  '${d.repeaterCount} repeaters',
                  if (d.bestSnr != null) 'best signal ${d.bestSnr!.toStringAsFixed(1)} dB',
                ].join(' · '),
                key: const Key('server-drive-totals'),
              ),
              // Follows the Hide button at once: the server's own review line is from when the page was opened.
              if (isHidden)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.visibility_off_outlined, size: 18, color: t.colorScheme.onSurfaceVariant),
                    const SizedBox(width: Gap.s),
                    const Expanded(child: Text('Hidden from the public maps. Only you see it.', key: Key('server-drive-hidden-note'))),
                  ]),
                )
              else if (x.reviewWords != null && x.review != 'hidden')
                Text(x.reviewWords!, style: dim),
              if (d.skipped > 0) Text('${d.skipped} pings could not be read and are left out.', style: dim),
              const SizedBox(height: Gap.s),
              if (_busy) const LinearProgressIndicator(key: Key('server-drive-busy')),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
                OutlinedButton.icon(
                    key: const Key('server-drive-rename'),
                    style: OutlinedButton.styleFrom(minimumSize: tap),
                    onPressed: _busy ? null : () => _rename(d),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Rename')),
                OutlinedButton.icon(
                    key: const Key('server-drive-hide'),
                    style: OutlinedButton.styleFrom(minimumSize: tap),
                    onPressed: _busy ? null : () => _hide(d),
                    icon: Icon(isHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    label: Text(isHidden ? 'Show on maps' : 'Hide from maps')),
                OutlinedButton.icon(
                    key: const Key('server-drive-delete'),
                    style: OutlinedButton.styleFrom(minimumSize: tap, foregroundColor: t.colorScheme.error),
                    onPressed: _busy ? null : () => _delete(d),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete from server')),
              ]),
              const Divider(height: Gap.xl),
              Text(d.pings.isEmpty ? 'Pings' : 'Pings (${d.pings.length})', key: const Key('server-drive-pings-title'), style: t.textTheme.titleMedium),
              if (d.pings.isEmpty) const Text('The server holds no pings for this drive.', key: Key('server-drive-nopings')),
              for (final p in d.pings)
                ListTile(
                  key: ValueKey('server-ping-${p.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(p.heard ? Icons.check_circle_outline : Icons.radio_button_unchecked, color: p.heard ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
                  title: Text(formatTime(p.at)),
                  subtitle: Text(p.echoes.isEmpty
                      ? 'Not heard'
                      : 'Heard by ${[
                          for (final e in p.echoes) '${e.name ?? e.repeaterId}${e.snr == null ? '' : ' ${e.snr!.toStringAsFixed(1)} dB'}',
                        ].join(', ')}'),
                ),
            ]);
          },
        ),
      ),
    );
  }
}


class _NameSheet extends StatefulWidget {
  final String initial;
  final ScrollController controller;
  const _NameSheet({required this.initial, required this.controller});
  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, _c.text.trim());

  @override
  Widget build(BuildContext context) => AppSheetScaffold(
        controller: widget.controller,
        title: 'Name this drive',
        primaryAction: FilledButton(key: const Key('server-drive-name-save'), onPressed: _save, child: const Text('Save')),
        secondaryAction: TextButton(key: const Key('server-drive-name-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        children: [
          TextField(
            key: const Key('server-drive-name'),
            controller: _c,
            autofocus: true, // the one field of this sheet: the keyboard is up without a second tap
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(), // Done on the keyboard saves
            decoration: InputDecoration(
              labelText: 'Drive name',
              helperText: 'Empty uses the date.',
              suffixIcon: IconButton(key: const Key('server-drive-name-clear'), tooltip: 'Clear', icon: const Icon(Icons.clear), onPressed: _c.clear),
            ),
          ),
        ],
      );
}
