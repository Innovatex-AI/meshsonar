// The Analyze tab: the viewed region's website data (Region) and this phone's drives and reports (Drives), one tap
// apart. Both screens keep their own app bars; the segmented control sits above them.
import 'package:flutter/material.dart';

import '../app.dart';
import '../region/region_hub_screen.dart';
import '../sessions_screen.dart';

class AnalyzeTab extends StatelessWidget {
  const AnalyzeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.maybeOf(context);
    final view = shell?.analyzeView ?? AnalyzeView.region;
    final t = Theme.of(context);
    return ColoredBox(
      color: t.colorScheme.surface,
      child: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.s),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<AnalyzeView>(
                  key: const Key('analyze-segments'),
                  showSelectedIcon: false,
                  style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(48, 48))),
                  segments: const [
                    ButtonSegment(value: AnalyzeView.region, label: Text('Region'), icon: Icon(Icons.public)),
                    ButtonSegment(value: AnalyzeView.drives, label: Text('Drives'), icon: Icon(Icons.list_alt)),
                  ],
                  selected: {view},
                  onSelectionChanged: (v) {
                    shell?.setAnalyzeView(v.first);
                    if (v.first == AnalyzeView.drives) AppScope.read(context).refreshSessions();
                  },
                ),
              ),
            ),
          ),
          Expanded(
            // The inner screens' app bars must not add the status-bar inset a second time.
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: IndexedStack(
                index: view.index,
                children: const [RegionHubScreen(), SessionsScreen()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
