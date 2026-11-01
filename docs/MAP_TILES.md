# Map tiles: sources, cache, offline packs, licences

One base map, three sources, drawn as layers (lib/ui/map/coverage_map.dart, lib/ui/map/tile_source.dart):

1. **Chart grid** (always): the lat/lon paper you see with nothing loaded. Never blank.
2. **Online + disk-cached raster tiles** (`MeshTileProvider`): OpenStreetMap (Chart, Street, Dark styles) or OpenTopoMap (Topo). Cache first (flutter_map's built-in disk cache, 1 GB cap, honours the server's Cache-Control/ETag), stale tiles are shown rather than a blank when the refresh fails or there is no signal, at most 6 concurrent requests (newest tile first), every request is cancelled when its tile leaves the screen, 8 s timeout, no retries; three failures in a row open a circuit breaker for 15 s (cache only, no requests); the phone's own "offline" state closes it at once and coming back online re-requests the empty tiles. Tiles that an installed offline pack draws are skipped (no request, no cache read).
3. **Offline region pack** (PMTiles vector tiles, `OfflineBasemapLayer`): drawn on top for the pack that covers the view centre; outside the pack's area the online/cached tiles carry on, so there is no blank edge. Topo has no pack.

The chip at the bottom left of the map says which is in use: Online map, Offline map: <pack>, Saved map (no signal), No map here (no signal). Installed packs show as dashed outlines.

## Licences and attribution (unchanged rules, enforced by tests)

- OpenStreetMap data/tiles: © OpenStreetMap contributors (ODbL). The attribution pill is always on the map (`map-attribution`). `tile.openstreetmap.org` is the public community server; its usage policy (https://operations.osmfoundation.org/policies/tiles) asks apps not to bulk-download and to identify themselves. The provider sends `User-Agent: flutter_map (com.meshsonar.app)`, caches, bounds concurrency, never prefetches and never retries in a loop. If the app's tile traffic grows, move Street/Chart to a paid or self-hosted tile service; the host is a single constant in `lib/core/map_styles.dart`.
- OpenTopoMap: © OpenStreetMap contributors, SRTM | Map style © OpenTopoMap (CC-BY-SA); max zoom 17.
- Offline packs: built from OpenStreetMap data, served from tiles.meshsonar.com, same attribution.
- Hosts are pinned by `test/integration/hosts_static_test.dart`.

## What was verified and what was not

Unit tests (test/ui/map/tile_source_test.dart): cache hit with no request, 304 handling, stale-beats-blank, no cache + no network = empty tile and no exception, breaker open/probe/close, offline flag, bounded concurrency, newest first, cancellation, timeout, pack skip. Benchmark run with live OSM tiles on the simulator. NOT verified: a real drive through a no-signal area on a phone, a real pack's vector-layer render cost (no pack file on the build machine; only the 3-tile fixture), and the 1 GB cache growth over weeks.
