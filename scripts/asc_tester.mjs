#!/usr/bin/env node
// App Store Connect internal TestFlight tester, via the team API key.
//   node scripts/asc_tester.mjs <email>          -> ASC user / pending invite status + members of the internal group
//   node scripts/asc_tester.mjs <email> --add    -> add that accepted ASC user to the internal group (idempotent)
// Group defaults to the internal "Andy" group (override with ASC_GROUP=<name>).
// An internal tester must be an ACCEPTED App Store Connect user: until the person accepts Apple's
// email invite, --add exits 3 and changes nothing.
// Key: ~/.appstoreconnect/private_keys/AuthKey_<KID>.p8 (never commit it). KID / issuer are identifiers, not secrets.
import { readFileSync } from "node:fs";
import { createSign } from "node:crypto";

const KID = process.env.ASC_KEY_ID ?? "P9GKN2934W";
const ISS = process.env.ASC_ISSUER_ID ?? "8dc71673-9c04-4541-b149-432a4dc0be48";
const GROUP = process.env.ASC_GROUP ?? "Andy";
const API = "https://api.appstoreconnect.apple.com";

function token() {
  const key = readFileSync(`${process.env.HOME}/.appstoreconnect/private_keys/AuthKey_${KID}.p8`, "utf8");
  const b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const data = `${b({ alg: "ES256", kid: KID, typ: "JWT" })}.${b({ iss: ISS, iat: now, exp: now + 600, aud: "appstoreconnect-v1" })}`;
  const sig = createSign("SHA256").update(data).sign({ key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${data}.${sig}`;
}
async function call(method, u, body) {
  const r = await fetch(API + u, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const t = await r.text();
  const j = t ? JSON.parse(t) : {};
  if (!r.ok) throw new Error(`HTTP ${r.status} ${JSON.stringify(j.errors ?? j).slice(0, 400)}`);
  return j;
}

const [email, flag] = process.argv.slice(2);
if (!email) { console.error("usage: asc_tester.mjs <email> [--add]"); process.exit(1); }
const e = email.toLowerCase();

const users = await call("GET", `/v1/users?filter[username]=${encodeURIComponent(e)}&fields[users]=username,firstName,lastName,roles`);
const user = users.data[0];
const inv = await call("GET", `/v1/userInvitations?filter[email]=${encodeURIComponent(e)}&fields[userInvitations]=email,roles,expirationDate`);
console.log("ASC user:", user ? `${user.attributes.firstName} ${user.attributes.lastName} ${user.attributes.roles.join(",")}` : "none (not accepted)");
console.log("pending invite:", inv.data.map((x) => `${x.attributes.roles.join(",")} expires ${x.attributes.expirationDate}`).join("; ") || "none");

const groups = await call("GET", `/v1/betaGroups?filter[name]=${encodeURIComponent(GROUP)}&fields[betaGroups]=name,isInternalGroup`);
const g = groups.data.find((x) => x.attributes.name === GROUP && x.attributes.isInternalGroup);
if (!g) { console.error(`internal group "${GROUP}" not found`); process.exit(1); }
const members = await call("GET", `/v1/betaGroups/${g.id}/betaTesters?limit=200&fields[betaTesters]=email,firstName,lastName,state`);
const inGroup = members.data.find((x) => (x.attributes.email ?? "").toLowerCase() === e);
console.log(`group "${GROUP}":`, members.data.map((x) => `${x.attributes.firstName} ${x.attributes.lastName} ${x.attributes.state}`).join(" | "));
console.log("in group:", inGroup ? `yes (${inGroup.attributes.state})` : "no");

if (flag === "--add") {
  if (inGroup) process.exit(0);
  if (!user) { console.log("cannot add: invite not accepted yet"); process.exit(3); }
  const r = await call("POST", "/v1/betaTesters", {
    data: {
      type: "betaTesters",
      attributes: { email: e, firstName: user.attributes.firstName, lastName: user.attributes.lastName },
      relationships: { betaGroups: { data: [{ type: "betaGroups", id: g.id }] } },
    },
  });
  console.log("added to group, tester id", r.data.id);
}
