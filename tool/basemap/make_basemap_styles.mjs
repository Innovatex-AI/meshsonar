// Writes the app's basemap styles (lib/core/basemap_styles.g.dart) from the SAME sources the website draws
// (meshcore-insights src/components/tools/map-style.ts): our Protomaps tiles with @protomaps/basemaps layers, white
// flavour (light) / black flavour (dark), no POIs, tinted by the website's tintBasemap() recipe with the website's
// token values; and the OpenFreeMap fallback (Positron / Dark) through the same tint. Plan unified-map-system §2.3, M2.
//
//   node tool/basemap/make_basemap_styles.mjs [path to meshcore-insights]   (default ../meshcore-insights)
//
// The app draws these with vector_tile_renderer (flutter_map + vector_map_tiles, raster mode), which supports a subset
// of the MapLibre expression language, so each style is reduced to what it can read (sanitize() below; the Dart test
// test/ui/map/basemap_styles_test.dart fails if the renderer warns about anything left):
//   - ["literal", x] is inlined; ["in", ["get", k], [..]] becomes the legacy ["in", k, ..] the renderer reads;
//   - every text-field becomes the English name (coalesce name:en, name); the multi-script "format" sections are for
//     scripts the app never meets in North America;
//   - text-font becomes the app's system font (SF Pro, "CupertinoSystemText"): labels are Flutter text, drawn on the
//     phone, so no glyph PBFs are needed and Barlow is not used (app-typeface decision, Nov 2 2026);
//   - icons (sprites), shields and one-way arrows are dropped: the app ships no sprite sheet and the map is about the mesh.
// Website token values (src/styles.css :root / .dark) are copied below; re-run when the website palette changes.
//
// Build 77 (redesign Round 1, N3 / F2 / F14):
//   - protomaps-data-light / protomaps-data-dark: the "data-first" road map the app draws while coverage is on (dataFirst()
//     below): no building outlines until street zoom, side streets dimmer than main roads, brighter water, fewer street
//     names, and names in full ink on a solid halo so they read when they are drawn ABOVE the coverage. The app splits each
//     into a base without names and a names-only pass at run time (lib/core/basemap.dart, BasemapLook.dataBase / dataLabels);
//     Topo is split the same way. Nothing extra is generated for the split.
//   - on the dark road map and the dark fallback, names are ink at 80 % instead of slate (grey on grey was hard to read).
//   - `--thumbs <dir>` also writes MapLibre versions of the picker styles (same layers and colours, before the reduction
//     for the phone renderer) for tool/basemap/make_basemap_thumbs.mjs, which renders assets/map/thumbs/*.png from them.
import { createRequire } from "node:module";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const app = path.resolve(here, "../..");
const argv = process.argv.slice(2);
const thumbsAt = argv.indexOf("--thumbs");
const thumbsDir = thumbsAt >= 0 ? path.resolve(argv.splice(thumbsAt, 2)[1]) : null;
const web = path.resolve(argv[0] ?? path.join(app, "../meshcore-insights"));
const require = createRequire(path.join(web, "package.json"));
const { layers: pmLayers, namedFlavor } = require("@protomaps/basemaps");

const TOKENS = {
  light: { paper: "#fafafa", ink: "#1b1f24", slate: "#5b636d", strong: "#2a7035", likely: "#2a6b9c", contour: "#5b636d" },
  dark: { paper: "#121417", ink: "#e6e8ea", slate: "#9aa2ab", strong: "#79be69", likely: "#6aaee0", contour: "#9aa2ab" },
};
const APP_FONT = "CupertinoSystemText";

// Every style carries its own `id` and `metadata.version`. vector_tile_renderer reads them as the theme's identity, and
// vector_map_tiles keys its rendered-tile caches (memory AND disk) and its isolate registries on that identity. Without them
// every style was "default / none", so a tile rendered in one style was served for all the others (build 71 iPad report).
// The version is the app's ONE basemap render version (lib/core/basemap.dart, `basemapRenderVersion`): bump it there, then
// re-run this tool; the app also applies it when it reads a style, so a bump takes effect even before the next regeneration.
const RENDER_VERSION = (() => {
  const m = /const int basemapRenderVersion = (\d+);/.exec(readFileSync(path.join(app, "lib/core/basemap.dart"), "utf8"));
  if (!m) throw new Error("lib/core/basemap.dart: `const int basemapRenderVersion = N;` not found");
  return m[1];
})();
/** The identity fields of a style named [name]. */
const identity = (name) => ({ id: name, metadata: { version: RENDER_VERSION } });

const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
const col = (hex, a = 1) => { const [r, g, b] = rgb(hex); return a >= 1 ? `rgb(${r},${g},${b})` : `rgba(${r},${g},${b},${a})`; };

/** website tintBasemap(), same regexes, same alphas. */
function tint(layers, theme) {
  const t = TOKENS[theme], dark = theme === "dark";
  for (const l of layers) {
    const id = l.id;
    const set = (prop, v) => {
      l.paint = { ...(l.paint ?? {}), [prop]: v };
      // vector_tile_renderer replaces the colour's own alpha with *-opacity when both are set (MapLibre multiplies them),
      // so the tinted rgba(...) alpha would be lost (white roads on the dark map): fold a numeric opacity into the colour
      // and drop an expression one (the tint alpha is the website's look at every zoom anyway).
      const op = prop.replace(/-color$/, "-opacity");
      const m = /^rgba\((\d+),(\d+),(\d+),([\d.]+)\)$/.exec(v);
      if (m && op !== prop && l.paint[op] !== undefined) {
        const o = l.paint[op];
        delete l.paint[op];
        if (typeof o === "number") l.paint[prop] = `rgba(${m[1]},${m[2]},${m[3]},${+(m[4] * o).toFixed(3)})`;
      }
    };
    if (l.type === "background" || id === "earth") set(l.type === "background" ? "background-color" : "fill-color", col(t.paper));
    else if (l.type === "fill") {
      if (/water/.test(id)) set("fill-color", col(t.likely, dark ? 0.22 : 0.16));
      else if (/park|wood|forest|grass|landcover|nature|golf|cemetery/.test(id)) set("fill-color", col(t.strong, dark ? 0.1 : 0.08));
      else if (/building/.test(id)) set("fill-color", col(t.ink, dark ? 0.08 : 0.06));
      else if (/landuse|residential|aeroway/.test(id)) set("fill-color", col(t.ink, dark ? 0.03 : 0.025));
    } else if (l.type === "line") {
      if (/waterway|river|stream|canal/.test(id)) set("line-color", col(t.likely, dark ? 0.45 : 0.4));
      else if (/boundary/.test(id)) set("line-color", col(t.contour, 0.45));
      else if (/road|highway|street|bridge|tunnel|path|rail/.test(id)) set("line-color", col(t.ink, /casing|case/.test(id) ? (dark ? 0.12 : 0.1) : (dark ? 0.2 : 0.16)));
    } else if (l.type === "symbol") {
      if (/water|river|lake/.test(id)) set("text-color", col(t.likely, 0.85));
      // App only (build 77): on the dark map slate names were grey on grey; ink at 80 % reads. Light keeps slate.
      else set("text-color", dark ? col(t.ink, 0.8) : col(t.slate));
      set("text-halo-color", col(t.paper, 0.9));
    }
  }
  return layers;
}

/** Rewrites one expression into the subset vector_tile_renderer 6.1 reads. */
function expr(x) {
  if (!Array.isArray(x)) return x;
  if (x.length === 0) return x;
  const [op, ...args] = x;
  if (op === "literal") return args[0];
  if (op === "in" && Array.isArray(args[0]) && args[0][0] === "get" && args.length === 2) {
    const values = Array.isArray(args[1]) && args[1][0] === "literal" ? args[1][1] : args[1];
    return ["in", args[0][1], ...values];
  }
  if (op === "!" && Array.isArray(args[0]) && args[0][0] === "in") {
    const inner = expr(args[0]);
    if (typeof inner[1] === "string") return ["!in", ...inner.slice(1)];
  }
  if (op === "match" && Array.isArray(args[0]) && args[0][0] === "geometry-type") {
    // OpenFreeMap: ["match", ["geometry-type"], ["MultiPolygon", "Polygon"], true, false] -> a $type test
    const out = [];
    for (let i = 1; i + 1 < args.length; i += 2) {
      const labels = Array.isArray(args[i]) ? args[i] : [args[i]];
      if (args[i + 1] === true) out.push(...labels.map((g) => g.replace(/^Multi/, "")));
    }
    const uniq = [...new Set(out)];
    return uniq.length === 1 ? ["==", "$type", uniq[0]] : ["any", ...uniq.map((g) => ["==", "$type", g])];
  }
  if (op === "geometry-type") return "$type";
  if ((op === "==" || op === "!=") && Array.isArray(args[0]) && args[0][0] === "typeof" && Array.isArray(args[0][1]) && args[0][1][0] === "get") {
    // OpenFreeMap: ["==", ["typeof", ["get", k]], "number"] -> ["has", k] (the field is numeric whenever present)
    return [op === "==" ? "has" : "!has", args[0][1][1]];
  }
  return [op, ...args.map(expr)];
}

const NAME = ["coalesce", ["get", "name:en"], ["get", "name"]];
const NAME_OMT = ["coalesce", ["get", "name:en"], ["get", "name:latin"], ["get", "name"]];

function has(x, op) {
  if (!Array.isArray(x)) return false;
  return x[0] === op || x.some((e) => has(e, op));
}

function sanitize(layers, { omt }) {
  const out = [];
  for (const l0 of layers) {
    const l = JSON.parse(JSON.stringify(l0));
    if (l.type !== "background" && l.type !== "fill" && l.type !== "line" && l.type !== "symbol") continue; // raster, extrusion, circle
    if (l.id === "pois" || l.id === "roads_shields" || l.id === "roads_oneway" || /shield|oneway|poi|aerodrome_label|highway-shield/.test(l.id)) continue;
    if (l.filter) l.filter = expr(l.filter);
    for (const k of ["paint", "layout"]) {
      if (!l[k]) continue;
      for (const [p, v] of Object.entries(l[k])) l[k][p] = expr(v);
    }
    if (l.layout) {
      delete l.layout["icon-image"];
      delete l.layout["icon-size"];
      delete l.layout["symbol-sort-key"];
      if (l.layout["text-field"] !== undefined) {
        const tf = l.layout["text-field"];
        const simple = typeof tf === "string" ? tf : null;
        if (has(tf, "format") || has(tf, "is-supported-script") || (simple && /name/.test(simple))) l.layout["text-field"] = omt ? NAME_OMT : NAME;
        l.layout["text-font"] = [APP_FONT];
      }
    }
    if (l.paint) {
      for (const p of Object.keys(l.paint)) if (p.startsWith("icon-")) delete l.paint[p];
    }
    if (l.type === "symbol" && l.layout?.["text-field"] === undefined) continue; // icon-only
    if (has(l.filter, "length") || has(l.layout?.["text-field"], "length")) continue;
    out.push(l);
  }
  return out;
}

/** The tinted Protomaps road layers of [theme] (MapLibre form, before sanitize()). */
function protomapsTinted(theme) {
  const flavor = namedFlavor(theme === "dark" ? "black" : "white");
  return tint(pmLayers("protomaps", flavor, { lang: "en" }).filter((l) => l.id !== "pois"), theme);
}
function protomaps(theme) {
  return { version: 8, name: `meshsonar-protomaps-${theme}`, ...identity(`meshsonar-protomaps-${theme}`), sources: { protomaps: { type: "vector" } }, layers: sanitize(protomapsTinted(theme), { omt: false }) };
}

/** Build 77 "data-first" knobs: the road map under coverage. Alphas are [dark, light] of the theme's ink / water / green. */
const DATA = {
  road: { highway: [0.36, 0.3], major: [0.27, 0.22], link: [0.16, 0.13], minor: [0.1, 0.075], service: [0.06, 0.05], rail: [0.08, 0.07], runway: [0.14, 0.12] },
  casing: [0.12, 0.1], // main roads only; side-street casings are not drawn
  water: [0.36, 0.28],
  waterway: [0.6, 0.5],
  park: [0.07, 0.06],
  building: [0.05, 0.04],
  buildingMinZoom: 16, // street zoom: no building outlines under coverage before it
  minorNamesMinZoom: 16, // side-street names one zoom later than the road map (15)
  roadName: [0.92, 0.85],
  halo: 0.92,
  haloWidth: 1.5,
};
/** Which road class a Protomaps road layer id draws. */
function roadClass(id) {
  if (/runway/.test(id)) return "runway";
  if (/rail/.test(id)) return "rail";
  if (/highway/.test(id)) return "highway";
  if (/major/.test(id)) return "major";
  if (/link/.test(id)) return "link";
  if (/minor_service|other|pier|taxiway/.test(id)) return "service";
  return "minor";
}
/** The data-first road map: the tinted road layers with the busy parts taken out or turned down (see DATA). */
function dataFirst(layers, theme) {
  const t = TOKENS[theme], i = theme === "dark" ? 0 : 1;
  const out = [];
  for (const l of layers) {
    const id = l.id;
    if (l.type === "fill") {
      if (/water/.test(id)) l.paint["fill-color"] = col(t.likely, DATA.water[i]);
      else if (id === "landuse_park") l.paint["fill-color"] = col(t.strong, DATA.park[i]);
      else if (/building/.test(id)) {
        l.minzoom = DATA.buildingMinZoom;
        l.paint["fill-color"] = col(t.ink, DATA.building[i]);
      } else if (/landuse/.test(id)) continue; // the faint land-use washes: not worth a layer under coverage
    } else if (l.type === "line") {
      if (/^water/.test(id)) l.paint["line-color"] = col(t.likely, DATA.waterway[i]);
      else if (/^roads_/.test(id)) {
        const k = roadClass(id);
        if (/casing/.test(id)) {
          if (k !== "highway" && k !== "major") continue;
          l.paint["line-color"] = col(t.ink, DATA.casing[i]);
        } else l.paint["line-color"] = col(t.ink, DATA.road[k][i]);
      }
    } else if (l.type === "symbol") {
      if (id === "address_label") continue;
      if (id === "roads_labels_minor") l.minzoom = DATA.minorNamesMinZoom;
      if (/water/.test(id)) l.paint["text-color"] = col(t.likely, theme === "dark" ? 0.95 : 0.9);
      else l.paint["text-color"] = /^roads_/.test(id) ? col(t.ink, DATA.roadName[i]) : col(t.ink);
      l.paint["text-halo-color"] = col(t.paper, DATA.halo);
      l.paint["text-halo-width"] = DATA.haloWidth;
    }
    out.push(l);
  }
  return out;
}
function protomapsData(theme) {
  return { version: 8, name: `meshsonar-protomaps-data-${theme}`, ...identity(`meshsonar-protomaps-data-${theme}`), sources: { protomaps: { type: "vector" } }, layers: sanitize(dataFirst(protomapsTinted(theme), theme), { omt: false }) };
}

/** M3 Topo: the definition's `basemaps[topo].topo` (Protomaps light / dark flavour with the palette overrides laid over it, landcover merged key
 *  by key), UNTINTED, exactly as the website draws it (meshcore-insights src/components/tools/map-style.ts `topoFlavor`). The overrides are read from the
 *  bundled definition (assets/map/map-definition.json), so a new definition palette is one re-run of this tool. */
function topoFlavor(theme) {
  const def = JSON.parse(readFileSync(path.join(app, "assets/map/map-definition.json"), "utf8"));
  const topo = def.basemaps.find((b) => b.id === "topo")?.topo;
  if (!topo) throw new Error("the bundled definition has no basemaps[topo].topo");
  const base = namedFlavor(topo.base[theme]);
  const { landcover, ...rest } = topo.overrides[theme];
  return { ...base, ...rest, landcover: { ...(base.landcover ?? {}), ...(landcover ?? {}) } };
}
const protomapsTopoLayers = (theme) => pmLayers("protomaps", topoFlavor(theme), { lang: "en" }).filter((l) => l.id !== "pois");
function protomapsTopo(theme) {
  const all = protomapsTopoLayers(theme);
  return { version: 8, name: `meshsonar-protomaps-topo-${theme}`, ...identity(`meshsonar-protomaps-topo-${theme}`), sources: { protomaps: { type: "vector" } }, layers: sanitize(all, { omt: false }) };
}
/** M3 Satellite labels: the black flavour's label layers only (town and road names), untinted, drawn over the imagery inside our extract. */
const protomapsLabelLayers = () => pmLayers("protomaps", namedFlavor("black"), { labelsOnly: true, lang: "en" }).filter((l) => !/^pois/.test(l.id));
function protomapsLabels() {
  const all = protomapsLabelLayers();
  return { version: 8, name: "meshsonar-protomaps-labels", ...identity("meshsonar-protomaps-labels"), sources: { protomaps: { type: "vector" } }, layers: sanitize(all, { omt: false }) };
}

async function openfreemap(theme) {
  const url = `https://tiles.openfreemap.org/styles/${theme === "dark" ? "dark" : "positron"}`;
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  const s = await r.json();
  const layers = s.layers.filter((l) => !l.source || l.source === "openmaptiles");
  return { version: 8, name: `meshsonar-openfreemap-${theme}`, ...identity(`meshsonar-openfreemap-${theme}`), sources: { openmaptiles: { type: "vector" } }, layers: sanitize(tint(layers, theme), { omt: true }) };
}

const styles = {};
for (const theme of ["light", "dark"]) {
  styles[`protomaps-${theme}`] = protomaps(theme);
  styles[`openfreemap-${theme}`] = await openfreemap(theme);
  styles[`protomaps-topo-${theme}`] = protomapsTopo(theme);
  styles[`protomaps-data-${theme}`] = protomapsData(theme);
}
styles["protomaps-labels"] = protomapsLabels();
const pkg = require("@protomaps/basemaps/package.json");
const camel = (k) => k.replace(/-(\w)/g, (_, c) => c.toUpperCase());
let dart = "// GENERATED by tool/basemap/make_basemap_styles.mjs. Do not edit by hand: re-run the tool.\n" +
  `// Sources: @protomaps/basemaps ${pkg.version} layers (BSD-3-Clause), OpenFreeMap Positron / Dark (OpenMapTiles styles,\n` +
  "// BSD-3-Clause code, CC-BY 4.0 design), tinted with the website palette (meshcore-insights src/styles.css).\n" +
  "// Map data (c) OpenStreetMap contributors (ODbL). Pure Dart.\n\n" +
  `/// @protomaps/basemaps version the Protomaps styles were generated from.\nconst basemapStylesProtomapsVersion = '${pkg.version}';\n\n` +
  `/// The basemap render version these styles were baked with (lib/core/basemap.dart basemapRenderVersion).\nconst basemapStylesRenderVersion = ${RENDER_VERSION};\n\n` +
  `/// Every generated style, by name: a style added to the tool is listed here, and the tests check each has its own id.\nconst basemapStyleJsonByName = <String, String>{\n${Object.keys(styles).map((k) => `  '${k}': ${camel(k)}StyleJson,\n`).join("")}};\n\n`;
const Q = "'''";
for (const [k, v] of Object.entries(styles)) {
  const json = JSON.stringify(v);
  if (json.includes(Q)) throw new Error(`${k} contains ${Q}`);
  dart += `/// ${k}: ${v.layers.length} layers.\nconst ${camel(k)}StyleJson = r${Q}${json}${Q};\n\n`;
}
const out = path.join(app, "lib/core/basemap_styles.g.dart");
writeFileSync(out, dart);
console.log(`wrote ${out}`);

// --thumbs <dir>: the picker styles for MapLibre (tool/basemap/make_basemap_thumbs.mjs). Same layers and colours as the app
// styles above, kept in MapLibre's own expression language with the server's glyphs; no icons, shields or POIs either.
if (thumbsDir) {
  const def = JSON.parse(readFileSync(path.join(app, "assets/map/map-definition.json"), "utf8"));
  const road = def.basemaps.find((b) => b.id === "road").vector;
  const sat = def.basemaps.find((b) => b.id === "satellite").satellite;
  const forMapLibre = (layers) =>
    JSON.parse(JSON.stringify(layers))
      .filter((l) => !/shield|oneway|poi/.test(l.id))
      .map((l) => {
        for (const k of ["icon-image", "icon-size"]) delete l.layout?.[k];
        return l;
      })
      .filter((l) => l.type !== "symbol" || l.layout?.["text-field"] !== undefined);
  const vector = (layers) => ({ version: 8, glyphs: road.glyphs, sources: { protomaps: { type: "vector", tiles: [road.tiles], maxzoom: road.maxzoom } }, layers: forMapLibre(layers) });
  const thumbs = {
    "road-light": vector(protomapsTinted("light")),
    "road-dark": vector(protomapsTinted("dark")),
    "data-light": vector(dataFirst(protomapsTinted("light"), "light")),
    "data-dark": vector(dataFirst(protomapsTinted("dark"), "dark")),
    "topo-light": vector(protomapsTopoLayers("light")),
    "topo-dark": vector(protomapsTopoLayers("dark")),
    satellite: {
      version: 8,
      glyphs: road.glyphs,
      sources: {
        protomaps: { type: "vector", tiles: [road.tiles], maxzoom: road.maxzoom },
        ...Object.fromEntries(sat.sources.map((s) => [s.id, { type: "raster", tiles: [s.tiles], tileSize: s.tileSize, minzoom: s.minzoom, maxzoom: s.maxzoom, bounds: s.bounds }])),
      },
      layers: [
        { id: "background", type: "background", paint: { "background-color": "#1b2a1f" } },
        ...sat.sources.map((s) => ({ id: `satellite-${s.id}`, type: "raster", source: s.id, ...(s.layerMaxZoom ? { maxzoom: s.layerMaxZoom } : {}) })),
        ...forMapLibre(protomapsLabelLayers()),
      ],
    },
  };
  mkdirSync(thumbsDir, { recursive: true });
  for (const [k, v] of Object.entries(thumbs)) writeFileSync(path.join(thumbsDir, `${k}.json`), JSON.stringify(v));
  console.log(`wrote ${Object.keys(thumbs).length} MapLibre styles to ${thumbsDir}`);
}
