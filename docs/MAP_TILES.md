# Map tiles: sources, cache, licences

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

There are no downloadable offline maps (removed in 0.46.0, build 76: the pack screen, the PMTiles reader, the pack style
and the coverage snapshots; files an older build downloaded are deleted at launch, `lib/core/removed_map_packs.dart`). What
stays is the ordinary tile cache: a tile that was drawn once is kept on the phone (flutter_map's built-in cache, through
`MeshTileProvider`) and shown again with no signal, stale if need be.

Base map styles (the cycler): **Chart** (our map, light or dark with the app theme), **Light** (always the light style; id
`street`), **Dark** (always the dark style), **Topo** and **Satellite** (M3, Nov 12 2026; offered only while the Map Definition
advertises `basemap.topo` / `basemap.satellite`, an older cached definition offers the first three and a saved Topo / Satellite
is drawn as Chart).

- **Topo** is our own vector tiles in the definition's topographic palette (`basemaps[topo].topo`: Protomaps' light / dark
  flavour with the overrides laid over it, baked into `lib/core/basemap_styles.g.dart` by `tool/basemap/make_basemap_styles.mjs`
  from `assets/map/map-definition.json`). OpenTopoMap is no longer called. (The definition's `offline` flag on a basemap is read past; the app does not use it.)
  Not drawn: the terrarium hillshade the website adds (no raster-DEM renderer in the app), recorded as a decision in the CHANGELOG.
- **Satellite** is raster imagery from the definition's sources, bottom to top: Esri World Imagery through MeshSonar's own proxy
  (`/api/map/satellite/esri/{z}/{y}/{x}`; left out when `esriAvailable` is false), then USGS NAIP over the contiguous US
  (native z16, drawn to z17), then our town and road names (labels-only black flavour) over the imagery inside our extract
  (`ui/map/satellite_layers.dart`). Tiles go through the same `MeshTileProvider` (disk cache, request gate, circuit breaker).
  No key, header or identifier is sent to any imagery host. With no network every base map shows "No connection. The map
  shows only places you have looked at before." (`map-needs-network`) instead of a silent blank map.

## Which map engine, and why vector (decision M2, Nov 9 2026)

The app's engine is flutter_map. It draws raster tiles natively and vector tiles through vector_map_tiles. Neither our tile server nor OpenFreeMap serves raster tiles, and running a raster render
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
  **"Protomaps © OpenStreetMap contributors"** on our tiles, **"OpenFreeMap © OpenStreetMap
  contributors"** on the fallback, the definition's imagery credits on Satellite ("Powered by Esri. Source: Esri, Maxar, Earthstar
  Geographics, and the GIS User Community", "Imagery: USGS National Map (NAIP)", plus ours). test/lint/map_credit_test.dart fails if a FlutterMap has no
  shared credit or draws its own raster tile layer.
- OpenStreetMap data © OpenStreetMap contributors (ODbL). Protomaps basemap layers (@protomaps/basemaps, BSD-3-Clause).
  OpenFreeMap: OpenMapTiles styles (BSD-3-Clause code, CC-BY 4.0 design), free and keyless.
- Esri World Imagery: terms require the attribution on the map (the proxy holds the key; never in the app). USGS National Map
  (NAIP): public-domain imagery, credited.
- Hosts are pinned by `test/integration/hosts_static_test.dart`.
