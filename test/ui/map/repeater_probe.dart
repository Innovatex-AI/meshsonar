// Test helpers for the unified repeater painter and its labels: find what was drawn, and where, without pixel diffs.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/map/layers/repeater_name_labels.dart';
import 'package:meshsonar/ui/map/layers/repeater_painter_layer.dart';

RepeaterPainter? repeaterPainter(WidgetTester t) {
  final f = find.byKey(RepeaterPainterLayer.paintKey);
  if (f.evaluate().isEmpty) return null;
  return t.widget<CustomPaint>(f).painter as RepeaterPainter;
}

/// The drawn repeater whose key starts with [keyPrefix], or null.
RepeaterItem? repeaterItem(WidgetTester t, String keyPrefix) {
  final p = repeaterPainter(t);
  if (p == null) return null;
  for (final it in p.scene.singles) {
    if (it.key.startsWith(keyPrefix)) return it;
  }
  return null;
}

/// Where [it] is on the test window.
Offset repeaterGlobal(WidgetTester t, RepeaterItem it) => t.renderObject<RenderBox>(find.byKey(RepeaterPainterLayer.paintKey)).localToGlobal(it.at);

List<DrawnLabel> drawnLabels(WidgetTester t) {
  final f = find.byKey(RepeaterNameLabels.paintKey);
  if (f.evaluate().isEmpty) return const [];
  return (t.widget<CustomPaint>(f).painter as LabelPainter).labels;
}

DrawnLabel? labelContaining(WidgetTester t, String text) {
  for (final l in drawnLabels(t)) {
    if (l.text.contains(text)) return l;
  }
  return null;
}

/// The scene source of [layerId] (`network` or `repeaters`), or null when that list draws nothing.
RepeaterSceneSource? sceneSource(WidgetTester t, String layerId) {
  final p = repeaterPainter(t);
  if (p == null) return null;
  for (final s in p.scene.sources) {
    if (s.layerId == layerId) return s;
  }
  return null;
}

/// How many points of [layerId] are in the cluster index (what that list draws, clusters included).
int indexedCountOf(WidgetTester t, String layerId) => sceneSource(t, layerId)?.index.indexedCount ?? 0;

/// The labels of the screen reader proxies the repeater painter exposes (needs `tester.ensureSemantics()`).
List<String> repeaterSemanticLabels(WidgetTester t) {
  final out = <String>[];
  void walk(SemanticsNode n) {
    if (n.label.startsWith('Repeater') || n.label.startsWith('Room server')) out.add(n.label);
    n.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(t.getSemantics(find.byKey(RepeaterPainterLayer.paintKey)));
  return out;
}
