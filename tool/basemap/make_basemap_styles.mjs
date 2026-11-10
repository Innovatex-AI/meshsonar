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
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const app = path.resolve(here, "../..");
const web = path.resolve(process.argv[2] ?? path.join(app, "../meshcore-insights"));
const require = createRequire(path.join(web, "package.json"));
const { layers: pmLayers, namedFlavor } = require("@protomaps/basemaps");

const TOKENS = {
  light: { paper: "#fafafa", ink: "#1b1f24", slate: "#5b636d", strong: "#2a7035", likely: "#2a6b9c", contour: "#5b636d" },
  dark: { paper: "#121417", ink: "#e6e8ea", slate: "#9aa2ab", strong: "#79be69", likely: "#6aaee0", contour: "#9aa2ab" },
};
const APP_FONT = "CupertinoSystemText";

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
      else set("text-color", col(t.slate));
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

function protomaps(theme) {
  const flavor = namedFlavor(theme === "dark" ? "black" : "white");
  const all = pmLayers("protomaps", flavor, { lang: "en" }).filter((l) => l.id !== "pois");
  return { version: 8, name: `meshsonar-protomaps-${theme}`, sources: { protomaps: { type: "vector" } }, layers: sanitize(tint(all, theme), { omt: false }) };
}

async function openfreemap(theme) {
  const url = `https://tiles.openfreemap.org/styles/${theme === "dark" ? "dark" : "positron"}`;
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  const s = await r.json();
  const layers = s.layers.filter((l) => !l.source || l.source === "openmaptiles");
  return { version: 8, name: `meshsonar-openfreemap-${theme}`, sources: { openmaptiles: { type: "vector" } }, layers: sanitize(tint(layers, theme), { omt: true }) };
}

const styles = {};
for (const theme of ["light", "dark"]) {
  styles[`protomaps-${theme}`] = protomaps(theme);
  styles[`openfreemap-${theme}`] = await openfreemap(theme);
}
const pkg = require("@protomaps/basemaps/package.json");
const camel = (k) => k.replace(/-(\w)/g, (_, c) => c.toUpperCase());
let dart = "// GENERATED by tool/basemap/make_basemap_styles.mjs. Do not edit by hand: re-run the tool.\n" +
  `// Sources: @protomaps/basemaps ${pkg.version} layers (BSD-3-Clause), OpenFreeMap Positron / Dark (OpenMapTiles styles,\n` +
  "// BSD-3-Clause code, CC-BY 4.0 design), tinted with the website palette (meshcore-insights src/styles.css).\n" +
  "// Map data (c) OpenStreetMap contributors (ODbL). Pure Dart.\n\n" +
  `/// @protomaps/basemaps version the Protomaps styles were generated from.\nconst basemapStylesProtomapsVersion = '${pkg.version}';\n\n`;
const Q = "'''";
for (const [k, v] of Object.entries(styles)) {
  const json = JSON.stringify(v);
  if (json.includes(Q)) throw new Error(`${k} contains ${Q}`);
  dart += `/// ${k}: ${v.layers.length} layers.\nconst ${camel(k)}StyleJson = r${Q}${json}${Q};\n\n`;
}
const out = path.join(app, "lib/core/basemap_styles.g.dart");
writeFileSync(out, dart);
console.log(`wrote ${out}`);
