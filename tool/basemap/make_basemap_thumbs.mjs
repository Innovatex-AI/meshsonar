// Renders the base map picker thumbnails (assets/map/thumbs/*.png) from the REAL styles, with MapLibre in headless Chromium
// (build 77, redesign Round 1 N3: the picker showed flat colour blocks).
//
//   node tool/basemap/make_basemap_styles.mjs <meshcore-insights> --thumbs <scratch>/styles
//   node tool/basemap/make_basemap_thumbs.mjs <meshcore-insights> <scratch>/styles
//
// maplibre-gl and playwright come from the website checkout's node_modules (nothing is installed in the app repo). Each
// thumbnail is 360 x 168 px (the 120 x 56 pt picker tile at its widest, at 3x), downtown Columbus OH (river, park,
// motorway and street grid in one frame), drawn from our own tiles; Satellite from the definition's imagery sources with
// our names over it. "road" is the Road (auto) tile: the light map and the dark map split on the diagonal, because Road
// follows the app theme. Needs the network (tiles, glyphs, imagery) and ImageMagick (`magick`) for the split and to shrink
// the PNGs. Re-run when a style changes; test/core/basemap_choices_test.dart checks the files exist at the right size.
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const app = path.resolve(here, "../..");
const web = path.resolve(process.argv[2] ?? path.join(app, "../meshcore-insights"));
const stylesDir = path.resolve(process.argv[3] ?? "styles");
const outDir = path.join(app, "assets/map/thumbs");
const require = createRequire(path.join(web, "package.json"));
const { chromium } = require("playwright");
const maplibreDir = path.dirname(require.resolve("maplibre-gl/package.json"));

// Drawn on a 240 x 112 page at 1.5x: twice the picker tile, so the frame holds a few km of town and the names are miniature.
const W = 240, H = 112, SCALE = 1.5;
const VIEW = { center: [-83.002, 39.962], zoom: 12.3 };
const SHOTS = { light: "road-light", dark: "road-dark", "topo-light": "topo-light", "topo-dark": "topo-dark", satellite: "satellite" };

mkdirSync(outDir, { recursive: true });
// CHROMIUM=<path to a Chromium / headless_shell binary> picks the browser when the one this playwright version expects is
// not installed (any recent build works, e.g. the one the Python playwright on this Mac installed).
const browser = await chromium.launch({ ...(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {}), args: ["--disable-web-security", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"] });
const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: SCALE });
// maplibre-gl 6 is ES modules with its own worker file: served from a local port for the page to import.
const server = createServer((req, res) => {
  const name = path.basename(new URL(req.url, "http://x").pathname);
  if (name === "" || name === "index.html") {
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(`<!doctype html><html><head><link rel="stylesheet" href="/maplibre-gl.css"><style>html,body,#map{margin:0;width:${W}px;height:${H}px}</style></head><body><div id="map"></div><script type="module">import * as m from "/maplibre-gl.mjs"; window.maplibregl = m.default ?? m; window.ready = true;</script></body></html>`);
  }
  try {
    const body = readFileSync(path.join(maplibreDir, "dist", name));
    res.writeHead(200, { "content-type": name.endsWith(".css") ? "text/css" : "text/javascript" });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
await page.goto(`http://127.0.0.1:${server.address().port}/`);
await page.waitForFunction("window.ready === true");
for (const [name, styleName] of Object.entries(SHOTS)) {
  const style = JSON.parse(readFileSync(path.join(stylesDir, `${styleName}.json`), "utf8"));
  const errors = await page.evaluate(
    async ({ style, view }) => {
      document.getElementById("map").innerHTML = "";
      const errors = [];
      const map = new maplibregl.Map({ container: "map", style, ...view, attributionControl: false, interactive: false, fadeDuration: 0, preserveDrawingBuffer: true });
      map.on("error", (e) => errors.push(String(e.error?.message ?? e.error ?? e)));
      await new Promise((done) => map.once("idle", done));
      return errors;
    },
    { style, view: VIEW },
  );
  if (errors.length) console.warn(`${name}: ${[...new Set(errors)].slice(0, 5).join(" | ")}`);
  await page.locator("#map").screenshot({ path: path.join(outDir, `${name}.png`) });
  console.log(`rendered ${name}`);
}
await browser.close();
server.close();

// Road (auto): light above the diagonal, dark below it.
const px = `${W * SCALE}x${H * SCALE}`;
execFileSync("magick", [
  path.join(outDir, "light.png"),
  "(", path.join(outDir, "dark.png"), "(", "-size", px, "xc:black", "-fill", "white", "-draw", `polygon ${W * SCALE},0 ${W * SCALE},${H * SCALE} 0,${H * SCALE}`, ")", "-alpha", "off", "-compose", "CopyOpacity", "-composite", ")",
  "-compose", "Over", "-composite", path.join(outDir, "road.png"),
]);
for (const name of [...Object.keys(SHOTS), "road"]) {
  const f = path.join(outDir, `${name}.png`);
  execFileSync("magick", [f, "-strip", "-alpha", "off", ...(name === "satellite" ? ["-colors", "160"] : ["-colors", "96"]), `PNG8:${f}`]);
}
console.log(`wrote ${Object.keys(SHOTS).length + 1} thumbnails to ${outDir}`);
