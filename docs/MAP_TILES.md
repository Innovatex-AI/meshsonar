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

Base map choices (the picker in Layers; build 77, redesign Round 1 N3). `lib/core/map_styles.dart`:

| Choice | Saved id | What it draws |
|---|---|---|
| **Road** | `chart` | Our road map, light or dark with the app theme. Called Chart before build 77. |
| **Light** | `street` | The same map, always light (sunlight). Always offered since build 77: builds 74 to 76 hid it when the definition merged Chart and Light, which left a dark-theme user with no light road map. |
| **Dark** | `dark` | The same map, always dark. |
| **Topo** | `topo` | Our tiles in the definition's topographic palette. |
| **Satellite** | `satellite` | Aerial imagery with our names over it. |

Topo and Satellite are offered only while the Map Definition advertises `basemap.topo` / `basemap.satellite` (an older
cached definition offers the first three and a saved Topo / Satellite is drawn as Road). Saved ids never change, so every
older build's setting maps onto a choice (`BaseMapStyle.parse`; the definition's own names `road` and `light` are read
too; anything unknown is Road).

Each choice has a real thumbnail, `assets/map/thumbs/{road,light,dark,topo-light,topo-dark,satellite}.png` (360 x 168 px,
downtown Columbus; Road is the light and the dark map split on the diagonal because it follows the theme):
`BaseMapStyle.thumbnailAsset(appDark:)`. They are rendered from the styles themselves with MapLibre in headless Chromium:

    node tool/basemap/make_basemap_styles.mjs <meshcore-insights> --thumbs <scratch>/styles
    node tool/basemap/make_basemap_thumbs.mjs <meshcore-insights> <scratch>/styles

(maplibre-gl and playwright come from the website checkout's node_modules; set `CHROMIUM=<binary>` when the Chromium that
playwright version expects is not installed. Needs the network and ImageMagick.) Re-run both when a style changes.

### What a choice draws: coverage off, coverage on (build 77, N3 / F2 / F14)

`BaseMapStyle.resolve(choice, appDark:, coverageOn:, labelsAbove:)` answers with the look of the bottom layer and, when
there is one, the look of a names-only pass to draw ABOVE the coverage (`ui/map/satellite_layers.dart`
`basemapLayersFor` / `basemapLabelsLayerFor` build the two widgets):

| Choice | Coverage off | Coverage on |
|---|---|---|
| Road, Light, Dark | `road` (names inside) | `dataBase` under the coverage, `dataLabels` above it |
| Topo | `topo` (names inside) | `topoBase` under, `topoLabels` above |
| Satellite | imagery, `labels` straight over it | imagery under, `labels` above |

- **Data-first** (`protomaps-data-light` / `-dark`, the `DATA` table in `tool/basemap/make_basemap_styles.mjs`) is the road
  map made quiet for data: no building outlines until street zoom (16), side streets at about half their strength and
  without casings while motorways and main roads are stronger, brighter water, the faint land-use washes not drawn, side-street
  names one zoom later (16) and no house numbers, names in full ink on a solid halo. Light gets the same treatment, so
  coverage over a dense street grid is no longer a wash over grey hatching (F14).
- **Names above coverage** (the definition's `labels.basemapLabelsAboveCoverage`). The base and the names pass are the two
  halves of one generated style, split when the app reads it (`lib/core/basemap.dart` `BasemapLook`; ids
  `<style>-base` / `<style>-labels`, so their renders never mix in the tile caches). Cost: a second vector layer over the
  same tiles; `labelsAbove: false` keeps one layer (the `data` look with its names inside) for a small map or a device
  that fails the map performance gate (`docs/MAP_PERFORMANCE.md`).
- **Not on the OpenFreeMap fallback.** OpenFreeMap has one style per theme and no names-only style. While the fallback
  draws (our server down, or the view outside the extract) the base layer is OpenFreeMap's own map with its names inside,
  the names pass draws nothing, and names are under the coverage as before build 77. There is no data-first fallback
  style either.
- On the dark road map and the dark fallback, names are ink at 80 % instead of slate (grey on grey was hard to read). This
  is the one place the app's road style differs from the website's `tintBasemap()`.
- **Cache version.** `basemapRenderVersion` is 3 (was 2): every style's identity changed, so a phone never draws a render
  build 76 cached, and those files are deleted once at first launch (`ui/map/basemap_cache.dart`).
- Nothing is published on the server for any of this: styles are bundled in the app (`lib/core/basemap_styles.g.dart`),
  the tiles are the same archive.

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
`@protomaps/basemaps` changes. Basemap names above coverage arrived in build 77 (see "What a choice draws" above); until
then names were part of the basemap image under the overlays.

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
