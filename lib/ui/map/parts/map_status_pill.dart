// The map says what it is doing (build 77, Round 1 N5): one small pill beside the legend chip. "Loading coverage", "Couldn't
// load" with Retry, "Nothing measured here", "Zoom in to see names". Before build 77 these existed only as status lines inside
// the Layers sheet, and data silently disappeared at some zooms. Keys: 'map-status-pill', 'map-status-retry'.
import 'package:flutter/material.dart';

import '../../design/tokens.dart' show AppColors, Hit;
import '../coverage_tiles_layer.dart' show CoverageViewStatus;

/// What the pill says, most important first.
enum MapStatus { failed, loading, nothingHere, zoomForNames }

/// The pill's message for the measured coverage status and the names, or null when the map has nothing to say.
MapStatus? mapStatusFor({CoverageViewStatus? coverage, bool namesHiddenByZoom = false}) => switch (coverage) {
  CoverageViewStatus.failed => MapStatus.failed,
  CoverageViewStatus.loading => MapStatus.loading,
  CoverageViewStatus.empty => MapStatus.nothingHere,
  _ => namesHiddenByZoom ? MapStatus.zoomForNames : null,
};

String mapStatusText(MapStatus s) => switch (s) {
  MapStatus.failed => "Couldn't load coverage",
  MapStatus.loading => 'Loading coverage',
  MapStatus.nothingHere => 'Nothing measured here',
  MapStatus.zoomForNames => 'Zoom in to see names',
};

class MapStatusPill extends StatelessWidget {
  final MapStatus status;
  final VoidCallback? onRetry;
  const MapStatusPill({super.key, required this.status, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = AppColors.fromTheme(t);
    final text = Text(mapStatusText(status), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.labelMedium?.copyWith(color: c.textMuted));
    return Container(
      key: const Key('map-status-pill'),
      height: 36,
      padding: EdgeInsets.only(left: 12, right: status == MapStatus.failed && onRetry != null ? 2 : 12),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: c.outline)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == MapStatus.loading) ...[
            SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: c.textMuted)),
            const SizedBox(width: 6),
          ],
          Flexible(child: Semantics(liveRegion: true, child: text)),
          if (status == MapStatus.failed && onRetry != null)
            TextButton(
              key: const Key('map-status-retry'),
              style: TextButton.styleFrom(minimumSize: const Size(Hit.min, 36), padding: const EdgeInsets.symmetric(horizontal: 10)),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}
