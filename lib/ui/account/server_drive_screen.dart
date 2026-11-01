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
    final c = TextEditingController(text: _label ?? d.drive.label ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this drive'),
        content: TextField(key: const Key('server-drive-name'), controller: c, maxLength: 80, decoration: const InputDecoration(hintText: 'Empty uses the date')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(key: const Key('server-drive-name-save'), onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    if (v == null || !mounted) return;
    await _run('Renaming', () => AppScope.read(context).updateServerDrive(d.drive.id, label: v, clearLabel: v.isEmpty), then: () => setState(() {
          _label = v;
        }));
  }

  Future<void> _hide(ServerDriveDetail d) async {
    final hide = !(_hidden ?? d.drive.review == 'hidden');
    await _run(hide ? 'Hiding' : 'Showing', () => AppScope.read(context).updateServerDrive(d.drive.id, hidden: hide), then: () {
      setState(() => _hidden = hide);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(hide ? 'Hidden from the public maps.' : 'Shown on the public maps again.')));
    });
  }

  Future<void> _delete(ServerDriveDetail d) async {
    final ok = await confirmSettingsChange(context,
        dialogKey: 'server-drive-delete-dialog',
        title: 'Delete this drive from the server?',
        body: 'The server forgets this drive and all its pings. A copy on this phone stays. This cannot be undone.',
        confirmLabel: 'Delete on the server',
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e, action: what))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final units = AppScope.unitsOf(context);
    final t = Theme.of(context);
    final x = widget.drive;
    return Scaffold(
      appBar: AppBar(title: Text(_label ?? x.label ?? formatDateTime(x.startedAt))),
      body: SafeArea(
        child: FutureBuilder<ServerDriveDetail>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError) {
              final e = snap.error;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.l),
                  child: Text(e is CmatException && e.status == 404 ? 'The server no longer has this drive.' : friendlyError(e!, action: 'Loading the drive'),
                      key: const Key('server-drive-error')),
                ),
              );
            }
            final d = snap.data!;
            final pings = _asPings(d);
            final isHidden = _hidden ?? x.review == 'hidden';
            final heardPct = d.pings.isEmpty ? null : (100 * d.heardCount / d.pings.length).round();
            return ListView(key: const Key('server-drive-screen'), padding: const EdgeInsets.all(Gap.l), children: [
              if (pings.isNotEmpty) SizedBox(height: 240, child: ClipRRect(borderRadius: BorderRadius.circular(Corners.card), child: DriveDetailMap(pings: pings))),
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
                  if (d.bestSnr != null) 'best ${d.bestSnr!.toStringAsFixed(1)} dB',
                ].join(' · '),
                key: const Key('server-drive-totals'),
              ),
              if (x.reviewWords != null) Text(x.reviewWords!, style: t.textTheme.bodySmall),
              if (d.skipped > 0) Text('${d.skipped} pings could not be read and are left out.', style: t.textTheme.bodySmall),
              const SizedBox(height: Gap.s),
              Wrap(spacing: Gap.s, children: [
                OutlinedButton.icon(
                    key: const Key('server-drive-rename'), onPressed: _busy ? null : () => _rename(d), icon: const Icon(Icons.edit_outlined), label: const Text('Rename')),
                OutlinedButton.icon(
                    key: const Key('server-drive-hide'),
                    onPressed: _busy ? null : () => _hide(d),
                    icon: Icon(isHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    label: Text(isHidden ? 'Show on public maps' : 'Hide from public maps')),
                OutlinedButton.icon(
                    key: const Key('server-drive-delete'),
                    style: OutlinedButton.styleFrom(foregroundColor: t.colorScheme.error),
                    onPressed: _busy ? null : () => _delete(d),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete on the server')),
              ]),
              const Divider(height: Gap.xl),
              Text('Pings', style: t.textTheme.titleMedium),
              if (d.pings.isEmpty) const Text('The server holds no pings for this drive.', key: Key('server-drive-nopings')),
              for (final p in d.pings)
                ListTile(
                  key: ValueKey('server-ping-${p.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(p.heard ? Icons.check_circle_outline : Icons.radio_button_unchecked, color: p.heard ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
                  title: Text(formatDateTime(p.at)),
                  subtitle: Text(p.echoes.isEmpty
                      ? 'Heard by no repeater'
                      : [
                          for (final e in p.echoes) '${e.name ?? e.repeaterId}${e.snr == null ? '' : ' ${e.snr!.toStringAsFixed(1)} dB'}',
                        ].join(', ')),
                ),
            ]);
          },
        ),
      ),
    );
  }
}
