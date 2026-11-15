// Generates link_radio_golden.json: the website's own plan-link maths (meshcore-insights src/lib/plan/link.ts linkAnswer,
// src/lib/tools/coverage.ts profileLink) over the three test profiles of plan_tools_golden.json, at three radios
// (US 910.525 MHz SF7, EU/UK narrow 869.618 MHz SF8, EU 869.525 MHz 250 kHz SF11), several heights and all directions.
// The app's lib/core/plan/link_model.dart must reproduce every number (test/core/plan/link_radio_golden_test.dart).
// Run inside a meshcore-insights checkout (its imports are relative to the repo root and its tsconfig resolves "@/"):
//   cd <meshcore-insights> && cp <meshsonar>/test/fixtures/plan_native/gen_link_radio_golden.ts .gen.ts && bun .gen.ts <meshsonar>; rm .gen.ts
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { linkAnswer, type LinkInput } from "./src/lib/plan/link";
import { profileLink, radioModel, radioSensitivityDbm, radioNoiseDbm, CLUTTER_DEFAULT } from "./src/lib/tools/coverage";

const app = process.argv[2];
if (!app) throw new Error("usage: bun gen_link_radio_golden.ts <meshsonar checkout>");
const g = JSON.parse(readFileSync(join(app, "test/fixtures/plan_tools_golden.json"), "utf8")).link;
const radios = [
  { freqMHz: 910.525, bwKHz: 62.5, sf: 7, cr: 5 },
  { freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 8 },
  { freqMHz: 869.525, bwKHz: 250, sf: 11, cr: 5 },
];
const heights: Array<[number, number]> = [[6, 6], [10, 1.5], [30, 8]];
const directions = ["down", "up", "both"] as const;
// the calibrated default and a light-clutter estimate (open country), so every verdict state appears
const clutters = [CLUTTER_DEFAULT, { endpointDb: 0, dbPerKm: 2, canopyM: 10 }];
const a = { lat: 37.1, lon: -80.2 }, b = { lat: 37.12, lon: -80.14 };
const cases: unknown[] = [];
for (const radio of radios) {
  const model = radioModel(radio);
  for (const p of g.profiles) {
    for (const [ha, hb] of heights) {
      for (const clutter of clutters) for (const direction of directions) {
        const x: LinkInput = {
          a, b, km: p.km, haM: ha, hbM: hb, radio, clutter, direction,
          aTxDbm: 22, bTxDbm: 20, aGainDbi: 3, bGainDbi: 5, aKey: null, bKey: null,
        };
        const ans = linkAnswer(x, p.ground, { terrain: { source: "test", samples: p.ground.length }, measured: null, regionCode: null, asOf: "2026-11-15T00:00:00Z" });
        const n = p.ground.length;
        const dist = p.ground.map((_: number, i: number) => (i / (n - 1)) * p.km * 1000);
        const pl = profileLink(dist, p.ground, {
          a: { lat: a.lat, lon: a.lon, heightM: ha, txDbm: 22, gainDbi: 3 },
          b: { lat: b.lat, lon: b.lon, heightM: hb, txDbm: 20, gainDbi: 5 },
          clutter, radio: model,
        });
        cases.push({
          radio, profile: p.name, haM: ha, hbM: hb, clutter: { canopyM: clutter.canopyM, dbPerKm: clutter.dbPerKm }, direction,
          raw: { fsplDb: pl.fsplDb, diffractionDb: pl.diffractionDb, clutterDb: pl.clutterDb, pathLossDb: pl.pathLossDb, abDb: pl.abDb, baDb: pl.baDb, los: pl.los },
          answer: { km: ans.km, fresnelClearancePct: ans.fresnelClearancePct, tightest: ans.tightest, ridge: ans.ridge, odds: ans.odds, tier: ans.tier, verdict: ans.verdict, marginDb: ans.marginDb, downDb: ans.downDb, upDb: ans.upDb },
        });
      }
    }
  }
}
const sens = radios.map((r) => ({ radio: r, sensitivityDbm: radioSensitivityDbm(radioModel(r)), noiseFloorDbm: radioNoiseDbm(radioModel(r)), lambdaM: radioModel(r).lambdaM }));
writeFileSync(join(app, "test/fixtures/plan_native/link_radio_golden.json"), JSON.stringify({ generatedFrom: "meshcore-insights src/lib/plan/link.ts + src/lib/tools/coverage.ts (release 0.38 S1)", ends: { a: { txDbm: 22, gainDbi: 3 }, b: { txDbm: 20, gainDbi: 5 } }, radios: sens, cases }, null, 1) + "\n");
console.log(`wrote ${cases.length} cases`);
