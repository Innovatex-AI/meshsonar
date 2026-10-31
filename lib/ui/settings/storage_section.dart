// Settings > Data & storage: what MeshSonar keeps on this phone and how much space it uses, with a clear action per
// item that says what clearing costs before it does anything. Drives that are not fully uploaded are never removed
// from here (lib/core/storage_usage.dart decides which are safe); those are deleted one at a time from Drives.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/etag_client.dart';
import '../../core/offline_packs.dart';
import '../../core/storage_usage.dart';
import '../app.dart';
import '../map/offline_basemap.dart';
import 'offline_packs_screen.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String storageHelp = 'What MeshSonar keeps on this phone. Clearing frees space; each item says what it costs '
    'first. Drives not fully uploaded are never removed here.';

/// Opens the offline map pack manager. Tests replace it; the app uses the shared one the map uses.
Future<OfflinePackManager> Function() storagePackManager = () => OfflineBasemap.instance.manager();

List<Widget> storageSectionRows(BuildContext context) => const [StorageRows()];

String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

/// Measured sizes (null = not known: not measurable here, or not measured yet).
class _Sizes {
  final int? drives, region, nodeMap, packs;
  final int packCount;
  final bool packsFailed;
  const _Sizes({this.drives, this.region, this.nodeMap, this.packs, this.packCount = 0, this.packsFailed = false});
}

class StorageRows extends StatefulWidget {
  const StorageRows({super.key});
  @override
  State<StorageRows> createState() => _StorageRowsState();
}

class _StorageRowsState extends State<StorageRows> {
  _Sizes _sizes = const _Sizes();
  bool _measuring = false;
  int _lastSessionCount = -1;
  bool _busy = false;

  AppState get _s => AppScope.read(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final n = AppScope.of(context).sessions.length;
    if (n != _lastSessionCount) {
      _lastSessionCount = n;
      unawaited(_measure());
    }
  }

  Future<int?> _regionBytes(AppState s) async {
    final caches = [s.services.regionCache, sharedEtagCache].whereType<StorageSized>().toList();
    if (caches.isEmpty) return null;
    var n = 0;
    for (final c in caches) {
      n += await c.bytesUsed();
    }
    return n;
  }

  Future<void> _measure() async {
    if (_measuring) return;
    _measuring = true;
    final s = _s;
    try {
      final store = s.services.store;
      final drives = store is StorageSized ? await (store as StorageSized).bytesUsed() : null;
      final region = await _regionBytes(s);
      final dir = s.services.directory;
      final nodeMap = dir == null ? null : await bytesOnDisk(dir.cacheFile);
      int? packs;
      var packCount = 0;
      var packsFailed = false;
      try {
        final m = await storagePackManager();
        packs = await m.usedBytes();
        packCount = m.installed.length;
      } catch (_) {
        packsFailed = true;
      }
      if (!mounted) return;
      setState(() => _sizes = _Sizes(
          drives: drives, region: region, nodeMap: nodeMap, packs: packs, packCount: packCount, packsFailed: packsFailed));
    } finally {
      _measuring = false;
    }
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _measure();
  }

  // ---------- clear actions ----------

  Future<void> _removeUploadedDrives(DriveStorageSplit split) async {
    final s = _s;
    final n = split.removable.length;
    final keptLine = split.kept == 0
        ? ''
        : '\n\n${split.kept} drive${split.kept == 1 ? '' : 's'} not fully uploaded stay${split.kept == 1 ? 's' : ''} on this '
            'phone${split.keptUnsentPings > 0 ? ' (${split.keptUnsentPings} pings the server does not have)' : ''}.';
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'storage-drives-dialog',
      title: 'Remove $n uploaded drive${n == 1 ? '' : 's'} from this phone?',
      body: 'The server already has every ping in ${n == 1 ? 'it' : 'them'}, so ${n == 1 ? 'it stays' : 'they stay'} on '
          'the coverage map and the website. This phone loses its copy: no export, drive report or ping log for '
          '${n == 1 ? 'it' : 'them'} here afterwards.$keptLine',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run(() async {
      var done = 0;
      // Re-checked against the latest list at removal time: a drive that changed meanwhile is skipped, never removed.
      final now = splitDrives(s.sessions, recordingId: s.currentSession?.id).removable.toSet();
      for (final id in split.removable) {
        if (!now.contains(id)) continue;
        if (await s.deleteSession(id, quiet: true)) done++;
      }
      _say('Removed $done uploaded drive${done == 1 ? '' : 's'} from this phone.'
          '${split.kept > 0 ? ' ${split.kept} not fully uploaded kept.' : ''}');
    });
  }

  Future<void> _clearRegion() async {
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'storage-region-dialog',
      title: 'Clear saved region data?',
      body: 'Coverage, region pages and site details download again the next time you open them, which uses data. '
          'Until then, with no signal, those screens have nothing to show. Your drives are not touched.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final s = _s;
    await _run(() async {
      var n = 0;
      for (final c in [s.services.regionCache, sharedEtagCache]) {
        if (c != null) n += await c.clear();
      }
      _say('Cleared $n saved region item${n == 1 ? '' : 's'}.');
    });
  }

  Future<void> _clearNames() async {
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'storage-repeaters-dialog',
      title: 'Forget saved repeater names?',
      body: 'Repeaters show as short codes until the names download again with Refresh, which needs a working '
          'driver key and signal. Drives keep what they recorded.',
      confirmLabel: 'Forget',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final s = _s;
    await _run(() async {
      await s.clearRepeaterNames();
      _say('Saved repeater names forgotten.');
    });
  }

  Future<void> _clearNodeMap() async {
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'storage-node-map-dialog',
      title: 'Clear the public node map?',
      body: 'Repeaters only the public map (map.meshcore.io) knows show as short codes until it downloads again '
          'around the start of your next drive. That download is large (tens of MB) and needs signal.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final s = _s;
    await _run(() async {
      await s.clearPublicNodeMap();
      _say('Public node map cleared.');
    });
  }

  Future<void> _discardReport() async {
    final ok = await confirmSettingsChange(
      context,
      dialogKey: 'storage-report-dialog',
      title: 'Discard the unsent problem report?',
      body: 'What you wrote is deleted from this phone and never sent.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final s = _s;
    await _run(() async {
      await s.discardSavedReport();
      _say('Unsent problem report discarded.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final z = _sizes;
    final split = splitDrives(s.sessions, recordingId: s.currentSession?.id);
    String size(int? b) => b == null ? '' : ' · ${formatStorageBytes(b)}';
    Widget clearButton(String key, String label, VoidCallback? onTap) => TextButton(
          key: Key(key),
          onPressed: _busy ? null : onTap,
          child: Text(label),
        );
    Widget row({
      required String id,
      required IconData icon,
      required String text,
      required String explain,
      Widget? action,
      String? whyNot,
    }) =>
        SettingsAnchor(
          id: id,
          child: Padding(
            key: Key(id),
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(settingsEntry(id).title, style: t.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(text, key: Key('$id-value'), style: t.textTheme.bodyMedium),
                  Text(explain, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  if (whyNot != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: SettingsWhyNot(whyNot, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    ),
                  if (action != null) Align(alignment: Alignment.centerLeft, child: action),
                ]),
              ),
            ]),
          ),
        );

    final known = [z.drives, z.region, z.nodeMap, z.packs].whereType<int>();
    final total = known.isEmpty ? null : known.reduce((a, b) => a + b);
    final drivesText = s.sessionsLoading && s.sessions.isEmpty
        ? 'Counting…'
        : split.total == 0
            ? 'No drives on this phone.'
            : '${split.total} drive${split.total == 1 ? '' : 's'}${size(z.drives)}: ${split.removable.length} fully '
                'uploaded, ${split.kept} not fully uploaded.';
    final repeaterCount = s.repeaters.length;
    final dir = s.services.directory;
    return Column(key: const Key('storage-rows'), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 0),
        child: Row(children: [
          Expanded(
            child: Text(
              total == null ? 'Measuring space used…' : 'About ${formatStorageBytes(total)} in use by the items below.',
              key: const Key('storage-total'),
              style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            key: const Key('storage-refresh'),
            tooltip: 'Measure again',
            onPressed: _busy ? null : () => unawaited(_measure()),
            icon: const Icon(Icons.refresh),
          ),
        ]),
      ),
      row(
        id: 'storage-drives',
        icon: Icons.route_outlined,
        text: drivesText,
        explain: 'Only fully uploaded drives can be removed here. A drive with pings waiting or rejected stays; delete it '
            'from Drives if you really mean to.',
        whyNot: split.removable.isNotEmpty
            ? null
            : split.total == 0
                ? 'Nothing to remove: there are no drives on this phone.'
                : 'Nothing to remove yet: no drive is fully uploaded. Upload them from Drives first.',
        action: clearButton('storage-drives-clear', 'Remove uploaded drives',
            split.removable.isEmpty ? null : () => _removeUploadedDrives(split)),
      ),
      const Divider(height: 1, indent: 56),
      row(
        id: 'storage-region',
        icon: Icons.layers_outlined,
        text: z.region == null
            ? 'Not stored on this phone.'
            : z.region == 0
                ? 'Nothing saved yet.'
                : 'Coverage and region pages${size(z.region)}.',
        explain: 'Kept so region screens open with no signal, labelled with their age. Downloads again after clearing.',
        whyNot: z.region == null || z.region == 0 ? 'Nothing to clear.' : null,
        action: z.region == null || z.region == 0 ? null : clearButton('storage-region-clear', 'Clear', _clearRegion),
      ),
      const Divider(height: 1, indent: 56),
      SettingsAnchor(
        id: 'refresh-repeaters',
        child: ListTile(
          key: const Key('refresh-repeaters'),
          leading: const Icon(Icons.cell_tower),
          title: Text(settingsEntry('refresh-repeaters').title),
          subtitle: !s.hasKey
              ? SettingsWhyNot('${repeaterCount == 0 ? 'None saved yet.' : '$repeaterCount saved for offline use.'} '
                  'Downloading names needs a driver key: create one in Account & driver key at the top.')
              : Text(repeaterCount == 0
                  ? 'None saved yet. Tap to download them; this needs a working key and signal.'
                  : '$repeaterCount saved for offline use. Tap to download them again.'),
          trailing: const Icon(Icons.refresh),
          onTap: s.hasKey ? () => s.refreshRepeaters() : null,
        ),
      ),
      if (repeaterCount > 0)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 64, bottom: 6),
            child: clearButton('storage-repeaters-clear', 'Forget saved names', _clearNames),
          ),
        ),
      if (dir != null) ...[
        const Divider(height: 1, indent: 56),
        row(
          id: 'storage-node-map',
          icon: Icons.hub_outlined,
          text: z.nodeMap == null || z.nodeMap == 0
              ? 'Not downloaded.'
              : '${_count(s.directory?.repeaters.length ?? 0, 'repeater')} near your drives${size(z.nodeMap)}.',
          explain: 'From map.meshcore.io, for names your server does not know. Refreshed weekly.',
          whyNot: z.nodeMap == null || z.nodeMap == 0 ? 'Nothing to clear. It downloads around the start of a drive.' : null,
          action: z.nodeMap == null || z.nodeMap == 0 ? null : clearButton('storage-node-map-clear', 'Clear', _clearNodeMap),
        ),
      ],
      const Divider(height: 1, indent: 56),
      row(
        id: 'storage-offline-maps',
        icon: Icons.map_outlined,
        text: z.packsFailed
            ? 'Couldn\'t read the offline maps folder.'
            : z.packs == null
                ? 'Measuring…'
                : z.packCount == 0 && z.packs == 0
                    ? 'No offline maps downloaded.'
                    : z.packCount == 0
                        ? 'Unfinished downloads${size(z.packs)}.'
                        : '${_count(z.packCount, 'map')}${size(z.packs)}.',
        explain: 'Each map is deleted on its own, on the Offline maps screen; it asks first.',
        action: clearButton(
            'storage-offline-maps-open',
            'Open Offline maps',
            () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const OfflinePacksScreen()));
              await _measure();
            }),
      ),
      if (s.savedReport != null) ...[
        const Divider(height: 1, indent: 56),
        row(
          id: 'storage-report-draft',
          icon: Icons.outbox_outlined,
          text: 'One report not sent yet.',
          explain: 'Kept until it is sent or you discard it. It is never sent on its own.',
          action: clearButton('storage-report-discard', 'Discard', _discardReport),
        ),
      ],
    ]);
  }
}
