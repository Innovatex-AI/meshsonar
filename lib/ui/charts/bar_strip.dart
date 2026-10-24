// A plain bar strip with no axes (moved unchanged from reports_panel.dart's _Bars into the chart kit): the tallest bar
// fills the height; a value of 0 still draws a hairline so the axis reads. Its numbers are the [summary], which is the
// one semantics label (the strip itself was silent to VoiceOver before).
import 'dart:math' as math;

import 'package:flutter/material.dart';

class BarStrip extends StatelessWidget {
  final List<int> values;
  final String summary;
  final double height;
  const BarStrip({super.key, required this.values, required this.summary, this.height = 56});

  @override
  Widget build(BuildContext context) {
    final max = values.fold<int>(0, (a, b) => b > a ? b : a);
    final color = Theme.of(context).colorScheme.primary;
    return Semantics(
      container: true,
      image: true,
      label: summary,
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final v in values)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: FractionallySizedBox(
                  heightFactor: max == 0 ? 0.03 : (v / max).clamp(0.03, 1.0),
                  alignment: Alignment.bottomCenter,
                  child: ColoredBox(color: color),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// "24 values: peak 52 (bar 14), total 1,487, lowest 0." for a [BarStrip]'s summary; [what] names the bars.
String barStripSummary(List<int> values, {required String what, String Function(int i)? labelOf}) {
  if (values.isEmpty) return '$what: no values.';
  var peakI = 0;
  for (var i = 1; i < values.length; i++) {
    if (values[i] > values[peakI]) peakI = i;
  }
  final total = values.fold<int>(0, (a, b) => a + b);
  final lowest = values.reduce(math.min);
  final at = labelOf == null ? '' : ' at ${labelOf(peakI)}';
  return '$what, ${values.length} bars: peak ${values[peakI]}$at, total $total, lowest $lowest.';
}
