// Build 76: the Network section strip reads as a scrollable row with the shown section obvious: a filled pill on the
// shown name, an edge marker wherever more names wait off screen, a plain hint per section, 44 pt targets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/network_request.dart' show NetworkSection, networkRegionSections;
import 'package:meshsonar/ui/network/network_sections.dart';
import 'package:meshsonar/ui/theme.dart';

void main() {
  Future<void> pumpStrip(WidgetTester t, NetworkSection selected, ValueChanged<NetworkSection> onChanged) async {
    t.view.physicalSize = const Size(375, 667);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: Scaffold(body: Column(children: [NetworkSectionStrip(selected: selected, onChanged: onChanged)])),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('the shown section is a filled pill; the others are plain; every name is a 44 pt target', (t) async {
    NetworkSection? picked;
    await pumpStrip(t, NetworkSection.live, (s) => picked = s);
    final scheme = Theme.of(t.element(find.byType(NetworkSectionStrip))).colorScheme;
    Color? fill(String name) {
      final box = t.widget<AnimatedContainer>(find.ancestor(of: find.byKey(Key('network-section-$name')), matching: find.byType(AnimatedContainer)).first);
      return (box.decoration as BoxDecoration).color;
    }

    expect(fill('live'), scheme.primaryContainer);
    expect(fill('packets'), Colors.transparent);
    expect(t.widget<Text>(find.byKey(const Key('network-section-live'))).style!.fontWeight, FontWeight.w700);
    final target = t.getSize(find.ancestor(of: find.byKey(const Key('network-section-packets')), matching: find.byType(InkWell)).first);
    expect(target.height, 44);
    expect(target.width, greaterThanOrEqualTo(44));
    await t.tap(find.byKey(const Key('network-section-packets')));
    expect(picked, NetworkSection.packets);
    expect(t.takeException(), isNull);
  });

  testWidgets('at phone width the strip marks the edge where more sections wait, and loses the mark at the end', (t) async {
    await pumpStrip(t, NetworkSection.live, (_) {});
    expect(find.byKey(const Key('network-sections-more-right')), findsOneWidget, reason: 'seven names do not fit 375 pt');
    expect(find.byKey(const Key('network-sections-more-left')), findsNothing);
    await t.drag(find.byKey(const Key('network-sections')), const Offset(-600, 0));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('network-sections-more-right')), findsNothing);
    expect(find.byKey(const Key('network-sections-more-left')), findsOneWidget);
  });

  test('every section has a plain hint of a few words', () {
    for (final s in networkRegionSections) {
      final hint = NetworkSectionStrip.hintOf(s);
      expect(hint.split(' ').length, lessThanOrEqualTo(6), reason: s.name);
      expect(hint, isNot(contains('SNR')));
    }
  });
}
