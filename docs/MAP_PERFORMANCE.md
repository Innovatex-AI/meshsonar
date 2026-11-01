# Map performance: how it is measured, what was slow, what changed

Benchmark: `integration_test/map_jank_benchmark_test.dart` (run on an iOS simulator; see its header). It starts the real Harness app, plays a generated 20-minute car route (test/support/gps_route.dart: ~15 m/s, turns, red lights, 1 Hz fixes, jitter, accuracy 5..45 m, 3..8 s signal dips) through the Map tab with 3,934 network hex cells, 60 repeaters and a 300-ping history, and records frame cost (max of build and raster, `SchedulerBinding.addTimingsCallback`), event-loop lag (4 ms probe), puck updates per second, the arrow's per-frame step against the true route and its position on the screen.

## Measurements (90 s window, iPhone 17 Pro simulator on a loaded M-series Mac, 60 Hz)

| | before | after |
|---|---|---|
| frame p50 / p95 / p99 | 3.7 / 15.9 / 24.5 ms | 3.5 / 8.2 / 14.6 ms |
| worst frame | 137.6 ms | 23 ms |
| frames > 16.7 ms / > 50 ms | 240 / 2 | 24 / 0 |
| UI event-loop lag p99 / worst | 27 / 142 ms | 15 / 30 ms (two of nine runs showed a lone 91 and 108 ms spike while other builds ran on the machine; none with the frames) |
| puck updates | 29 per s (30 ms timer) | 59.8 per s = every frame |
| puck hops (> 3x the expected step) | 8 (biggest 17.6 m) | 0 (biggest frame step 0.9 m) |
| steps against the course | 14 | 0 |
| arrow position on screen while following | n/a (camera stepped 30x/s) | std 0.0000000002 px |

Simulator numbers are a floor: a phone is several times slower, so the margins matter more than the absolutes. With the cells removed the old build was already at p95 8.1 ms: the cell layer was ~8 ms of the p95 and ~110 ms of the worst frame.

## Where the time went (evidence)

1. `PolygonLayer` projected and culled every polygon on every camera move. The camera moved 30 times a second while following. (A/B: 3,934 cells vs 1: p95 15.9 vs 8.1 ms, worst 137 vs 26 ms.)
2. `DriveMapModel` notified the whole map every 20 m or 2 s: rebuilt thousands of `Polygon` objects with 4 colour lookups each, the ping markers and the labels.
3. `buildNetworkCells` (an FFI call per cell) ran on the UI isolate.
4. The old camera follow moved in 30 Hz steps and the puck ticked at 30 Hz, so on a 60/120 Hz screen the car moved in visible steps whatever the frame times.

Fixes: cached-picture cell layers (lib/ui/map/cell_raster_layer.dart), notifications every 100 m / 6 s, big cell sets built on another isolate, per-frame camera follow from the puck's own pose, bounds reports throttled to ~3 a second.
