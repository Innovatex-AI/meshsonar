// Drive WP6 F5, end to end: the live coverage fetch succeeds and is saved, the next fetch fails, the saved copy is served
// (AppState.networkCoverageFromCache) and the layers sheet status line says so (DriveMapModel.statusOf).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';

import '../settings_test_kit.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ms_cov_cache_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('a failed refresh serves the saved copy and statusOf says "Saved copy from"', (tester) async {
    final h = DiskHarness(tmp);
    await h.pumpDiskApp(tester);
    final model = DriveMapModel(h.state);
    addTearDown(model.dispose);

    h.client.publicCoverageResult = PublicCoverage(
      asOf: '2026-10-20T12:00:00Z',
      grid: const CoverageGrid.square(cellDeg: 0.005),
      cells: const [CoverageCell(lat: 39.96, lon: -82.99, pings: 10, heard: 8, bestSnr: 6.0, medianSnr: 4.0, repeaters: 2, lastAt: '2026-10-20T11:00:00Z')],
    );
    await tester.runAsync(h.state.refreshNetworkCoverage);
    expect(h.state.networkCoverageFromCache, isFalse);
    expect(h.state.networkCoverage, isNotNull);

    h.client.publicCoverageResult = null;
    h.client.publicCoverageError = const CmatException('server error', status: 500);
    await tester.runAsync(h.state.refreshNetworkCoverage);

    expect(h.state.networkCoverageFromCache, isTrue);
    expect(h.state.networkCoverageSavedAt, isNotNull);
    expect(h.state.networkCoverage, isNotNull, reason: 'the saved copy is on screen, not blank');
    final status = model.statusOf('measured');
    expect(status.availability, LayerAvailability.stale);
    expect(status.detail, contains('Saved copy from'));
  });
}
