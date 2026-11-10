// Settings > Offline maps: download, update and delete per-region map packs (PMTiles), the Wi-Fi-only rule and
// storage. Logic lives in core/offline_packs.dart; the network kind comes from lib/platform/network_monitor.dart.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/messages.dart';
import '../../core/basemap.dart' show OurBasemap;
import '../../core/offline_packs.dart';
import '../app.dart' show AppScope;
import '../design/app_surfaces.dart';
import '../map/offline_basemap.dart';
import '../region/region_common.dart' show agoText;
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
  /// Injected by tests; the app uses the shared [OfflineBasemap] manager and network monitor.
  final OfflinePackManager? manager;
  final NetworkMonitor? network;
  const OfflinePacksScreen({super.key, this.manager, this.network});

  @override
  State<OfflinePacksScreen> createState() => _OfflinePacksScreenState();
}

class _OfflinePacksScreenState extends State<OfflinePacksScreen> {
  OfflinePackManager? _m;
  PackManifest? _manifest;
  String? _manifestError;
  String? _openError;
  bool _loadingManifest = false;
  int _used = 0;
  Map<String, int> _byPack = const {};
  StreamSubscription<void>? _sub;

  NetworkMonitor get _network => widget.network ?? OfflineBasemap.instance.network;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    OfflinePackManager m;
    try {
      m = widget.manager ?? await OfflineBasemap.instance.manager();
    } catch (e) {
      if (mounted) setState(() => _openError = "Couldn't open map pack storage on this device.");
      return;
    }
    if (!mounted) {
      return;
    }
    _m = m;
    _sub = m.changes.listen((_) => _refreshStorage());
    await _refreshStorage();
    unawaited(_loadManifest());
  }

  Future<void> _refreshStorage() async {
    final m = _m;
    if (m == null) return;
    final u = await m.usedBytes();
    final b = await m.bytesByPack();
    if (mounted) {
      setState(() {
        _used = u;
        _byPack = b;
      });
    }
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

  /// Download / Update / Retry: applies the Wi-Fi-only rule (asks with the size on cellular).
  Future<void> _start(PackManifestEntry e) async {
    final m = _m!;
    final net = await _network.current();
    final r = await m.start(e, net);
    if (!mounted) return;
    if (r == StartResult.offline) {
      showAppToast(context, 'No connection. The download starts by itself when you are back online.');
      return;
    }
    if (r != StartResult.needsCellularConsent) return;
    final now = await showAppActionSheet<bool>(
      context,
      sheetKey: const Key('pack-cellular-dialog'),
      title: 'Not on Wi-Fi',
      message: '${e.name} is ${formatPackBytes(e.bytes)}. Download it over cellular now, or wait and it downloads by itself '
          'when you are on Wi-Fi (with the app open).',
      actions: [
        const AppAction('Download now', true, key: Key('pack-use-cellular')),
        const AppAction('Wait for Wi-Fi', false, key: Key('pack-wait-wifi'), isDefault: true),
      ],
    );
    if (now == true) {
      m.allowCellular(e.code);
      await m.start(e, net);
    } else if (now == false) {
      await m.queueForWifi(e);
    }
  }

  Future<void> _confirmDelete(InstalledPack ip) async {
    final ok = await showAppConfirm(
      context,
      title: 'Delete ${ip.name}?',
      message: 'Frees ${formatPackBytes(ip.bytes)}. The map goes back to online tiles here.',
      confirmLabel: 'Delete',
      destructive: true,
      cancelLabel: 'Keep',
      confirmKey: const Key('pack-delete-confirm'),
    );
    if (ok) {
      await _guard(() => _m!.delete(ip.code));
    }
  }

  Future<void> _confirmDeleteAll() async {
    final ok = await showAppConfirm(
      context,
      title: 'Delete all map packs?',
      message: 'Frees ${formatPackBytes(_used)}, including unfinished downloads. The map goes back to online tiles.',
      confirmLabel: 'Delete all',
      destructive: true,
      cancelLabel: 'Keep',
      confirmKey: const Key('pack-delete-all-confirm'),
    );
    if (ok) {
      await _guard(() => _m!.deleteAll());
    }
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) {
        showAppToast(context, friendlyError(e, action: 'Deleting the map pack'), kind: AppToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = _m;
    final installed = m?.installed ?? const <String, InstalledPack>{};
    final entries = _manifest?.packs ?? const <PackManifestEntry>[];
    final listed = {for (final e in entries) e.code};
    // Installed packs missing from the manifest (retired, or the list failed) stay listed so they can still be deleted;
    // queued downloads too, so they can be cancelled.
    final orphans = [
      for (final ip in installed.values)
        if (!listed.contains(ip.code)) ip,
    ];
    final orphanQueued = [
      for (final e in m?.pending.values ?? const <PackManifestEntry>[])
        if (!listed.contains(e.code) && !installed.containsKey(e.code)) e,
    ];
    final mf = _manifest;
    return Scaffold(
      appBar: AppBar(title: const Text('Offline maps')),
      body: SafeArea(
        child: m == null
            ? Center(
                child: _openError == null
                    ? const CircularProgressIndicator()
                    : Text(_openError!, key: const Key('pack-open-error')),
              )
            : ListView(
                key: const Key('offline-packs-list'),
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
                children: [
                  Text(
                    'Download a region once and its map works with no signal: the road map, coverage (measured and '
                    'predicted) and repeaters. Packs are the same OpenStreetMap map MeshSonar draws online, hosted by '
                    'MeshSonar; their coverage is refreshed on Wi-Fi. Without a pack the map uses online tiles. Downloads '
                    'run while the app is open and pick up where they stopped.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                  SwitchListTile(
                    key: const Key('pack-wifi-only'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Download on Wi-Fi only'),
                    subtitle: const Text('On cellular you are asked first, with the size.'),
                    value: m.wifiOnly,
                    onChanged: (v) => m.setWifiOnly(v),
                  ),
                  const Divider(),
                  if (_loadingManifest) const LinearProgressIndicator(),
                  if (_manifestError != null)
                    ListTile(
                      key: const Key('pack-manifest-error'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.cloud_off_rounded),
                      title: Text(_manifestError!),
                      trailing: TextButton(onPressed: _loadManifest, child: const Text('Retry')),
                    ),
                  if (mf != null && mf.fromCache)
                    ListTile(
                      key: const Key('pack-manifest-offline'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.cloud_off_rounded),
                      title: Text('Offline - pack list as of ${agoText(mf.fetchedAt)}'),
                      trailing: TextButton(onPressed: _loadManifest, child: const Text('Retry')),
                    ),
                  for (final e in entries)
                    _PackTile(
                      key: Key('pack-${e.code}'),
                      manager: m,
                      entry: e,
                      installed: installed[e.code],
                      onDisk: _byPack[e.code],
                      onStart: _start,
                      onDelete: _confirmDelete,
                    ),
                  for (final e in orphanQueued)
                    _PackTile(key: Key('pack-${e.code}'), manager: m, entry: e, installed: null, onDisk: _byPack[e.code], onStart: _start, onDelete: _confirmDelete),
                  for (final ip in orphans)
                    _PackTile(key: Key('pack-${ip.code}'), manager: m, entry: null, installed: ip, onDisk: _byPack[ip.code], onStart: _start, onDelete: _confirmDelete),
                  if (mf != null && entries.isEmpty && orphans.isEmpty)
                    const ListTile(key: Key('pack-none'), title: Text('No map packs are published yet.')),
                  if (mf != null) ?_viewedRegionNote(context, entries),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Storage used by map packs: ${formatPackBytes(_used)}',
                          key: const Key('pack-storage'),
                          style: t.textTheme.titleSmall,
                        ),
                      ),
                      if (_used > 0)
                        TextButton(key: const Key('pack-delete-all'), onPressed: _confirmDeleteAll, child: const Text('Delete all')),
                    ],
                  ),
                  const SizedBox(height: Gap.l),
                  Text(mf?.attribution ?? 'Protomaps © OpenStreetMap contributors', style: t.textTheme.labelSmall),
                ],
              ),
      ),
    );
  }
}

/// The viewed region has no pack (Nov 10, plan §8d: packs are built for every region with coverage inside our North America
/// extract; elsewhere the online map falls back to OpenFreeMap). Said plainly instead of leaving the person to look for it.
Widget? _viewedRegionNote(BuildContext context, List<PackManifestEntry> entries) {
  final r = AppScope.maybeOf(context)?.viewingRegion;
  if (r == null || entries.any((e) => e.code.toLowerCase() == r.code.toLowerCase() || e.code.toLowerCase() == r.slug.toLowerCase())) return null;
  final b = r.bbox;
  final ob = OurBasemap.bounds;
  final insideExtract = b != null && b.length == 4 && (b[0] + b[2]) / 2 >= ob[0] && (b[0] + b[2]) / 2 <= ob[2] && (b[1] + b[3]) / 2 >= ob[1] && (b[1] + b[3]) / 2 <= ob[3];
  return ListTile(
    key: const Key('pack-region-none'),
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.info_outline),
    title: Text('No offline pack for ${r.name}'),
    subtitle: Text(
      insideExtract
          ? 'A pack is built once the region has coverage. The online map works here.'
          : 'Offline packs cover North America only. The online map works here (OpenFreeMap).',
    ),
  );
}

class _PackTile extends StatelessWidget {
  final OfflinePackManager manager;
  final PackManifestEntry? entry;
  final InstalledPack? installed;
  final int? onDisk;
  final Future<void> Function(PackManifestEntry) onStart;
  final Future<void> Function(InstalledPack) onDelete;
  const _PackTile({
    super.key,
    required this.manager,
    required this.entry,
    required this.installed,
    required this.onDisk,
    required this.onStart,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final ip = installed;
    final code = e?.code ?? ip!.code;
    final name = e?.name ?? ip!.name;
    final prog = manager.active[code];
    final update = e != null && manager.updateAvailable(e);
    final updating = ip != null && prog != null;
    Widget? trailing;
    String subtitle;
    if (prog != null && (prog.phase == PackPhase.downloading || prog.phase == PackPhase.verifying)) {
      final verifying = prog.phase == PackPhase.verifying;
      subtitle = verifying ? 'Verifying...' : '${formatPackBytes(prog.received)} of ${formatPackBytes(prog.total)}';
      if (updating) subtitle = 'Updating: $subtitle. The current version stays in use until the new one is verified.';
      trailing = verifying
          ? null
          : IconButton(
              key: Key('pack-cancel-$code'),
              tooltip: 'Pause',
              icon: const Icon(Icons.pause_circle_outline),
              onPressed: () => manager.cancel(code),
            );
    } else if (prog != null && prog.phase == PackPhase.waiting) {
      final have = prog.received > 0 ? ', ${formatPackBytes(prog.received)} of ${formatPackBytes(prog.total)} so far' : '';
      subtitle = manager.wifiOnly ? 'Waiting for Wi-Fi$have' : 'Waiting for a connection$have';
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (e != null && manager.wifiOnly)
            TextButton(
              key: Key('pack-now-$code'),
              onPressed: () {
                manager.allowCellular(code);
                onStart(e);
              },
              child: const Text('Download now'),
            ),
          IconButton(
            key: Key('pack-cancel-$code'),
            tooltip: 'Cancel',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => manager.cancel(code),
          ),
        ],
      );
    } else if (prog != null) {
      subtitle = prog.error ?? 'Download failed';
      trailing = TextButton(
        key: Key('pack-retry-$code'),
        onPressed: e == null ? null : () => onStart(e),
        child: const Text('Retry'),
      );
    } else if (ip != null) {
      final size = formatPackBytes(onDisk ?? ip.bytes);
      subtitle = update ? 'Downloaded, $size. Update available (${formatPackBytes(e.bytes)})' : 'Downloaded, $size';
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (update) TextButton(key: Key('pack-update-$code'), onPressed: () => onStart(e), child: const Text('Update')),
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
      trailing = FilledButton.tonal(key: Key('pack-download-$code'), onPressed: () => onStart(e), child: const Text('Download'));
    }
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(ip != null ? Icons.offline_pin_outlined : Icons.map_outlined),
          title: Text('$name ($code)'),
          subtitle: Text(subtitle, key: Key('pack-status-$code')),
          trailing: trailing,
        ),
        if (prog != null && prog.phase == PackPhase.downloading)
          LinearProgressIndicator(key: Key('pack-progress-$code'), value: prog.fraction),
      ],
    );
  }
}
