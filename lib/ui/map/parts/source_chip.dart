// Moved unchanged from coverage_map.dart (Drive plan WP2, step 1).
import 'package:flutter/material.dart';

import '../../theme.dart';
import '../tile_source.dart';
import 'map_chips.dart';

/// Where the base map is coming from right now: the installed offline pack, the network, or the disk cache with no signal.
class SourceChip extends StatefulWidget {
  final MapTileStats stats;
  final TileFetchGate gate;
  final String? packName;
  final DateTime Function() clock;
  const SourceChip({super.key, required this.stats, required this.gate, required this.packName, required this.clock});

  @override
  State<SourceChip> createState() => SourceChipState();
}

class SourceChipState extends State<SourceChip> {
  late MapSource _source = _compute();

  MapSource _compute() => currentMapSource(widget.stats, widget.clock(), packActive: widget.packName != null, gateOpen: widget.gate.isOpen);

  @override
  void initState() {
    super.initState();
    widget.stats.addListener(_changed);
  }

  void _changed() {
    final n = _compute();
    if (n != _source && mounted) setState(() => _source = n);
  }

  @override
  void didUpdateWidget(SourceChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    final n = _compute();
    if (n != _source) _source = n;
  }

  @override
  void dispose() {
    widget.stats.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final (icon, text, color) = switch (_source) {
      MapSource.offlinePack => (Icons.download_done_rounded, 'Offline map: ${widget.packName ?? 'pack'}', mc.snrStrong),
      MapSource.online => (Icons.cloud_done_outlined, 'Online map', mc.textMuted),
      MapSource.cachedOffline => (Icons.sd_storage_outlined, 'Saved map (no signal)', mc.beacon),
      MapSource.none => (Icons.cloud_off_rounded, 'No map here (no signal)', mc.beacon),
    };
    return MapPill(
      key: _source == MapSource.cachedOffline || _source == MapSource.none ? const Key('map-offline') : const Key('map-source'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Flexible(child: Text(text, overflow: TextOverflow.ellipsis, style: t.textTheme.labelSmall?.copyWith(fontSize: 11))),
        ],
      ),
    );
  }
}
