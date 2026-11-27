// W1-A colour language on the Network screens (build 77, Round 2 N-V3): amber only for warnings. A favourite star is
// the accent; a repeater is the neutral repeater colour; "Partly ready" and "Out of date" are neutral; a node heard less
// often, an observer report that is late, are the warning colour.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/ui/network/network_context.dart';
import 'package:meshsonar/ui/network/nodes/node_ui.dart';
import 'package:meshsonar/ui/region/region_common.dart';
import 'package:meshsonar/ui/theme.dart';

void main() {
  for (final b in Brightness.values) {
    testWidgets('$b: no amber where nothing is wrong', (t) async {
      debugResetNetworkFavourites();
      late BuildContext ctx;
      await t.pumpWidget(MaterialApp(
        theme: meshSonarTheme(b),
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return const Column(children: [
              RegionStatusChip(RegionDataStatus(state: RegionDataState.partial)),
              FavouriteStar(kind: FavouriteKind.node, id: 'k1'),
            ]);
          }),
        ),
      ));
      final m = MeshSonarColors.of(ctx);
      final chip = t.widget<Container>(find.byKey(const Key('region-status-chip')));
      expect((chip.decoration as BoxDecoration).color, isNot(m.warning));
      expect((chip.decoration as BoxDecoration).color, isNot(m.beacon.withValues(alpha: .22)));
      expect(nodeStatusColor(ctx, 'degraded'), m.warning);
      expect(nodeStatusColor(ctx, 'stale'), m.warning);
      await networkFavourites(ctx).toggleFavourite(FavouriteKind.node, 'k1');
      await t.pump();
      final star = t.widget<Icon>(find.descendant(of: find.byKey(const Key('fav-node-k1')), matching: find.byType(Icon)));
      expect(star.color, Theme.of(ctx).colorScheme.primary);
    });
  }
}
