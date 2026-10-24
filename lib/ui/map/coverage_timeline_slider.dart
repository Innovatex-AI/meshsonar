// The coverage-growth slider (scrub the network-coverage layer back to an "as of" day, play it forward, reset to
// live) and the "Coverage as of <date>" badge drawn over the map. State lives in CoverageTimelineController.
import 'package:flutter/material.dart';

import '../../core/coverage_timeline.dart';
import '../drive/drive_map_model.dart';
import '../theme.dart';
import 'coverage_timeline_controller.dart';

class CoverageTimelineSlider extends StatefulWidget {
  final DriveMapModel model;
  const CoverageTimelineSlider({super.key, required this.model});

  @override
  State<CoverageTimelineSlider> createState() => _CoverageTimelineSliderState();
}

class _CoverageTimelineSliderState extends State<CoverageTimelineSlider> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.model.timeline.ensureLoaded();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final model = widget.model;
    final tl = model.timeline;
    final label = t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Padding(
      key: const Key('coverage-timeline'),
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: ListenableBuilder(
        listenable: Listenable.merge([tl, model.state]),
        builder: (context, _) {
          final sc = tl.scale;
          Widget note(String text, {Key? key}) => Text(text, key: key, style: t.textTheme.bodySmall);
          Widget body;
          if (tl.load == TimelineLoad.loading || tl.load == TimelineLoad.idle) {
            body = note('Loading the timeline...', key: const Key('timeline-loading'));
          } else if (sc == null) {
            body = note("Timeline unavailable: this region's first-data date could not be loaded.", key: const Key('timeline-unavailable'));
          } else {
            final i = tl.index;
            final live = tl.isLive;
            body = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                      key: const Key('timeline-play'),
                      tooltip: tl.playing ? 'Pause' : 'Play coverage growth',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(tl.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      onPressed: tl.playing ? tl.pause : tl.play,
                    ),
                    Expanded(
                      child: Slider(
                        key: const Key('timeline-slider'),
                        min: 0,
                        max: sc.liveIndex.toDouble(),
                        divisions: sc.liveIndex,
                        value: i.toDouble().clamp(0, sc.liveIndex.toDouble()),
                        label: live ? 'Live' : timelineDayLabel(sc.dayAt(i)),
                        onChanged: (v) {
                          tl.pause();
                          tl.scrubTo(v.round());
                        },
                      ),
                    ),
                    TextButton(
                      key: const Key('timeline-live'),
                      onPressed: live ? null : tl.reset,
                      child: const Text('Live'),
                    ),
                  ],
                ),
                Text(
                  live ? 'Live (first data ${timelineDayLabel(sc.first)})' : 'Showing coverage through ${timelineDayLabel(sc.dayAt(i))} (UTC)',
                  key: const Key('timeline-status'),
                  style: t.textTheme.bodySmall,
                ),
                if (!live) _stateNote(model, sc.dayAt(i), t),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text('Coverage growth (as of)', style: label), const SizedBox(height: 4), body],
          );
        },
      ),
    );
  }

  Widget _stateNote(DriveMapModel model, DateTime day, ThemeData t) {
    final s = model.state;
    String? text;
    Key key = const Key('timeline-note');
    if (s.networkCoverageLoading) {
      text = 'Loading coverage...';
      key = const Key('timeline-note-loading');
    } else if (s.networkCoverageFailed) {
      text = "Offline or the server didn't answer: the map may not match this date.";
      key = const Key('timeline-note-offline');
    } else if (model.networkCells.isEmpty) {
      text = 'No coverage measured before ${timelineDayLabel(day.add(const Duration(days: 1)))}.';
      key = const Key('timeline-note-empty');
    }
    return text == null ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(top: 2), child: Text(text, key: key, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)));
  }
}

/// "Coverage as of Oct 18, 2026" over the map while the slider is scrubbed back; nothing at live.
class CoverageAsOfBadge extends StatelessWidget {
  final DriveMapModel model;
  const CoverageAsOfBadge({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model.timeline,
      builder: (context, _) {
        final text = model.layers.networkCoverage ? model.timeline.asOfLabel : null;
        if (text == null) return const SizedBox.shrink();
        return Chip(
          key: const Key('coverage-as-of'),
          avatar: const Icon(Icons.history_rounded, size: 16),
          label: Text(text),
          visualDensity: VisualDensity.compact,
        );
      },
    );
  }
}
