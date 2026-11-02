// Small shared pieces of the Adverts and Rx log screens: a label/value list for detail sheets, and a bottom-sheet frame.
import 'package:flutter/material.dart';

import '../theme.dart';
import '../design/app_surfaces.dart';

/// Label / value pairs; each pair reads as one line to a screen reader.
class FactRows extends StatelessWidget {
  final List<(String, String)> facts;
  const FactRows(this.facts, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (label, value) in facts)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Semantics(
            container: true,
            label: '$label: $value',
            excludeSemantics: true,
            child: Wrap(spacing: Gap.s, children: [
              Text('$label:', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              Text(value, style: t.textTheme.bodyMedium),
            ]),
          ),
        ),
    ]);
  }
}

/// Opens a scrollable bottom sheet with a title.
Future<void> showToolSheet(BuildContext context, {required Key key, required String title, required List<Widget> children}) {
  return showAppSheet<void>(
    context,
    detents: const [0.6, 0.92],
    builder: (ctx, c) => SafeArea(
      child: SingleChildScrollView(
        controller: c,
        key: key,
        padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(header: true, child: Text(title, style: Theme.of(ctx).textTheme.titleLarge)),
          const SizedBox(height: Gap.m),
          ...children,
        ]),
      ),
    ),
  );
}
