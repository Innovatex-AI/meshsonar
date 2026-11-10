# Map tiles: sources, cache, offline packs, licences

Since 0.32.0 (plan unified-map-system §2.3, phase M2) every map in the app draws ONE basemap: our own Protomaps vector
tiles, the same tiles and the same light / dark styles as the website, with OpenFreeMap as the automatic fallback.
OpenStreetMap's community tile server is no longer used anywhere (test/lint/no_osm_tile_server_test.dart fails if its
host appears in the app sources or assets).

Drawn as layers (lib/ui/map/coverage_map.dart and every small map, lib/ui/map/basemap_layer.dart):

1. **Chart grid** (always): the lat/lon paper you see with nothing loaded. Never blank.
2. **Online basemap** (`BasemapLayer`): vector tiles from `https://api.meshsonar.com/basemap/t/na-20261108/{z}/{x}/{y}.bin`
   (meshsonar-infra `stack/basemap`, North America z0-14, Cloudflare edge-cached), rendered on the phone by
   vector_map_tiles in raster mode with the styles in `lib/core/basemap_styles.g.dart`. Each tile goes through
   `MeshTileProvider` (`tile_source.dart`): disk cache first, stale beats blank, 6 requests at most, 8 s timeout, no
   retries, circuit breaker, the phone's offline state; a 204 (empty tile) is a tile, not a failure.
3. **Offline region pack** (`OfflineBasemapLayer`): drawn on top for the pack covering the view centre; tiles it draws are
   never requested online.

Base map styles (the cycler): **Chart** (our map, light or dark with the app theme), **Light** (always the light style; id
`street`), **Dark** (always the dark style), **Topo** (OpenTopoMap raster, until M3 brings our own Topo).

## Which map engine, and why vector (decision M2, Nov 9 2026)

The app's engine is flutter_map. It draws raster tiles natively and vector tiles through vector_map_tiles (already used
for offline packs since WP13). Neither our tile server nor OpenFreeMap serves raster tiles, and running a raster render
server would be new infrastructure, so the app draws our vector tiles itself (raster mode: each tile is rendered to an
image once and cached, every overlay keeps working unchanged). The styles are generated from the website's own code:
`node tool/basemap/make_basemap_styles.mjs` builds @protomaps/basemaps layers (white / black flavours, no POIs), applies
the website's `tintBasemap()` recipe with the website token values, fetches OpenFreeMap Positron / Dark through the same
tint, and reduces every expression to what vector_tile_renderer 6.1 reads (test/ui/map/basemap_styles_test.dart: zero
renderer warnings, real tiles from both servers render as light / dark maps). Re-run it when the website palette or
`@protomaps/basemaps` changes. Not done in M2 (the M2 phase proper renders from the Map Definition): basemap labels drawn
above coverage (the website does; here labels are part of the basemap image under the overlays).

## Fallback (same rules as the website, `lib/core/basemap.dart`)

- Health probe `GET https://api.meshsonar.com/basemap/t/<archive>.json`, 4 s budget, at most once a minute for the whole
  app; a failed probe draws OpenFreeMap until a later probe answers.
- 4 tile failures in a row mid-session switch to OpenFreeMap (until the next probe in a minute).
- A view outside the extract (`viewInsideOurBasemap`, the website's `viewInsideBasemap`) draws OpenFreeMap; back to ours
  when the view returns.
- OpenFreeMap's tile URL comes from its TileJSON (`https://tiles.openfreemap.org/planet`, host pinned), read once when first
  needed; a built-in URL is used until then. 4 OpenFreeMap failures pause it for a minute; with both down, the chart grid.

## Labels and fonts (the glyph caveat, resolved)

Labels are Flutter text drawn on the phone in the system font (`CupertinoSystemText` = SF Pro on iOS): the styles' every
`text-font` is that family and the app never loads glyph PBFs or sprites. So the server's Noto glyphs
(`/basemap/fonts/`) serve only the website, Barlow is not used by any map, and SF Pro (which may not be redistributed as
glyph PBFs) needs no server copy. Decision recorded in meshsonar-infra HANDOFF (M2 entry).

## Licences and attribution

- The credit is always on the map, no interaction needed: the Drive map's `AttributionLine` (12 pt, bottom right, (i) opens
  the Credits sheet) and every small map's `MiniMapCredit` (= `BasemapCredit`). Both name the source drawn right now:
  **"Protomaps © OpenStreetMap contributors"** on our tiles and on M2 offline packs, **"OpenFreeMap © OpenStreetMap
  contributors"** on the fallback, Topo's own line on Topo. test/lint/map_credit_test.dart fails if a FlutterMap has no
  shared credit or draws its own raster tile layer.
- OpenStreetMap data © OpenStreetMap contributors (ODbL). Protomaps basemap layers (@protomaps/basemaps, BSD-3-Clause).
  OpenFreeMap: OpenMapTiles styles (BSD-3-Clause code, CC-BY 4.0 design), free and keyless.
- OpenTopoMap: CC-BY-SA, credit "© OpenStreetMap contributors, SRTM | Map style © OpenTopoMap (CC-BY-SA)"; max zoom 17.
- Hosts are pinned by `test/integration/hosts_static_test.dart`.

## Offline packs (M2)

A pack is one region's road basemap (an extract of the same North America archive, z0-14, schema `protomaps`) plus a
coverage snapshot (`<CODE>.coverage.pmtiles`: Measured z6-13 and Predicted z8-13 coverage v2 tiles of the region's default
preset, both layers in each tile) plus repeaters, which ride on the app's on-disk repeater store (`repeater_sync.dart`,
read at launch before any network call, so pins and names work offline). Built on the server by meshsonar-infra
`stack/basemap/build-packs.py`, served from `https://api.meshsonar.com/basemap/packs/` (manifest + immutable files,
range requests for resume). Pack style = the online style, so moving in or out of a pack changes nothing on screen.

- Manifest `https://api.meshsonar.com/basemap/packs/manifest.json`; each entry adds `schema` and a `coverage` block
  (`url`, `bytes`, `sha256`, `version`, `preset`). While it is not published (404) the app reads the pre-M2 manifest on
  `tiles.meshsonar.com` (OpenMapTiles packs, drawn with the old `offline_style.dart` until updated).
- Coverage snapshot: downloaded after the basemap file, size + SHA-256 checked, written atomically; a failed one never
  replaces a good one. Refreshed at launch at most every 12 h (Wi-Fi rule respected); the server rebuilds it nightly.
- When the network fails, the coverage layers read the pack snapshot (`CoverageTileStore.offlineTiles`), first while the
  layer is offline; the live tile replaces it once the network is back. Deeper zooms use the z13 hexagons as stand-ins.

### Pre-M2 packs (`offlineStyleVersion` bump rule, web styles, Barlow glyph stacks)
Kept only for packs installed before M2 and the website's old pack styles on tiles.meshsonar.com:

### `offlineStyleVersion` bump rule
`offlineStyleVersion` (`lib/core/offline_style.dart`) and the manifest's `style_version` are one number. Bump both, in the same release, whenever the offline style changes in a way an installed pack must pick up: layer set, colours, label fonts or sizes, source-layer names. Do not bump for a new or rebuilt pack (that is the pack `version`) or for app-only code that does not change the style JSON. The website styles at `styles/v<N>/` are regenerated from the same code (`dart run tool/make_web_styles.dart`), uploaded under the new `v<N>` path before the manifest points at them, and the old `v<N-1>` path stays.

### Glyph stacks (web only)
The app does not use baked glyph PBFs: the offline vector pack is drawn by `vector_map_tiles` in raster mode and labels are Flutter text (`offline_basemap.dart`, app target of `offline_style.dart`), so the app typeface change to SF Pro touches only the app-target `text-font` entries. The glyph PBFs under `tiles.meshsonar.com/fonts/` (Barlow-Regular, Barlow-Medium, BarlowSemiCondensed-SemiBold, SIL OFL, built with `build_pbf_glyphs` 1.4.3, recipe in `meshsonar-infra/tiles/upload-v4/README.md`) are used only by MapLibre on the website. Decision (Drive D14): they stay as they are until the website typeface changes. SF Pro cannot be used for glyph stacks (Apple licence). If the website typeface changes: re-bake the stacks from an open font under the OFL into a new `fonts/<Stack>/` path, point a new style version at them, bump `style_version` per the rule above, keep the Barlow stacks published.
