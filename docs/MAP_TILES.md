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

## Offline packs on tiles.meshsonar.com (WP13, Nov 2026)

Packs: CMH (Columbus), DAY (Dayton), CVG (Cincinnati). Each is one immutable PMTiles v3 file named `<CODE>-v<yymmdd>.pmtiles` (gzip tiles, z0-14, OpenMapTiles schema, bbox = the region's bbox from `/api/cmh/regions-index`). DAY is built from the Ohio + Indiana extracts, CVG from Ohio + Indiana + Kentucky (merged with osmium; `meshsonar-infra/scripts/tiles/build-region-pack.sh`). Topo has no pack and never works offline; the base-style sheet row says "needs signal".

**Publishing rule (additive only):** upload the new pack file(s) first, then replace `manifest.json` last. A published pack file is never overwritten in place and old versions are kept until clients have updated (a changed pack means a new filename and a new `version`). `meshsonar-infra/scripts/tiles/check-manifest.sh` HEADs every pack in the live manifest (200, `content-length` equals the manifest `bytes`, `accept-ranges: bytes`, host pinned, style files 200) and requires CMH, DAY and CVG; run it before and after every publish. Test: `test/core/offline_pack_regions_test.dart` (3-tile fixture with the DAY and CVG bboxes, manifest with three packs).

### `offlineStyleVersion` bump rule
`offlineStyleVersion` (`lib/core/offline_style.dart`) and the manifest's `style_version` are one number. Bump both, in the same release, whenever the offline style changes in a way an installed pack must pick up: layer set, colours, label fonts or sizes, source-layer names. Do not bump for a new or rebuilt pack (that is the pack `version`) or for app-only code that does not change the style JSON. The website styles at `styles/v<N>/` are regenerated from the same code (`dart run tool/make_web_styles.dart`), uploaded under the new `v<N>` path before the manifest points at them, and the old `v<N-1>` path stays.

### Glyph stacks (web only)
The app does not use baked glyph PBFs: the offline vector pack is drawn by `vector_map_tiles` in raster mode and labels are Flutter text (`offline_basemap.dart`, app target of `offline_style.dart`), so the app typeface change to SF Pro touches only the app-target `text-font` entries. The glyph PBFs under `tiles.meshsonar.com/fonts/` (Barlow-Regular, Barlow-Medium, BarlowSemiCondensed-SemiBold, SIL OFL, built with `build_pbf_glyphs` 1.4.3, recipe in `meshsonar-infra/tiles/upload-v4/README.md`) are used only by MapLibre on the website. Decision (Drive D14): they stay as they are until the website typeface changes. SF Pro cannot be used for glyph stacks (Apple licence). If the website typeface changes: re-bake the stacks from an open font under the OFL into a new `fonts/<Stack>/` path, point a new style version at them, bump `style_version` per the rule above, keep the Barlow stacks published.
