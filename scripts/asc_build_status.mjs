#!/usr/bin/env node
// App Store Connect build status (TestFlight), via the team API key.
//   node scripts/asc_build_status.mjs          -> last 3 uploaded builds and their processing state
//   node scripts/asc_build_status.mjs 53       -> plus build 53's beta groups and beta review state
//   node scripts/asc_build_status.mjs 53 --wait -> poll every 30 s until build 53 is VALID (or fails), max 20 min
// Key: ~/.appstoreconnect/private_keys/AuthKey_<KID>.p8 (never commit it). KID / issuer are identifiers, not secrets.
import { readFileSync } from "node:fs";
import { createSign } from "node:crypto";

const KID = process.env.ASC_KEY_ID ?? "P9GKN2934W";
const ISS = process.env.ASC_ISSUER_ID ?? "8dc71673-9c04-4541-b149-432a4dc0be48";
const API = "https://api.appstoreconnect.apple.com";

function token() {
  const key = readFileSync(`${process.env.HOME}/.appstoreconnect/private_keys/AuthKey_${KID}.p8`, "utf8");
  const b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const data = `${b({ alg: "ES256", kid: KID, typ: "JWT" })}.${b({ iss: ISS, iat: now, exp: now + 600, aud: "appstoreconnect-v1" })}`;
  const sig = createSign("SHA256").update(data).sign({ key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${data}.${sig}`;
}
const get = async (u) => {
  const r = await fetch(API + u, { headers: { Authorization: `Bearer ${token()}` } });
  const j = await r.json();
  if (!r.ok) throw new Error(`HTTP ${r.status} ${JSON.stringify(j.errors ?? j).slice(0, 300)}`);
  return j;
};

async function latest() {
  const j = await get("/v1/builds?sort=-uploadedDate&limit=3&fields[builds]=version,processingState,uploadedDate");
  return j.data.map((x) => ({ id: x.id, version: x.attributes.version, state: x.attributes.processingState }));
}

const [want, flag] = process.argv.slice(2);
const stamp = () => new Date().toTimeString().slice(0, 8);

if (flag === "--wait" && want) {
  for (let i = 0; i < 40; i++) {
    const b = await latest();
    console.log(stamp(), b.map((x) => `${x.version}:${x.state}`).join(", "));
    const hit = b.find((x) => x.version === want);
    if (hit?.state === "VALID") process.exit(0);
    if (hit && ["INVALID", "FAILED"].includes(hit.state)) process.exit(2);
    await new Promise((r) => setTimeout(r, 30_000));
  }
  console.log("timed out waiting for", want);
  process.exit(1);
}

const b = await latest();
console.log("latest:", b.map((x) => `${x.version}:${x.state}`).join(", "));
if (want) {
  const j = await get(`/v1/builds?filter[version]=${encodeURIComponent(want)}&fields[builds]=version,processingState,expired`);
  const build = j.data[0];
  if (!build) { console.log("build", want, "not found"); process.exit(1); }
  console.log("build", want, build.attributes.processingState, "expired:", build.attributes.expired);
  const g = await get(`/v1/betaGroups?filter[builds]=${build.id}&fields[betaGroups]=name,isInternalGroup`);
  console.log("groups:", g.data.map((x) => `${x.attributes.name}${x.attributes.isInternalGroup ? " (internal)" : ""}`).join(", ") || "none");
  const d = await get(`/v1/builds/${build.id}/buildBetaDetail?fields[buildBetaDetails]=internalBuildState,externalBuildState`);
  console.log("beta state:", JSON.stringify(d.data?.attributes));
}
