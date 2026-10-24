// Settings > Offline maps: download, update and delete per-region map packs (PMTiles). Logic lives in core/offline_packs.dart.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/offline_packs.dart';
import '../map/offline_basemap.dart';
import '../theme.dart';

String formatPackBytes(int b) {
  if (b < 1024 * 1024) {
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(b < 100 * 1024 * 1024 ? 1 : 0)} MB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class OfflinePacksScreen extends StatefulWidget {
  /// Injected by tests; the app uses the shared [OfflineBasemap] manager.
  final OfflinePackManager? manager;
  const OfflinePacksScreen({super.key, this.manager});

  @override
  State<OfflinePacksScreen> createState() => _OfflinePacksScreenState();
}

class _OfflinePacksScreenState extends State<OfflinePacksScreen> {
  OfflinePackManager? _m;
  PackManifest? _manifest;
  String? _manifestError;
  bool _loadingManifest = false;
  int _used = 0;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final m = widget.manager ?? await OfflineBasemap.instance.manager();
    if (!mounted) {
      return;
    }
    _m = m;
    _sub = m.changes.listen((_) async {
      final u = await m.usedBytes();
      if (mounted) {
        setState(() => _used = u);
      }
    });
    _used = await m.usedBytes();
    if (mounted) {
      setState(() {});
    }
    unawaited(_loadManifest());
  }

  Future<void> _loadManifest() async {
    final m = _m;
    if (m == null) {
      return;
    }
    setState(() {
      _loadingManifest = true;
      _manifestError = null;
    });
    try {
      final mf = await m.fetchManifest();
      if (mounted) {
        setState(() => _manifest = mf);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _manifestError = "Couldn't load the list of map packs. Check your connection.");
      }
    } finally {
      if (mounted) {
        setState(() => _loadingManifest = false);
      }
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _confirmDelete(InstalledPack ip) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${ip.name}?'),
        content: Text('Frees ${formatPackBytes(ip.bytes)}. The map goes back to online tiles here.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(key: const Key('pack-delete-confirm'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await _m!.delete(ip.code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = _m;
    final installed = m?.installed ?? const <String, InstalledPack>{};
    final entries = _manifest?.packs ?? const <PackManifestEntry>[];
    final listed = {for (final e in entries) e.code};
    // Installed packs missing from the manifest (offline, or retired) stay listed so they can still be deleted.
    final orphans = [
      for (final ip in installed.values)
        if (!listed.contains(ip.code)) ip,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Offline maps')),
      body: SafeArea(
        child: m == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                key: const Key('offline-packs-list'),
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
                children: [
                  Text(
                    'Download a region once and its map works with no signal. Packs are OpenStreetMap data hosted by MeshSonar. '
                    'Without a pack the map uses online tiles. Large downloads: use Wi-Fi.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: Gap.m),
                  Text(
                    'Storage used by map packs: ${formatPackBytes(_used)}',
                    key: const Key('pack-storage'),
                    style: t.textTheme.titleSmall,
                  ),
                  const SizedBox(height: Gap.m),
                  if (_loadingManifest) const LinearProgressIndicator(),
                  if (_manifestError != null)
                    ListTile(
                      key: const Key('pack-manifest-error'),
                      leading: const Icon(Icons.cloud_off_rounded),
                      title: Text(_manifestError!),
                      trailing: TextButton(onPressed: _loadManifest, child: const Text('Retry')),
                    ),
                  for (final e in entries)
                    _PackTile(key: Key('pack-${e.code}'), manager: m, entry: e, installed: installed[e.code], onDelete: _confirmDelete),
                  for (final ip in orphans)
                    _PackTile(key: Key('pack-${ip.code}'), manager: m, entry: null, installed: ip, onDelete: _confirmDelete),
                  if (_manifest != null && entries.isEmpty && orphans.isEmpty)
                    const ListTile(key: Key('pack-none'), title: Text('No map packs are published yet.')),
                  const SizedBox(height: Gap.l),
                  Text(_manifest?.attribution ?? '© OpenStreetMap contributors', style: t.textTheme.labelSmall),
                ],
              ),
      ),
    );
  }
}

class _PackTile extends StatelessWidget {
  final OfflinePackManager manager;
  final PackManifestEntry? entry;
  final InstalledPack? installed;
  final Future<void> Function(InstalledPack) onDelete;
  const _PackTile({super.key, required this.manager, required this.entry, required this.installed, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final ip = installed;
    final code = e?.code ?? ip!.code;
    final name = e?.name ?? ip!.name;
    final prog = manager.active[code];
    final update = e != null && manager.updateAvailable(e);
    Widget? trailing;
    String subtitle;
    if (prog != null && prog.phase != PackPhase.failed) {
      final verifying = prog.phase == PackPhase.verifying;
      subtitle = verifying ? 'Verifying...' : '${formatPackBytes(prog.received)} of ${formatPackBytes(prog.total)}';
      trailing = verifying
          ? null
          : IconButton(
              key: Key('pack-cancel-$code'),
              tooltip: 'Pause',
              icon: const Icon(Icons.pause_circle_outline),
              onPressed: () => manager.cancel(code),
            );
    } else if (prog != null) {
      subtitle = prog.error ?? 'Download failed';
      trailing = TextButton(
        key: Key('pack-retry-$code'),
        onPressed: e == null ? null : () => manager.download(e),
        child: const Text('Retry'),
      );
    } else if (ip != null) {
      subtitle = 'Downloaded, ${formatPackBytes(ip.bytes)}${update ? ' - update available' : ''}';
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (update) TextButton(key: Key('pack-update-$code'), onPressed: () => manager.download(e), child: const Text('Update')),
          IconButton(
            key: Key('pack-delete-$code'),
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => onDelete(ip),
          ),
        ],
      );
    } else {
      subtitle = formatPackBytes(e!.bytes);
      trailing = FilledButton.tonal(key: Key('pack-download-$code'), onPressed: () => manager.download(e), child: const Text('Download'));
    }
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(ip != null ? Icons.offline_pin_outlined : Icons.map_outlined),
          title: Text('$name ($code)'),
          subtitle: Text(subtitle),
          trailing: trailing,
        ),
        if (prog != null && prog.phase == PackPhase.downloading)
          LinearProgressIndicator(key: Key('pack-progress-$code'), value: prog.fraction),
      ],
    );
  }
}
