// WP14 accessibility audit helper: a screen must expose at least one node with the header trait (its title or a section
// header), so VoiceOver's rotor can jump between sections and focus lands on the title when it is presented.
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

int headerCount(WidgetTester tester) {
  final owner = tester.binding.renderViews.first.owner?.semanticsOwner;
  final root = owner?.rootSemanticsNode;
  if (root == null) return -1;
  var n = 0;
  void walk(SemanticsNode node) {
    if (node.getSemanticsData().flagsCollection.isHeader) n++;
    node.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(root);
  return n;
}

/// Fails when semantics are off or the screen has no header node.
void expectHeader(WidgetTester tester, {String? reason}) {
  final n = headerCount(tester);
  expect(n, isNot(-1), reason: 'call tester.ensureSemantics() first');
  expect(n, greaterThan(0), reason: reason ?? 'the screen has no header-trait node (title or section header)');
}
